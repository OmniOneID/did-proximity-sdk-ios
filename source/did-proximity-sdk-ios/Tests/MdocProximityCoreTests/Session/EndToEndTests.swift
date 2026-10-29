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

/// **한 프로세스에서 mdoc ↔ mdoc reader 전 세션 성공**.
/// 신뢰 판정은 하지 않는다(MdocTrust 몫이다). 키는 stub resolver 로 주입한다.
final class EndToEndTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    func testFullSessionOverLoopback() async throws {
        // ── engagement (QR) ──────────────────────────────────────────────
        let eDevice = P256.KeyAgreement.PrivateKey()
        let eReader = P256.KeyAgreement.PrivateKey()
        func coseKey(_ pub: P256.KeyAgreement.PublicKey) -> Data {
            let r = pub.x963Representation
            return CborEncoder.tag24(CborEncoder.encode(.map([
                CborPair(.unsigned(1), .unsigned(2)), CborPair(.negative(0), .unsigned(1)),
                CborPair(.negative(1), .bytes(r.subdata(in: 1..<33))),
                CborPair(.negative(2), .bytes(r.subdata(in: 33..<65)))])))
        }
        let edkBytes = coseKey(eDevice.publicKey)
        let engagement = CborEncoder.encode(.map([
            CborPair(.unsigned(0), .text("1.0")),
            CborPair(.unsigned(1), .array([.unsigned(1), try CborDecoder.decode(edkBytes)]))]))

        // 리더가 QR 을 파싱한다 — 원본 바이트를 보존해 트랜스크립트에 넣는다
        let parsed = try EngagementCodec.decode(engagement)
        XCTAssertEqual(parsed.version, "1.0")
        let erkBytes = coseKey(eReader.publicKey)
        let transcript = SessionTranscriptBuilder.qr(
            deviceEngagementBytes: parsed.raw,
            eReaderKeyBytes: OpaqueCBOR(preserving: erkBytes))

        // ── 세션 키 (양쪽이 독립적으로 같은 값을 만들어야 한다) ─────────────
        let zabReader = try eReader.sharedSecretFromKeyAgreement(with: eDevice.publicKey)
        let zabDevice = try eDevice.sharedSecretFromKeyAgreement(with: eReader.publicKey)
        let zR = zabReader.withUnsafeBytes { Data($0) }
        let zD = zabDevice.withUnsafeBytes { Data($0) }
        XCTAssertEqual(zR, zD, "ECDH 결과가 같아야 한다")

        let readerCipher = SessionCipher(role: .mdocReader, sharedSecret: zR, transcript: transcript)
        let mdocCipher = SessionCipher(role: .mdoc, sharedSecret: zD, transcript: transcript)

        // ── 전송 ────────────────────────────────────────────────────────
        let (readerLink, mdocLink) = LoopbackTransport.pair()
        try await readerLink.open(TransportConfig(role: .mdocReader))
        try await mdocLink.open(TransportConfig(role: .mdoc))

        // 리더: 요청 생성 → 암호화 → 전송
        let spec = ItemsRequestSpec(docType: "org.iso.18013.5.1.mDL",
                                    items: ["org.iso.18013.5.1": ["family_name": false]])
        let requestBytes = try RequestCodec.encode(DeviceRequest(docRequests: [spec]))
        try await readerLink.send(try readerCipher.encrypt(requestBytes))

        // mdoc: 수신 → 복호화 → (월렛이 응답을 만든다) → 암호화 → 전송
        let received = await mdocLink.nextMessage()
        XCTAssertEqual(try mdocCipher.decrypt(received!), requestBytes)

        let deviceKey = P256.Signing.PrivateKey()
        let issuerKey = P256.Signing.PrivateKey()
        let response = makeResponse(transcript: transcript, deviceKey: deviceKey, issuerKey: issuerKey)
        try await mdocLink.send(try mdocCipher.encrypt(response))

        // ── 리더: 수신 → 복호화 → 파싱 → 검증 ────────────────────────────
        let back = await readerLink.nextMessage()
        let plain = try readerCipher.decrypt(back!)
        let decoded = try ResponseCodec.decode(plain)
        XCTAssertEqual(decoded.status, 0)
        XCTAssertEqual(decoded.documents.count, 1)

        let doc = decoded.documents[0]
        // 발급자 검증 — 키를 주입받는다 (검증키가 응답 안에 오지 않는다)
        let issuer = IssuerDataAuthVerifier.verifyCryptographic(
            doc.issuerSigned, docType: doc.docType,
            issuerPublicKeySEC1: issuerKey.publicKey.x963Representation,
            at: Date())
        XCTAssertTrue(issuer.signatureValid, "issuerAuth 서명")
        XCTAssertTrue(issuer.docTypeChecked)
        XCTAssertTrue(issuer.docTypeMatches)
        XCTAssertEqual(issuer.validity?.isCurrentlyValid, true)
        XCTAssertEqual(issuer.digests?.allMatch, true, "valueDigests 대조")

        // 같은 MSO 를 다른 docType 으로 기대하면 — 비교는 했고(checked) 결과가 다르다(mismatch).
        // MSO 를 못 읽은 경로(checked = false)와 구분되는 자리다
        let mismatch = IssuerDataAuthVerifier.verifyCryptographic(
            doc.issuerSigned, docType: "org.example.other",
            issuerPublicKeySEC1: issuerKey.publicKey.x963Representation, at: Date())
        XCTAssertTrue(mismatch.docTypeChecked)
        XCTAssertFalse(mismatch.docTypeMatches)

        // mdoc 인증 — MSO 의 deviceKey 로 검증한다
        let mdocAuth = MdocAuthVerifier.verify(
            doc.deviceSigned.deviceAuth, transcript: transcript, docType: doc.docType,
            deviceNameSpacesBytes: doc.deviceSigned.nameSpacesBytes,
            deviceKeySEC1: issuer.deviceKeySEC1, eMacKey: nil)
        XCTAssertEqual(mdocAuth.method, .ecdsa)
        XCTAssertTrue(mdocAuth.valid, "DeviceAuth 서명")

        readerLink.close(.normal)
    }

    /// 월렛 SDK 자리 — 이 SDK 밖이지만 E2E 를 돌리려면 필요하다.
    private func makeResponse(transcript: SessionTranscriptBytes,
                              deviceKey: P256.Signing.PrivateKey,
                              issuerKey: P256.Signing.PrivateKey) -> Data {
        let ns = "org.iso.18013.5.1", docType = "org.iso.18013.5.1.mDL"
        let item = CborEncoder.tag24(CborEncoder.encode(.map([
            CborPair(.text("digestID"), .unsigned(1)),
            CborPair(.text("random"), .bytes(Data(repeating: 9, count: 16))),
            CborPair(.text("elementIdentifier"), .text("family_name")),
            CborPair(.text("elementValue"), .text("Doe"))])))
        let r = deviceKey.publicKey.x963Representation
        let mso = CborEncoder.tag24(CborEncoder.encode(.map([
            CborPair(.text("version"), .text("1.0")),
            CborPair(.text("digestAlgorithm"), .text("SHA-256")),
            CborPair(.text("valueDigests"), .map([CborPair(.text(ns),
                .map([CborPair(.unsigned(1), .bytes(Data(SHA256.hash(data: item))))]))])),
            CborPair(.text("deviceKeyInfo"), .map([CborPair(.text("deviceKey"), .map([
                CborPair(.unsigned(1), .unsigned(2)), CborPair(.negative(0), .unsigned(1)),
                CborPair(.negative(1), .bytes(r.subdata(in: 1..<33))),
                CborPair(.negative(2), .bytes(r.subdata(in: 33..<65)))]))])),
            CborPair(.text("docType"), .text(docType)),
            CborPair(.text("validityInfo"), .map([
                CborPair(.text("signed"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
                CborPair(.text("validFrom"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
                CborPair(.text("validUntil"), .tagged(0, .text("2027-01-01T00:00:00Z")))]))])))
        let issuerSig = try! issuerKey.signature(for: SigStructure.bytes(
            protected: CoseConstants.protectedES256, payload: mso))
        let dns = OpaqueCBOR(preserving: CborEncoder.tag24(CborEncoder.encode(.map([]))))
        let dab = try! DeviceAuthenticationBuilder.taggedBytes(
            transcript: transcript, docType: docType, deviceNameSpacesBytes: dns)
        let devSig = try! deviceKey.signature(for: SigStructure.bytes(
            protected: CoseConstants.protectedES256, payload: dab))

        return CborEncoder.encode(.map([
            CborPair(.text("version"), .text("1.0")),
            CborPair(.text("documents"), .array([.map([
                CborPair(.text("docType"), .text(docType)),
                CborPair(.text("issuerSigned"), .map([
                    CborPair(.text("nameSpaces"), .map([CborPair(.text(ns), .array([try! CborDecoder.decode(item)]))])),
                    CborPair(.text("issuerAuth"), .array([
                        .bytes(CoseConstants.protectedES256),
                        .map([CborPair(.unsigned(4), .bytes(Data("did:omn:issuer#assert".utf8)))]),
                        .bytes(mso), .bytes(issuerSig.rawRepresentation)]))])),
                CborPair(.text("deviceSigned"), .map([
                    CborPair(.text("nameSpaces"), try! CborDecoder.decode(dns.raw)),
                    CborPair(.text("deviceAuth"), .map([CborPair(.text("deviceSignature"), .array([
                        .bytes(CoseConstants.protectedES256), .map([]), .null,
                        .bytes(devSig.rawRepresentation)]))]))]))])])),
            CborPair(.text("status"), .unsigned(0))]))
    }
}
