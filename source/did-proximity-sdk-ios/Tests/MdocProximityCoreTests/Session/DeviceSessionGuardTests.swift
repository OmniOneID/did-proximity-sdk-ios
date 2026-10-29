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

/// mdoc 세션의 안전망 — CA 앱 실기기 시험(2026-09-11)에서 드러난 세 구멍의 세션 층 회귀.
/// 전송체 층(GATT 서버의 큐 비움·구독 해제)은 CoreBluetooth 없이 재현할 수 없어 하네스가 맡는다.
final class DeviceSessionGuardTests: XCTestCase, MdocDeviceSessionDelegate {

    private var failure: MdocProximityError?
    private var finished = false
    private var states: [MdocDeviceState] = []
    private let failed = XCTestExpectation(description: "didFailWith")

    func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState) { states.append(state) }
    func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data, sessionTranscript: Data) {}
    func mdocSessionDidFinish(_ s: MdocDeviceSession) { finished = true }
    func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError) {
        failure = error; failed.fulfill()
    }

    override func tearDown() { SessionRegistry.release() }

    private func pair(responseTimeout: TimeInterval = 60)
        -> (reader: MdocReaderSession, mdoc: MdocDeviceSession) {
        let eD = P256.KeyAgreement.PrivateKey(), eR = P256.KeyAgreement.PrivateKey()
        let zab = try! eR.sharedSecretFromKeyAgreement(with: eD.publicKey).withUnsafeBytes { Data($0) }
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)
        let (rl, ml) = LoopbackTransport.pair()
        let trust = DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() }
        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(responseTimeout: 3),
                                       transport: rl, trust: trust)
        var cfg = MdocDeviceConfiguration()
        cfg.responseTimeout = responseTimeout
        let mdoc = MdocDeviceSession(configuration: cfg, transport: ml)
        mdoc.delegate = self
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        reader.begin(transcript: transcript, sharedSecret: zab, eReaderKeyBytes: erk)
        return (reader, mdoc)
    }

    /// 앱이 `responseTimeout` 안에 respond/reject 하지 않으면 **status 20 을 보내고** failed.
    /// 선언만 있고 한 번도 걸리지 않던 값이다.
    func testResponseTimeoutSendsTerminationAndFails() async throws {
        let (reader, mdoc) = pair(responseTimeout: 0.2)
        do {
            _ = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date())
            XCTFail("리더는 status 20 을 받아야 한다")
        } catch {
            guard case MdocProximityError.terminatedByPeer(let status) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 20, "만료 시 세션 종료 메시지가 먼저 나간다")
        }
        await fulfillment(of: [failed], timeout: 2)
        guard case .responseTimeout? = failure else { return XCTFail("\(String(describing: failure))") }
        XCTAssertEqual(mdoc.state, .failed)
    }

    /// **종단 상태는 뒤늦은 status 20 으로도 덮이지 않는다.** `responseTimeout` 으로 `failed` 가 되고
    /// `didFailWith` 가 나간 뒤 리더의 종료 통지가 오면, 전에는 `terminated` 로 바뀌어 앱이 실패 뒤에
    /// 상태가 또 움직이는 것을 봤다 (종단 상태 불변).
    func testLateTerminationDoesNotOverwriteFailed() async throws {
        let (reader, mdoc) = pair(responseTimeout: 0.2)
        _ = try? await reader.request([ItemsRequestPresets.ageOver(18)], at: Date())
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(mdoc.state, .failed)
        try mdoc.receive(SessionCodec.encodeData(SessionData.terminate))
        XCTAssertEqual(mdoc.state, .failed, "failed → terminated 로 덮이면 안 된다")
        await drainCallbacks()
        XCTAssertEqual(states.filter { $0 == .terminated }.count, 0)
    }

    /// respond 가 제때 오면 타임아웃은 걸리지 않는다 — 취소 경로
    func testRespondCancelsResponseDeadline() async throws {
        let (reader, mdoc) = pair(responseTimeout: 0.2)
        let requestTask = Task { try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date()) }
        // 요청이 도착해 awaitingResponse 가 될 때까지
        for _ in 0..<50 where mdoc.state != .awaitingResponse { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(mdoc.state, .awaitingResponse)
        try await mdoc.reject()                     // 응답 대신 거부 — 데드라인이 취소돼야 한다
        _ = try? await requestTask.value
        try await Task.sleep(nanoseconds: 400_000_000)   // 타임아웃이 살아 있었다면 여기서 fail 이 온다
        XCTAssertNil(failure, "reject 뒤에 responseTimeout 이 걸리면 안 된다")
        XCTAssertEqual(mdoc.state, .terminated)
    }

    /// 같은 세션의 **두 번째 `DeviceRequest`** 는 status 20 을 보내고 `terminated` 로 간다.
    /// 전에는 `terminate()` 뒤에 던진 `invalidState` 를 펌프가 다시 `fail` 로 올려 `failed` 가 됐다.
    func testSecondDeviceRequestTerminatesNotFails() async throws {
        let eD = P256.KeyAgreement.PrivateKey(), eR = P256.KeyAgreement.PrivateKey()
        let zab = try eR.sharedSecretFromKeyAgreement(with: eD.publicKey).withUnsafeBytes { Data($0) }
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let mdoc = MdocDeviceSession(transport: mdocLink)
        mdoc.delegate = self
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        let readerCipher = SessionCipher(role: .mdocReader, sharedSecret: zab, transcript: transcript)
        let request = try RequestCodec.encode(DeviceRequest(docRequests: [ItemsRequestPresets.ageOver(18)]))

        try await readerLink.send(SessionCodec.encodeData(SessionData(data: try readerCipher.encrypt(request))))
        for _ in 0..<50 where mdoc.state != .awaitingResponse { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(mdoc.state, .awaitingResponse)

        try await readerLink.send(SessionCodec.encodeData(SessionData(data: try readerCipher.encrypt(request))))
        for _ in 0..<50 where mdoc.state == .awaitingResponse { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)          // 펌프의 catch 가 돌 시간
        XCTAssertEqual(mdoc.state, .terminated, "두 번째 요청은 failed 가 아니라 terminated 다")
        XCTAssertNil(failure, "상대의 위반이지 앱 오류가 아니다 — didFailWith 는 오지 않는다")
        XCTAssertEqual(states.last, .terminated)
        // 리더 쪽에는 status 20 이 간다
        var bye: Data?
        for await ev in readerLink.events {
            if case .message(let m) = ev { bye = m; break }
        }
        XCTAssertEqual(try SessionCodec.decodeData(XCTUnwrap(bye)).status, 20)
    }

    /// 상대가 조용히 사라지면(전송체 `peerClosed`) mdoc 은 `terminated` 로 간다 — GATT 서버의
    /// 구독 해제가 이 이벤트로 번역된다는 전제 위에 있다.
    func testPeerVanishingTerminatesIdleSession() async throws {
        let (reader, mdoc) = pair()
        XCTAssertEqual(mdoc.state, .sessionEstablished)
        reader.terminate()                          // 리더가 status 20 을 보내고 링크를 닫는다
        for _ in 0..<50 where mdoc.state == .sessionEstablished { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotEqual(mdoc.state, .sessionEstablished, "상대가 사라졌는데 살아 있는 세션은 가짜다")
        XCTAssertNil(failure)
    }
}
