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

@_spi(MdocInternal) public enum CoseKey {

    public static func encode(x963: Data) throws -> Data {
        let (x, y) = try coordinates(x963: x963)
        return CborEncoder.encode(.map([
            CborPair(.unsigned(1), .unsigned(2)),
            CborPair(.negative(0), .unsigned(1)),      // -1 = crv
            CborPair(.negative(1), .bytes(x)),         // -2 = x
            CborPair(.negative(2), .bytes(y))          // -3 = y
        ]))
    }

    public static func keyBytes(x963: Data) throws -> OpaqueCBOR {
        OpaqueCBOR(preserving: CborEncoder.tag24(try encode(x963: x963)))
    }

    public static func x963(fromKeyBytes bytes: OpaqueCBOR) throws -> Data {
        let outer = try CborDecoder.decode(bytes.raw)
        let key: CborValue
        if case .tagged(24, .bytes(let inner)) = outer {
            key = try CborDecoder.decode(inner)
        } else {
            key = outer
        }
        guard key.member(UInt64(1))?.asUInt == 2 else {
            throw MdocProximityError.validationFailed(detail: "COSE_Key: kty is not EC2")
        }
        guard negative(key, 1)?.asUInt == 1 else {      // crv = P-256
            throw MdocProximityError.validationFailed(detail: "COSE_Key: crv is not P-256")
        }
        guard let x = negative(key, 2)?.asBytes, let y = negative(key, 3)?.asBytes,
              x.count == 32, y.count == 32 else {
            throw MdocProximityError.validationFailed(detail: "COSE_Key: bad coordinates")
        }
        return Data([0x04]) + x + y
    }

    private static func negative(_ v: CborValue, _ label: Int) -> CborValue? {
        guard case .map(let pairs) = v else { return nil }
        return pairs.first { $0.key == .negative(UInt64(label - 1)) }?.value
    }

    private static func coordinates(x963: Data) throws -> (Data, Data) {
        guard x963.count == 65, x963.first == 0x04 else {
            throw MdocProximityError.validationFailed(detail: "SEC1: not an uncompressed P-256 point")
        }
        return (x963.subdata(in: 1..<33), x963.subdata(in: 33..<65))
    }
}

@_spi(MdocInternal) public struct EphemeralKeyPair {

    private let privateKey: P256.KeyAgreement.PrivateKey
    public let keyBytes: OpaqueCBOR

    public init() {
        let k = P256.KeyAgreement.PrivateKey()
        privateKey = k
        keyBytes = try! CoseKey.keyBytes(x963: k.publicKey.x963Representation)
    }

    public func sharedSecret(withPeerKeyBytes peer: OpaqueCBOR) throws -> Data {
        try sharedSecret(withPeerX963: try CoseKey.x963(fromKeyBytes: peer))
    }

    public func sharedSecret(withPeerX963 sec1: Data) throws -> Data {
        guard let pub = try? P256.KeyAgreement.PublicKey(x963Representation: sec1) else {
            throw MdocProximityError.validationFailed(detail: "COSE_Key: not a valid P-256 point")
        }
        guard let z = try? privateKey.sharedSecretFromKeyAgreement(with: pub) else {
            throw MdocProximityError.sessionEncryptionFailed
        }
        return z.withUnsafeBytes { Data($0) }
    }
}
