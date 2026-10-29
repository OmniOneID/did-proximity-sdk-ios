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

@_spi(MdocInternal) public struct DeviceResponse {
    public let version: String
    public let documents: [Document]
    public let documentErrors: [DocType: Int64]
    public let status: UInt64
}

@_spi(MdocInternal) public struct Document {
    public let docType: DocType
    public let issuerSigned: IssuerSigned
    public let deviceSigned: DeviceSigned
    public let errors: [NameSpace: [DataElementIdentifier: Int64]]
}

@_spi(MdocInternal) public struct IssuerSigned {
    public let nameSpaces: [NameSpace: [IssuerSignedItemEntry]]
    public let issuerAuth: CoseSign1
}

@_spi(MdocInternal) public struct IssuerSignedItemEntry {
    public let raw: OpaqueCBOR
    public let digestID: UInt64
    public let elementIdentifier: DataElementIdentifier
    public let elementValue: CborValue
}

@_spi(MdocInternal) public struct DeviceSigned {
    public let nameSpacesBytes: OpaqueCBOR
    public let deviceAuth: DeviceAuth
}

@_spi(MdocInternal) public enum DeviceAuth {
    case deviceSignature(CoseSign1)
    case deviceMac(CoseMac0)
}

@_spi(MdocInternal) public struct MobileSecurityObject {
    public let version: String
    public let digestAlgorithm: String            // "SHA-256"
    public let valueDigests: [NameSpace: [UInt64: Data]]
    public let deviceKeyBytes: Data
    public let docType: DocType
    public let signed: Date
    public let validFrom: Date
    public let validUntil: Date
    public var keyAuthorizations = KeyAuthorizations()
}

/// MSO `deviceKeyInfo.keyAuthorizations` (9.1.2.4). If absent, the deviceKey may not sign or MAC
/// any element.
@_spi(MdocInternal) public struct KeyAuthorizations: Equatable {
    public var nameSpaces: Set<NameSpace> = []
    public var dataElements: [NameSpace: Set<DataElementIdentifier>] = [:]
    public init() {}

    public func allows(_ nameSpace: NameSpace, _ id: DataElementIdentifier) -> Bool {
        nameSpaces.contains(nameSpace) || dataElements[nameSpace]?.contains(id) == true
    }
}
