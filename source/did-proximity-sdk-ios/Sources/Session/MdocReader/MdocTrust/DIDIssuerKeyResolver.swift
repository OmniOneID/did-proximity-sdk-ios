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
#if canImport(MdocProximityCore)
@_spi(MdocInternal) import MdocProximityCore
#endif

public final class DIDIssuerKeyResolver: TrustEvaluatorProtocol {

    private let trustedIssuers: [String]
    private let resolve: (_ did: String, _ versionId: String?) async throws -> Data

    public init(trustedIssuers: [String],
                resolve: @escaping (_ did: String, _ versionId: String?) async throws -> Data) {
        self.trustedIssuers = trustedIssuers
        self.resolve = resolve
    }

    public func evaluate(header: COSEHeaderSummary,
                         purpose: TrustPurpose,
                         at date: Date) async -> IssuerKeyResolution {
        guard let kid = header.kid, kid.hasPrefix("did:") else {
            return IssuerKeyResolution(publicKey: nil,
                                       trust: .untrusted(reason: "kid is not a DID URL"),
                                       source: .none)
        }
        let (body, versionId) = Self.normalize(kid)
        let method = body.split(separator: ":").dropFirst().first.map(String.init) ?? ""

        guard trustedIssuers.contains(body) else {
            return IssuerKeyResolution(publicKey: nil,
                                       trust: .untrusted(reason: "issuer not in trustedIssuers"),
                                       source: .did(method: method))
        }
        do {
            let key = try await resolve(body, versionId)
            return IssuerKeyResolution(publicKey: key, trust: .trusted, source: .did(method: method))
        } catch {
            return IssuerKeyResolution(publicKey: nil, trust: .unknown, source: .did(method: method))
        }
    }

    /// `did:omn:issuer?versionId=1#assert` → (`did:omn:issuer`, `"1"`)
    static func normalize(_ kid: String) -> (body: String, versionId: String?) {
        var s = Substring(kid)
        if let hash = s.firstIndex(of: "#") { s = s[s.startIndex..<hash] }
        var version: String? = nil
        if let q = s.firstIndex(of: "?") {
            let query = s[s.index(after: q)...]
            for pair in query.split(separator: "&") where pair.hasPrefix("versionId=") {
                version = String(pair.dropFirst("versionId=".count))
            }
            s = s[s.startIndex..<q]
        }
        return (String(s), version)
    }
}
