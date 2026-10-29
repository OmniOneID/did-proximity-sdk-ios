/*
 * Copyright 2026 OmniOne.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import XCTest
import CryptoKit
@_spi(MdocInternal) @testable import MdocProximityCore
@_spi(MdocInternal) @testable import MdocTrust
@_spi(MdocInternal) @testable import MdocDevice
@_spi(MdocInternal) @testable import MdocReader

/// 세션 종료 경로 (9.1.1.4 · Table 20) — 종단 상태에서도 종료 통지를 보내고,
/// 상대의 상태 코드를 받으면 링크를 내리고, 송신 실패가 상태를 멈춰 두지 않는다.
final class SessionTerminationTests: XCTestCase, MdocDeviceSessionDelegate {

    private var failure: MdocProximityError?
    private var states: [MdocDeviceState] = []
    private var finished = 0

    func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState) { states.append(state) }
    func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data, sessionTranscript: Data) {}
    func mdocSessionDidFinish(_ s: MdocDeviceSession) { finished += 1 }
    func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError) { failure = error }

    override func tearDown() { SessionRegistry.release() }

    private struct Keys {
        let zab: Data
        let transcript: SessionTranscriptBytes
        let erk: OpaqueCBOR
        var readerCipher: SessionCipher { SessionCipher(role: .mdocReader, sharedSecret: zab, transcript: transcript) }
    }

    private func keys() -> Keys {
        let eD = P256.KeyAgreement.PrivateKey(), eR = P256.KeyAgreement.PrivateKey()
        let zab = try! eR.sharedSecretFromKeyAgreement(with: eD.publicKey).withUnsafeBytes { Data($0) }
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        return Keys(zab: zab, transcript: SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk),
                    erk: erk)
    }

    private func mdoc(over link: DataRetrievalTransportProtocol, _ k: Keys) -> MdocDeviceSession {
        let m = MdocDeviceSession(transport: link)
        m.delegate = self
        m.begin(transcript: k.transcript, sharedSecret: k.zab)
        return m
    }

    private func requestBytes(_ k: Keys, _ cipher: SessionCipher) throws -> Data {
        let request = try RequestCodec.encode(DeviceRequest(docRequests: [ItemsRequestPresets.ageOver(18)]))
        return SessionCodec.encodeData(SessionData(data: try cipher.encrypt(request)))
    }

    private func wait(_ m: MdocDeviceSession, until s: MdocDeviceState) async throws {
        for _ in 0..<100 where m.state != s { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(m.state, s)
    }

    /// 다음 메시지 또는 링크 해제까지 읽는다.
    private func next(_ link: LoopbackTransport) async -> TransportEvent? {
        for await ev in link.events {
            switch ev {
            case .message, .peerClosed: return ev
            default: continue
            }
        }
        return nil
    }

    /// 9.1.1.4 — `completed` 뒤 두 번째 요청은 **status 20 으로 종료**한다. 상태는 `completed`
    /// 그대로다(종단 상태 불변). 전에는 링크만 닫아 NFC·L2CAP 리더가 종료 통지를 받지 못했다.
    func testSecondRequestAfterCompletedSendsStatus20() async throws {
        let k = keys()
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let m = mdoc(over: mdocLink, k)
        let cipher = k.readerCipher
        try await readerLink.send(requestBytes(k, cipher))
        try await wait(m, until: .awaitingResponse)
        try await m.respond(deviceResponse: Data([0xa0]))
        XCTAssertEqual(m.state, .completed)
        guard case .message? = await next(readerLink) else { return XCTFail("응답이 먼저 와야 한다") }

        try await readerLink.send(requestBytes(k, cipher))
        guard case .message(let bye)? = await next(readerLink) else { return XCTFail("status 20 이 와야 한다") }
        XCTAssertEqual(try SessionCodec.decodeData(bye).status, 20)
        XCTAssertEqual(m.state, .completed, "completed 는 덮이지 않는다")
        XCTAssertNil(failure)
    }

    /// 9.1.1.4 — `failed` 에서 `terminate()` 도 세션이 있으면 status 20 을 보낸 뒤 닫는다.
    func testTerminateFromFailedSendsStatus20() async throws {
        let k = keys()
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let m = mdoc(over: mdocLink, k)
        try await readerLink.send(SessionCodec.encodeData(SessionData(data: Data([0x00, 0x01]))))
        try await wait(m, until: .failed)
        m.terminate()
        guard case .message(let bye)? = await next(readerLink) else { return XCTFail("status 20 이 와야 한다") }
        XCTAssertEqual(try SessionCodec.decodeData(bye).status, 20)
    }

    /// Table 20 — 상대의 status 10/11 도 세션 종료다. 링크를 내리고 키를 버린다. 다시 부른
    /// `terminate()` 는 상대가 이미 끝낸 세션에 status 20 을 보내지 않는다.
    func testPeerStatus10ClosesLink() async throws {
        let k = keys()
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let m = mdoc(over: mdocLink, k)
        try await readerLink.send(SessionCodec.encodeData(SessionData(status: 10)))
        try await wait(m, until: .failed)
        XCTAssertEqual(failure, .terminatedByPeer(status: 10))
        guard case .peerClosed? = await next(readerLink) else { return XCTFail("링크가 내려가야 한다") }
        m.terminate()
    }

    /// 송신이 실패한 `respond()` 는 `responding` 에 멈추지 않고 `failed` 로 간다. 던진 경로라
    /// `didFailWith` 는 오지 않는다(한 사건은 한 경로로).
    func testRespondSendFailureMovesToFailed() async throws {
        let k = keys()
        let link = SendFailingTransport()
        let m = mdoc(over: link, k)
        try m.receive(requestBytes(k, k.readerCipher))
        XCTAssertEqual(m.state, .awaitingResponse)
        do {
            try await m.respond(deviceResponse: Data([0xa0]))
            XCTFail("송신 실패가 던져져야 한다")
        } catch {}
        XCTAssertEqual(m.state, .failed)
        await drainCallbacks()
        XCTAssertNil(failure)
    }

    /// 응답 송신 중 `terminate()` — 송신이 성공해도 `terminated` 는 `completed` 로 덮이지 않고,
    /// `respond()` 는 `CancellationError` 를 던지며 `mdocSessionDidFinish` 는 오지 않는다(리더 쪽과 같은 규칙).
    /// 전에는 `send` 뒤에 상태를 다시 보지 않아 종료한 세션이 `completed` 로 되살아났다.
    func testTerminateDuringRespondKeepsTerminated() async throws {
        let k = keys()
        let link = GatedSendTransport()
        let m = mdoc(over: link, k)
        try m.receive(requestBytes(k, k.readerCipher))
        XCTAssertEqual(m.state, .awaitingResponse)

        let task = Task { try await m.respond(deviceResponse: Data([0xa0])) }
        await link.waitUntilSendStarted()
        XCTAssertEqual(m.state, .responding)
        m.terminate()
        link.releaseSend()                       // 송신은 성공으로 끝난다

        do { try await task.value; XCTFail("CancellationError 여야 한다") } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(m.state, .terminated)
        await drainCallbacks()
        XCTAssertEqual(finished, 0)
        XCTAssertNil(failure)
    }

    /// `reject()` 도 같다 — 전에는 타이머가 꺼진 채 `awaitingResponse` 에 남았다.
    func testRejectSendFailureMovesToFailed() async throws {
        let k = keys()
        let link = SendFailingTransport()
        let m = mdoc(over: link, k)
        try m.receive(requestBytes(k, k.readerCipher))
        do {
            try await m.reject()
            XCTFail("송신 실패가 던져져야 한다")
        } catch {}
        XCTAssertEqual(m.state, .failed)
    }

    /// 리더 — 상대가 상태 코드만 보내면 `failed` 와 함께 링크를 내린다(Table 20).
    func testReaderClosesLinkOnPeerStatus() async throws {
        let k = keys()
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let trust = DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() }
        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(responseTimeout: 3),
                                       transport: readerLink, trust: trust)
        reader.begin(transcript: k.transcript, sharedSecret: k.zab, eReaderKeyBytes: k.erk)
        let task = Task { try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date()) }
        guard case .message? = await next(mdocLink) else { return XCTFail("요청이 와야 한다") }
        try await mdocLink.send(SessionCodec.encodeData(SessionData(status: 11)))
        do { _ = try await task.value; XCTFail("terminatedByPeer 여야 한다") } catch {
            XCTAssertEqual(error as? MdocProximityError, .terminatedByPeer(status: 11))
        }
        XCTAssertEqual(reader.state, .failed)
        guard case .peerClosed? = await next(mdocLink) else { return XCTFail("리더가 링크를 내려야 한다") }
    }
}

private final class SendFailingTransport: DataRetrievalTransportProtocol {
    let events: AsyncStream<TransportEvent>
    init() { events = AsyncStream { _ in } }
    func open(_ config: TransportConfig) async throws {}
    func send(_ message: Data) async throws { throw MdocProximityError.peerDisconnected }
    func close(_ reason: TransportCloseReason) {}
}

/// 첫 `send` 를 `releaseSend()` 까지 붙잡아 두는 전송체. 그 뒤의 `send`(종료 통지 등)는 바로 끝난다.
private final class GatedSendTransport: DataRetrievalTransportProtocol, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let lock = NSLock()
    private var gated = true
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    init() { events = AsyncStream { _ in } }
    func open(_ config: TransportConfig) async throws {}
    func close(_ reason: TransportCloseReason) {}

    func send(_ message: Data) async throws {
        lock.lock()
        guard gated else { lock.unlock(); return }
        gated = false
        didStart = true
        let s = started; started = nil
        lock.unlock()
        s?.resume()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released { lock.unlock(); c.resume() } else { gate = c; lock.unlock() }
        }
    }

    func waitUntilSendStarted() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if didStart { lock.unlock(); c.resume() } else { started = c; lock.unlock() }
        }
    }

    func releaseSend() {
        lock.lock(); released = true; let g = gate; gate = nil; lock.unlock()
        g?.resume()
    }
}
