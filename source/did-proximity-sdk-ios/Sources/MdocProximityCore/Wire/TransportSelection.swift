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

@_spi(MdocInternal) public enum TransportSelection {

    public static func select(advertised: [TransmissionTechnology],
                              priority: [TransmissionKind],
                              blePreferredMode: BleModePreference,
                              available: [TransmissionTechnology]) -> TransmissionTechnology? {
        let usable = { (t: TransmissionTechnology) in advertised.contains(t) && available.contains(t) }
        for kind in priority {
            switch kind {
            case .nfc:
                if usable(.nfc) { return .nfc }
            case .wifiAware:
                if usable(.wifiAware) { return .wifiAware }
            case .ble:
                if let mode = blePreferredMode.gattModes.first(where: { usable(.ble($0)) }) {
                    return .ble(mode)
                }
            }
        }
        return nil
    }
}
