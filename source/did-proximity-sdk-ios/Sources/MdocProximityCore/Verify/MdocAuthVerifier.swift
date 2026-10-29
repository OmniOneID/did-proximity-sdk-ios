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

@_spi(MdocInternal) public enum MdocAuthVerifier {

    public static func verify(_ auth: DeviceAuth,
                              transcript: SessionTranscriptBytes,
                              docType: DocType,
                              deviceNameSpacesBytes: OpaqueCBOR,
                              deviceKeySEC1: Data?,
                              eMacKey: Data?) -> MdocAuthResult {
        guard let dab = try? DeviceAuthenticationBuilder.taggedBytes(
                transcript: transcript, docType: docType,
                deviceNameSpacesBytes: deviceNameSpacesBytes) else {
            return MdocAuthResult(method: method(auth), valid: false, boundToIssuerDeviceKey: false)
        }

        switch auth {
        case .deviceMac(let mac):
            // 9.1.3.5 — HMAC 256/256 only. Any other alg fails without comparison
            guard mac.algorithm == CoseConstants.hmac256, let k = eMacKey else {
                return MdocAuthResult(method: .mac, valid: false, boundToIssuerDeviceKey: false)
            }
            let structure = MacStructure.bytes(protected: mac.protectedBytes, payload: dab)
            let expected = Data(HMAC<SHA256>.authenticationCode(for: structure,
                                                               using: SymmetricKey(data: k)))
            return MdocAuthResult(method: .mac,
                                  valid: constantTimeEqual(expected, mac.tag),
                                  boundToIssuerDeviceKey: true)

        case .deviceSignature(let sign):
            guard sign.algorithm == CoseConstants.es256, let sec1 = deviceKeySEC1,
                  let key = try? P256.Signing.PublicKey(x963Representation: sec1),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sign.signature) else {
                return MdocAuthResult(method: .ecdsa, valid: false, boundToIssuerDeviceKey: false)
            }
            let structure = SigStructure.bytes(protected: sign.protectedBytes, payload: dab)
            return MdocAuthResult(method: .ecdsa,
                                  valid: key.isValidSignature(sig, for: structure),
                                  boundToIssuerDeviceKey: true)
        }
    }

    private static func method(_ a: DeviceAuth) -> MdocAuthResult.Method {
        if case .deviceMac = a { return .mac }; return .ecdsa
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
