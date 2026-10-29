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
@_spi(MdocInternal) @testable import MdocBLE
@_spi(MdocInternal) @testable import MdocReader
@_spi(MdocInternal) @testable import MdocDevice

/// BLE 전송체 자체는 시뮬레이터에서 돌지 않는다. **라디오 없이 검증 가능한 부분**만 본다 —
/// 프로파일 표와 재조립 버퍼다.
final class BleFramingTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    // 모드 차이는 UUID 표다. Ident 는 central client mode 에만 있다
    func testProfileTables() {
        let uuid = CBUUIDStub.service
        let ps = BleServiceProfile.peripheralServerMode(serviceUUID: uuid)
        XCTAssertNil(ps.ident, "peripheral server mode 에는 Ident 가 없다 (Table 11)")
        XCTAssertTrue(ps.state.uuidString.hasPrefix("00000001"))
        XCTAssertTrue(ps.client2Server.uuidString.hasPrefix("00000002"))
        XCTAssertTrue(ps.server2Client.uuidString.hasPrefix("00000003"))

        let cc = BleServiceProfile.centralClientMode(serviceUUID: uuid)
        XCTAssertNotNil(cc.ident, "central client mode 에만 Ident 가 있다 (Table 12)")
        XCTAssertTrue(cc.state.uuidString.hasPrefix("00000005"))
        XCTAssertTrue(cc.ident!.uuidString.hasPrefix("00000008"))
    }

    // 재조립. 선두 바이트가 0x01/0x00 이외면 프로토콜 오류다
    func testReassembly() throws {
        let b = ReassemblyBuffer()
        XCTAssertNil(try b.append(Data([0x01, 0xaa, 0xbb])))
        XCTAssertEqual(try b.append(Data([0x00, 0xcc])), Data([0xaa, 0xbb, 0xcc]))
        // 완료 후 버퍼가 비어야 다음 메시지가 섞이지 않는다
        XCTAssertEqual(try b.append(Data([0x00, 0xdd])), Data([0xdd]))
        XCTAssertThrowsError(try b.append(Data([0x02, 0xee]))) { e in
            guard case MdocProximityError.decodeFailed = e else { return XCTFail("\(e)") }
        }
    }

    // 512 KiB 상한. 상한이 없으면 상대가 0x01 part 를 무한히 보낼 수 있다
    func testBufferCap() {
        let b = ReassemblyBuffer()
        let chunk = Data([0x01]) + Data(repeating: 0, count: 64 * 1024)
        XCTAssertThrowsError(try {
            for _ in 0..<9 { _ = try b.append(chunk) }     // 576 KiB
        }())
    }
}

enum CBUUIDStub {
    static let service = { () -> CBUUID in CBUUID(string: "0000AAAA-0000-1000-8000-00805F9B34FB") }()
}
import CoreBluetooth

/// **길이 헤더만이 메시지 경계**다. GATT 의 선두 상태 바이트와 달리 프래그멘테이션
/// 자체가 없고, 스트림이라 읽기 단위와 메시지 단위가 어긋나는 것이 정상이다.
final class L2capFramingTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    func testFrameIsHeaderPlusBody() {
        let framed = L2capFraming.frame(Data([0xaa, 0xbb, 0xcc]))
        XCTAssertEqual(framed.hex, "00000003aabbcc")
        XCTAssertEqual(L2capFraming.frame(Data()).hex, "00000000", "빈 메시지도 헤더는 나간다")
    }

    /// 한 번의 읽기에 **여러 메시지가 붙어** 온다
    func testReassemblesConcatenatedMessages() throws {
        let r = L2capFraming.Reassembler()
        let chunk = L2capFraming.frame(Data([0x01])) + L2capFraming.frame(Data([0x02, 0x03]))
        XCTAssertEqual(try r.append(chunk), [Data([0x01]), Data([0x02, 0x03])])
    }

    /// **헤더 4바이트가 쪼개져** 온다 — 여기서 길이를 성급히 읽으면 메시지가 어긋난다
    func testReassemblesSplitHeader() throws {
        let r = L2capFraming.Reassembler()
        let framed = L2capFraming.frame(Data(repeating: 0x5a, count: 300))
        XCTAssertEqual(try r.append(framed.prefix(2)), [])
        XCTAssertEqual(try r.append(framed.subdata(in: 2..<5)), [])
        XCTAssertEqual(try r.append(framed.subdata(in: 5..<framed.count)).count, 1)
    }

    /// 상한은 GATT 재조립 상한과 **같은 값**이다 — 전송이 달라도 위협이 같다
    func testRejectsOversizedLength() {
        let r = L2capFraming.Reassembler()
        XCTAssertThrowsError(try r.append(L2capFraming.lengthHeader(600 * 1024)))
    }

    /// 끊기면 **부분 메시지를 올리지 않는다**
    func testDiscardsPartialMessage() throws {
        let r = L2capFraming.Reassembler()
        _ = try r.append(L2capFraming.frame(Data(repeating: 1, count: 10)).prefix(8))
        r.discard()
        XCTAssertEqual(try r.append(L2capFraming.frame(Data([0x09]))), [Data([0x09])])
    }
}


/// **L2CAP 을 여는 쪽은 GATT client 다.** 그 배치가 모드마다 뒤집히므로
/// 팩토리가 어느 구현체를 세우는지가 곧 규정의 구현이다.
/// 기본값이 꺼짐인 것도 함께 고정한다 — GATT 경로를 실기기에서 먼저 확인하기 위한 것이다.
/// PSM 특성 값 — 표준이 길이를 안 정했으므로 우리 결정을 테스트가 고정한다
final class L2capPsmCodecTests: XCTestCase {
    func testWritesFourBytesBigEndian() {
        XCTAssertEqual(L2capPsmCodec.encode(0x0081).hex, "00000081")
        XCTAssertEqual(L2capPsmCodec.encode(0xC0DE).hex, "0000c0de")
    }
    func testReadsTwoOrFourBytes() {
        XCTAssertEqual(L2capPsmCodec.decode(Data([0x00, 0x81])), 0x81, "구버전 우리 SDK — 2바이트")
        XCTAssertEqual(L2capPsmCodec.decode(Data([0, 0, 0xC0, 0xDE])), 0xC0DE, "Android 레퍼런스 — 4바이트")
        XCTAssertNil(L2capPsmCodec.decode(Data([0, 1, 0, 0x81])), "PSM 은 16비트다")
        XCTAssertNil(L2capPsmCodec.decode(Data([0x81])))
        XCTAssertNil(L2capPsmCodec.decode(Data()))
    }
}

final class L2capUpgradeWiringTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    /// **L2CAP 은 모드가 아니라 파라미터의 속성이다** — 같은 모드에 `l2cap` 만 달리 준다
    private func params(_ t: TransmissionTechnology, _ role: SessionRole, l2cap: Bool,
                        psm: UInt64? = nil) -> TransportParameters {
        TransportParameters(technology: t, role: role, l2cap: l2cap,
                            serviceUUID: Data(repeating: 0xAB, count: 16),
                            ident: Data(repeating: 1, count: 16), l2capPSM: psm)
    }

    func testReaderOpensChannelOnlyInPeripheralMode() throws {
        let f = ReaderTransportFactory()
        XCTAssertTrue(try f.makeTransport(params(.ble(.peripheralServer), .mdocReader, l2cap: false))
                        is BleGattClientTransport)
        // 상대가 PSM 을 광고해도 **꺼져 있으면 GATT** 다
        XCTAssertTrue(try f.makeTransport(params(.ble(.peripheralServer), .mdocReader, l2cap: false, psm: 0x81))
                        is BleGattClientTransport)
        // peripheral 계열에서는 **리더가** GATT client 이므로 리더가 연다
        XCTAssertTrue(try f.makeTransport(params(.ble(.peripheralServer), .mdocReader, l2cap: true))
                        is BleL2capOpeningTransport)
        // central 계열에서는 리더가 GATT server 다 — 열지 않고 PSM 만 게시한다
        XCTAssertTrue(try f.makeTransport(params(.ble(.centralClient), .mdocReader, l2cap: true))
                        is BleGattServerTransport)
    }

    func testDeviceOpensChannelOnlyInCentralMode() throws {
        let f = DeviceTransportFactory()
        XCTAssertTrue(try f.makeTransport(params(.ble(.centralClient), .mdoc, l2cap: false))
                        is BleGattClientTransport)
        // central 계열에서는 **mdoc 이** GATT client 다 — 여는 쪽이 뒤집힌다
        XCTAssertTrue(try f.makeTransport(params(.ble(.centralClient), .mdoc, l2cap: true))
                        is BleL2capOpeningTransport)
        XCTAssertTrue(try f.makeTransport(params(.ble(.peripheralServer), .mdoc, l2cap: true))
                        is BleGattServerTransport)
    }

    /// 광고 집합에 L2CAP 항목은 없다 — 모드 둘뿐이고, PSM 은 engagement 에 실리지 않는다
    func testAdvertisedSetHasNoL2capEntry() {
        XCTAssertEqual(DeviceTransportFactory().availableTechnologies,
                       [.ble(.peripheralServer), .ble(.centralClient)])
    }
}

/// **mdoc 은 광고한 경로 전부에서 대기해야 한다** — 무엇을 쓸지는 리더가 고르기 때문이다
/// (8.3.3.1.1.1). 하나만 세우면 리더가 다른 것을 골랐을 때 둘 다 광고만 하고 만나지 못한다.
final class FirstReadyTransportTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    /// 이벤트를 손으로 밀어 넣는 전송체. 어느 쪽이 먼저 서는지를 시험이 정한다.
    private final class Stub: DataRetrievalTransportProtocol {
        let events: AsyncStream<TransportEvent>
        private let emit: AsyncStream<TransportEvent>.Continuation
        private(set) var opened = false
        private(set) var closed = false
        private(set) var sent: [Data] = []
        /// 열다가 throw 하는 후보 — 카드 에뮬레이션이 비대상 기기에서 `nfcUnavailable` 을 내는 꼴
        var openError: MdocProximityError?
        init() {
            var c: AsyncStream<TransportEvent>.Continuation!
            events = AsyncStream { c = $0 }
            emit = c
        }
        func open(_ config: TransportConfig) async throws {
            if let openError { throw openError }
            opened = true
        }
        func send(_ message: Data) async throws { sent.append(message) }
        func close(_ reason: TransportCloseReason) { closed = true }
        func becomeReady() { emit.yield(.ready) }
        func fail(_ e: MdocProximityError) { emit.yield(.failed(e)) }
    }

    func testAdoptsFirstReadyAndClosesTheRest() async throws {
        let a = Stub(), b = Stub()
        let transport = FirstReadyTransport([a, b])
        try await transport.open(TransportConfig(role: .mdoc))
        XCTAssertTrue(a.opened && b.opened, "후보를 전부 연다")

        let router = TransportEventRouter(transport)
        router.start()
        b.becomeReady()
        try await router.waitReady()

        // **먼저 선 쪽만 남는다** — 나머지 라디오를 계속 잡고 있으면 배터리·간섭 비용이 든다
        XCTAssertTrue(a.closed)
        XCTAssertFalse(b.closed)

        try await transport.send(Data([0x01]))
        XCTAssertEqual(b.sent, [Data([0x01])])
        XCTAssertTrue(a.sent.isEmpty, "채택되지 않은 경로로는 보내지 않는다")
    }

    /// 채택 전에 한 경로가 실패하는 것은 **사건이 아니다** — 다른 경로가 설 수 있다.
    func testFailureBeforeSelectionIsNotSurfaced() async throws {
        let a = Stub(), b = Stub()
        let transport = FirstReadyTransport([a, b])
        try await transport.open(TransportConfig(role: .mdoc))
        let router = TransportEventRouter(transport)
        router.start()

        // a 가 죽어도 b 로 세션이 선다
        a.fail(.connectionFailed(detail: "a"))
        b.becomeReady()
        try await router.waitReady()
        XCTAssertFalse(b.closed)
    }

    /// **후보 전부가 실패하면 첫 실패를 올린다** — 권한 프롬프트 직후 블루투스가 꺼져 있으면 두 BLE
    /// 후보가 모두 `configurationRequired(.enableBluetooth)` 를 내는데, 이것까지 삼키면 앱은
    /// `engagementTimeout` 까지 원인을 모른다 (CA 앱 실기, 2026-09-15). `open()` 의 throw 규칙과 대칭.
    func testAllCandidatesFailingSurfacesFirstFailure() async throws {
        let a = Stub(), b = Stub()
        let transport = FirstReadyTransport([a, b])
        try await transport.open(TransportConfig(role: .mdoc))
        let router = TransportEventRouter(transport)
        let seen = SeenFailures()
        router.onEvent = { if case .failed(let e) = $0 { seen.append(e) } }
        router.start()

        b.fail(.configurationRequired(action: .enableBluetooth))   // 하나만 — 아직 사건이 아니다
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(seen.isEmpty, "한 후보의 실패는 올리지 않는다")

        a.fail(.configurationRequired(action: .enableBluetooth))   // 둘 다 — 이제 사건이다
        do { try await router.waitReady(); XCTFail("실패가 올라와야 한다") }
        catch { XCTAssertEqual(error as? MdocProximityError, .configurationRequired(action: .enableBluetooth)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(seen.count, 1, "한 번만 올린다")
    }

    /// **열다 throw 한 후보도 "전부 실패" 의 분모에 든다.** 카드 에뮬이 `open` 에서 `nfcUnavailable`
    /// 을 던지고 두 BLE 후보가 블루투스 꺼짐으로 `.failed` 를 내면, throw 를 세지 않을 때는 2/3 에서
    /// 멈춰 아무것도 올라가지 않았다 — 위 시험이 잡으려던 침묵이 이 조합에서는 그대로였다.
    func testOpenThrowCountsTowardAllFailed() async throws {
        let nfc = Stub(), a = Stub(), b = Stub()
        nfc.openError = .nfcUnavailable(reason: .vendorPolicy)
        let transport = FirstReadyTransport([("nfc", nfc), ("a", a), ("b", b)])
        try await transport.open(TransportConfig(role: .mdoc))     // 하나만 throw 면 open 은 성공이다
        let router = TransportEventRouter(transport)
        let seen = SeenFailures()
        router.onEvent = { if case .failed(let e) = $0 { seen.append(e) } }
        router.start()

        a.fail(.configurationRequired(action: .enableBluetooth))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(seen.isEmpty, "아직 b 가 남아 있다")
        b.fail(.configurationRequired(action: .enableBluetooth))
        do { try await router.waitReady(); XCTFail("전부 실패했으면 올라와야 한다") }
        catch {
            // 첫 실패 = 후보 순서상 첫 번째 — open 에서 throw 한 NFC 의 오류다
            XCTAssertEqual(error as? MdocProximityError, .nfcUnavailable(reason: .vendorPolicy))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(seen.count, 1, "한 번만 올린다")
    }

    /// `.failed` 가 먼저 오고 throw 가 뒤에 오는 순서도 같다 — `open()` 이 끝나는 자리에서 다시 판정한다
    func testAllFailedIsReportedWhenOpenThrowLandsLast() async throws {
        let a = Stub(), late = Stub()
        late.openError = .nfcUnavailable(reason: .vendorPolicy)
        let transport = FirstReadyTransport([("a", a), ("late", late)])
        let router = TransportEventRouter(transport)
        let seen = SeenFailures()
        router.onEvent = { if case .failed(let e) = $0 { seen.append(e) } }
        router.start()
        a.fail(.configurationRequired(action: .enableBluetooth))   // open 전에 이미 죽어 있다
        try await transport.open(TransportConfig(role: .mdoc))
        do { try await router.waitReady(); XCTFail("전부 실패했으면 올라와야 한다") }
        catch { XCTAssertEqual(error as? MdocProximityError, .configurationRequired(action: .enableBluetooth)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(seen.count, 1)
    }
}

/// 리더의 "구현한 것 ∩ 쓸 수 있는 것" — **종류별로 따로 거른다**
final class ReaderAvailableTechnologiesTests: XCTestCase {

    override func tearDown() { MdocCapabilities.provider = nil }

    private func capabilities(ble: TransportCapability, nfc: TransportCapability) {
        MdocCapabilities.provider = {
            let role = RoleCapabilities(ble: ble, nfc: nfc, wifiAware: .unsupported(reason: .vendorPolicy))
            return MdocCapabilities(mdoc: role, mdocReader: role)
        }
    }

    /// 블루투스가 꺼져 있어도 NFC data retrieval 은 남는다 — 통째로 비우면 NFC 만 광고한 mdoc 에
    /// `unsupportedTransmissionTechnology`(광고 불일치)로 오진한다
    func testBluetoothOffKeepsNfc() {
        capabilities(ble: .configurationRequired(action: .enableBluetooth), nfc: .supported)
        XCTAssertEqual(ReaderTransportFactory().availableTechnologies, [.nfc])
    }

    func testNfcUnsupportedKeepsBle() {
        capabilities(ble: .supported, nfc: .unsupported(reason: .noHardware))
        XCTAssertEqual(ReaderTransportFactory().availableTechnologies, [.ble(.centralClient), .ble(.peripheralServer)])
    }

    func testBothBlockedIsEmpty() {
        capabilities(ble: .unsupported(reason: .noHardware), nfc: .unsupported(reason: .noHardware))
        XCTAssertEqual(ReaderTransportFactory().availableTechnologies, [])
    }
}

/// 라우터 Task 가 쓰고 테스트가 읽는다 — 잠금으로 묶는다
private final class SeenFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MdocProximityError] = []
    func append(_ e: MdocProximityError) { lock.withLock { items.append(e) } }
    var isEmpty: Bool { lock.withLock { items.isEmpty } }
    var count: Int { lock.withLock { items.count } }
}
