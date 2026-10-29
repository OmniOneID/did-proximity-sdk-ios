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

public enum MdocProximityError: Error, Equatable {
    // capability
    case bleUnavailable(reason: CapabilityReason)
    case nfcUnavailable(reason: CapabilityReason)
    case wifiAwareUnavailable(reason: CapabilityReason)
    case configurationRequired(action: RequiredAction)
    // engagement
    case malformedEngagement(detail: String)
    case unsupportedTransmissionTechnology
    case engagementTimeout
    // transport
    case connectionFailed(detail: String)
    case peerDisconnected
    case transferTimeout
    // session
    case sessionEncryptionFailed
    case counterMismatch
    case terminatedByPeer(status: UInt64)
    // codec
    case decodeFailed(detail: String)
    case validationFailed(detail: String)
    case responseTimeout
    case invalidState(current: String, attempted: String)
}

public enum CapabilityReason: Equatable {
    case noHardware
    case osVersion
    case vendorPolicy
}

public enum RequiredAction: Equatable {
    case enableBluetooth
    case enableNfc
    case enableWifi
    case enableLocationServices
    case grantPermission(String)
    case addEntitlement(String)
}
