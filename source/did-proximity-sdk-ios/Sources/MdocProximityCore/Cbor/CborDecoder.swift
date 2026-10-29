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

@_spi(MdocInternal) public enum CborDecoder {

    public static let maxDepth = 32
    public static let maxItems = 65_536

    public static func decode(_ data: Data) throws -> CborValue {
        try decodeNode(data).value
    }

    public static func decodeNode(_ data: Data) throws -> CborNode {
        var p = Parser(bytes: [UInt8](data))
        let node = try p.item(depth: 0)
        guard p.i == p.bytes.count else {
            throw MdocProximityError.decodeFailed(detail: "trailing bytes at \(p.i)")
        }
        return node
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func byte() throws -> UInt8 {
            guard i < bytes.count else { throw MdocProximityError.decodeFailed(detail: "truncated") }
            defer { i += 1 }
            return bytes[i]
        }

        mutating func head() throws -> (major: UInt8, value: UInt64?) {
            let b = try byte()
            let major = b >> 5
            let ai = b & 0x1f
            switch ai {
            case ..<24: return (major, UInt64(ai))
            case 24:    return (major, UInt64(try byte()))
            case 25:    return (major, try be(2))
            case 26:    return (major, try be(4))
            case 27:    return (major, try be(8))
            case 31:    return (major, nil)          // indefinite-length
            default:    throw MdocProximityError.decodeFailed(detail: "reserved additional info \(ai)")
            }
        }

        mutating func be(_ n: Int) throws -> UInt64 {
            var v: UInt64 = 0
            for _ in 0..<n { v = (v << 8) | UInt64(try byte()) }
            return v
        }

        mutating func take(_ n: UInt64) throws -> Data {
            guard n <= UInt64(bytes.count - i) else {
                throw MdocProximityError.decodeFailed(detail: "length \(n) exceeds input")
            }
            let start = i
            i += Int(n)
            return Data(bytes[start..<i])
        }

        mutating func item(depth: Int) throws -> CborNode {
            guard depth <= CborDecoder.maxDepth else {
                throw MdocProximityError.decodeFailed(detail: "depth > \(CborDecoder.maxDepth)")
            }
            let start = i
            let (major, len) = try head()

            switch major {
            case 0:
                guard let n = len else { throw MdocProximityError.decodeFailed(detail: "indefinite uint") }
                return CborNode(.unsigned(n), start..<i)
            case 1:
                guard let n = len else { throw MdocProximityError.decodeFailed(detail: "indefinite nint") }
                return CborNode(.negative(n), start..<i)
            case 2, 3:
                var payload = Data()
                if let n = len {
                    payload = try take(n)
                } else {                                   // indefinite-length chunks
                    while true {
                        if i < bytes.count, bytes[i] == 0xff { i += 1; break }
                        let chunk = try item(depth: depth + 1)
                        switch chunk.value {
                        case .bytes(let d): payload.append(d)
                        case .text(let s):  payload.append(Data(s.utf8))
                        default: throw MdocProximityError.decodeFailed(detail: "bad indefinite chunk")
                        }
                    }
                }
                if major == 2 { return CborNode(.bytes(payload), start..<i) }
                guard let s = String(data: payload, encoding: .utf8) else {
                    throw MdocProximityError.decodeFailed(detail: "invalid utf8")
                }
                return CborNode(.text(s), start..<i)
            case 4:
                var kids: [CborNode] = []
                try collect(len, depth: depth) { kids.append($0) }
                return CborNode(.array(kids.map(\.value)), start..<i, kids)
            case 5:
                var kids: [CborNode] = []
                if let n = len, n > UInt64(CborDecoder.maxItems) {
                    throw MdocProximityError.decodeFailed(detail: "items > \(CborDecoder.maxItems)")
                }
                try collect(len.map { $0 * 2 }, depth: depth) { kids.append($0) }
                guard kids.count % 2 == 0 else {
                    throw MdocProximityError.decodeFailed(detail: "odd map entries")
                }
                var pairs: [CborPair] = []
                for k in stride(from: 0, to: kids.count, by: 2) {
                    pairs.append(CborPair(kids[k].value, kids[k + 1].value))
                }
                return CborNode(.map(pairs), start..<i, kids)
            case 6:
                guard let t = len else { throw MdocProximityError.decodeFailed(detail: "indefinite tag") }
                let inner = try item(depth: depth + 1)
                return CborNode(.tagged(t, inner.value), start..<i, [inner])
            case 7:
                // Accept anything well-formed — floats and simple values surface as values; upper layers interpret them.
                guard let v = len else { throw MdocProximityError.decodeFailed(detail: "unexpected break") }
                switch bytes[start] & 0x1f {
                case 20: return CborNode(.bool(false), start..<i)
                case 21: return CborNode(.bool(true), start..<i)
                case 22: return CborNode(.null, start..<i)
                case 23: return CborNode(.undefined, start..<i)
                case ..<20: return CborNode(.simple(UInt8(v)), start..<i)
                case 24:
                    // RFC 8949 3.3 — encoding a value below 32 with the 1-byte extension is not well-formed
                    guard v >= 32 else { throw MdocProximityError.decodeFailed(detail: "simple \(v) in extended form") }
                    return CborNode(.simple(UInt8(v)), start..<i)
                case 25: return CborNode(.float(Self.half(UInt16(v))), start..<i)
                case 26: return CborNode(.float(Double(Float(bitPattern: UInt32(v)))), start..<i)
                default: return CborNode(.float(Double(bitPattern: v)), start..<i)
                }
            default:
                throw MdocProximityError.decodeFailed(detail: "major \(major)")
            }
        }

        /// IEEE 754 binary16 → Double (RFC 8949 Appendix D).
        static func half(_ h: UInt16) -> Double {
            let exp = Int((h >> 10) & 0x1f), mant = Double(h & 0x3ff)
            let magnitude: Double
            switch exp {
            case 0:  magnitude = mant * pow(2, -24)
            case 31: magnitude = mant == 0 ? .infinity : .nan
            default: magnitude = (mant + 1024) * pow(2, Double(exp - 25))
            }
            return h & 0x8000 != 0 ? -magnitude : magnitude
        }

        private mutating func collect(_ len: UInt64?,
                                      depth: Int,
                                      _ sink: (CborNode) -> Void) throws {
            if let n = len {
                guard n <= UInt64(CborDecoder.maxItems) else {
                    throw MdocProximityError.decodeFailed(detail: "items > \(CborDecoder.maxItems)")
                }
                for _ in 0..<n { sink(try item(depth: depth + 1)) }
            } else {
                var count = 0
                while true {
                    if i < bytes.count, bytes[i] == 0xff { i += 1; break }
                    count += 1
                    guard count <= CborDecoder.maxItems else {
                        throw MdocProximityError.decodeFailed(detail: "items > \(CborDecoder.maxItems)")
                    }
                    sink(try item(depth: depth + 1))
                }
            }
        }
    }
}
