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

@_spi(MdocInternal) public protocol Iso7816Channel: AnyObject {
    func transceive(_ apdu: Data) async throws -> Data
    var isAvailable: Bool { get }
    func close()
}

@_spi(MdocInternal) public enum BerTlv53 {
    public static func value(_ d: Data) throws -> Data {
        var i = d.startIndex
        guard i < d.endIndex, d[i] == 0x53 else {
            throw MdocProximityError.decodeFailed(detail: "NFC: not a 53 data object")
        }
        i += 1
        guard i < d.endIndex else { throw MdocProximityError.decodeFailed(detail: "NFC: truncated TLV") }
        var length = Int(d[i]); i += 1
        if length >= 0x81 && length <= 0x83 {
            let count = length - 0x80
            guard i + count <= d.endIndex else {
                throw MdocProximityError.decodeFailed(detail: "NFC: truncated TLV length")
            }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(d[i]); i += 1 }
        }
        guard i + length <= d.endIndex else {
            throw MdocProximityError.decodeFailed(detail: "NFC: TLV shorter than its length")
        }
        return d.subdata(in: i..<(i + length))
    }

    public static func values(_ d: Data) throws -> Data {
        var out = Data()
        var rest = d
        while !rest.isEmpty {
            let v = try value(rest)
            out.append(v)
            let consumed = headerLength(rest) + v.count
            rest = rest.subdata(in: (rest.startIndex + consumed)..<rest.endIndex)
        }
        return out
    }

    public static func encode(_ payload: Data) -> Data {
        var out = Data([0x53])
        let n = payload.count
        if n < 0x80 { out.append(UInt8(n)) }
        else if n <= 0xff { out.append(contentsOf: [0x81, UInt8(n)]) }
        else if n <= 0xffff { out.append(contentsOf: [0x82, UInt8(n >> 8), UInt8(n & 0xff)]) }
        else { out.append(contentsOf: [0x83, UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]) }
        out.append(payload)
        return out
    }

    private static func headerLength(_ d: Data) -> Int {
        let l = d[d.startIndex + 1]
        return l >= 0x81 && l <= 0x83 ? Int(l - 0x80) + 2 : 2
    }
}
