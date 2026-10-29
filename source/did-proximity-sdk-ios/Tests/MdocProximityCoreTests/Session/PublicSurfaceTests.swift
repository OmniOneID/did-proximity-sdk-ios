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

final class PublicSurfaceTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    override func tearDown() { SessionRegistry.release() }

    /// `l2capUpgrade` 는 설정에 있고 **세션이 그 값을 `TransportParameters.l2cap`
    /// 으로 전송체에 넘긴다.** 이 배선이 없으면 설정은 선언만 있는 값이 된다.
    func testL2capUpgradeReachesTransportParameters() async throws {
        XCTAssertFalse(MdocDeviceConfiguration().l2capUpgrade, "기본은 꺼짐이다")
        XCTAssertFalse(MdocReaderConfiguration().l2capUpgrade, "기본은 꺼짐이다")
        XCTAssertEqual(MdocReaderConfiguration().blePreferredMode, .peripheral,
                       "배포처 결정 — 표준 should(central) 와 다르지만 적합하다")

        // mdoc — 광고하는 모드 전부에 l2cap 이 실린다
        var device = MdocDeviceConfiguration()
        device.l2capUpgrade = true
        let df = RecordingFactory()
        let d = MdocDeviceSession(configuration: device, transportFactory: df)
        _ = try? await d.start(technology: .qr)      // 스텁이 던져 실패하지만 파라미터는 기록됐다
        XCTAssertFalse(df.seen.isEmpty)
        XCTAssertTrue(df.seen.allSatisfy { $0.l2cap }, "설정이 파라미터로 온다")
        d.terminate(); SessionRegistry.release()

        // 리더 — 고른 모드에 l2cap 이 실린다
        var reader = MdocReaderConfiguration()
        reader.l2capUpgrade = true
        let rf = RecordingFactory()
        let r = MdocReaderSession(configuration: reader,
                                  trust: DIDIssuerKeyResolver(trustedIssuers: ["did:omn:x"]) { _, _ in Data() },
                                  transportFactory: rf, nfcTagSource: UnavailableNfcTagSource())
        let engagement = try EngagementCodec.encode(
            eDeviceKeyBytes: EphemeralKeyPair().keyBytes,
            retrievalMethods: [DeviceRetrievalMethod(type: 2, version: 1, options: .map([
                CborPair(.unsigned(0), .bool(true)), CborPair(.unsigned(1), .bool(false)),
                CborPair(.unsigned(10), .bytes(Data(repeating: 1, count: 16)))]))])
        _ = try? await r.connect(to: try EngagementPayload.make(engagement))
        XCTAssertEqual(rf.seen.map(\.technology), [.ble(.peripheralServer)])
        XCTAssertEqual(rf.seen.first?.l2cap, true)
        r.terminate(); SessionRegistry.release()
    }

    /// 파라미터만 기록하고 던진다 — 라디오를 만들지 않는다
    private final class RecordingFactory: TransportFactoryProtocol {
        private(set) var seen: [TransportParameters] = []
        var availableTechnologies: [TransmissionTechnology] { [.ble(.centralClient), .ble(.peripheralServer), .nfc] }
        func makeTransport(_ p: TransportParameters) throws -> DataRetrievalTransportProtocol {
            seen.append(p); throw MdocProximityError.connectionFailed(detail: "stub")
        }
    }

    // 4.3.2 직렬화 — 두 플랫폼이 같은 바이트를 내야 하므로 키 사전순·compact 다
    func testRequestProfileSerialization() throws {
        let spec = ItemsRequestPresets.ageOver(18, includePortrait: true)
        let json = try spec.jsonData()
        let s = String(data: json, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("{\"docType\""), "키가 사전순이어야 한다: \(s)")
        XCTAssertFalse(s.contains("\n"), "compact 여야 한다")
        XCTAssertEqual(try ItemsRequestSpec.from(jsonData: json), spec)

        // 모르는 version 은 decodeFailed 로 거절한다
        let bad = Data("{\"version\":2,\"docType\":\"x\",\"items\":{}}".utf8)
        XCTAssertThrowsError(try ItemsRequestSpec.from(jsonData: bad)) { e in
            guard case MdocProximityError.decodeFailed = e else { return XCTFail("\(e)") }
        }
    }

    // engagement 생성 → QR 문자열 → 파싱 왕복
    func testEngagementRoundTrip() throws {
        let edk = OpaqueCBOR(preserving: CborEncoder.tag24(CborEncoder.encode(.map([
            CborPair(.unsigned(1), .unsigned(2))]))))
        let ble = CborValue.map([CborPair(.unsigned(0), .bool(true)),
                                 CborPair(.unsigned(1), .bool(false))])
        let bytes = try EngagementCodec.encode(
            eDeviceKeyBytes: edk,
            retrievalMethods: [DeviceRetrievalMethod(type: 2, version: 1, options: ble)])
        let payload = try EngagementPayload.make(bytes)
        XCTAssertTrue(payload.qrString!.hasPrefix("mdoc:"))
        XCTAssertEqual(payload.transmissions, [.ble(.peripheralServer)])

        let parsed = try EngagementPayload.parse(qrString: payload.qrString!)
        XCTAssertEqual(parsed.transmissions, payload.transmissions)
        // 파싱한 원본 바이트로 만든 트랜스크립트가 같아야 한다
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        XCTAssertEqual(parsed.sessionTranscript(eReaderKeyBytes: erk),
                       payload.sessionTranscript(eReaderKeyBytes: erk))
    }

    // 활성 세션은 프로세스당 하나
    func testOnlyOneActiveSession() throws {
        try SessionRegistry.claim("first")
        XCTAssertThrowsError(try SessionRegistry.claim("second")) { e in
            guard case MdocProximityError.invalidState = e else { return XCTFail("\(e)") }
        }
        SessionRegistry.release()
        XCTAssertNoThrow(try SessionRegistry.claim("third"))
    }

    // 값 타입 — 태그를 값으로 보존한다
    func testMdocValueMapping() {
        XCTAssertEqual(MdocValue(.tagged(1004, .text("1990-01-01"))), .fullDate("1990-01-01"))
        XCTAssertEqual(MdocValue(.tagged(0, .text("2026-01-01T00:00:00Z"))), .dateTime("2026-01-01T00:00:00Z"))
        XCTAssertEqual(MdocValue(.negative(0)), .integer(-1))
        XCTAssertEqual(MdocValue(.bool(true)).asBoolean, true)

        // **표현하지 못하는 값은 .unsupported 다 — 조용히 다른 것이 되지 않는다**
        // 모르는 태그: 떼고 내려가면 bignum 이 .bytes 로 보인다
        XCTAssertEqual(MdocValue(.tagged(2, .bytes(Data([0x01])))), .unsupported)
        XCTAssertEqual(MdocValue(.tagged(1004, .unsigned(3))), .unsupported, "태그는 맞고 안쪽이 다르다")
        // 문자열이 아닌 키를 가진 맵: 버리면 빈 맵으로 보인다
        XCTAssertEqual(MdocValue(.map([CborPair(.unsigned(1), .text("x"))])), .unsupported)
        XCTAssertEqual(MdocValue(.map([CborPair(.text("a"), .text("x"))])), .map(["a": .text("x")]))
        // Int64 범위를 넘는 정수: Int64(n) 은 트랩이라 그대로 두면 프로세스가 죽는다
        XCTAssertEqual(MdocValue(.unsigned(UInt64.max)), .unsupported)
        XCTAssertEqual(MdocValue(.negative(UInt64.max)), .unsupported)
        XCTAssertEqual(MdocValue(.unsigned(UInt64(Int64.max))), .integer(Int64.max))
    }

    // 보관 의무 — intentToRetain 이 true 인 것만, 그리고 digest 가 맞은 것만
    func testRetainableElements() async throws {
        let eD = P256.KeyAgreement.PrivateKey(), eR = P256.KeyAgreement.PrivateKey()
        let zab = try eR.sharedSecretFromKeyAgreement(with: eD.publicKey).withUnsafeBytes { Data($0) }
        let transcript = SessionTranscriptBuilder.qr(
            deviceEngagementBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0]))),
            eReaderKeyBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0]))))
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in
            issuerKey.publicKey.x963Representation }

        let (rl, ml) = LoopbackTransport.pair()
        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(),
                                       transport: rl, trust: trust)
        let mdoc = MdocDeviceSession(transport: ml)
        let responder = AutoResponder(session: mdoc) {
            Fixtures.response(transcript: transcript, issuerKey: issuerKey,
                              deviceKey: deviceKey, did: did)
        }
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        reader.begin(transcript: transcript, sharedSecret: zab, eReaderKeyBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0]))))

        // family_name 은 보관 요청(true), portrait 는 아니다
        let spec = ItemsRequestSpec(docType: "org.iso.18013.5.1.mDL",
                                    items: ["org.iso.18013.5.1": ["family_name": true, "portrait": false]])
        let result = try await reader.request([spec], at: Date())

        let doc = result.documents[0]
        XCTAssertEqual(doc.verdict, .valid)
        XCTAssertEqual(doc.provenance("org.iso.18013.5.1", "family_name"), .issuerSigned)

        let keep = doc.retainableElements()
        XCTAssertEqual(keep["org.iso.18013.5.1"]?.count, 1)
        XCTAssertEqual(keep["org.iso.18013.5.1"]?["family_name"], .text("Doe"))
        XCTAssertNil(keep["org.iso.18013.5.1"]?["portrait"], "보관 요청이 없는 것은 빠져야 한다")
    }

    // MARK: - 검증 결과 모델

    /// 출처별 분리·경고·보관 범위가 제대로 나오는가. 응답에 **요청하지 않은
    /// 미정의 요소**, **Table 5 요소가 DeviceSigned 로**, **도메스틱 네임스페이스**를 섞는다.
    func testWarningsProvenanceAndRetainable() async throws {
        let iso = MdocDocTypes.mDLNameSpace, kr = "org.iso.18013.5.1.KR"
        let (reader, mdoc, responder) = try makeFacades {
            Fixtures.response(
                transcript: $0, issuerKey: $1, deviceKey: $2, did: $3,
                extraIssuerItems: [(iso, "favourite_colour", .text("blue"))],
                deviceNameSpaces: [iso: ["portrait": .bytes(Data([1, 2, 3]))],
                                   kr: ["resident_registration": .text("x")]])
        }
        let spec = ItemsRequestSpec(docType: MdocDocTypes.mDL,
                                    items: [iso: ["family_name": true, "portrait": false]])
        let doc = try await reader.request([spec], at: Date()).documents[0]
        _ = (mdoc, responder)

        // 출처별 분리 — DeviceSigned 는 발급자가 보증하지 않는다
        XCTAssertEqual(doc.issuerSignedElements[iso]?.keys.sorted(), ["family_name", "favourite_colour"])
        XCTAssertEqual(doc.deviceSignedElements[iso]?["portrait"], .bytes(Data([1, 2, 3])))
        XCTAssertEqual(doc.deviceSignedElements[kr]?["resident_registration"], .text("x"))
        XCTAssertEqual(doc.provenance(iso, "family_name"), .issuerSigned)
        XCTAssertEqual(doc.provenance(iso, "portrait"), .deviceSigned)
        XCTAssertNil(doc.provenance(iso, "nope"))
        XCTAssertEqual(doc.allElements[iso]?.count, 3)
        // portrait 는 DeviceSigned 로라도 왔으므로 미제공이 아니다
        XCTAssertEqual(doc.notReturned, [:])

        // 경고 — 요청하지 않은 요소만. 네임스페이스는 판단하지 않고(8.3.1 — 제한 없음), ISO 네임스페이스
        // 안 식별자의 Table 5 대조는 보류다. 네임스페이스·식별자 사전순
        XCTAssertEqual(doc.warnings, [
            .unrequestedElement(iso, "favourite_colour"),
            .unrequestedElement(kr, "resident_registration")])

        // 검증은 경고와 무관하게 전부 했다 — 모르는 요소도 digest 대조에 들어간다
        XCTAssertEqual(doc.digests?.matches[iso]?["favourite_colour"], true)
        XCTAssertEqual(doc.digests?.allMatch, true)
        XCTAssertEqual(doc.verdict, .valid)

        // 보관 범위 — 요청에서 true 로 선언한 것만. 요청하지 않은 것은 어떤 경우에도 없다
        XCTAssertEqual(doc.retainable, [iso: ["family_name"]])
        XCTAssertEqual(doc.retainableElements(), [iso: ["family_name": .text("Doe")]])
        XCTAssertEqual(doc.retainableElements(requiringValidDigest: false), [iso: ["family_name": .text("Doe")]])
    }

    /// elementValue 에 float 가 와도 그 항목이 빠지지 않는다 — 값은 `.unsupported`, 다이제스트는
    /// 원본 바이트로 대조된다. 전에는 디코딩 실패로 조용히 빠져 `notReturned` 로 보였다.
    func testFloatElementValueIsKeptAsUnsupported() async throws {
        let iso = MdocDocTypes.mDLNameSpace
        let (reader, mdoc, responder) = try makeFacades {
            Fixtures.response(transcript: $0, issuerKey: $1, deviceKey: $2, did: $3,
                              extraIssuerItems: [(iso, "height_cm", .float(172.5))])
        }
        let spec = ItemsRequestSpec(docType: MdocDocTypes.mDL, items: [iso: ["family_name": false, "height_cm": false]])
        let doc = try await reader.request([spec], at: Date()).documents[0]
        _ = (mdoc, responder)
        XCTAssertEqual(doc.issuerSignedElements[iso]?["height_cm"], .unsupported)
        XCTAssertEqual(doc.digests?.matches[iso]?["height_cm"], true)
        XCTAssertEqual(doc.notReturned, [:])
        XCTAssertEqual(doc.verdict, .valid)
    }

    /// 목록 밖 발급자는 키가 없어 서명을 대조하지 못했다 — "틀렸다"(.invalid)가 아니라
    /// "판정 불가"(.unverified)다 (`VerificationVerdict`).
    func testIssuerOutsideListIsUnverifiedNotInvalid() async throws {
        let (reader, mdoc, responder) = try makeFacades(
            trust: { _ in DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() } }) {
            Fixtures.response(transcript: $0, issuerKey: $1, deviceKey: $2, did: $3)
        }
        let doc = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date()).documents[0]
        _ = (mdoc, responder)
        guard case .untrusted = doc.issuerDataAuth.trust else { return XCTFail("\(doc.issuerDataAuth.trust)") }
        XCTAssertFalse(doc.issuerDataAuth.signatureValid)
        XCTAssertEqual(doc.verdict, .unverified)
    }

    /// 세션 중에 키를 못 찾은 문서(`trust == .unknown`)는 `resolveTrust` 가 받은 키로
    /// **서명을 다시 대조한다**. 전에는 trust 만 바뀌고 서명은 처음 값(false)에 머물렀다.
    func testResolveTrustReverifiesSignature() async throws {
        let (reader, mdoc, responder) = try makeFacades(
            trust: { _ in DIDIssuerKeyResolver(trustedIssuers: ["did:omn:issuer"]) { _, _ in
                throw MdocProximityError.peerDisconnected } }) {
            Fixtures.response(transcript: $0, issuerKey: $1, deviceKey: $2, did: $3)
        }
        let doc = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date()).documents[0]
        _ = (mdoc, responder)
        XCTAssertEqual(doc.issuerDataAuth.trust, .unknown)
        XCTAssertEqual(doc.verdict, .unverified, "키를 못 찾았으면 판정 불가다")

        // 엉뚱한 키 — 대조했더니 틀렸다
        let wrong = DIDIssuerKeyResolver(trustedIssuers: ["did:omn:issuer"]) { _, _ in
            P256.Signing.PrivateKey().publicKey.x963Representation }
        let bad = await MdocReaderSession.resolveTrust(for: doc, using: wrong, at: Date())
        XCTAssertEqual(bad.issuerDataAuth.trust, .trusted)
        XCTAssertFalse(bad.issuerDataAuth.signatureValid)
        XCTAssertEqual(bad.verdict, .invalid)
    }

    /// 같은 문서에 맞는 키가 오면 `.valid` 까지 간다.
    func testResolveTrustWithRightKeyYieldsValid() async throws {
        var key: P256.Signing.PrivateKey?
        let (reader, mdoc, responder) = try makeFacades(
            trust: { k in key = k
                return DIDIssuerKeyResolver(trustedIssuers: ["did:omn:issuer"]) { _, _ in
                    throw MdocProximityError.peerDisconnected } }) {
            Fixtures.response(transcript: $0, issuerKey: $1, deviceKey: $2, did: $3)
        }
        let doc = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date()).documents[0]
        _ = (mdoc, responder)
        let pub = try XCTUnwrap(key).publicKey.x963Representation
        let right = DIDIssuerKeyResolver(trustedIssuers: ["did:omn:issuer"]) { _, _ in pub }
        let resolved = await MdocReaderSession.resolveTrust(for: doc, using: right, at: Date())
        XCTAssertTrue(resolved.issuerDataAuth.signatureValid)
        XCTAssertEqual(resolved.verdict, .valid)
    }

    /// `skipIssuerAuth` 로 건너뛴 문서는 `resolveTrust` 가 조회도 하지 않고 신뢰도 올리지 않는다 —
    /// 서명을 보지 않은 문서가 `.trusted` 가 되면 안 된다.
    func testResolveTrustLeavesSkippedDocumentAlone() async throws {
        var config = verifyingReaderConfiguration(responseTimeout: 3)
        config.skipIssuerAuth = true
        let (reader, mdoc, responder) = try makeFacades(configuration: config) {
            Fixtures.response(transcript: $0, issuerKey: $1, deviceKey: $2, did: $3)
        }
        let doc = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date()).documents[0]
        _ = (mdoc, responder)
        var called = false
        let probe = DIDIssuerKeyResolver(trustedIssuers: ["did:omn:issuer"]) { _, _ in
            called = true; return Data() }
        let after = await MdocReaderSession.resolveTrust(for: doc, using: probe, at: Date())
        XCTAssertFalse(called, "건너뛴 문서를 위해 조회하지 않는다")
        XCTAssertEqual(after.issuerDataAuth.trust, .unknown)
        XCTAssertEqual(after.verdict, .unverified)
    }

    /// 9.1.3.4 — MSO `keyAuthorizations` 가 허가하지 않은 deviceSigned 요소는 값에서 빠지고
    /// `.unauthorizedDeviceSignedElement` 경고로 남는다. 허가는 네임스페이스 전체 또는 요소 단위다.
    /// 나머지 문서 판정은 그대로다 (문서 전체를 무효로 하지 않는다).
    func testDeviceSignedElementsOutsideKeyAuthorizationsAreDropped() async throws {
        let iso = MdocDocTypes.mDLNameSpace, kr = "org.iso.18013.5.1.KR"
        let (reader, mdoc, responder) = try makeFacades {
            Fixtures.response(
                transcript: $0, issuerKey: $1, deviceKey: $2, did: $3,
                deviceNameSpaces: [iso: ["portrait": .bytes(Data([1])), "sex": .unsigned(1)],
                                   kr: ["resident_registration": .text("x")]],
                keyAuthorizations: .map([CborPair(.text("dataElements"), .map([
                    CborPair(.text(iso), .array([.text("portrait")]))]))]))
        }
        let spec = ItemsRequestSpec(docType: MdocDocTypes.mDL,
                                    items: [iso: ["family_name": false, "portrait": false, "sex": false],
                                            kr: ["resident_registration": false]])
        let doc = try await reader.request([spec], at: Date()).documents[0]
        _ = (mdoc, responder)

        XCTAssertEqual(doc.deviceSignedElements, [iso: ["portrait": .bytes(Data([1]))]])
        XCTAssertEqual(doc.warnings, [
            .unauthorizedDeviceSignedElement(iso, "sex"),
            .unauthorizedDeviceSignedElement(kr, "resident_registration")])
        XCTAssertEqual(doc.notReturned, [iso: ["sex"], kr: ["resident_registration"]],
                       "허가 밖 요소는 쓸 수 없으므로 미제공과 같다")
        XCTAssertEqual(doc.verdict, .valid)
    }

    // mDL 편의 상수와 세 프리셋
    func testDocTypesAndPresets() {
        XCTAssertEqual(MdocDocTypes.mDL, "org.iso.18013.5.1.mDL")
        XCTAssertEqual(MdocDocTypes.mDLNameSpace, "org.iso.18013.5.1")
        XCTAssertEqual(ItemsRequestPresets.drivingPrivileges.items[MdocDocTypes.mDLNameSpace]?.keys.sorted(),
                       ["document_number", "driving_privileges", "expiry_date"])
        XCTAssertTrue(ItemsRequestPresets.drivingPrivileges.items.values.allSatisfy { $0.values.allSatisfy { !$0 } },
                      "프리셋은 전부 intentToRetain = false 다")
        // 프로파일 왕복 — SDK 가 책임지는 것은 포맷 하나다
        let round = try? ItemsRequestSpec.from(jsonData: ItemsRequestPresets.identity.jsonData())
        XCTAssertEqual(round, ItemsRequestPresets.identity)
    }

    // MARK: - 스레딩 / 진행률

    /// 델리게이트는 `callbackQueue` 에서 온다 — 기본은 메인이고, 바꾸면 그 큐다.
    func testCallbacksArriveOnConfiguredQueue() async throws {
        let key = DispatchSpecificKey<String>()
        let queue = DispatchQueue(label: "app.callbacks")
        queue.setSpecific(key: key, value: "app")
        var configuration = MdocReaderConfiguration()
        configuration.callbackQueue = queue

        let (rl, _) = LoopbackTransport.pair()
        let trust = DIDIssuerKeyResolver(trustedIssuers: ["did:omn:x"]) { _, _ in Data() }
        let reader = MdocReaderSession(configuration: configuration, transport: rl, trust: trust)
        let observer = QueueObserver(key: key)
        reader.delegate = observer
        reader.begin(transcript: SessionTranscriptBytes(raw: Data([0x83, 0xf6, 0xf6, 0xf6])),
                     sharedSecret: Data(repeating: 1, count: 32),
                     eReaderKeyBytes: OpaqueCBOR(preserving: Data([0xa0])))
        await fulfillment(of: [observer.seen], timeout: 2)
        XCTAssertEqual(observer.queueMarker, "app", "설정한 큐에서 불려야 한다")
        XCTAssertEqual(observer.states, [.connected])
    }

    /// mdoc 측 `didProgress` — 응답 전송 진행률이 델리게이트로 나온다.
    func testDeviceProgressCallback() async throws {
        let (reader, mdoc, responder) = try makeFacades {
            Fixtures.response(transcript: $0, issuerKey: $1, deviceKey: $2, did: $3)
        }
        _ = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date())
        _ = mdoc
        await drainCallbacks()
        let p = try XCTUnwrap(responder.progress, "전송이 있었으면 진행률이 한 번은 와야 한다")
        XCTAssertEqual(p.sent, p.total)
        XCTAssertGreaterThan(p.total, 0)
    }

    // MARK: -

    /// Loopback 으로 이어진 리더·mdoc 파사드 한 쌍. 발급자 검증은 켠다.
    /// **mdoc 세션도 돌려준다** — `AutoResponder` 는 weak 로만 잡으므로 호출자가 살려 둬야 한다.
    private func makeFacades(
        configuration: MdocReaderConfiguration = verifyingReaderConfiguration(responseTimeout: 3),
        trust makeTrust: ((P256.Signing.PrivateKey) -> TrustEvaluatorProtocol)? = nil,
        response: @escaping (SessionTranscriptBytes, P256.Signing.PrivateKey, P256.Signing.PrivateKey, String) -> Data
    ) throws -> (MdocReaderSession, MdocDeviceSession, AutoResponder) {
        let eD = P256.KeyAgreement.PrivateKey(), eR = P256.KeyAgreement.PrivateKey()
        let zab = try eR.sharedSecretFromKeyAgreement(with: eD.publicKey).withUnsafeBytes { Data($0) }
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let trust = makeTrust?(issuerKey)
            ?? DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in issuerKey.publicKey.x963Representation }
        let (rl, ml) = LoopbackTransport.pair()
        let reader = MdocReaderSession(configuration: configuration, transport: rl, trust: trust)
        let mdoc = MdocDeviceSession(transport: ml)
        let responder = AutoResponder(session: mdoc) { response(transcript, issuerKey, deviceKey, did) }
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        reader.begin(transcript: transcript, sharedSecret: zab, eReaderKeyBytes: erk)
        return (reader, mdoc, responder)
    }
}

private final class QueueObserver: MdocReaderSessionDelegate {
    let seen = XCTestExpectation(description: "state callback")
    private let key: DispatchSpecificKey<String>
    private(set) var queueMarker: String?
    private(set) var states: [MdocReaderState] = []
    init(key: DispatchSpecificKey<String>) { self.key = key }

    func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState) {
        queueMarker = DispatchQueue.getSpecific(key: key)
        states.append(state)
        seen.fulfill()
    }
    func readerSessionDidConnect(_ s: MdocReaderSession) {}
    func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int) {}
    func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError) {}
}
