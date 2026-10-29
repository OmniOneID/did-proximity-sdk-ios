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
#if canImport(CoreNFC)
import CoreNFC
#endif

@_spi(MdocInternal) public enum NfcAid {
    public static let ndefTagApplication = Data([0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01])
    public static let mdocDataRetrieval = Data([0xA0, 0x00, 0x00, 0x02, 0x48, 0x04, 0x00])
}

@_spi(MdocInternal) public enum NfcCapability {

    public static func mdocSupport() -> TransportCapability {
        .unsupported(reason: .vendorPolicy)
    }

    public static func readerSupport(hasSelectIdentifiers: Bool) -> TransportCapability {
        hasSelectIdentifiers ? .supported
                             : .configurationRequired(action: .addEntitlement(
                                 "com.apple.developer.nfc.readersession.iso7816.select-identifiers"))
    }

    public static func validateSelectIdentifiers(_ list: [Data]) -> Bool {
        guard let first = list.first else { return false }
        return first == NfcAid.ndefTagApplication && list.contains(NfcAid.mdocDataRetrieval)
    }

    public static func validateSelectIdentifiers(_ list: [String]) -> Bool {
        validateSelectIdentifiers(list.compactMap { Data(hexString: $0) })
    }

    static func registeredSelectIdentifiers() -> [String] {
        (Bundle.main.object(forInfoDictionaryKey:
            "com.apple.developer.nfc.readersession.iso7816.select-identifiers") as? [String]) ?? []
    }

    static func readerCurrent() -> TransportCapability {
        #if canImport(CoreNFC)
        guard NFCTagReaderSession.readingAvailable else { return .unsupported(reason: .noHardware) }
        return readerSupport(hasSelectIdentifiers: validateSelectIdentifiers(registeredSelectIdentifiers()))
        #else
        return .unsupported(reason: .noHardware)
        #endif
    }
}

private extension Data {
    init?(hexString: String) {
        var d = Data(); var it = hexString.startIndex
        while it < hexString.endIndex {
            guard let n = hexString.index(it, offsetBy: 2, limitedBy: hexString.endIndex),
                  let b = UInt8(hexString[it..<n], radix: 16) else { return nil }
            d.append(b); it = n
        }
        self = d
    }
}
