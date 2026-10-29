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

@_spi(MdocInternal) public enum DigestChecker {

    public static func check(_ issuerSigned: IssuerSigned,
                             valueDigests: [NameSpace: [UInt64: Data]],
                             digestAlgorithm: String = "SHA-256") -> DigestCheckResult {
        let hash = hasher(digestAlgorithm)
        var out: [NameSpace: [DataElementIdentifier: Bool]] = [:]
        for (ns, items) in issuerSigned.nameSpaces {
            var m: [DataElementIdentifier: Bool] = [:]
            for item in items {
                let expected = valueDigests[ns]?[item.digestID]
                m[item.elementIdentifier] = hash.map { expected == $0(item.raw.raw) } ?? false
            }
            out[ns] = m
        }
        return DigestCheckResult(matches: out)
    }

    static func hasher(_ algorithm: String) -> ((Data) -> Data)? {
        switch algorithm {
        case "SHA-256": return { Data(SHA256.hash(data: $0)) }
        case "SHA-384": return { Data(SHA384.hash(data: $0)) }
        case "SHA-512": return { Data(SHA512.hash(data: $0)) }
        default: return nil
        }
    }
}
