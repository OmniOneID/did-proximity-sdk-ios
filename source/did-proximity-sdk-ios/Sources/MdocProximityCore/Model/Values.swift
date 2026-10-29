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

public enum MdocValue: Equatable {
    case text(String)
    case integer(Int64)
    case boolean(Bool)
    case bytes(Data)
    case fullDate(String)      // tag 1004
    case dateTime(String)      // tag 0
    case array([MdocValue])
    case map([String: MdocValue])
    case null
    case unsupported

    @_spi(MdocInternal) public init(_ v: CborValue) {
        switch v {
        case .text(let s): self = .text(s)
        case .unsigned(let n): self = Int64(exactly: n).map(MdocValue.integer) ?? .unsupported
        case .negative(let n):
            self = Int64(exactly: n).map { .integer(-1 - $0) } ?? .unsupported
        case .bool(let b): self = .boolean(b)
        case .bytes(let d): self = .bytes(d)
        case .null: self = .null
        case .undefined, .float, .simple: self = .unsupported
        case .array(let a): self = .array(a.map(MdocValue.init))
        case .tagged(0, .text(let s)): self = .dateTime(s)
        case .tagged(1004, .text(let s)): self = .fullDate(s)
        case .tagged: self = .unsupported
        case .map(let pairs):
            var m: [String: MdocValue] = [:]
            for p in pairs {
                guard let k = p.key.asText else { self = .unsupported; return }
                m[k] = MdocValue(p.value)
            }
            self = .map(m)
        }
    }

    public var asBoolean: Bool? { if case .boolean(let b) = self { return b }; return nil }
    public var asText: String? { if case .text(let s) = self { return s }; return nil }
}

public enum ElementProvenance: Equatable {
    case issuerSigned
    case deviceSigned
}

public enum VerificationVerdict: Equatable {
    case valid
    case invalid
    case unverified
}

public enum EngagementTechnology: Equatable {
    case qr
    case nfcStaticHandover
    case nfcNegotiatedHandover

    public var isNFC: Bool { self != .qr }
}

public enum TransmissionTechnology: Equatable {
    case ble(BleMode)
    case nfc
    case wifiAware
}

public enum BleAdvertiseMode: Equatable {
    case peripheralServer
    case centralClient
    case both

    public func allows(_ technology: TransmissionTechnology) -> Bool {
        guard case .ble(let mode) = technology else { return true }
        switch self {
        case .both: return true
        case .peripheralServer: return mode == .peripheralServer
        case .centralClient: return mode == .centralClient
        }
    }
}

public enum BleMode: Equatable {
    case peripheralServer, centralClient
}

public enum TransmissionKind: Equatable {
    case ble
    case nfc
    case wifiAware
}

public enum BleModePreference: Equatable {
    case central
    case peripheral

    var gattModes: [BleMode] {
        switch self {
        case .central: return [.centralClient, .peripheralServer]
        case .peripheral: return [.peripheralServer, .centralClient]
        }
    }
}
