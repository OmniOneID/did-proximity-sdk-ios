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

@_spi(MdocInternal) public struct EnvelopeChaining {

    public let commandLimit: Int
    public let responseLimit: Int
    /// Switches to extended length only when the peer advertised limits above the short limits (255 / 256) (8.3.3.1.2 —
    /// extended is a should). Never exceeds the limits the peer advertised.
    public var extended: Bool { commandLimit > 255 || responseLimit > 256 }

    public init(commandLimit: Int, responseLimit: Int) {
        self.commandLimit = commandLimit
        self.responseLimit = responseLimit
    }

    public func commands(for message: Data) throws -> [Data] {
        guard commandLimit > 0 else {
            throw MdocProximityError.connectionFailed(detail: "NFC command limit too small")
        }
        let tlv = BerTlv53.encode(message)
        var out: [Data] = []
        var i = 0
        while i < tlv.count {
            let end = min(i + commandLimit, tlv.count)
            let isLast = end >= tlv.count
            out.append(extended
                ? Apdu.envelopeExtended(tlv[i..<end], isLast: isLast, le: isLast ? responseLimit : nil)
                : Apdu.envelope(tlv[i..<end], isLast: isLast,
                                le: isLast ? UInt8(min(responseLimit, 255)) : nil))
            i = end
        }
        return out
    }

    public enum Next: Equatable {
        case done(Data)
        case getResponse(le: UInt8)
        case getResponseExtended(le: Int)
        case failed
    }

    public func step(_ response: Data) -> Next {
        let sw = Apdu.statusWord(response)
        let body = response.count >= 2 ? response.prefix(response.count - 2) : Data()
        switch sw >> 8 {
        case 0x90 where sw == 0x9000: return .done(Data(body))
        case 0x61:
            let remaining = UInt8(sw & 0xff)
            // `61 00` means "256 or more remaining" — with extended length, fetch up to the limit at once
            if extended { return .getResponseExtended(le: remaining == 0 ? responseLimit : Int(remaining)) }
            return .getResponse(le: remaining == 0 ? UInt8(min(responseLimit, 255)) : remaining)
        default: return .failed
        }
    }
}
