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
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

@_spi(MdocInternal) public enum BleCapabilityProbe {

    #if canImport(CoreBluetooth)
    private static let lock = NSLock()
    private static var manager: CBCentralManager?
    #endif

    public static func current() -> TransportCapability {
        #if canImport(CoreBluetooth)
        switch CBManager.authorization {
        case .denied, .restricted:
            return .configurationRequired(action: .grantPermission("bluetooth"))
        case .notDetermined:
            return .supported
        default:
            break
        }
        lock.lock()
        if manager == nil {
            manager = CBCentralManager(delegate: nil, queue: nil,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        let state = manager!.state
        lock.unlock()
        return map(state)
        #else
        return .unsupported(reason: .noHardware)
        #endif
    }

    #if canImport(CoreBluetooth)
    static func map(_ state: CBManagerState) -> TransportCapability {
        switch state {
        case .poweredOff:   return .configurationRequired(action: .enableBluetooth)
        case .unauthorized: return .configurationRequired(action: .grantPermission("bluetooth"))
        case .unsupported:  return .unsupported(reason: .noHardware)
        default:            return .supported     // poweredOn · unknown · resetting
        }
    }
    #endif
}
