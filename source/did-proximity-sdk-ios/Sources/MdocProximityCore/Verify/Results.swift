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

public struct MdocAuthResult: Equatable {
    public enum Method: Equatable { case ecdsa, mac }
    public let method: Method
    public let valid: Bool
    public let boundToIssuerDeviceKey: Bool
}

public struct ValidityCheck: Equatable {
    public let signed: Date
    public let validFrom: Date
    public let validUntil: Date
    public let isCurrentlyValid: Bool
}

public struct DigestCheckResult: Equatable {
    public let matches: [NameSpace: [DataElementIdentifier: Bool]]
    public var allMatch: Bool { matches.values.allSatisfy { $0.values.allSatisfy { $0 } } }
}
