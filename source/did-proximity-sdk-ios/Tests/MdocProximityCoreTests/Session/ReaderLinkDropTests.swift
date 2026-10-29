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
@_spi(MdocInternal) @testable import MdocProximityCore
@_spi(MdocInternal) @testable import MdocTrust
@_spi(MdocInternal) @testable import MdocReader

/// 리더의 오류는 두 경로로 온다 — `connect`/`request` 안이면 throw, **요청 밖에서 링크가 죽으면
/// `didFailWith`**. 같은 사건이 두 경로로 두 번 가지 않는다.
/// 실기기(iPhone 14) 상호운용 시험에서 유휴 중 끊김이 앱에 도달하지 않던 것을 여기에 못 박는다.
final class ReaderLinkDropTests: XCTestCase, MdocReaderSessionDelegate {

    private var failure: MdocProximityError?
    private var states: [MdocReaderState] = []
    private let failed = XCTestExpectation(description: "didFailWith")

    func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState) { states.append(state) }
    func readerSessionDidConnect(_ s: MdocReaderSession) {}
    func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int) {}
    func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError) {
        failure = error; failed.fulfill()
    }

    override func tearDown() { SessionRegistry.release() }

    private func connectedReader() -> (MdocReaderSession, LoopbackTransport) {
        let (rl, ml) = LoopbackTransport.pair()
        let trust = DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() }
        let reader = MdocReaderSession(transport: rl, trust: trust)
        reader.delegate = self
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        reader.begin(transcript: SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk),
                     sharedSecret: Data(repeating: 1, count: 32), eReaderKeyBytes: erk)
        return (reader, ml)
    }

    /// 요청 사이에 홀더가 멀어졌다 — 받을 호출자가 없으므로 델리게이트로 온다
    func testIdleLinkDropReachesDelegate() async {
        let (reader, ml) = connectedReader()
        XCTAssertEqual(reader.state, .connected)
        ml.close(.normal)
        await fulfillment(of: [failed], timeout: 2)
        guard case .peerDisconnected? = failure else { return XCTFail("\(String(describing: failure))") }
        XCTAssertEqual(reader.state, .failed)
        XCTAssertEqual(states.last, .failed)
    }

    /// 요청 중에 끊겼다 — `request` 가 throw 하므로 델리게이트는 **오지 않는다** (이중 전달 금지)
    func testLinkDropDuringRequestThrowsOnly() async throws {
        let (reader, ml) = connectedReader()
        Task {
            _ = await ml.nextMessage()   // SessionEstablishment 를 받은 뒤 링크를 끊는다
            ml.close(.normal)
        }
        do {
            _ = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date())
            XCTFail("peerDisconnected 가 나와야 한다")
        } catch {
            guard case MdocProximityError.peerDisconnected = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(reader.state, .failed)
        // 콜백 큐가 비워질 시간을 준 뒤에도 didFailWith 는 없어야 한다
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(failure, "throw 로 간 오류가 델리게이트로도 오면 앱이 두 번 처리한다")
    }

    /// **`SessionEstablishment` 송신이 throw 하면 세션은 `failed` 다.** 상태를 `awaitingResponse` 로
    /// 바꾼 뒤 보내므로, 여기서 닫지 않으면 `requested` 는 참이고 펌프는 `connected` 에서만 링크 사건을
    /// 올려 — `didChangeState(.failed)` 도 `didFailWith` 도 영영 오지 않았다.
    func testSendFailureDuringRequestFailsSession() async throws {
        final class SendFails: DataRetrievalTransportProtocol {
            let events: AsyncStream<TransportEvent>
            private let emit: AsyncStream<TransportEvent>.Continuation
            init() { var c: AsyncStream<TransportEvent>.Continuation!; events = AsyncStream { c = $0 }; emit = c }
            func open(_ config: TransportConfig) async throws { emit.yield(.ready) }
            func send(_ message: Data) async throws { throw MdocProximityError.peerDisconnected }
            func close(_ reason: TransportCloseReason) { emit.finish() }
        }
        let reader = MdocReaderSession(transport: SendFails(),
                                       trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() })
        reader.delegate = self
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        reader.begin(transcript: SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk),
                     sharedSecret: Data(repeating: 1, count: 32), eReaderKeyBytes: erk)
        do {
            _ = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date())
            XCTFail("송신 실패는 throw 다")
        } catch {
            guard case MdocProximityError.peerDisconnected = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(reader.state, .failed, "awaitingResponse 에 머물면 안 된다")
        await drainCallbacks()
        XCTAssertEqual(states.last, .failed)
        XCTAssertNil(failure, "throw 로 간 오류는 델리게이트로 오지 않는다")
    }

    /// **`connectTimeout` 이 실제로 돌아온다.** 링크가 서지 않는 전송(광고를 못 찾는 스캔)에서
    /// `waitReady()` 가 취소에 응답하지 않아 `Deadline` 이 만료돼도 `connect` 가 영영 돌아오지
    /// 않았다 — 리더 앱 실기기에서 세션이 3분 넘게 `connecting` 이었다 (2026-09-15).
    func testConnectTimeoutFiresWhenLinkNeverComesUp() async throws {
        final class NeverReady: DataRetrievalTransportProtocol {
            let events: AsyncStream<TransportEvent>
            private let emit: AsyncStream<TransportEvent>.Continuation
            private(set) var closed = false
            init() { var c: AsyncStream<TransportEvent>.Continuation!; events = AsyncStream { c = $0 }; emit = c }
            func open(_ config: TransportConfig) async throws {}          // 스캔만 시작하고 상대가 없다
            func send(_ message: Data) async throws {}
            func close(_ reason: TransportCloseReason) { closed = true; emit.finish() }
        }
        final class Factory: TransportFactoryProtocol {
            let transport = NeverReady()
            var availableTechnologies: [TransmissionTechnology] { [.ble(.peripheralServer), .ble(.centralClient)] }
            func makeTransport(_ p: TransportParameters) throws -> DataRetrievalTransportProtocol { transport }
        }
        let engagement = try EngagementCodec.encode(
            eDeviceKeyBytes: EphemeralKeyPair().keyBytes,
            retrievalMethods: [DeviceRetrievalMethod(type: 2, version: 1, options: .map([
                CborPair(.unsigned(0), .bool(true)), CborPair(.unsigned(1), .bool(false)),
                CborPair(.unsigned(10), .bytes(Data(repeating: 9, count: 16)))]))])
        var config = MdocReaderConfiguration()
        config.connectTimeout = 0.2
        let factory = Factory()
        let reader = MdocReaderSession(configuration: config,
                                       trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
                                       transportFactory: factory, nfcTagSource: UnavailableNfcTagSource())
        let started = Date()
        do {
            try await reader.connect(to: try EngagementPayload.make(engagement))
            XCTFail("링크가 서지 않으면 connectTimeout 이다")
        } catch {
            XCTAssertEqual(error as? MdocProximityError, .connectionFailed(detail: "connect timeout"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "타임아웃이 실제로 돌아와야 한다")
        XCTAssertEqual(reader.state, .failed)
        XCTAssertTrue(factory.transport.closed, "실패했으면 전송체를 내려 링크를 놓는다")
        XCTAssertFalse(SessionRegistry.isActive)
    }
}
