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

final class CoreLayerTests: XCTestCase {

    // session/cipher-iv — identifier(8) ‖ counter(4, BE), 카운터는 1에서 시작
    func testIVConstruction() {
        XCTAssertEqual(SessionCipher.iv(role: .mdocReader, counter: 1).hex, "000000000000000000000001")
        XCTAssertEqual(SessionCipher.iv(role: .mdocReader, counter: 3).hex, "000000000000000000000003")
        XCTAssertEqual(SessionCipher.iv(role: .mdoc, counter: 1).hex, "000000000000000100000001")
        XCTAssertEqual(SessionCipher.iv(role: .mdoc, counter: 3).hex, "000000000000000100000003")
    }

    private func makeTranscript() -> SessionTranscriptBytes {
        SessionTranscriptBuilder.qr(
            deviceEngagementBytes: OpaqueCBOR(preserving: Data(hex: "d81845a0010203")!),
            eReaderKeyBytes: OpaqueCBOR(preserving: Data(hex: "d81845a0040506")!))
    }

    // 양쪽이 서로의 키로 주고받는다
    func testSessionCipherRoundTrip() throws {
        let st = makeTranscript()
        let zab = Data(repeating: 0x11, count: 32)
        let reader = SessionCipher(role: .mdocReader, sharedSecret: zab, transcript: st)
        let mdoc = SessionCipher(role: .mdoc, sharedSecret: zab, transcript: st)

        let request = Data("DeviceRequest bytes".utf8)
        XCTAssertEqual(try mdoc.decrypt(try reader.encrypt(request)), request)

        let response = Data("DeviceResponse bytes".utf8)
        XCTAssertEqual(try reader.decrypt(try mdoc.encrypt(response)), response)
    }

    // negative/counter-rewind — 기대 3, 수신 2 → counterMismatch
    func testCounterRewindRejected() throws {
        let st = makeTranscript()
        let zab = Data(repeating: 0x22, count: 32)
        let reader = SessionCipher(role: .mdocReader, sharedSecret: zab, transcript: st)
        let mdoc = SessionCipher(role: .mdoc, sharedSecret: zab, transcript: st)

        for i in 1...2 { _ = try mdoc.decrypt(try reader.encrypt(Data([UInt8(i)]))) }   // recvCounter → 3
        let next = try reader.encrypt(Data([0x03]))
        XCTAssertThrowsError(try mdoc.decrypt(next, counter: 2)) { e in
            XCTAssertEqual(e as? MdocProximityError, .counterMismatch)
        }
    }

    // 카운터 2³²−1 도달 → `sessionEncryptionFailed`. 전에는 `try?` 가 삼켜 같은 nonce 로 한 번 더 봉인했다
    func testSendCounterExhaustionFailsClosed() throws {
        let cipher = SessionCipher(role: .mdocReader, sharedSecret: Data(repeating: 0x33, count: 32),
                                   transcript: makeTranscript())
        cipher.setSendCounterForTesting(UInt32.max - 1)
        XCTAssertNoThrow(try cipher.encrypt(Data([0x01])))          // counter = max−1 로 봉인, max 로 전진
        XCTAssertThrowsError(try cipher.encrypt(Data([0x02]))) { e in
            XCTAssertEqual(e as? MdocProximityError, .sessionEncryptionFailed)
        }
        XCTAssertThrowsError(try cipher.encrypt(Data([0x03])), "고갈 뒤에도 계속 던진다 — nonce 재사용 금지")
    }

    // DeviceEngagement 의 cipher suite 가 Int64 범위를 넘으면 `validationFailed` — 스캔한 QR 이 리더를 트랩시키면 안 된다
    func testEngagementCipherSuiteOutOfRangeRejected() {
        let de = CborEncoder.encode(.map([
            CborPair(.unsigned(0), .text("1.0")),
            CborPair(.unsigned(1), .array([.unsigned(UInt64.max), .bytes(Data([0xa0]))]))]))
        XCTAssertThrowsError(try EngagementCodec.decode(de)) { e in
            guard case .validationFailed = (e as! MdocProximityError) else { return XCTFail("wrong code") }
        }
        let negative = CborEncoder.encode(.map([
            CborPair(.unsigned(0), .text("1.0")),
            CborPair(.unsigned(1), .array([.negative(UInt64.max), .bytes(Data([0xa0]))]))]))
        XCTAssertThrowsError(try EngagementCodec.decode(negative))
    }

    // DeviceResponse 의 ErrorCode 가 Int64 범위를 넘으면 `validationFailed` — 홀더가 준 값으로 리더가 죽지 않는다
    func testResponseErrorCodeOutOfRangeRejected() {
        let r = CborEncoder.encode(.map([
            CborPair(.text("version"), .text("1.0")),
            CborPair(.text("documentErrors"), .array([.map([CborPair(.text("org.iso.18013.5.1.mDL"), .unsigned(UInt64.max))])])),
            CborPair(.text("status"), .unsigned(0))]))
        XCTAssertThrowsError(try ResponseCodec.decode(r)) { e in
            guard case .validationFailed(let d) = (e as! MdocProximityError) else { return XCTFail("wrong code") }
            XCTAssertTrue(d.contains("ErrorCode"), d)
        }
        // 범위 안의 음수는 그대로 받는다
        let ok = CborEncoder.encode(.map([
            CborPair(.text("version"), .text("1.0")),
            CborPair(.text("documentErrors"), .array([.map([CborPair(.text("org.iso.18013.5.1.mDL"), .negative(0))])])),
            CborPair(.text("status"), .unsigned(0))]))
        XCTAssertEqual(try ResponseCodec.decode(ok).documentErrors["org.iso.18013.5.1.mDL"], -1)
    }

    // mso/value-digests — digest 는 IssuerSignedItemBytes **원본** 위에서 계산한다
    func testValueDigests() throws {
        let items = [
            "d8185852a46672616e646f6d5001010101010101010101010101010101686469676573744944016c656c656d656e7456616c756563446f6571656c656d656e744964656e7469666965726b66616d696c795f6e616d65",
            "d818584fa46672616e646f6d5002020202020202020202020202020202686469676573744944026c656c656d656e7456616c7565f571656c656d656e744964656e7469666965726b6167655f6f7665725f3138",
            "d818588da46672616e646f6d5003030303030303030303030303030303686469676573744944036c656c656d656e7456616c756558400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000071656c656d656e744964656e74696669657268706f727472616974"
        ]
        var entries: [IssuerSignedItemEntry] = []
        for hex in items {
            let raw = Data(hex: hex)!
            let node = try CborDecoder.decodeNode(raw)
            guard case .tagged(24, .bytes(let inner)) = node.value else { return XCTFail("not tag24") }
            let item = try CborDecoder.decode(inner)
            entries.append(IssuerSignedItemEntry(raw: OpaqueCBOR(preserving: raw),
                                                 digestID: item.member("digestID")!.asUInt!,
                                                 elementIdentifier: item.member("elementIdentifier")!.asText!,
                                                 elementValue: item.member("elementValue")!))
        }
        let ns = "org.iso.18013.5.1"
        let signed = IssuerSigned(nameSpaces: [ns: entries],
                                  issuerAuth: CoseSign1(protectedBytes: Data(), unprotected: .null,
                                                        payload: nil, signature: Data()))
        let digests: [NameSpace: [UInt64: Data]] = [ns: [
            1: Data(hex: "eda73d0987af3d848f50e416db7603385c6a339ab55cd91ed9680cc5ff3b8ccf")!,
            2: Data(hex: "2d1820b11eb9d553b215d5f1cbdcfe6b374f72f6fa0f18f74bd214f88e05723e")!,
            3: Data(hex: "1c9f10321d31c9c8599a5a1091a146f49affc65a560afbf3a5aeddfd689a8472")!
        ]]
        let r = DigestChecker.check(signed, valueDigests: digests)
        XCTAssertTrue(r.allMatch)
        XCTAssertEqual(r.matches[ns]?["family_name"], true)

        // 한 바이트만 바꾸면 그 항목만 어긋난다
        var broken = digests; broken[ns]?[2] = Data(repeating: 0, count: 32)
        XCTAssertEqual(DigestChecker.check(signed, valueDigests: broken).matches[ns]?["age_over_18"], false)

        // 알고리즘은 MSO 의 `digestAlgorithm` 을 따른다 (9.1.2.5) — SHA-384 로 발급된 mdoc 을
        // SHA-256 으로 계산하면 전부 어긋난다
        let sha384: [NameSpace: [UInt64: Data]] = [ns: Dictionary(uniqueKeysWithValues: entries.map {
            ($0.digestID, Data(SHA384.hash(data: $0.raw.raw)))
        })]
        XCTAssertTrue(DigestChecker.check(signed, valueDigests: sha384, digestAlgorithm: "SHA-384").allMatch)
        XCTAssertFalse(DigestChecker.check(signed, valueDigests: sha384).allMatch)
        XCTAssertFalse(DigestChecker.check(signed, valueDigests: digests, digestAlgorithm: "MD5").allMatch,
                       "모르는 알고리즘은 계산할 수 없으므로 불일치다")
    }

    /// **MSO 를 얻지 못하면 "확인하지 못함"이지 "통과"가 아니다.** 빈 `DigestCheckResult` 로
    /// 두면 `allMatch` 가 `true` 가 되어 대조하지 않은 문서가 통과로 읽혔다.
    func testUnreadableMSOYieldsNoDigestsNorValidity() throws {
        let ns = "org.iso.18013.5.1"
        let entry = IssuerSignedItemEntry(raw: OpaqueCBOR(preserving: Data([0xa0])),
                                          digestID: 1, elementIdentifier: "family_name",
                                          elementValue: .text("Doe"))
        func check(_ payload: Data?) -> IssuerAuthCryptoCheck {
            IssuerDataAuthVerifier.verifyCryptographic(
                IssuerSigned(nameSpaces: [ns: [entry]],
                             issuerAuth: CoseSign1(protectedBytes: Data(), unprotected: .null,
                                                   payload: payload, signature: Data())),
                docType: "org.iso.18013.5.1.mDL", issuerPublicKeySEC1: nil, at: Date())
        }
        // ① payload 부재(detached) — issuerAuth 에서는 비적합이다
        // ② 바이트는 있으나 MSO 로 파싱되지 않는다
        for c in [check(nil), check(Data([0xa0]))] {
            XCTAssertNil(c.digests, "대조를 못 했으면 빈 결과가 아니라 없음이다")
            XCTAssertNil(c.validity)
            XCTAssertFalse(c.signatureValid)
            XCTAssertFalse(c.docTypeChecked, "비교를 못 했으면 '다르다'가 아니라 '확인 안 함'이다")
            XCTAssertFalse(c.docTypeMatches)
            XCTAssertNil(c.deviceKeySEC1)
        }
        // 빈 결과였다면 true 가 됐을 자리다 — 그 형태를 여기에 못 박아 둔다
        XCTAssertTrue(DigestCheckResult(matches: [:]).allMatch)
    }

    // negative/documents-empty — CDDL 위반이지만 문서 0건으로 받는다
    func testDocumentsEmptyArrayAccepted() throws {
        let r = try ResponseCodec.decode(Data(hex: "a366737461747573006776657273696f6e63312e3069646f63756d656e747380")!)
        XCTAssertEqual(r.documents.count, 0)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.version, "1.0")
    }

    // 요청의 docType 유일 — 입구에서 막는다
    func testDuplicateDocTypeRejected() {
        let spec = ItemsRequestSpec(docType: "org.iso.18013.5.1.mDL",
                                    items: ["org.iso.18013.5.1": ["age_over_18": false]])
        XCTAssertNoThrow(try RequestCodec.encode(DeviceRequest(docRequests: [spec])))
        XCTAssertThrowsError(try RequestCodec.encode(DeviceRequest(docRequests: [spec, spec]))) { e in
            guard case .validationFailed = (e as! MdocProximityError) else { return XCTFail("wrong code") }
        }
    }

    // kid 는 protected → unprotected 순으로 찾고, alg 는 protected 에서 읽는다
    func testCoseHeaderKidAndAlgFromEitherHeader() {
        let kid = Data("did:omn:issuer?versionId=1#assert".utf8)
        let protectedWithBoth = CborEncoder.encode(.map([
            CborPair(.unsigned(1), .negative(6)),            // alg = -7 (ES256)
            CborPair(.unsigned(4), .bytes(kid))]))
        let a = CoseSign1(protectedBytes: protectedWithBoth, unprotected: .map([]), payload: nil, signature: Data())
        XCTAssertEqual(a.keyIdentifier, "did:omn:issuer?versionId=1#assert")
        XCTAssertEqual(a.algorithm, -7)

        // 발급자가 kid 를 unprotected 에 실어도 읽는다 — 지금 테스트 벡터가 이 형태다
        let b = CoseSign1(protectedBytes: CoseConstants.protectedES256,
                          unprotected: .map([CborPair(.unsigned(4), .bytes(kid))]),
                          payload: nil, signature: Data())
        XCTAssertEqual(b.keyIdentifier, "did:omn:issuer?versionId=1#assert")
        XCTAssertEqual(b.algorithm, -7)

        // protected 쪽이 우선이다 — 서명 입력에 들어가는 값
        let c = CoseSign1(protectedBytes: protectedWithBoth,
                          unprotected: .map([CborPair(.unsigned(4), .bytes(Data("did:omn:other".utf8)))]),
                          payload: nil, signature: Data())
        XCTAssertEqual(c.keyIdentifier, "did:omn:issuer?versionId=1#assert")

        // alg 가 없으면 nil — 하드코딩하지 않는다
        let d = CoseSign1(protectedBytes: Data(), unprotected: .map([]), payload: nil, signature: Data())
        XCTAssertNil(d.algorithm); XCTAssertNil(d.keyIdentifier)
    }
}
