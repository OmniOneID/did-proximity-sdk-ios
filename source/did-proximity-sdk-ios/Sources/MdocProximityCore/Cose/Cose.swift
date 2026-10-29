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

@_spi(MdocInternal) public struct CoseSign1 {
    public let protectedBytes: Data
    public let unprotected: CborValue
    public let payload: Data?
    public let signature: Data

    public init(protectedBytes: Data, unprotected: CborValue, payload: Data?, signature: Data) {
        self.protectedBytes = protectedBytes; self.unprotected = unprotected
        self.payload = payload; self.signature = signature
    }

    var protectedHeader: CborValue {
        protectedBytes.isEmpty ? .map([]) : ((try? CborDecoder.decode(protectedBytes)) ?? .map([]))
    }

    public var keyIdentifier: String? {
        for header in [protectedHeader, unprotected] {
            if let d = header.member(4)?.asBytes { return String(data: d, encoding: .utf8) }
        }
        return nil
    }

    public var algorithm: Int? { CoseConstants.algorithm(in: protectedBytes) }
}

@_spi(MdocInternal) public struct CoseMac0 {
    public let protectedBytes: Data
    public let unprotected: CborValue
    public let payload: Data?
    public let tag: Data

    public var algorithm: Int? { CoseConstants.algorithm(in: protectedBytes) }
}

@_spi(MdocInternal) public enum CoseConstants {
    /// alg = ES256 (-7)
    public static let protectedES256 = Data([0xa1, 0x01, 0x26])
    /// alg = HMAC 256/256 (5)
    public static let protectedHMAC256 = Data([0xa1, 0x01, 0x05])
    public static let externalAAD = Data()
    public static let es256 = -7
    public static let hmac256 = 5

    /// `alg` (label 1) from the protected header.
    static func algorithm(in protectedBytes: Data) -> Int? {
        guard !protectedBytes.isEmpty, let header = try? CborDecoder.decode(protectedBytes) else { return nil }
        switch header.member(1) {
        case .unsigned(let n)?: return Int(exactly: n)
        case .negative(let n)?: return Int(exactly: n).map { -1 - $0 }
        default: return nil
        }
    }
}

@_spi(MdocInternal) public enum SigStructure {
    /// `[ "Signature1", protected, external_aad, payload ]`
    public static func bytes(protected: Data, payload: Data) -> Data {
        CborEncoder.encode(.array([
            .text("Signature1"), .bytes(protected), .bytes(CoseConstants.externalAAD), .bytes(payload)
        ]))
    }
}

@_spi(MdocInternal) public enum MacStructure {
    /// `[ "MAC0", protected, external_aad, payload ]`
    public static func bytes(protected: Data, payload: Data) -> Data {
        CborEncoder.encode(.array([
            .text("MAC0"), .bytes(protected), .bytes(CoseConstants.externalAAD), .bytes(payload)
        ]))
    }
}
