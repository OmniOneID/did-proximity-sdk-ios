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

@_spi(MdocInternal) public enum BleFraming {

    public static func partSizes(mtu: Int) throws -> (partTotal: Int, partPayload: Int) {
        let total = mtu - 3
        let payload = total - 1
        guard payload >= 1 else {
            throw MdocProximityError.connectionFailed(detail: "MTU \(mtu) too small")
        }
        return (total, payload)
    }

    public static func split(_ message: Data, mtu: Int) throws -> [Data] {
        let (_, payload) = try partSizes(mtu: mtu)
        var parts: [Data] = []
        var i = 0
        while i < message.count {
            let end = min(i + payload, message.count)
            let last = end >= message.count
            parts.append(Data([last ? 0x00 : 0x01]) + message[i..<end])
            i = end
        }
        return parts
    }
}

@_spi(MdocInternal) public enum L2capFraming {
    public static func lengthHeader(_ length: UInt32) -> Data {
        withUnsafeBytes(of: length.bigEndian) { Data($0) }
    }

    public static func frame(_ message: Data) -> Data {
        lengthHeader(UInt32(message.count)) + message
    }

    public final class Reassembler {
        public static let maxMessageBytes = 512 * 1024
        private var buffer = Data()

        public init() {}

        public func append(_ chunk: Data) throws -> [Data] {
            buffer.append(chunk)
            var out: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                guard length <= UInt32(Self.maxMessageBytes) else {
                    throw MdocProximityError.decodeFailed(detail: "L2CAP message > 512 KiB")
                }
                let total = 4 + Int(length)
                guard buffer.count >= total else { break }
                out.append(buffer.subdata(in: 4..<total))
                buffer.removeSubrange(0..<total)
            }
            return out
        }

        public func discard() { buffer.removeAll() }
    }
}

@_spi(MdocInternal) public enum L2capPsmCodec {
    public static func encode(_ psm: UInt16) -> Data {
        Data([0, 0, UInt8(psm >> 8), UInt8(psm & 0xff)])
    }

    public static func decode(_ value: Data) -> UInt16? {
        let b = [UInt8](value)
        switch b.count {
        case 2: return UInt16(b[0]) << 8 | UInt16(b[1])
        case 4: return b[0] == 0 && b[1] == 0 ? UInt16(b[2]) << 8 | UInt16(b[3]) : nil
        default: return nil
        }
    }
}
