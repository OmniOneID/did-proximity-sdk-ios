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

@_spi(MdocInternal) public struct Type4TagEmulator {

    public static let ccFileID: UInt16 = 0xE103
    public static let ndefFileID: UInt16 = 0xE104

    public enum Mode {
        case `static`
        case negotiated(Tnep.ServiceParameter, onHandoverRequest: (Data) -> Data?)
    }

    private let cc: Data
    private var ndefFile: Data
    private var selectedFile: UInt16?
    private let mode: Mode
    private var serviceSelected = false
    public private(set) var lastResponse: Data?

    public init(ndefMessage: Data, mode: Mode = .static, mLe: UInt16 = 255, mLc: UInt16 = 255) {
        self.mode = mode
        let initial: Data
        let writable: UInt8
        let maxNdef: UInt16
        switch mode {
        case .static:
            initial = ndefMessage; writable = 0xFF
            maxNdef = UInt16(clamping: ndefMessage.count + 2)
        case .negotiated(let sp, _):
            initial = Ndef.encode([sp.record]); writable = 0x00
            maxNdef = UInt16(clamping: Int(sp.maxMessageSize) + 2)
        }
        cc = Data([0x00, 0x0F,                                  // CCLEN
                   0x20,                                        // Mapping Version 2.0
                   UInt8(mLe >> 8), UInt8(mLe & 0xff),
                   UInt8(mLc >> 8), UInt8(mLc & 0xff),
                   0x04, 0x06,                                  // NDEF File Control TLV
                   UInt8(Self.ndefFileID >> 8), UInt8(Self.ndefFileID & 0xff),
                   UInt8(maxNdef >> 8), UInt8(maxNdef & 0xff),
                   0x00,
                   writable])
        ndefFile = Self.file(initial)
    }

    private static func file(_ message: Data) -> Data {
        Data([UInt8(message.count >> 8), UInt8(message.count & 0xff)]) + message
    }

    public mutating func reset() { selectedFile = nil }

    public mutating func handle(_ apdu: Data) -> Data {
        guard apdu.count >= 4 else { return Data([0x67, 0x00]) }
        let ins = apdu[apdu.startIndex + 1], p1 = apdu[apdu.startIndex + 2], p2 = apdu[apdu.startIndex + 3]
        switch ins {
        case 0xA4 where p1 == 0x00:                                     // SELECT by file id
            guard apdu.count >= 7, apdu[apdu.startIndex + 4] == 0x02 else { return Data([0x6A, 0x86]) }
            let id = UInt16(apdu[apdu.startIndex + 5]) << 8 | UInt16(apdu[apdu.startIndex + 6])
            guard id == Self.ccFileID || id == Self.ndefFileID else { return Data([0x6A, 0x82]) }
            selectedFile = id
            return Data([0x90, 0x00])
        case 0xB0:                                                      // ReadBinary
            guard let selectedFile else { return Data([0x69, 0x86]) }
            let file = selectedFile == Self.ccFileID ? cc : ndefFile
            let offset = Int(p1) << 8 | Int(p2)
            let le = apdu.count >= 5 ? Int(apdu[apdu.startIndex + 4]) : 0
            let length = le == 0 ? 256 : le
            guard offset <= file.count else { return Data([0x6B, 0x00]) }
            let end = min(offset + length, file.count)
            return file.subdata(in: offset..<end) + Data([0x90, 0x00])
        case 0xD6:                                                      // UpdateBinary
            guard case .negotiated = mode else { return Data([0x69, 0x82]) }
            guard selectedFile == Self.ndefFileID else { return Data([0x69, 0x86]) }
            guard apdu.count >= 5 else { return Data([0x67, 0x00]) }
            let lc = Int(apdu[apdu.startIndex + 4])
            guard apdu.count >= 5 + lc else { return Data([0x67, 0x00]) }
            let data = apdu.subdata(in: (apdu.startIndex + 5)..<(apdu.startIndex + 5 + lc))
            let offset = Int(p1) << 8 | Int(p2)
            if ndefFile.count < offset + data.count {
                ndefFile.append(Data(repeating: 0, count: offset + data.count - ndefFile.count))
            }
            ndefFile.replaceSubrange(offset..<(offset + data.count), with: data)
            if offset == 0, data.count >= 2 {
                let nlen = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
                if nlen > 0 { receivedMessage(ndefFile.subdata(in: 2..<min(2 + nlen, ndefFile.count))) }
            }
            return Data([0x90, 0x00])
        default:
            return Data([0x6D, 0x00])
        }
    }

    private mutating func receivedMessage(_ message: Data) {
        guard case .negotiated(let sp, let onHandoverRequest) = mode,
              let records = try? Ndef.parse(message) else {
            return respond(Ndef.encode([Tnep.status(Tnep.statusProtocolError)]))
        }
        if let name = Tnep.selectedService(in: records) {
            serviceSelected = name == sp.serviceName
            return name.isEmpty ? respond(Data()) : respond(Ndef.encode([Tnep.status(
                serviceSelected ? Tnep.statusSuccess : Tnep.statusProtocolError)]))
        }
        guard serviceSelected, records.contains(where: { $0.typeNameFormat == 0x01 && $0.typeText == "Hr" }),
              let select = onHandoverRequest(message) else {
            return respond(Ndef.encode([Tnep.status(Tnep.statusProtocolError)]))
        }
        respond(select)
    }

    private mutating func respond(_ message: Data) {
        lastResponse = message.isEmpty ? nil : message
        ndefFile = Self.file(message)
    }
}
