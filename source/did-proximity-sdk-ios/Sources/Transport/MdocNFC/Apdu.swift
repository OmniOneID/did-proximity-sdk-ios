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

@_spi(MdocInternal) public enum Apdu {

    /// SELECT by name (Table 14) — CLA `00`, INS `A4`, P1-P2 `04 0C`, Le absent
    public static func selectByName(_ aid: Data) -> Data {
        Data([0x00, 0xA4, 0x04, 0x0C, UInt8(aid.count)]) + aid
    }

    public static func selectFile(_ fileID: UInt16) -> Data {
        Data([0x00, 0xA4, 0x00, 0x0C, 0x02,
              UInt8(fileID >> 8), UInt8(fileID & 0xff)])
    }

    public static func readBinary(offset: UInt16, length: UInt8) -> Data {
        Data([0x00, 0xB0, UInt8(offset >> 8), UInt8(offset & 0xff), length])
    }

    public static func updateBinary(offset: UInt16, data: Data) -> Data {
        Data([0x00, 0xD6, UInt8(offset >> 8), UInt8(offset & 0xff), UInt8(data.count)]) + data
    }

    public static func envelope(_ chunk: Data, isLast: Bool, le: UInt8?) -> Data {
        var a = Data([isLast ? 0x00 : 0x10, 0xC3, 0x00, 0x00, UInt8(chunk.count)])
        a.append(chunk)
        if isLast, let le { a.append(le) }
        return a
    }

    /// extended-length ENVELOPE (7816-4 5.2) — Lc is 3 bytes (`00` + 2), Le is 2 bytes (`0000` = 65536).
    /// Never mixed with short length within one APDU.
    public static func envelopeExtended(_ chunk: Data, isLast: Bool, le: Int?) -> Data {
        var a = Data([isLast ? 0x00 : 0x10, 0xC3, 0x00, 0x00,
                      0x00, UInt8(chunk.count >> 8), UInt8(chunk.count & 0xff)])
        a.append(chunk)
        if isLast, let le { a.append(contentsOf: extendedLe(le)) }
        return a
    }

    /// extended-length GET RESPONSE — no Lc, Le is 3 bytes.
    public static func getResponseExtended(le: Int) -> Data {
        Data([0x00, 0xC0, 0x00, 0x00, 0x00]) + extendedLe(le)
    }

    private static func extendedLe(_ le: Int) -> [UInt8] {
        let v = le >= 65_536 ? 0 : le
        return [UInt8(v >> 8), UInt8(v & 0xff)]
    }

    public static func berTlv53(_ payload: Data) -> Data {
        Data([0x53, UInt8(payload.count)]) + payload
    }

    public static func getResponse(le: UInt8) -> Data { Data([0x00, 0xC0, 0x00, 0x00, le]) }

    public static func statusWord(_ r: Data) -> UInt16 {
        guard r.count >= 2 else { return 0 }
        return UInt16(r[r.count - 2]) << 8 | UInt16(r[r.count - 1])
    }
}

@_spi(MdocInternal) public struct CapabilityContainer {
    public let mLe: UInt16
    public let mLc: UInt16
    public let ndefFileID: UInt16
    public let maxNdefSize: UInt16
    public let writable: Bool

    public init?(_ d: Data) {
        guard d.count >= 15 else { return nil }
        mLe = UInt16(d[3]) << 8 | UInt16(d[4])
        mLc = UInt16(d[5]) << 8 | UInt16(d[6])
        // NDEF File Control TLV: T=04 L=06
        guard d[7] == 0x04, d[8] == 0x06 else { return nil }
        ndefFileID = UInt16(d[9]) << 8 | UInt16(d[10])
        maxNdefSize = UInt16(d[11]) << 8 | UInt16(d[12])
        writable = (d[14] == 0x00)
    }
}
