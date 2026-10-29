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

public struct MdocDeviceConfiguration {
    public var engagementTimeout: TimeInterval = 90
    public var responseTimeout: TimeInterval = 60
    public var bleAdvertiseMode: BleAdvertiseMode = .both
    public var l2capUpgrade: Bool = false
    public var callbackQueue: DispatchQueue = .main
    public init() {}
}

public struct MdocReaderConfiguration {
    public var transmissionPriority: [TransmissionKind] = [.ble, .nfc, .wifiAware]
    public var blePreferredMode: BleModePreference = .peripheral
    public var skipIssuerAuth: Bool = true
    public var l2capUpgrade: Bool = false
    public var connectTimeout: TimeInterval = 30
    public var responseTimeout: TimeInterval = 120
    public var callbackQueue: DispatchQueue = .main
    public init() {}
}

public enum TransportCapability: Equatable {
    case supported
    case unsupported(reason: CapabilityReason)
    case configurationRequired(action: RequiredAction)
}

@_spi(MdocInternal) public extension TransportCapability {
    func blockingError(for kind: TransmissionKind) -> MdocProximityError? {
        switch self {
        case .supported: return nil
        case .configurationRequired(let action): return .configurationRequired(action: action)
        case .unsupported(let reason):
            switch kind {
            case .ble: return .bleUnavailable(reason: reason)
            case .nfc: return .nfcUnavailable(reason: reason)
            case .wifiAware: return .wifiAwareUnavailable(reason: reason)
            }
        }
    }
}

public struct RoleCapabilities: Equatable {
    public let ble: TransportCapability
    public let nfc: TransportCapability
    public let wifiAware: TransportCapability

    @_spi(MdocInternal) public func blockingError(among kinds: [TransmissionKind]) -> MdocProximityError? {
        for kind in kinds {
            let capability: TransportCapability
            switch kind {
            case .ble: capability = ble
            case .nfc: capability = nfc
            case .wifiAware: capability = wifiAware
            }
            if let e = capability.blockingError(for: kind) { return e }
        }
        return nil
    }
}

public struct MdocCapabilities: Equatable {
    public let mdoc: RoleCapabilities
    public let mdocReader: RoleCapabilities

    @_spi(MdocInternal) public static var provider: (() -> MdocCapabilities)?

    @_spi(MdocInternal) public static func assumeAllSupportedForTests() {
        provider = {
            MdocCapabilities(mdoc: RoleCapabilities(ble: .supported, nfc: .unsupported(reason: .vendorPolicy),
                                                    wifiAware: .unsupported(reason: .vendorPolicy)),
                             mdocReader: RoleCapabilities(ble: .supported, nfc: .supported,
                                                          wifiAware: .unsupported(reason: .vendorPolicy)))
        }
    }

    public static func current() -> MdocCapabilities {
        if let provider { return provider() }
        let ble = BleCapabilityProbe.current()
        let wifi = TransportCapability.unsupported(reason: .vendorPolicy)
        return MdocCapabilities(
            mdoc: RoleCapabilities(ble: ble, nfc: NfcCapability.mdocSupport(), wifiAware: wifi),
            mdocReader: RoleCapabilities(ble: ble, nfc: NfcCapability.readerCurrent(), wifiAware: wifi))
    }
}
