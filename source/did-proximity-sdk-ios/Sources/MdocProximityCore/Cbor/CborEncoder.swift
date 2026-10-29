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

@_spi(MdocInternal) public enum CborEncoder {

    public static func encode(_ v: CborValue) -> Data {
        var out = Data()
        append(v, to: &out)
        return out
    }

    public static func tag24(_ innerEncoded: Data) -> Data {
        var out = Data()
        appendHead(major: 6, value: 24, to: &out)
        appendHead(major: 2, value: UInt64(innerEncoded.count), to: &out)
        out.append(innerEncoded)
        return out
    }

    private static func append(_ v: CborValue, to out: inout Data) {
        switch v {
        case .unsigned(let n): appendHead(major: 0, value: n, to: &out)
        case .negative(let n): appendHead(major: 1, value: n, to: &out)
        case .bytes(let d):
            appendHead(major: 2, value: UInt64(d.count), to: &out); out.append(d)
        case .text(let s):
            let d = Data(s.utf8)
            appendHead(major: 3, value: UInt64(d.count), to: &out); out.append(d)
        case .array(let items):
            appendHead(major: 4, value: UInt64(items.count), to: &out)
            for i in items { append(i, to: &out) }
        case .map(let pairs):
            appendHead(major: 5, value: UInt64(pairs.count), to: &out)
            let sorted = pairs
                .map { (encode($0.key), $0.value) }
                .sorted { lexLess($0.0, $1.0) }
            for (k, val) in sorted { out.append(k); append(val, to: &out) }
        case .tagged(let t, let inner):
            appendHead(major: 6, value: t, to: &out); append(inner, to: &out)
        case .bool(let b): out.append(b ? 0xf5 : 0xf4)
        case .null: out.append(0xf6)
        case .undefined: out.append(0xf7)
        case .float(let d):
            out.append(0xfb); out.append(contentsOf: be(d.bitPattern, 8))
        case .simple(let n):
            if n < 24 { out.append(0xe0 | n) } else { out.append(0xf8); out.append(n) }
        }
    }

    private static func lexLess(_ a: Data, _ b: Data) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }

    private static func appendHead(major: UInt8, value: UInt64, to out: inout Data) {
        let m = major << 5
        switch value {
        case ..<24:              out.append(m | UInt8(value))
        case ..<0x100:           out.append(m | 24); out.append(UInt8(value))
        case ..<0x1_0000:        out.append(m | 25); out.append(contentsOf: be(value, 2))
        case ..<0x1_0000_0000:   out.append(m | 26); out.append(contentsOf: be(value, 4))
        default:                 out.append(m | 27); out.append(contentsOf: be(value, 8))
        }
    }

    private static func be(_ v: UInt64, _ n: Int) -> [UInt8] {
        (0..<n).reversed().map { UInt8((v >> (8 * UInt64($0))) & 0xff) }
    }
}
