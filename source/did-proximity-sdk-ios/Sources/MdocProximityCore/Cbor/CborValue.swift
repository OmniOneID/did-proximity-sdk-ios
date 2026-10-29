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

@_spi(MdocInternal) public indirect enum CborValue: Equatable {
    case unsigned(UInt64)
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CborValue])
    case map([CborPair])
    case tagged(UInt64, CborValue)
    case bool(Bool)
    case null
    case undefined
    /// Holds float16/32/64 as Double — the original width stays in the raw bytes at `CborNode.range`.
    case float(Double)
    /// A simple value outside 20–23 (RFC 8949 3.3).
    case simple(UInt8)
}

@_spi(MdocInternal) public struct CborPair: Equatable {
    public let key: CborValue
    public let value: CborValue
    public init(_ key: CborValue, _ value: CborValue) { self.key = key; self.value = value }
}

@_spi(MdocInternal) public extension CborValue {
    func member(_ key: UInt64) -> CborValue? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == .unsigned(key) }?.value
    }
    func member(_ key: String) -> CborValue? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == .text(key) }?.value
    }
    var asUInt: UInt64? { if case .unsigned(let v) = self { return v }; return nil }
    var asText: String? { if case .text(let v) = self { return v }; return nil }
    var asBytes: Data? { if case .bytes(let v) = self { return v }; return nil }
    var asArray: [CborValue]? { if case .array(let v) = self { return v }; return nil }
}

@_spi(MdocInternal) public final class CborNode {
    public let value: CborValue
    public let range: Range<Int>
    public let children: [CborNode]
    init(_ value: CborValue, _ range: Range<Int>, _ children: [CborNode] = []) {
        self.value = value; self.range = range; self.children = children
    }
}
