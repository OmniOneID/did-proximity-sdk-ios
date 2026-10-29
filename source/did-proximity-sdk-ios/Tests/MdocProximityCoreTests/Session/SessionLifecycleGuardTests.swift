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
@_spi(MdocInternal) @testable import MdocNFC
@_spi(MdocInternal) @testable import MdocReader

/// 세션 등록과 종단 상태 불변의 회귀 — 2026-09-29 코드 리뷰에서 드러난 것들.
final class SessionLifecycleGuardTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    override func tearDown() { SessionRegistry.release() }

    // MARK: - 등록

    /// 증표가 다르면 풀지 않는다 — 이미 푼 증표로 다시 불러도 다음 등록은 남는다
    func testReleaseWithStaleClaimKeepsOtherRegistration() throws {
        let first = try SessionRegistry.claim("first")
        SessionRegistry.release(first)
        let second = try SessionRegistry.claim("second")
        SessionRegistry.release(first)
        XCTAssertTrue(SessionRegistry.isActive, "이미 푼 증표가 다른 세션의 등록을 지우면 안 된다")
        SessionRegistry.release(second)
        XCTAssertFalse(SessionRegistry.isActive)
    }

    /// 등록한 적 없는 세션(`idle`)의 `terminate()` 는 다른 세션의 등록을 풀지 않는다
    func testIdleTerminateDoesNotReleaseAnotherSession() throws {
        let other = try SessionRegistry.claim("other")
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        MdocDeviceSession(transport: mdocLink).terminate()
        MdocReaderSession(configuration: verifyingReaderConfiguration(), transport: readerLink,
                          trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() }).terminate()
        XCTAssertTrue(SessionRegistry.isActive)
        SessionRegistry.release(other)
    }

    /// 종단 상태에서 `terminate()` 를 두 번 불러도 두 번째는 그 사이 열린 세션을 건드리지 않는다
    func testSecondTerminateDoesNotReleaseNextSession() async throws {
        let (_, mdocLink) = LoopbackTransport.pair()
        let mdoc = MdocDeviceSession(transport: mdocLink)
        _ = try await mdoc.start(technology: .qr)
        mdoc.terminate()
        XCTAssertFalse(SessionRegistry.isActive)
        let next = try SessionRegistry.claim("next")
        mdoc.terminate()
        XCTAssertTrue(SessionRegistry.isActive, "끝난 세션의 terminate() 가 다음 세션의 등록을 지웠다")
        SessionRegistry.release(next)
    }

    // MARK: - start() 중 terminate()

    /// `open` 을 기다리는 사이 `terminate()` 가 오면 — open 이 성공해도 `engaging` 으로 되살아나지 않는다
    func testTerminateDuringOpenIsNotRevivedBySuccess() async throws {
        try await terminateDuringOpen(openFails: false)
    }

    /// open 이 실패해도 `terminated` 를 `failed` 로 덮지 않고, 등록을 한 번 더 풀지 않는다
    func testTerminateDuringOpenIsNotOverwrittenByFailure() async throws {
        try await terminateDuringOpen(openFails: true)
    }

    private func terminateDuringOpen(openFails: Bool) async throws {
        let link = GatedOpenTransport()
        let mdoc = MdocDeviceSession(transport: link)
        let start = Task { try await mdoc.start(technology: .qr) }
        for _ in 0..<200 where !link.isOpening { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(link.isOpening)
        mdoc.terminate()
        XCTAssertEqual(mdoc.state, .terminated)
        let other = try SessionRegistry.claim("other")
        link.finishOpen(failing: openFails)
        do { _ = try await start.value; XCTFail("종료된 start 는 payload 를 돌려주지 않는다") } catch {}
        XCTAssertEqual(mdoc.state, .terminated)
        XCTAssertTrue(SessionRegistry.isActive, "start 의 실패 경로가 다른 세션의 등록을 지웠다")
        SessionRegistry.release(other)
    }

    // MARK: - request() 중 terminate()

    /// 응답을 기다리는 사이 `terminate()` 가 오면 이어지는 링크 오류가 `terminated` 를 `failed` 로 덮지 않는다
    func testReaderTerminateDuringAwaitingResponseStaysTerminated() async throws {
        let eD = P256.KeyAgreement.PrivateKey(), eR = P256.KeyAgreement.PrivateKey()
        let zab = try eR.sharedSecretFromKeyAgreement(with: eD.publicKey).withUnsafeBytes { Data($0) }
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)
        let (rl, ml) = LoopbackTransport.pair()
        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(responseTimeout: 3),
                                       transport: rl,
                                       trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() })
        let mdoc = MdocDeviceSession(transport: ml)             // 응답하지 않는다 — 리더는 계속 기다린다
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        reader.begin(transcript: transcript, sharedSecret: zab, eReaderKeyBytes: erk)

        let request = Task { try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date()) }
        for _ in 0..<200 where reader.state != .awaitingResponse { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(reader.state, .awaitingResponse)
        reader.terminate()
        do {
            _ = try await request.value
            XCTFail("종료된 request 는 돌아오지 않는다")
        } catch {
            XCTAssertTrue(error is CancellationError, "이어진 링크 오류(\(error))를 던지면 앱이 '연결 끊김' 으로 읽는다")
        }
        XCTAssertEqual(reader.state, .terminated, "terminate() 뒤의 링크 오류가 상태를 덮었다")
        mdoc.terminate()
    }

    /// 검증하는 사이 `terminate()` 가 오면 결과를 돌려주지 않는다 — 앱이 끝낸 거래의 데이터는
    /// 넘기지 않는다 (8.3.2.1.2.1)
    func testReaderTerminateDuringVerifyingDropsResult() async throws {
        let eD = P256.KeyAgreement.PrivateKey(), eR = P256.KeyAgreement.PrivateKey()
        let zab = try eR.sharedSecretFromKeyAgreement(with: eD.publicKey).withUnsafeBytes { Data($0) }
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let trust = GatedTrust(key: issuerKey.publicKey.x963Representation)
        let (rl, ml) = LoopbackTransport.pair()
        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(responseTimeout: 3),
                                       transport: rl, trust: trust)
        let mdoc = MdocDeviceSession(transport: ml)
        let responder = AutoResponder(session: mdoc) {
            Fixtures.response(transcript: transcript, issuerKey: issuerKey, deviceKey: deviceKey, did: "did:omn:issuer")
        }
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        reader.begin(transcript: transcript, sharedSecret: zab, eReaderKeyBytes: erk)

        let request = Task { try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date()) }
        for _ in 0..<200 where !trust.isEvaluating { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(reader.state, .verifying)
        reader.terminate()
        trust.release()
        do {
            _ = try await request.value
            XCTFail("terminate() 뒤에 검증 결과를 돌려줬다")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(reader.state, .terminated)
        _ = responder
        mdoc.terminate()
    }

    // MARK: - connect() 중 terminate()

    /// 전송체가 만들어지는 순간 `terminate()` 가 오면 — 그 전송체를 열지 않고 닫는다. 전에는
    /// `terminate()` 가 전송체를 보지 못한 채 끝나고, 이어서 링크가 서면 `connected` 로 되살아났다
    func testReaderTerminateBeforeTransportIsAssignedDoesNotOpenIt() async throws {
        let source = CountingTagSource()
        let factory = HookedFactory()
        let reader = MdocReaderSession(configuration: MdocReaderConfiguration(),
                                       trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
                                       transportFactory: factory, nfcTagSource: source)
        factory.onMake = { reader.terminate() }
        do {
            try await reader.connect(to: try bleEngagement())
            XCTFail("종료된 connect 는 돌아오지 않는다")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(reader.state, .terminated)
        XCTAssertFalse(factory.transport.opened, "terminate() 뒤에 링크를 열었다")
        XCTAssertTrue(factory.transport.closed)
        XCTAssertEqual(source.cancelCount, 0, "QR 경로의 terminate() 가 NFC 소스를 취소하면 다음 connectViaNFC() 가 곧바로 끝난다")
        XCTAssertFalse(SessionRegistry.isActive)
    }

    /// 링크 수립을 기다리는 사이 `terminate()` 가 오면 `connect` 는 `CancellationError` 다 —
    /// 이어지는 링크 오류(`peerDisconnected`)를 던지지 않는다 (`connecting` 의 취소)
    func testReaderTerminateWhileWaitingForLinkThrowsCancellation() async throws {
        let factory = HookedFactory()
        factory.transport.signalsReady = false
        let reader = MdocReaderSession(configuration: MdocReaderConfiguration(),
                                       trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
                                       transportFactory: factory, nfcTagSource: CountingTagSource())
        let connect = Task { try await reader.connect(to: try bleEngagement()) }
        for _ in 0..<200 where !factory.transport.opened { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(factory.transport.opened)
        reader.terminate()
        let other = try SessionRegistry.claim("other")
        do {
            try await connect.value
            XCTFail("종료된 connect 는 돌아오지 않는다")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(reader.state, .terminated)
        XCTAssertTrue(SessionRegistry.isActive, "connect 의 실패 경로가 다른 세션의 등록을 지웠다")
        SessionRegistry.release(other)
    }

    /// `terminate()` 뒤의 `begin()` 은 세션을 `connected` 로 되살리지 않는다 — 링크가 선 직후
    /// `begin()` 직전에 온 `terminate()` 의 자리
    func testReaderBeginAfterTerminateStaysTerminated() throws {
        let (readerLink, _) = LoopbackTransport.pair()
        let reader = MdocReaderSession(configuration: MdocReaderConfiguration(), transport: readerLink,
                                       trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() })
        reader.terminate()
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)
        reader.begin(transcript: transcript, sharedSecret: Data(repeating: 1, count: 32), eReaderKeyBytes: erk)
        XCTAssertEqual(reader.state, .terminated)
    }

    private func bleEngagement() throws -> EngagementPayload {
        try EngagementPayload.make(try EngagementCodec.encode(
            eDeviceKeyBytes: EphemeralKeyPair().keyBytes,
            retrievalMethods: [DeviceRetrievalMethod(type: 2, version: 1, options: .map([
                CborPair(.unsigned(0), .bool(true)), CborPair(.unsigned(1), .bool(false)),
                CborPair(.unsigned(10), .bytes(Data(repeating: 9, count: 16)))]))]))
    }

    // MARK: - engagementTimeout

    /// 소수부를 버리지 않는다 — 0.5 초가 0 초가 되면 `start` 직후 곧바로 실패했다
    func testFractionalEngagementTimeout() async throws {
        let (_, mdocLink) = LoopbackTransport.pair()
        var cfg = MdocDeviceConfiguration()
        cfg.engagementTimeout = 0.5
        let mdoc = MdocDeviceSession(configuration: cfg, transport: mdocLink)
        _ = try await mdoc.start(technology: .qr)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mdoc.state, .engaging, "0.5 초가 지나기 전에 만료됐다")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(mdoc.state, .failed)
        mdoc.terminate()
    }
}

/// `open` 이 테스트가 풀어 줄 때까지 돌아오지 않는 전송체 — `start()` 중의 `terminate()` 를 재현한다
private final class GatedOpenTransport: DataRetrievalTransportProtocol {
    let events: AsyncStream<TransportEvent>
    private let emit: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Error>?

    init() {
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
    }

    var isOpening: Bool { lock.lock(); defer { lock.unlock() }; return gate != nil }

    func open(_ config: TransportConfig) async throws {
        try await withCheckedThrowingContinuation { c in
            lock.lock(); gate = c; lock.unlock()
        }
    }

    func finishOpen(failing: Bool) {
        lock.lock(); let g = gate; gate = nil; lock.unlock()
        if failing { g?.resume(throwing: MdocProximityError.connectionFailed(detail: "stub")) } else { g?.resume() }
    }

    func send(_ message: Data) async throws {}
    func close(_ reason: TransportCloseReason) { emit.finish() }
}

/// 열리면 곧바로 `ready` 를 내는 리더 쪽 전송체 — `signalsReady` 가 거짓이면 링크가 서지 않는다
private final class ReadyOnOpenTransport: DataRetrievalTransportProtocol {
    let events: AsyncStream<TransportEvent>
    private let emit: AsyncStream<TransportEvent>.Continuation
    var signalsReady = true
    // 세션 Task 가 쓰고 테스트가 읽는다
    private let lock = NSLock()
    private var _opened = false
    private var _closed = false
    var opened: Bool { lock.withLock { _opened } }
    var closed: Bool { lock.withLock { _closed } }

    init() {
        var c: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
    }

    func open(_ config: TransportConfig) async throws {
        lock.withLock { _opened = true }
        if signalsReady { emit.yield(.ready) }
    }

    func send(_ message: Data) async throws {}
    func close(_ reason: TransportCloseReason) { lock.withLock { _closed = true }; emit.finish() }
}

/// 전송체를 만드는 순간 `onMake` 를 부른다 — 그 자리에 끼어드는 `terminate()` 를 재현한다
private final class HookedFactory: TransportFactoryProtocol {
    let transport = ReadyOnOpenTransport()
    var onMake: (() -> Void)?
    var availableTechnologies: [TransmissionTechnology] { [.ble(.peripheralServer), .ble(.centralClient)] }
    func makeTransport(_ p: TransportParameters) throws -> DataRetrievalTransportProtocol {
        onMake?()
        return transport
    }
}

/// 테스트가 풀어 줄 때까지 판정을 돌려주지 않는 신뢰 평가기 — `verifying` 중의 `terminate()` 를 재현한다
private final class GatedTrust: TrustEvaluatorProtocol {
    private let inner: DIDIssuerKeyResolver
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    init(key: Data) {
        inner = DIDIssuerKeyResolver(trustedIssuers: ["did:omn:issuer"]) { _, _ in key }
    }

    var isEvaluating: Bool { lock.lock(); defer { lock.unlock() }; return gate != nil }

    func evaluate(header: COSEHeaderSummary, purpose: TrustPurpose, at date: Date) async -> IssuerKeyResolution {
        await withCheckedContinuation { c in
            lock.lock()
            if released { lock.unlock(); c.resume() } else { gate = c; lock.unlock() }
        }
        return await inner.evaluate(header: header, purpose: purpose, at: date)
    }

    func release() {
        lock.lock(); released = true; let g = gate; gate = nil; lock.unlock()
        g?.resume()
    }
}

private final class CountingTagSource: NfcTagSource {
    private(set) var cancelCount = 0
    func openChannel() async throws -> Iso7816Channel { throw CancellationError() }
    func cancel() { cancelCount += 1 }
}
