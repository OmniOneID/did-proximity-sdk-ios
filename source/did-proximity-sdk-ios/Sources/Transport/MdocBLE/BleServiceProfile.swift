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
#endif

@_spi(MdocInternal) public struct BleServiceProfile {
    public let serviceUUID: CBUUID
    public let state: CBUUID
    public let client2Server: CBUUID     // GATT client → server
    public let server2Client: CBUUID     // GATT server → client
    public let ident: CBUUID?
    public let l2cap: CBUUID

    private static let suffix = "-A123-48CE-896B-4C76973373E6"
    private static func u(_ n: String) -> CBUUID { CBUUID(string: "0000000\(n)" + suffix) }

    public static func peripheralServerMode(serviceUUID: CBUUID) -> BleServiceProfile {
        BleServiceProfile(serviceUUID: serviceUUID, state: u("1"),
                          client2Server: u("2"), server2Client: u("3"), ident: nil,
                          l2cap: u("A"))
    }

    public static func centralClientMode(serviceUUID: CBUUID) -> BleServiceProfile {
        BleServiceProfile(serviceUUID: serviceUUID, state: u("5"),
                          client2Server: u("6"), server2Client: u("7"), ident: u("8"),
                          l2cap: u("B"))
    }
}

enum BleState: UInt8 {
    case start = 0x01
    case end = 0x02
}

final class ReassemblyBuffer {
    static let maxMessageBytes = 512 * 1024
    private var buffer = Data()

    func append(_ part: Data) throws -> Data? {
        guard let flag = part.first, flag == 0x00 || flag == 0x01 else {
            throw MdocProximityError.decodeFailed(detail: "BLE part: bad leading byte")
        }
        buffer.append(part.dropFirst())
        guard buffer.count <= Self.maxMessageBytes else {
            throw MdocProximityError.decodeFailed(detail: "BLE message > 512 KiB")
        }
        if flag == 0x00 { defer { buffer.removeAll() }; return buffer }
        return nil
    }

    func discard() { buffer.removeAll() }
}
