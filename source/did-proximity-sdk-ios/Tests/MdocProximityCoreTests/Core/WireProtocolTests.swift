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

final class WireProtocolTests: XCTestCase {
    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }


    override func tearDown() { SessionRegistry.release() }

    // 첫 메시지에 eReaderKey 가 **원본 바이트로** 실려야 한다
    func testSessionEstablishmentRoundTrip() throws {
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(CborEncoder.encode(.map([
            CborPair(.unsigned(1), .unsigned(2))]))))
        let bytes = try SessionCodec.encodeEstablishment(eReaderKeyBytes: erk, data: Data([0xAA, 0xBB]))
        let back = try SessionCodec.decodeEstablishment(bytes)
        XCTAssertEqual(back.eReaderKeyBytes.raw, erk.raw, "eReaderKeyBytes 는 원본 그대로여야 한다")
        XCTAssertEqual(back.data, Data([0xAA, 0xBB]))
    }

    // 종료는 status 만 담는다
    func testSessionDataTermination() throws {
        let bytes = SessionCodec.encodeData(SessionData.terminate)
        XCTAssertEqual(bytes.hex, "a166737461747573" + "14")   // {"status": 20}
        let back = try SessionCodec.decodeData(bytes)
        XCTAssertNil(back.data)
        XCTAssertEqual(back.status, 20)
    }

    // **목록 하나가 전부다.** NFC 로 탭했어도 목록이 BLE 를 앞세우면 BLE 로 넘어가고,
    // 그 링크를 유지하려면 그 세션의 목록을 `[.nfc, .ble]` 로 둔다
    func testPriorityListIsTheOnlyRule() {
        let both: [TransmissionTechnology] = [.nfc, .ble(.peripheralServer)]
        XCTAssertEqual(TransportSelection.select(
            advertised: both, priority: [.ble, .nfc], blePreferredMode: .central, available: both),
            .ble(.peripheralServer), "기본 목록은 NFC 탭 뒤에도 BLE 다 — 실사용 주 경로")
        XCTAssertEqual(TransportSelection.select(
            advertised: both, priority: [.nfc, .ble], blePreferredMode: .central, available: both),
            .nfc, "링크를 유지하려면 목록으로 말한다")
        // 상대가 NFC 만 광고하면 기본 목록에서도 NFC — 허용 목록에 있으므로 폴백
        XCTAssertEqual(TransportSelection.select(
            advertised: [.nfc], priority: [.ble, .nfc], blePreferredMode: .central, available: both), .nfc)
    }

    // Wi-Fi Aware 는 케이스만 있고 iOS 는 능력이 걸러 늘 건너뛴다
    func testWifiAwareIsSkippedOnIos() {
        XCTAssertEqual(TransportSelection.select(
            advertised: [.wifiAware, .nfc], priority: [.ble, .nfc, .wifiAware], blePreferredMode: .central,
            available: [.nfc]), .nfc)
        XCTAssertNil(TransportSelection.select(
            advertised: [.wifiAware], priority: [.ble, .nfc, .wifiAware], blePreferredMode: .central,
            available: [.nfc, .ble(.peripheralServer)]))
        XCTAssertEqual(MdocReaderConfiguration().transmissionPriority, [.ble, .nfc, .wifiAware], "맨 뒤")
        XCTAssertEqual(MdocCapabilities.current().mdocReader.wifiAware, .unsupported(reason: .vendorPolicy))
        XCTAssertEqual(RoleCapabilities(ble: .supported, nfc: .supported,
                                        wifiAware: .unsupported(reason: .vendorPolicy))
                           .blockingError(among: [.wifiAware]),
                       .wifiAwareUnavailable(reason: .vendorPolicy), "같은 어휘")
    }

    // 3중 교집합. **목록에서 뺀 것은 상대가 광고해도 고르지 않는다**
    func testIntersection() {
        XCTAssertEqual(TransportSelection.select(
            advertised: [.ble(.centralClient), .ble(.peripheralServer)],
            priority: [.ble, .nfc], blePreferredMode: .central,
            available: [.ble(.peripheralServer)]),           // 리더가 central 을 못 쓴다
            .ble(.peripheralServer))

        // 교집합이 비면 nil — 상위가 unsupportedTransmissionTechnology 로 실패시킨다
        XCTAssertNil(TransportSelection.select(
            advertised: [.nfc], priority: [.ble], blePreferredMode: .central,
            available: [.ble(.peripheralServer)]))
    }

    // BLE 는 목록에 한 항목이고 **모드는 `blePreferredMode` 가 가른다.** 상대가 둘 다
    // 광고했을 때만 선호가 작동하고, 하나만 광고하면 선호와 무관하게 그것이다
    func testBlePreferredModeAppliesOnlyWhenBothAdvertised() {
        let both: [TransmissionTechnology] = [.ble(.centralClient), .ble(.peripheralServer)]
        let all: [TransmissionTechnology] = [.ble(.centralClient), .ble(.peripheralServer), .nfc]
        XCTAssertEqual(TransportSelection.select(
            advertised: both, priority: [.ble], blePreferredMode: .central, available: all),
            .ble(.centralClient), "central 선호 — 표준의 should 쪽")
        XCTAssertEqual(TransportSelection.select(
            advertised: both, priority: [.ble], blePreferredMode: .peripheral, available: all),
            .ble(.peripheralServer))
        // 상대가 peripheral 만 광고 — central 선호여도 peripheral 이다 (선호이지 허용 목록이 아니다)
        XCTAssertEqual(TransportSelection.select(
            advertised: [.ble(.peripheralServer)], priority: [.ble],
            blePreferredMode: .central, available: all),
            .ble(.peripheralServer))
    }

    // 상대가 status 만 보내오면 failed 로 가고 terminatedByPeer 가 실린다
    func testPeerTerminationSurfaces() async throws {
        let (rl, ml) = LoopbackTransport.pair()
        let trust = DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() }
        let reader = MdocReaderSession(transport: rl, trust: trust)
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        reader.begin(transcript: SessionTranscriptBuilder.qr(deviceEngagementBytes: erk,
                                                            eReaderKeyBytes: erk),
                     sharedSecret: Data(repeating: 1, count: 32), eReaderKeyBytes: erk)

        Task {   // mdoc 이 거부한다 — 빈 DeviceResponse 를 만들지 않는다
            _ = await ml.nextMessage()
            try? await ml.send(SessionCodec.encodeData(SessionData.terminate))
        }
        do {
            _ = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date())
            XCTFail("terminatedByPeer 가 나와야 한다")
        } catch {
            guard case MdocProximityError.terminatedByPeer(let status) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(status, 20)
            XCTAssertEqual(reader.state, .failed)
        }
    }

    // awaitingResponse 타임아웃. 값만 있고 시계가 없던 것을 강제한다
    func testResponseTimeoutFires() async throws {
        var config = MdocReaderConfiguration()
        config.responseTimeout = 0.2
        let (rl, ml) = LoopbackTransport.pair()
        let trust = DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() }
        let reader = MdocReaderSession(configuration: config, transport: rl, trust: trust)
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        reader.begin(transcript: SessionTranscriptBuilder.qr(deviceEngagementBytes: erk,
                                                            eReaderKeyBytes: erk),
                     sharedSecret: Data(repeating: 2, count: 32), eReaderKeyBytes: erk)

        Task { _ = await ml.nextMessage() }      // 받기만 하고 답하지 않는다
        do {
            _ = try await reader.request([ItemsRequestPresets.identity], at: Date())
            XCTFail("타임아웃이 나야 한다")
        } catch {
            XCTAssertEqual(error as? MdocProximityError, .responseTimeout, "설정 이름과 같은 에러다")
            XCTAssertEqual(reader.state, .failed)
        }
    }
}
