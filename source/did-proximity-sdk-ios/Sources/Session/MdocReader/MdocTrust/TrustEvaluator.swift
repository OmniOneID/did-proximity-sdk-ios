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

public enum TrustVerdict: Equatable {
    case trusted
    case untrusted(reason: String)
    case unknown
}

public enum TrustSource: Equatable {
    case did(method: String)
    case none
}

public struct COSEHeaderSummary: Equatable {
    public let kid: String?
    public let algorithm: Int
    public init(kid: String?, algorithm: Int) { self.kid = kid; self.algorithm = algorithm }
}

public enum TrustPurpose {
    case issuerDataAuthentication
    case mdocReaderAuthentication
}

public struct IssuerKeyResolution {
    public let publicKey: Data?       // SEC1 uncompressed point
    public let trust: TrustVerdict
    public let source: TrustSource

    public init(publicKey: Data?, trust: TrustVerdict, source: TrustSource) {
        self.publicKey = publicKey; self.trust = trust; self.source = source
    }

    public static let notResolved = IssuerKeyResolution(publicKey: nil, trust: .unknown, source: .none)
}

public protocol TrustEvaluatorProtocol: AnyObject {
    func evaluate(header: COSEHeaderSummary, purpose: TrustPurpose, at date: Date) async -> IssuerKeyResolution
}
