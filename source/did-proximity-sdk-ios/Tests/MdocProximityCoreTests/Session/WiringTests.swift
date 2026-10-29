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

/// **전송체를 무는 배선** — engagement 생성 → 전송 선택 → 링크 → 키 합의 → 트랜스크립트까지
/// 앱이 부르는 두 호출(`start` / `connect`)만으로 도달하는지 본다.
/// 주입 경로(`begin`)는 이 축을 건너뛰므로 여기서만 잡힌다.
final class WiringTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    override func tearDown() { SessionRegistry.release() }

    // MARK: COSE_Key

    /// 벡터의 `EDeviceKeyBytes` 와 **바이트가 같아야** 한다 — 우리가 만든 키가 상대의
    /// BLEIdent·NANService 파생과 같은 입력을 내는지가 여기 걸린다.
    func testCoseKeyMatchesVectorBytes() throws {
        let vector = Data(hex: "d818584ba401022001215820101112131415161718191a1b1c1d1e1f20212223"
                             + "2425262728292a2b2c2d2e2f225820303132333435363738393a3b3c3d3e3f40"
                             + "4142434445464748494a4b4c4d4e4f")!
        let sec1 = try CoseKey.x963(fromKeyBytes: OpaqueCBOR(preserving: vector))
        XCTAssertEqual(sec1.first, 0x04)
        XCTAssertEqual(sec1.count, 65)
        XCTAssertEqual(try CoseKey.keyBytes(x963: sec1).raw, vector, "재인코딩이 원본과 같아야 한다")
    }

    /// 곡선을 확인하지 않으면 다른 곡선의 좌표를 P-256 으로 읽어 조용히 어긋난다.
    func testCoseKeyRejectsOtherCurve() {
        let bad = CborEncoder.tag24(CborEncoder.encode(.map([
            CborPair(.unsigned(1), .unsigned(2)),
            CborPair(.negative(0), .unsigned(2)),          // crv = P-384
            CborPair(.negative(1), .bytes(Data(repeating: 1, count: 32))),
            CborPair(.negative(2), .bytes(Data(repeating: 2, count: 32)))])))
        XCTAssertThrowsError(try CoseKey.x963(fromKeyBytes: OpaqueCBOR(preserving: bad)))
    }

    /// 양쪽이 상대의 `…KeyBytes` 만으로 같은 `ZAB` 에 도달한다.
    func testEphemeralKeyAgreementIsSymmetric() throws {
        let device = EphemeralKeyPair(), reader = EphemeralKeyPair()
        XCTAssertEqual(try device.sharedSecret(withPeerKeyBytes: reader.keyBytes),
                       try reader.sharedSecret(withPeerKeyBytes: device.keyBytes))
    }

    // MARK: engagement → 전송 선택

    /// 광고 집합은 **SDK 가 정한다** — 앱이 목록을 넣는 자리가 없다.
    /// 아직 구현하지 않은 전송이 광고되면 리더가 그것을 고르고 연결이 실패한다.
    func testStartAdvertisesOnlyImplementedTransports() async throws {
        let (link, _) = LoopbackTransport.pair()
        let mdoc = MdocDeviceSession(transport: link)
        let payload = try await mdoc.start(technology: .qr)

        XCTAssertEqual(mdoc.state, .engaging)
        // **peripheral server 가 실기기에서 확인된 뒤 central client 가 더해졌다**.
        // 순서는 리더의 우선순위가 정하므로 집합만 본다
        XCTAssertEqual(payload.transmissions.count, 2)
        XCTAssertTrue(payload.transmissions.contains(.ble(.centralClient)))
        XCTAssertTrue(payload.transmissions.contains(.ble(.peripheralServer)))
        XCTAssertNotNil(payload.qrString)
        // BleOptions — 서비스 UUID 는 트랜잭션마다 새로 만든 16바이트다
        let options = try XCTUnwrap(payload.bleOptions)
        XCTAssertTrue(options.peripheralServerMode)
        XCTAssertTrue(options.centralClientMode)
        XCTAssertEqual(options.peripheralServerUUID?.count, 16)
        XCTAssertEqual(options.centralClientUUID?.count, 16)
        // 키 10 과 11 은 **다른 서비스**다 — 같으면 두 모드를 함께 광고했을 때 겹친다
        XCTAssertNotEqual(options.peripheralServerUUID, options.centralClientUUID)
        XCTAssertNil(options.l2capPSM, "구현하지 않은 L2CAP 을 광고하면 안 된다")
    }

    /// **UUID 없는 모드는 고르지 않는다.** 플래그 0·1 둘 다 true 인데 UUID 는 키 11 만 실은
    /// engagement(Multipaz, 2026-09-14) — peripheral 선호여도 central 로 내려가야 한다. 표준은
    /// 지원 모드의 UUID 를 shall be present 로 요구하지만(8.3.3.1.1.1) 어긴 상대에서 리더가
    /// `malformedEngagement` 로 하드 실패할 이유는 없다.
    func testPreferredModeWithoutUUIDFallsBackToTheOther() async throws {
        let uuid = Data(repeating: 0x5A, count: 16)
        let engagement = try EngagementCodec.encode(
            eDeviceKeyBytes: EphemeralKeyPair().keyBytes,
            retrievalMethods: [DeviceRetrievalMethod(type: 2, version: 1, options: .map([
                CborPair(.unsigned(0), .bool(true)), CborPair(.unsigned(1), .bool(true)),
                CborPair(.unsigned(11), .bytes(uuid))]))])          // 키 10 이 없다
        let payload = try EngagementPayload.make(engagement)
        XCTAssertEqual(Set(payload.transmissions.map { "\($0)" }).count, 2, "광고 사실은 그대로다")

        var cfg = MdocReaderConfiguration()
        cfg.blePreferredMode = .peripheral
        let factory = RecordingFactory()
        let reader = MdocReaderSession(configuration: cfg,
                                       trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
                                       transportFactory: factory, nfcTagSource: UnavailableNfcTagSource())
        do {
            try await reader.connect(to: payload)
            XCTFail("스텁 팩토리는 항상 던진다")
        } catch {
            XCTAssertEqual(error as? MdocProximityError, .connectionFailed(detail: "stub"),
                           "malformedEngagement 가 아니라 다음 모드로 내려가야 한다")
        }
        XCTAssertEqual(factory.requested, [.ble(.centralClient)])
        XCTAssertEqual(factory.serviceUUIDs, [uuid])
        SessionRegistry.release()

        // UUID 가 하나도 없으면 고를 것이 없다 — 연결 전에 실패한다
        let bare = try EngagementCodec.encode(
            eDeviceKeyBytes: EphemeralKeyPair().keyBytes,
            retrievalMethods: [DeviceRetrievalMethod(type: 2, version: 1, options: .map([
                CborPair(.unsigned(0), .bool(true)), CborPair(.unsigned(1), .bool(true))]))])
        let reader2 = MdocReaderSession(configuration: cfg,
                                        trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
                                        transportFactory: RecordingFactory(), nfcTagSource: UnavailableNfcTagSource())
        do {
            try await reader2.connect(to: try EngagementPayload.make(bare))
            XCTFail("UUID 가 없으면 붙을 수 없다")
        } catch {
            XCTAssertEqual(error as? MdocProximityError, .unsupportedTransmissionTechnology)
        }
        SessionRegistry.release()
    }

    /// 어떤 모드를 어떤 UUID 로 만들려 했는지만 기록하고 던진다 — 라디오를 만들지 않는다
    private final class RecordingFactory: TransportFactoryProtocol {
        private(set) var requested: [TransmissionTechnology] = []
        private(set) var serviceUUIDs: [Data?] = []
        var availableTechnologies: [TransmissionTechnology] {
            [.ble(.centralClient), .ble(.peripheralServer), .nfc]
        }
        func makeTransport(_ p: TransportParameters) throws -> DataRetrievalTransportProtocol {
            requested.append(p.technology); serviceUUIDs.append(p.serviceUUID)
            throw MdocProximityError.connectionFailed(detail: "stub")
        }
    }

    /// 리더가 쓸 수 없는 것만 광고돼 있으면 **연결 전에** 실패한다. Wi-Fi Aware 만
    /// 광고한 상대 — iOS 는 그 전송을 정책상 못 쓰므로 조회와 같은 어휘 `wifiAwareUnavailable(.vendorPolicy)`
    /// 다. 전에는 케이스 자체가 없어 RFU 로 무시돼 `unsupportedTransmissionTechnology` 였다.
    func testConnectFailsWhenNoCommonTransport() async throws {
        let engagement = try EngagementCodec.encode(
            eDeviceKeyBytes: EphemeralKeyPair().keyBytes,
            retrievalMethods: [DeviceRetrievalMethod(type: 3, version: 1, options: .map([]))])
        let payload = try EngagementPayload.make(engagement)
        let reader = MdocReaderSession(trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() })

        do {
            try await reader.connect(to: payload)
            XCTFail("iOS 가 못 쓰는 전송만 광고된 상대에는 붙을 수 없다")
        } catch {
            XCTAssertEqual(error as? MdocProximityError, .wifiAwareUnavailable(reason: .vendorPolicy))
        }
        XCTAssertEqual(reader.state, .failed)
        XCTAssertFalse(SessionRegistry.isActive, "실패했으면 자원을 놓아야 한다")
    }

    /// **블루투스가 꺼져 있으면 조회와 같은 어휘로 실패한다** — 후보가 빈 원인이 기기 능력이면
    /// `configurationRequired(.enableBluetooth)` 이지 `unsupportedTransmissionTechnology` 가 아니다
    /// (에러 축과 Capability 축은 1:1). 양 역할 모두.
    func testBluetoothOffFailsWithCapabilityVocabulary() async throws {
        MdocCapabilities.provider = {
            MdocCapabilities(
                mdoc: RoleCapabilities(ble: .configurationRequired(action: .enableBluetooth),
                                       nfc: .unsupported(reason: .vendorPolicy),
                                       wifiAware: .unsupported(reason: .vendorPolicy)),
                mdocReader: RoleCapabilities(ble: .configurationRequired(action: .enableBluetooth),
                                             nfc: .supported,
                                             wifiAware: .unsupported(reason: .vendorPolicy)))
        }
        defer { MdocCapabilities.assumeAllSupportedForTests() }

        let mdoc = MdocDeviceSession()
        do {
            _ = try await mdoc.start(technology: .qr)
            XCTFail("블루투스가 꺼져 있으면 광고할 것이 없다")
        } catch {
            XCTAssertEqual(error as? MdocProximityError, .configurationRequired(action: .enableBluetooth))
        }
        XCTAssertFalse(SessionRegistry.isActive)

        let engagement = try EngagementCodec.encode(
            eDeviceKeyBytes: EphemeralKeyPair().keyBytes,
            retrievalMethods: [DeviceRetrievalMethod(type: 2, version: 1, options: .map([
                CborPair(.unsigned(0), .bool(true)), CborPair(.unsigned(1), .bool(false)),
                CborPair(.unsigned(10), .bytes(Data(repeating: 7, count: 16)))]))])
        let reader = MdocReaderSession(trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() })
        do {
            try await reader.connect(to: try EngagementPayload.make(engagement))
            XCTFail("블루투스가 꺼져 있으면 붙을 수 없다")
        } catch {
            XCTAssertEqual(error as? MdocProximityError, .configurationRequired(action: .enableBluetooth))
        }
        XCTAssertEqual(reader.state, .failed)
        XCTAssertFalse(SessionRegistry.isActive)
    }

    /// **mdoc 앱은 광고할 BLE 모드를 고른다 — 좁히기만 된다**.
    /// 값이 셋인 것은 축이 둘뿐이기 때문이고, `both` 는 "제한하지 않는다"는 뜻이다.
    func testAppNarrowsAdvertisedModes() async throws {
        for (mode, expected) in [(BleAdvertiseMode.peripheralServer, TransmissionTechnology.ble(.peripheralServer)),
                                 (.centralClient, .ble(.centralClient))] {
            let (link, _) = LoopbackTransport.pair()
            var cfg = MdocDeviceConfiguration()
            cfg.bleAdvertiseMode = mode
            let mdoc = MdocDeviceSession(configuration: cfg, transport: link)
            let payload = try await mdoc.start(technology: .qr)
            XCTAssertEqual(payload.transmissions, [expected], "\(mode) 만 광고해야 한다")
            let options = try XCTUnwrap(payload.bleOptions)
            // 쓰지 않는 모드는 **UUID 도 싣지 않는다** — 키 10/11 은 다른 서비스다
            XCTAssertEqual(options.peripheralServerUUID != nil, mode == .peripheralServer)
            XCTAssertEqual(options.centralClientUUID != nil, mode == .centralClient)
            mdoc.terminate()
            SessionRegistry.release()
        }
    }

    /// 기본값은 `both` 이고, 그것은 **기기 능력 교집합을 그대로 통과시킨다**는 뜻이다.
    func testBothIsTheDefaultAndDoesNotWiden() async throws {
        XCTAssertEqual(MdocDeviceConfiguration().bleAdvertiseMode, .both)
        // BLE 가 아닌 전송은 이 정책의 대상이 아니다 — 정책으로 켜지지도 꺼지지도 않는다
        for mode in [BleAdvertiseMode.both, .peripheralServer, .centralClient] {
            XCTAssertTrue(mode.allows(.nfc))
        }
        XCTAssertTrue(BleAdvertiseMode.peripheralServer.allows(.ble(.peripheralServer)))
        XCTAssertFalse(BleAdvertiseMode.peripheralServer.allows(.ble(.centralClient)))
    }

    /// 리더 앱이 목록에서 뺀 것은 **상대가 광고해도 고르지 않는다** — 순서이자 허용 목록이다.
    func testPriorityIsAlsoAnAllowList() async throws {
        let (link, _) = LoopbackTransport.pair()
        let mdoc = MdocDeviceSession(transport: link)
        let payload = try await mdoc.start(technology: .qr)
        SessionRegistry.release()

        var cfg = MdocReaderConfiguration()
        cfg.transmissionPriority = [.nfc]        // 상대가 광고한 BLE 두 모드를 전부 뺐다
        let reader = MdocReaderSession(configuration: cfg,
                                       trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() })
        do {
            try await reader.connect(to: try EngagementPayload.parse(qrString: payload.qrString!))
            XCTFail("목록에서 뺀 전송으로 붙으면 안 된다")
        } catch {
            XCTAssertEqual(error as? MdocProximityError, .unsupportedTransmissionTechnology)
        }
    }

    // MARK: 전 흐름 — 주입 없이

    /// `start()` → QR → `connect(to:)` → `request(_:at:)`.
    /// **키 합의와 트랜스크립트를 양쪽이 독립적으로 만든다** — 한 바이트라도 어긋나면
    /// 복호화가 AEAD 태그 불일치로 실패하므로, 이 테스트가 그 축을 고정한다.
    func testEndToEndWithoutInjectedKeys() async throws {
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in
            issuerKey.publicKey.x963Representation
        }

        let mdoc = MdocDeviceSession(transport: mdocLink)
        let payload = try await mdoc.start(technology: .qr)
        // 활성 세션 1개 규칙은 프로세스 단위다 — 한 프로세스에 양측을 세우는 것은
        // 테스트뿐이므로 여기서만 푼다
        SessionRegistry.release()

        let responder = LateResponder(issuerKey: issuerKey, deviceKey: deviceKey, did: did)
        mdoc.delegate = responder

        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(),
                                       transport: readerLink, trust: trust)
        try await reader.connect(to: try EngagementPayload.parse(qrString: payload.qrString!))
        XCTAssertEqual(reader.state, .connected)

        let result = try await reader.request([ItemsRequestPresets.identity], at: Date())

        XCTAssertEqual(mdoc.state, .completed)
        XCTAssertEqual(result.documents.count, 1)
        let doc = try XCTUnwrap(result.documents.first)
        XCTAssertTrue(doc.issuerDataAuth.signatureValid)
        XCTAssertTrue(doc.mdocAuth.valid, "트랜스크립트가 양쪽에서 같아야 통과한다")
        XCTAssertEqual(doc.issuerDataAuth.trust, .trusted)
    }

    /// 응답을 받은 리더는 **status 20 을 보내고 링크를 끊은 뒤** 검증한다.
    /// mdoc 은 이미 `completed` 이므로 그 통지를 정상 경로로 받아야 한다 — 실패로 받으면
    /// 정상 트랜잭션이 매번 `failed` 로 끝난다.
    func testReaderTerminatesBeforeVerifying() async throws {
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in
            issuerKey.publicKey.x963Representation
        }

        let mdoc = MdocDeviceSession(transport: mdocLink)
        let payload = try await mdoc.start(technology: .qr)
        SessionRegistry.release()
        let responder = LateResponder(issuerKey: issuerKey, deviceKey: deviceKey, did: did)
        mdoc.delegate = responder

        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(),
                                       transport: readerLink, trust: trust)
        try await reader.connect(to: try EngagementPayload.parse(qrString: payload.qrString!))
        let result = try await reader.request([ItemsRequestPresets.identity], at: Date())

        XCTAssertEqual(result.documents.count, 1, "링크를 끊은 뒤에도 검증은 끝까지 간다")
        XCTAssertEqual(reader.state, .completed)
        XCTAssertEqual(mdoc.state, .completed, "종료 통지는 실패가 아니다")
        await drainCallbacks()
        XCTAssertNil(responder.failure)
    }

    /// status 10·11 은 다르다 — **상대가 알려온 실패**이므로 그대로 올린다.
    func testPeerReportedFailureIsAnError() async throws {
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let mdoc = MdocDeviceSession(transport: mdocLink)
        _ = try await mdoc.start(technology: .qr)
        SessionRegistry.release()
        let responder = LateResponder(issuerKey: P256.Signing.PrivateKey(),
                                      deviceKey: P256.Signing.PrivateKey(), did: "did:omn:x")
        mdoc.delegate = responder

        try await readerLink.send(SessionCodec.encodeData(SessionData(status: 10)))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(mdoc.state, .failed)
        await drainCallbacks()
        XCTAssertEqual(responder.failure, .terminatedByPeer(status: 10))
    }

    /// **기본값은 발급자 검증을 하지 않는다**. 그때 판정은 `.unverified` 가
    /// 상한이고 — `deviceKey` 가 응답 안에 오므로 발급자 서명 없이는 그 키가 누구 것인지
    /// 말할 수 없다 — **해석기를 부르지도 않는다**(조회가 나가지 않는다).
    func testSkippingIssuerAuthNeverYieldsValid() async throws {
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        var resolverCalled = false
        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in
            resolverCalled = true
            return issuerKey.publicKey.x963Representation
        }

        let mdoc = MdocDeviceSession(transport: mdocLink)
        let payload = try await mdoc.start(technology: .qr)
        SessionRegistry.release()
        // delegate 는 weak 다 — 지역 변수로 잡아 두지 않으면 즉시 해제되고 응답이 오지 않는다
        let responder = LateResponder(issuerKey: issuerKey, deviceKey: deviceKey, did: did)
        mdoc.delegate = responder

        // 기본 설정 — skipIssuerAuth 는 true 다
        let reader = MdocReaderSession(transport: readerLink, trust: trust)
        XCTAssertTrue(MdocReaderConfiguration().skipIssuerAuth, "기본은 검증하지 않는다")
        try await reader.connect(to: try EngagementPayload.parse(qrString: payload.qrString!))
        let result = try await reader.request([ItemsRequestPresets.identity], at: Date())

        let doc = try XCTUnwrap(result.documents.first)
        XCTAssertTrue(doc.issuerDataAuth.verificationSkipped)
        XCTAssertFalse(doc.issuerDataAuth.signatureValid, "확인하지 않았으므로 참일 수 없다")
        XCTAssertFalse(resolverCalled, "검증하지 않을 키를 위해 조회를 내보내지 않는다")
        // 나머지는 그대로 한다 — 다이제스트·유효기간·deviceAuth
        XCTAssertEqual(doc.digests?.allMatch, true)
        XCTAssertTrue(doc.mdocAuth.valid)
        XCTAssertEqual(doc.issuerDataAuth.trust, .unknown)
        XCTAssertEqual(doc.verdict, .unverified, "건너뛰었으면 .valid 는 나오지 않는다")
    }

    /// **`deviceMac` 은 리더가 자기 임시키로 `ZAB'` 를 만들어야 검증된다**.
    /// 주입 경로에서는 그 키가 없어 이 축이 통째로 비어 있었다 — 배선 뒤에만 확인 가능하다.
    /// 월렛은 트랜스크립트에서 `EReaderKeyBytes` 를 꺼내 반대 방향으로 같은 값에 도달한다.
    func testDeviceMacVerifiesEndToEnd() async throws {
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in
            issuerKey.publicKey.x963Representation
        }

        let mdoc = MdocDeviceSession(transport: mdocLink)
        let payload = try await mdoc.start(technology: .qr)
        SessionRegistry.release()

        let responder = LateResponder(issuerKey: issuerKey, deviceKey: deviceKey, did: did, useMac: true)
        mdoc.delegate = responder

        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(),
                                       transport: readerLink, trust: trust)
        try await reader.connect(to: try EngagementPayload.parse(qrString: payload.qrString!))
        let result = try await reader.request([ItemsRequestPresets.identity], at: Date())

        let doc = try XCTUnwrap(result.documents.first)
        XCTAssertEqual(doc.mdocAuth.method, .mac)
        XCTAssertTrue(doc.mdocAuth.valid, "리더가 EMacKey 를 스스로 만들어야 한다")
        XCTAssertTrue(doc.mdocAuth.boundToIssuerDeviceKey)
    }
}

/// 트랜스크립트를 **콜백으로 받은 바이트에서** 만든다 — 테스트가 따로 계산하면
/// 양쪽이 같은 값에 도달했는지 확인할 수 없다.
private final class LateResponder: MdocDeviceSessionDelegate {
    private let issuerKey: P256.Signing.PrivateKey
    private let deviceKey: P256.Signing.PrivateKey
    private let did: String
    private let useMac: Bool
    private(set) var failure: MdocProximityError?

    init(issuerKey: P256.Signing.PrivateKey, deviceKey: P256.Signing.PrivateKey,
         did: String, useMac: Bool = false) {
        self.issuerKey = issuerKey; self.deviceKey = deviceKey; self.did = did; self.useMac = useMac
    }

    func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState) {}
    func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data,
                     sessionTranscript: Data) {
        let transcript = SessionTranscriptBytes(raw: sessionTranscript)
        let bytes = Fixtures.response(
            transcript: transcript, issuerKey: issuerKey, deviceKey: deviceKey, did: did,
            eMacKey: useMac ? try? Fixtures.eMacKey(transcript: transcript, deviceKey: deviceKey) : nil)
        Task { try? await s.respond(deviceResponse: bytes) }
    }
    func mdocSessionDidFinish(_ s: MdocDeviceSession) {}
    func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError) { failure = error }
}
