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
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
@_spi(MdocInternal) @testable import MdocProximityCore
@_spi(MdocInternal) @testable import MdocNFC

/// CoreNFC 연결부는 실기기가 필요하다. **APDU·체이닝·CC 파싱은 순수 로직**이라 여기서 본다.
final class NfcTests: XCTestCase {

    // mdoc NFC 명령 형태
    func testApduShapes() {
        XCTAssertEqual(Apdu.selectByName(NfcAid.mdocDataRetrieval).hex,
                       "00a4040c07" + "a0000002480400")
        XCTAssertEqual(Apdu.selectFile(0xE103).hex, "00a4000c02e103")
        XCTAssertEqual(Apdu.readBinary(offset: 0, length: 2).hex, "00b0000002")
        XCTAssertEqual(Apdu.berTlv53(Data([0xaa, 0xbb])).hex, "5302aabb")
        // 체인 중이면 CLA 10 이고 Le 가 없다. 조각은 이미 TLV 로 감싼 바이트열의 일부다
        XCTAssertEqual(Apdu.envelope(Data([0x01]), isLast: false, le: nil).hex, "10c3000001" + "01")
        // 마지막이면 CLA 00 + Le
        XCTAssertEqual(Apdu.envelope(Data([0x01]), isLast: true, le: 0xff).hex, "00c3000001" + "01" + "ff")
        // 53 TLV 길이 형식 — short / 81 / 82
        XCTAssertEqual(BerTlv53.encode(Data([0xaa, 0xbb])).hex, "5302aabb")
        XCTAssertEqual(BerTlv53.encode(Data(repeating: 0, count: 200)).prefix(3).hex, "5381c8")
        XCTAssertEqual(BerTlv53.encode(Data(repeating: 0, count: 300)).prefix(4).hex, "5382012c")
        // 64 KiB 이상은 `83` — 초상화·복수 문서 응답이 NFC 로 나갈 때. 전에는 `UInt8(n >> 8)` 트랩이었다
        let big = Data(repeating: 0x5A, count: 0x1_0000)
        XCTAssertEqual(BerTlv53.encode(big).prefix(5).hex, "5383010000")
        XCTAssertEqual(try BerTlv53.value(BerTlv53.encode(big)), big)
        XCTAssertEqual(try BerTlv53.values(BerTlv53.encode(big) + BerTlv53.encode(Data([1]))), big + Data([1]))
        XCTAssertNoThrow(try EnvelopeChaining(commandLimit: 255, responseLimit: 256).commands(for: big))
    }

    // D2760000850101 이 앞이어야 한다. 순서는 취향이 아니라 동작이다
    func testSelectIdentifierOrder() {
        XCTAssertTrue(NfcCapability.validateSelectIdentifiers(
            [NfcAid.ndefTagApplication, NfcAid.mdocDataRetrieval]))
        XCTAssertFalse(NfcCapability.validateSelectIdentifiers(
            [NfcAid.mdocDataRetrieval, NfcAid.ndefTagApplication]), "순서가 뒤집히면 engagement 을 건너뛴다")
        XCTAssertFalse(NfcCapability.validateSelectIdentifiers([NfcAid.ndefTagApplication]))
        // Info.plist 형태 — hex 문자열 배열
        XCTAssertTrue(NfcCapability.validateSelectIdentifiers(["D2760000850101", "A0000002480400"]))
        XCTAssertFalse(NfcCapability.validateSelectIdentifiers(["A0000002480400", "D2760000850101"]))
        XCTAssertFalse(NfcCapability.validateSelectIdentifiers(["zz"]))
    }

    /// `current()` 는 **런타임 조회**다. 시험 호스트(macOS)는 CoreNFC 가 없으므로
    /// reader NFC 는 `noHardware`, mdoc NFC 는 정책상 `vendorPolicy`, BLE 는 권한 상태에 따라
    /// 셋 중 하나이지 임의의 상수가 아니다. 두 역할의 BLE 는 같은 라디오라 같은 값이다.
    func testCapabilitiesAreRuntimeFacts() {
        let saved = MdocCapabilities.provider; MdocCapabilities.provider = nil
        defer { MdocCapabilities.provider = saved }
        let caps = MdocCapabilities.current()
        XCTAssertEqual(caps.mdoc.nfc, .unsupported(reason: .vendorPolicy))
        #if !canImport(CoreNFC)
        XCTAssertEqual(caps.mdocReader.nfc, .unsupported(reason: .noHardware))
        #endif
        XCTAssertEqual(caps.mdoc.ble, caps.mdocReader.ble)
        switch caps.mdoc.ble {
        case .supported, .configurationRequired(.enableBluetooth),
             .configurationRequired(.grantPermission("bluetooth")), .unsupported(.noHardware): break
        default: XCTFail("BLE 조회가 낼 수 없는 값: \(caps.mdoc.ble)")
        }
    }

    /// 전송체의 `didUpdateState` 표와 같은 값을 낸다 — 두 곳이 어긋나면 조회와 실행이 다른 말을 한다
    #if canImport(CoreBluetooth)
    func testBleStateMapMatchesTransport() {
        XCTAssertEqual(BleCapabilityProbe.map(.poweredOff), .configurationRequired(action: .enableBluetooth))
        XCTAssertEqual(BleCapabilityProbe.map(.unauthorized), .configurationRequired(action: .grantPermission("bluetooth")))
        XCTAssertEqual(BleCapabilityProbe.map(.unsupported), .unsupported(reason: .noHardware))
        XCTAssertEqual(BleCapabilityProbe.map(.poweredOn), .supported)
        XCTAssertEqual(BleCapabilityProbe.map(.unknown), .supported, "모르는 것을 안 된다로 바꾸지 않는다")
    }
    #endif

    // CC file. Write 가 00 이면 negotiated 가능
    func testCapabilityContainer() {
        let cc = Data([0x00, 0x0F, 0x20, 0x00, 0x3B, 0x00, 0x34,
                       0x04, 0x06, 0xE1, 0x04, 0x04, 0x00, 0x00, 0x00])
        let parsed = CapabilityContainer(cc)!
        XCTAssertEqual(parsed.mLe, 0x003B)
        XCTAssertEqual(parsed.mLc, 0x0034)
        XCTAssertEqual(parsed.ndefFileID, 0xE104)
        XCTAssertTrue(parsed.writable, "Write 00 이면 negotiated 가능")
    }

    // 체이닝. **53 TLV 하나가 체인을 가로지른다**(7816-4 5.3). 마지막이 아닌 조각에는 Le 가 없다
    func testEnvelopeChaining() throws {
        let c = EnvelopeChaining(commandLimit: 10, responseLimit: 256)
        let cmds = try c.commands(for: Data(repeating: 0xAA, count: 20))
        XCTAssertEqual(cmds.count, 3)                       // TLV 22바이트를 10씩 — 10 + 10 + 2
        XCTAssertEqual(cmds[0].first, 0x10)                 // 체인 중
        XCTAssertEqual(cmds.last!.first, 0x00)              // 마지막
        XCTAssertEqual(cmds[0].count, 5 + 10)               // 헤더 + 조각
        XCTAssertEqual(cmds[0][5], 0x53, "TLV 헤더는 첫 조각에만 있다")
        XCTAssertEqual(cmds.last!.count, 5 + 2 + 1)         // 마지막 조각 + Le
        // 조각들을 이어 붙이면 TLV 하나다 — 카드 쪽은 이것을 한 번에 읽는다
        let joined = cmds.map { $0.count > 5 ? $0.subdata(in: 5..<(5 + Int($0[4]))) : Data() }.reduce(Data(), +)
        XCTAssertEqual(try BerTlv53.values(joined), Data(repeating: 0xAA, count: 20))

        XCTAssertEqual(c.step(Data([0xAA, 0x90, 0x00])), .done(Data([0xAA])))
        XCTAssertEqual(c.step(Data([0x61, 0x20])), .getResponse(le: 0x20))
        // 61 00 — 잔여가 Le+255 를 넘는다. 최대 길이로 요청한다
        XCTAssertEqual(c.step(Data([0x61, 0x00])), .getResponse(le: 255))
        XCTAssertEqual(c.step(Data([0x6A, 0x82])), .failed)
    }

    // 8.3.3.1.2 — 상대(mdoc)가 short 한계보다 큰 값을 통지하면 extended-length 로 간다. Lc 3바이트,
    // 마지막 조각 Le 2바이트(`0000` = 65536), `61 xx` 뒤 GET RESPONSE 도 extended. 통지한 한계는 넘지 않는다
    func testExtendedLengthWhenPeerAdvertisesLargerLimits() throws {
        let c = EnvelopeChaining(commandLimit: 1000, responseLimit: 4096)
        XCTAssertTrue(c.extended)
        let cmds = try c.commands(for: Data(repeating: 0xAA, count: 1500))   // TLV 1504 = 53 82 05DC + 1500
        XCTAssertEqual(cmds.count, 2)
        XCTAssertEqual(Array(cmds[0].prefix(7)), [0x10, 0xC3, 0x00, 0x00, 0x00, 0x03, 0xE8])
        XCTAssertEqual(cmds[0].count, 7 + 1000)
        XCTAssertEqual(Array(cmds[1].prefix(7)), [0x00, 0xC3, 0x00, 0x00, 0x00, 0x01, 0xF8])
        XCTAssertEqual(Array(cmds[1].suffix(2)), [0x10, 0x00], "Le = 4096")
        XCTAssertEqual(cmds[1].count, 7 + 504 + 2)
        let joined = cmds.map { $0.subdata(in: 7..<(7 + (Int($0[5]) << 8 | Int($0[6])))) }.reduce(Data(), +)
        XCTAssertEqual(try BerTlv53.values(joined), Data(repeating: 0xAA, count: 1500))

        XCTAssertEqual(c.step(Data([0x61, 0x00])), .getResponseExtended(le: 4096))
        XCTAssertEqual(c.step(Data([0x61, 0x20])), .getResponseExtended(le: 0x20))
        XCTAssertEqual(Apdu.getResponseExtended(le: 4096), Data([0x00, 0xC0, 0x00, 0x00, 0x00, 0x10, 0x00]))
        XCTAssertEqual(Apdu.getResponseExtended(le: 65_536), Data([0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00]))

        // 응답 한계만 큰 경우도 extended — 한 APDU 안에서 short Lc 와 extended Le 를 섞지 않는다
        let r = EnvelopeChaining(commandLimit: 255, responseLimit: 65_536)
        XCTAssertTrue(r.extended)
        let one = try r.commands(for: Data([0x01]))
        XCTAssertEqual(Array(one[0]), [0x00, 0xC3, 0x00, 0x00, 0x00, 0x00, 0x03, 0x53, 0x01, 0x01, 0x00, 0x00])
        // short 한계면 지금까지와 같다
        XCTAssertFalse(EnvelopeChaining(commandLimit: 255, responseLimit: 256).extended)
    }

    // 없는 쪽을 지우지 않는다. 컴파일은 되되 unsupported 를 돌려준다
    func testUnsupportedPathsStillCompile() {
        XCTAssertEqual(NfcCapability.mdocSupport(), .unsupported(reason: .vendorPolicy))
    }
}
