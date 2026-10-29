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

final class SessionFacadeTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    // DID 본체 정규화 — 쿼리·프래그먼트를 떼지 않으면 키 회전마다 매칭이 깨진다 (6.2.1 규칙 3)
    func testDidNormalization() {
        let (body, version) = DIDIssuerKeyResolver.normalize("did:omn:issuer?versionId=1#assert")
        XCTAssertEqual(body, "did:omn:issuer")
        XCTAssertEqual(version, "1")
        XCTAssertEqual(DIDIssuerKeyResolver.normalize("did:omn:issuer").body, "did:omn:issuer")
    }

    // 규칙 2 — 빈 목록은 "전부 허용"이 아니라 **전부 거부**다 (fail-closed)
    func testEmptyListRejectsAll() async {
        let r = DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() }
        let out = await r.evaluate(header: COSEHeaderSummary(kid: "did:omn:issuer#assert", algorithm: -7),
                                   purpose: .issuerDataAuthentication, at: Date())
        guard case .untrusted = out.trust else { return XCTFail("빈 목록은 전부 거부여야 한다") }
        XCTAssertNil(out.publicKey)
    }

    // 규칙 4 — 목록 확인이 조회보다 먼저다. 허용하지 않을 발급자를 위해 외부에 요청하지 않는다
    func testListCheckedBeforeResolve() async {
        var resolveCalled = false
        let r = DIDIssuerKeyResolver(trustedIssuers: ["did:omn:other"]) { _, _ in
            resolveCalled = true; return Data()
        }
        _ = await r.evaluate(header: COSEHeaderSummary(kid: "did:omn:issuer#assert", algorithm: -7),
                             purpose: .issuerDataAuthentication, at: Date())
        XCTAssertFalse(resolveCalled, "목록에 없는 발급자를 위해 조회하면 안 된다")
    }

    /// 세션 파사드로 전 흐름 — 요청 생성부터 검증까지
    func testFullSessionThroughFacades() async throws {
        let eDevice = P256.KeyAgreement.PrivateKey(), eReader = P256.KeyAgreement.PrivateKey()
        let zab = try eReader.sharedSecretFromKeyAgreement(with: eDevice.publicKey)
            .withUnsafeBytes { Data($0) }
        let transcript = SessionTranscriptBuilder.qr(
            deviceEngagementBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0]))),
            eReaderKeyBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa1, 0x01, 0x02]))))

        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { d, _ in
            XCTAssertEqual(d, did, "본체로 정규화된 DID 가 넘어와야 한다")
            return issuerKey.publicKey.x963Representation
        }

        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(),
                                       transport: readerLink, trust: trust)
        let mdoc = MdocDeviceSession(transport: mdocLink)
        let responder = AutoResponder(session: mdoc) {
            Fixtures.response(transcript: transcript, issuerKey: issuerKey,
                              deviceKey: deviceKey, did: did)
        }
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        reader.begin(transcript: transcript, sharedSecret: zab, eReaderKeyBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0]))))

        // mdoc 측: 요청이 오면 응답을 만들어 보낸다 (월렛 자리는 테스트가 대신한다)

        // 리더 측: 두 요소를 요청한다 — 응답에는 하나만 담긴다
        let spec = ItemsRequestSpec(docType: "org.iso.18013.5.1.mDL",
                                    items: ["org.iso.18013.5.1": ["family_name": false,
                                                                  "portrait": true]])
        let result = try await reader.request([spec], at: Date())

        await drainCallbacks()
        XCTAssertTrue(responder.finished)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.documents.count, 1)
        let doc = result.documents[0]

        XCTAssertEqual(doc.issuerDataAuth.trust, .trusted)
        XCTAssertEqual(doc.issuerDataAuth.source, .did(method: "omn"))
        XCTAssertTrue(doc.issuerDataAuth.signatureValid)
        XCTAssertEqual(doc.digests?.allMatch, true)
        XCTAssertEqual(doc.issuerDataAuth.validity?.isCurrentlyValid, true)
        XCTAssertTrue(doc.mdocAuth.valid)

        // **부분 응답은 실패가 아니다** — 누락은 요청 ∖ 응답으로 계산한다
        XCTAssertEqual(doc.notReturned["org.iso.18013.5.1"], ["portrait"])
        XCTAssertNotNil(doc.issuerSignedElements["org.iso.18013.5.1"]?["family_name"])
        XCTAssertEqual(reader.state, .completed)

        // 세션당 1회 — 두 번째 요청은 invalidState
        do { _ = try await reader.request([spec], at: Date()); XCTFail("재사용이 막혀야 한다") }
        catch { guard case MdocProximityError.invalidState = error else { return XCTFail("\(error)") } }

        // 종단 상태에서 terminate() 는 상태를 바꾸지 않는다
        reader.terminate()
        XCTAssertEqual(reader.state, .completed)
    }
}

/// 신뢰하지 않는 응답이 리더를 **트랩**시키면 안 된다 — 거절은 오류지 크래시가 아니다
final class UntrustedResponseTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }
    override func tearDown() { SessionRegistry.release() }

    private func duplicateFamilyName(transcript: SessionTranscriptBytes,
                                     issuerKey: P256.Signing.PrivateKey,
                                     deviceKey: P256.Signing.PrivateKey) -> Data {
        Fixtures.response(transcript: transcript, issuerKey: issuerKey, deviceKey: deviceKey,
                          did: "did:omn:issuer",
                          extraIssuerItems: [("org.iso.18013.5.1", "family_name", .text("Roe"))])
    }

    /// 한 네임스페이스에 같은 `elementIdentifier` 가 둘 — 코덱이 `validationFailed` 로 거절한다.
    /// 전에는 리더가 요소 사전을 만들다 `Dictionary(uniqueKeysWithValues:)` 에서 트랩했다.
    func testDuplicateElementIdentifierIsRejectedByCodec() throws {
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)
        let bytes = duplicateFamilyName(transcript: transcript, issuerKey: P256.Signing.PrivateKey(),
                                        deviceKey: P256.Signing.PrivateKey())
        XCTAssertThrowsError(try ResponseCodec.decode(bytes)) { error in
            guard case MdocProximityError.validationFailed(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("family_name"), detail)
        }
    }

    /// 리더 세션 끝까지 — `request` 가 throw 하고 상태는 `failed` 다(`verifying` 에 남지 않는다)
    func testDuplicateElementIdentifierFailsRequest() async throws {
        let eDevice = P256.KeyAgreement.PrivateKey(), eReader = P256.KeyAgreement.PrivateKey()
        let zab = try eReader.sharedSecretFromKeyAgreement(with: eDevice.publicKey).withUnsafeBytes { Data($0) }
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let reader = MdocReaderSession(transport: readerLink,
                                       trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() })
        let mdoc = MdocDeviceSession(transport: mdocLink)
        let responder = AutoResponder(session: mdoc) { [self] in
            duplicateFamilyName(transcript: transcript, issuerKey: issuerKey, deviceKey: deviceKey)
        }
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        reader.begin(transcript: transcript, sharedSecret: zab, eReaderKeyBytes: erk)
        do {
            _ = try await reader.request([ItemsRequestPresets.ageOver(18)], at: Date())
            XCTFail("중복 식별자는 거절돼야 한다")
        } catch {
            guard case MdocProximityError.validationFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(reader.state, .failed)
        _ = responder
    }

    /// 입구 포맷 오류(빈 목록·`docType` 중복)는 세션을 **소비하지 않는다** — 상태는 `connected` 그대로,
    /// 고쳐서 다시 부르면 진행된다. 전에는 `requested` 가 먼저 참이 돼 재시도가 전부 `invalidState` 였다
    func testRequestFormatErrorDoesNotConsumeSession() async throws {
        let eDevice = P256.KeyAgreement.PrivateKey(), eReader = P256.KeyAgreement.PrivateKey()
        let zab = try eReader.sharedSecretFromKeyAgreement(with: eDevice.publicKey).withUnsafeBytes { Data($0) }
        let erk = OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0])))
        let transcript = SessionTranscriptBuilder.qr(deviceEngagementBytes: erk, eReaderKeyBytes: erk)
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let reader = MdocReaderSession(transport: readerLink,
                                       trust: DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in issuerKey.publicKey.x963Representation })
        let mdoc = MdocDeviceSession(transport: mdocLink)
        let responder = AutoResponder(session: mdoc) {
            Fixtures.response(transcript: transcript, issuerKey: issuerKey, deviceKey: deviceKey, did: did)
        }
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        reader.begin(transcript: transcript, sharedSecret: zab, eReaderKeyBytes: erk)

        let spec = ItemsRequestPresets.ageOver(18)
        for bad in [[ItemsRequestSpec](), [spec, spec]] {
            do { _ = try await reader.request(bad, at: Date()); XCTFail("포맷 오류는 던져야 한다") }
            catch { guard case MdocProximityError.validationFailed = error else { return XCTFail("\(error)") } }
            XCTAssertEqual(reader.state, .connected, "입구 오류는 상태를 건드리지 않는다")
        }
        let result = try await reader.request([spec], at: Date())
        XCTAssertEqual(reader.state, .completed)
        XCTAssertEqual(result.documents.count, 1)
        _ = responder
    }
}

enum Fixtures {
    /// 트랜스크립트 둘째 원소가 `EReaderKeyBytes` 다. 월렛은 여기서 리더의 공개키를 얻어
    /// `ZAB'` 를 만든다 — **리더가 자기 개인키로 만드는 것과 같은 값**이어야 한다.
    static func eReaderKeyBytes(in transcript: SessionTranscriptBytes) throws -> OpaqueCBOR {
        let inner = try SessionTranscriptBuilder.transcriptArray(transcript)
        let node = try CborDecoder.decodeNode(inner)
        return OpaqueCBOR(node.children[1], in: inner)
    }

    /// 월렛 자리 — `deviceMac` 을 만들 때 쓰는 키. 리더와 **반대 방향**으로 합의한다.
    static func eMacKey(transcript: SessionTranscriptBytes,
                        deviceKey: P256.Signing.PrivateKey) throws -> Data {
        let readerPublic = try CoseKey.x963(fromKeyBytes: try eReaderKeyBytes(in: transcript))
        let priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: deviceKey.rawRepresentation)
        let zabPrime = try priv.sharedSecretFromKeyAgreement(
            with: try P256.KeyAgreement.PublicKey(x963Representation: readerPublic))
            .withUnsafeBytes { Data($0) }
        return KeyDerivation.eMacKey(zabPrime: zabPrime, transcript: transcript)
    }

    /// `eMacKey` 를 주면 `deviceMac`, 안 주면 `deviceSignature` 다 — 방식은 키가 정한다.
    static func response(transcript: SessionTranscriptBytes,
                         issuerKey: P256.Signing.PrivateKey,
                         deviceKey: P256.Signing.PrivateKey,
                         did: String,
                         eMacKey: Data? = nil,
                         /// `family_name` 뒤에 더 싣는 IssuerSigned 요소 — 전부 MSO 에 다이제스트가 있다
                         extraIssuerItems: [(NameSpace, DataElementIdentifier, CborValue)] = [],
                         /// DeviceSigned 로 싣는 요소. 서명 입력이므로 바이트가 그대로 DeviceAuth 에 들어간다
                         deviceNameSpaces: [NameSpace: [DataElementIdentifier: CborValue]] = [:],
                         /// MSO `keyAuthorizations`. 기본은 `deviceNameSpaces` 의 네임스페이스 전체를 허가한다
                         keyAuthorizations: CborValue? = nil) -> Data {
        let ns = "org.iso.18013.5.1", docType = "org.iso.18013.5.1.mDL"
        var entries: [(NameSpace, Data)] = []      // (ns, IssuerSignedItemBytes)
        var digests: [NameSpace: [CborPair]] = [:]
        for (i, e) in ([(ns, "family_name", CborValue.text("Doe"))] + extraIssuerItems).enumerated() {
            let item = CborEncoder.tag24(CborEncoder.encode(.map([
                CborPair(.text("digestID"), .unsigned(UInt64(i + 1))),
                CborPair(.text("random"), .bytes(Data(repeating: 7, count: 16))),
                CborPair(.text("elementIdentifier"), .text(e.1)),
                CborPair(.text("elementValue"), e.2)])))
            entries.append((e.0, item))
            digests[e.0, default: []].append(CborPair(.unsigned(UInt64(i + 1)), .bytes(Data(SHA256.hash(data: item)))))
        }
        let r = deviceKey.publicKey.x963Representation
        let auth = keyAuthorizations ?? (deviceNameSpaces.isEmpty ? nil : .map([
            CborPair(.text("nameSpaces"), .array(deviceNameSpaces.keys.sorted().map { .text($0) }))]))
        let mso = CborEncoder.tag24(CborEncoder.encode(.map([
            CborPair(.text("version"), .text("1.0")),
            CborPair(.text("digestAlgorithm"), .text("SHA-256")),
            CborPair(.text("valueDigests"), .map(digests.keys.sorted().map {
                CborPair(.text($0), .map(digests[$0]!)) })),
            CborPair(.text("deviceKeyInfo"), .map([CborPair(.text("deviceKey"), .map([
                CborPair(.unsigned(1), .unsigned(2)), CborPair(.negative(0), .unsigned(1)),
                CborPair(.negative(1), .bytes(r.subdata(in: 1..<33))),
                CborPair(.negative(2), .bytes(r.subdata(in: 33..<65)))]))]
                + (auth.map { [CborPair(.text("keyAuthorizations"), $0)] } ?? []))),
            CborPair(.text("docType"), .text(docType)),
            CborPair(.text("validityInfo"), .map([
                CborPair(.text("signed"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
                CborPair(.text("validFrom"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
                CborPair(.text("validUntil"), .tagged(0, .text("2027-01-01T00:00:00Z")))]))])))
        let isig = try! issuerKey.signature(for: SigStructure.bytes(
            protected: CoseConstants.protectedES256, payload: mso))
        let dns = OpaqueCBOR(preserving: CborEncoder.tag24(CborEncoder.encode(.map(
            deviceNameSpaces.keys.sorted().map { space in
                CborPair(.text(space), .map(deviceNameSpaces[space]!.keys.sorted().map {
                    CborPair(.text($0), deviceNameSpaces[space]![$0]!) })) }))))
        let dab = try! DeviceAuthenticationBuilder.taggedBytes(
            transcript: transcript, docType: docType, deviceNameSpacesBytes: dns)
        let dsig = try! deviceKey.signature(for: SigStructure.bytes(
            protected: CoseConstants.protectedES256, payload: dab))
        let deviceAuth: CborValue
        if let eMacKey {
            let tag = Data(HMAC<SHA256>.authenticationCode(
                for: MacStructure.bytes(protected: CoseConstants.protectedHMAC256, payload: dab),
                using: SymmetricKey(data: eMacKey)))
            deviceAuth = .map([CborPair(.text("deviceMac"), .array([
                .bytes(CoseConstants.protectedHMAC256), .map([]), .null, .bytes(tag)]))])
        } else {
            deviceAuth = .map([CborPair(.text("deviceSignature"), .array([
                .bytes(CoseConstants.protectedES256), .map([]), .null,
                .bytes(dsig.rawRepresentation)]))])
        }
        return CborEncoder.encode(.map([
            CborPair(.text("version"), .text("1.0")),
            CborPair(.text("documents"), .array([.map([
                CborPair(.text("docType"), .text(docType)),
                CborPair(.text("issuerSigned"), .map([
                    CborPair(.text("nameSpaces"), .map(Set(entries.map(\.0)).sorted().map { space in
                        CborPair(.text(space), .array(entries.filter { $0.0 == space }
                                                          .map { try! CborDecoder.decode($0.1) })) })),
                    CborPair(.text("issuerAuth"), .array([
                        .bytes(CoseConstants.protectedES256),
                        .map([CborPair(.unsigned(4), .bytes(Data("\(did)?versionId=1#assert".utf8)))]),
                        .bytes(mso), .bytes(isig.rawRepresentation)]))])),
                CborPair(.text("deviceSigned"), .map([
                    CborPair(.text("nameSpaces"), try! CborDecoder.decode(dns.raw)),
                    CborPair(.text("deviceAuth"), deviceAuth)]))])])),
            CborPair(.text("status"), .unsigned(0))]))
    }
}

/// 기본값이 "검증하지 않음"이므로, **발급자 서명을 보는 시험은 명시적으로 켠다**
///
func verifyingReaderConfiguration(responseTimeout: TimeInterval? = nil) -> MdocReaderConfiguration {
    var c = MdocReaderConfiguration()
    c.skipIssuerAuth = false
    if let responseTimeout { c.responseTimeout = responseTimeout }
    return c
}
