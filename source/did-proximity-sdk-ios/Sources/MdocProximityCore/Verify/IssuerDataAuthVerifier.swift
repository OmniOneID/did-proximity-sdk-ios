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

import Foundation
import CryptoKit

@_spi(MdocInternal) public struct IssuerAuthCryptoCheck {
    public let signatureValid: Bool
    public var verificationSkipped: Bool = false
    /// Whether an issuer key was available and the signature was actually checked. Without a key, `signatureValid`
    /// means "could not check", not "wrong".
    public var signatureChecked: Bool = false
    public let docTypeChecked: Bool
    public let docTypeMatches: Bool
    public let validity: ValidityCheck?
    public let digests: DigestCheckResult?
    public let deviceKeySEC1: Data?
    /// `nil` if the MSO could not be read — then no deviceSigned element is treated as authorized.
    public var keyAuthorizations: KeyAuthorizations? = nil
}

@_spi(MdocInternal) public enum IssuerDataAuthVerifier {

    public static func verifyCryptographic(_ issuerSigned: IssuerSigned,
                                           docType: DocType,
                                           issuerPublicKeySEC1: Data?,
                                           at now: Date,
                                           skippingSignature: Bool = false) -> IssuerAuthCryptoCheck {
        guard let msoBytes = issuerSigned.issuerAuth.payload,
              let mso = try? parseMSO(msoBytes) else {
            return IssuerAuthCryptoCheck(signatureValid: false,
                                        verificationSkipped: skippingSignature,
                                        docTypeChecked: false,
                                        docTypeMatches: false,
                                        validity: nil,
                                        digests: nil,
                                        deviceKeySEC1: nil)
        }

        let outcome = skippingSignature ? nil : issuerPublicKeySEC1.flatMap {
            verifySignature(issuerSigned.issuerAuth, issuerPublicKeySEC1: $0)
        }
        let checked = outcome != nil
        let sigValid = outcome == true

        let validity = ValidityCheck(
            signed: mso.signed, validFrom: mso.validFrom, validUntil: mso.validUntil,
            isCurrentlyValid: mso.signed <= now && mso.validFrom <= now && now <= mso.validUntil)

        return IssuerAuthCryptoCheck(
            signatureValid: sigValid,
            verificationSkipped: skippingSignature,
            signatureChecked: checked,
            docTypeChecked: true,
            docTypeMatches: mso.docType == docType,
            validity: validity,
            digests: DigestChecker.check(issuerSigned, valueDigests: mso.valueDigests,
                                         digestAlgorithm: mso.digestAlgorithm),
            deviceKeySEC1: mso.deviceKeyBytes,
            keyAuthorizations: mso.keyAuthorizations)
    }

    /// Checks the `issuerAuth` signature (9.3.1 step 2). **`nil` means not checked** — this SDK supports only ES256 / P-256
    /// (short of the reader shall). Other algs or curves mean "could not check", not "wrong".
    public static func verifySignature(_ issuerAuth: CoseSign1, issuerPublicKeySEC1: Data) -> Bool? {
        guard issuerAuth.algorithm == CoseConstants.es256,
              let key = try? P256.Signing.PublicKey(x963Representation: issuerPublicKeySEC1) else { return nil }
        guard let payload = issuerAuth.payload,
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: issuerAuth.signature) else {
            return false
        }
        return key.isValidSignature(sig, for: SigStructure.bytes(protected: issuerAuth.protectedBytes,
                                                                 payload: payload))
    }

    /// `MobileSecurityObjectBytes = #6.24(bstr .cbor MobileSecurityObject)`
    static func parseMSO(_ taggedBytes: Data) throws -> MobileSecurityObject {
        let node = try CborDecoder.decodeNode(taggedBytes)
        guard case .tagged(24, .bytes(let inner)) = node.value else {
            throw MdocProximityError.validationFailed(detail: "MSO: not #6.24(bstr)")
        }
        let m = try CborDecoder.decode(inner)
        guard let version = m.member("version")?.asText,
              let alg = m.member("digestAlgorithm")?.asText,
              let docType = m.member("docType")?.asText,
              case .map(let vdPairs)? = m.member("valueDigests"),
              let validity = m.member("validityInfo") else {
            throw MdocProximityError.validationFailed(detail: "MSO: missing required field")
        }
        var digests: [NameSpace: [UInt64: Data]] = [:]
        for p in vdPairs {
            guard let ns = p.key.asText, case .map(let ids) = p.value else { continue }
            var m2: [UInt64: Data] = [:]
            for e in ids { if let id = e.key.asUInt, let d = e.value.asBytes { m2[id] = d } }
            digests[ns] = m2
        }
        func date(_ key: String) throws -> Date {
            guard case .tagged(0, .text(let s))? = validity.member(key),
                  let d = ISO8601DateFormatter().date(from: s) else {
                throw MdocProximityError.validationFailed(detail: "MSO: bad \(key)")
            }
            return d
        }
        var sec1: Data? = nil
        // COSE_Key kty 2 (EC2) / crv 1 (P-256) only — never splice another curve's x/y into a P-256 point
        if let dk = m.member("deviceKeyInfo")?.member("deviceKey"),
           dk.member(1) == .unsigned(2), dk.member(negativeValue: 0) == .unsigned(1),
           let x = dk.member(negative: 1), let y = dk.member(negative: 2), x.count == 32, y.count == 32 {
            sec1 = Data([0x04]) + x + y
        }
        var mso = MobileSecurityObject(
            version: version, digestAlgorithm: alg, valueDigests: digests,
            deviceKeyBytes: sec1 ?? Data(), docType: docType,
            signed: try date("signed"), validFrom: try date("validFrom"),
            validUntil: try date("validUntil"))
        if let auth = m.member("deviceKeyInfo")?.member("keyAuthorizations") {
            mso.keyAuthorizations = keyAuthorizations(auth)
        }
        return mso
    }

    /// `KeyAuthorizations = { ? "nameSpaces": [+ tstr], ? "dataElements": { + tstr => [+ tstr] } }`
    static func keyAuthorizations(_ v: CborValue) -> KeyAuthorizations {
        var out = KeyAuthorizations()
        if case .array(let spaces)? = v.member("nameSpaces") {
            out.nameSpaces = Set(spaces.compactMap(\.asText))
        }
        if case .map(let pairs)? = v.member("dataElements") {
            for p in pairs {
                guard let ns = p.key.asText, case .array(let ids) = p.value else { continue }
                out.dataElements[ns, default: []].formUnion(ids.compactMap(\.asText))
            }
        }
        return out
    }
}

private extension CborValue {
    func member(negative n: UInt64) -> Data? {
        member(negativeValue: n)?.asBytes
    }
    func member(negativeValue n: UInt64) -> CborValue? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == .negative(n) }?.value
    }
}
