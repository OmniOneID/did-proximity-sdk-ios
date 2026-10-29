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

/// 알고리즘 범위 — ES256·P-256 만 지원한다(리더 shall 미충족). 범위 밖의 키·alg 는 다른
/// 곡선의 바이트를 P-256 으로 오인하지 않고, "틀렸다"가 아니라 "확인 못 함"으로 둔다.
final class AlgorithmScopeTests: XCTestCase {

    private func mso(deviceKey: [CborPair]) -> Data {
        CborEncoder.tag24(CborEncoder.encode(.map([
            CborPair(.text("version"), .text("1.0")),
            CborPair(.text("digestAlgorithm"), .text("SHA-256")),
            CborPair(.text("valueDigests"), .map([])),
            CborPair(.text("deviceKeyInfo"), .map([CborPair(.text("deviceKey"), .map(deviceKey))])),
            CborPair(.text("docType"), .text("org.iso.18013.5.1.mDL")),
            CborPair(.text("validityInfo"), .map([
                CborPair(.text("signed"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
                CborPair(.text("validFrom"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
                CborPair(.text("validUntil"), .tagged(0, .text("2027-01-01T00:00:00Z")))]))])))
    }

    private func ec2(crv: UInt64, coordinate: Int) -> [CborPair] {
        [CborPair(.unsigned(1), .unsigned(2)), CborPair(.negative(0), .unsigned(crv)),
         CborPair(.negative(1), .bytes(Data(repeating: 1, count: coordinate))),
         CborPair(.negative(2), .bytes(Data(repeating: 2, count: coordinate)))]
    }

    /// MSO deviceKey 는 kty 2 · crv 1 · 32바이트 좌표일 때만 P-256 점이 된다.
    func testOnlyP256DeviceKeyIsExtracted() throws {
        XCTAssertEqual(try IssuerDataAuthVerifier.parseMSO(mso(deviceKey: ec2(crv: 1, coordinate: 32))).deviceKeyBytes.count, 65)
        XCTAssertEqual(try IssuerDataAuthVerifier.parseMSO(mso(deviceKey: ec2(crv: 2, coordinate: 48))).deviceKeyBytes, Data(),
                       "P-384 키를 P-256 점으로 이어 붙이지 않는다")
        let okp = [CborPair(.unsigned(1), .unsigned(1)), CborPair(.negative(0), .unsigned(6)),
                   CborPair(.negative(1), .bytes(Data(repeating: 1, count: 32)))]
        XCTAssertEqual(try IssuerDataAuthVerifier.parseMSO(mso(deviceKey: okp)).deviceKeyBytes, Data(), "Ed25519(OKP)")
    }

    /// issuerAuth 의 alg 가 ES256 이 아니면 대조하지 못한 것이다(`nil`) — 서명이 틀렸다는 뜻이 아니다.
    func testNonES256IssuerAuthIsNotChecked() throws {
        let key = P256.Signing.PrivateKey()
        let payload = mso(deviceKey: ec2(crv: 1, coordinate: 32))
        func sign1(protected: Data) throws -> CoseSign1 {
            let sig = try key.signature(for: SigStructure.bytes(protected: protected, payload: payload))
            return CoseSign1(protectedBytes: protected, unprotected: .map([]), payload: payload,
                             signature: sig.rawRepresentation)
        }
        let pub = key.publicKey.x963Representation
        XCTAssertEqual(IssuerDataAuthVerifier.verifySignature(try sign1(protected: CoseConstants.protectedES256),
                                                              issuerPublicKeySEC1: pub), true)
        let es384 = CborEncoder.encode(.map([CborPair(.unsigned(1), .negative(34))]))   // alg -35
        XCTAssertNil(IssuerDataAuthVerifier.verifySignature(try sign1(protected: es384), issuerPublicKeySEC1: pub))
        XCTAssertNil(IssuerDataAuthVerifier.verifySignature(try sign1(protected: CoseConstants.protectedES256),
                                                            issuerPublicKeySEC1: Data(repeating: 4, count: 97)),
                     "P-384 공개키")
        let wrong = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertEqual(IssuerDataAuthVerifier.verifySignature(try sign1(protected: CoseConstants.protectedES256),
                                                              issuerPublicKeySEC1: wrong), false)
    }
}
