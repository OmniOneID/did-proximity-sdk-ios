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
import CoreBluetooth
#if canImport(MdocProximityCore)
@_spi(MdocInternal) import MdocProximityCore
@_spi(MdocInternal) import MdocBLE
#endif

@_spi(MdocInternal) public struct DeviceTransportFactory: TransportFactoryProtocol {

    public init() {}

    public var availableTechnologies: [TransmissionTechnology] {
        guard MdocCapabilities.current().mdoc.ble == .supported else { return [] }
        return [.ble(.peripheralServer), .ble(.centralClient)]
    }

    public func makeTransport(_ p: TransportParameters) throws -> DataRetrievalTransportProtocol {
        switch p.technology {
        case .ble(.peripheralServer):
            return BleGattServerTransport(profile: .peripheralServerMode(serviceUUID: try uuid(p)),
                                          publishesL2cap: p.l2cap)
        case .ble(.centralClient):
            let profile = BleServiceProfile.centralClientMode(serviceUUID: try uuid(p))
            guard p.l2cap else {
                return BleGattClientTransport(profile: profile, expectedIdent: p.ident)
            }
            return BleL2capOpeningTransport(profile: profile, expectedIdent: p.ident) {
                BleGattClientTransport(profile: profile, expectedIdent: p.ident)
            }
        case .nfc:
            throw MdocProximityError.unsupportedTransmissionTechnology
        case .wifiAware:
            throw MdocProximityError.wifiAwareUnavailable(reason: .vendorPolicy)
        }
    }

    private func uuid(_ p: TransportParameters) throws -> CBUUID {
        guard let raw = p.serviceUUID, raw.count == 16 else {
            throw MdocProximityError.connectionFailed(detail: "missing service UUID")
        }
        return CBUUID(data: raw)
    }
}
