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

@_spi(MdocInternal) public struct Type4TagEngagementReader {

    private let channel: Iso7816Channel

    public init(channel: Iso7816Channel) { self.channel = channel }

    public struct NotAnMdocTag: Error {}

    public struct Result {
        public let engagementBytes: Data
        public let handoverSelectBytes: Data
        public let writable: Bool
        public let records: [NdefRecord]
        public let handover: HandoverSelect.Parsed
        public let handoverRequestBytes: Data?
    }

    public func read(negotiated: ((Tnep.ServiceParameter) -> Data)? = nil) async throws -> Result {
        let selected = try await channel.transceive(Apdu.selectByName(NfcAid.ndefTagApplication))
        guard Apdu.statusWord(selected) == 0x9000 else { throw NotAnMdocTag() }

        try await select(fileID: 0xE103)
        let ccBytes = try await readBinary(offset: 0, length: 15, unit: 15)
        guard let cc = CapabilityContainer(ccBytes) else {
            throw MdocProximityError.malformedEngagement(detail: "NFC: bad CC file")
        }

        try await select(fileID: cc.ndefFileID)
        let nlenBytes = try await readBinary(offset: 0, length: 2, unit: 2)
        let nlen = Int(nlenBytes[nlenBytes.startIndex]) << 8 | Int(nlenBytes[nlenBytes.startIndex + 1])
        guard nlen > 0 else {
            throw MdocProximityError.malformedEngagement(detail: "NFC: empty NDEF file")
        }
        let unit = max(1, min(Int(cc.mLe), 255))
        let message = try await readBinary(offset: 2, length: nlen, unit: unit)

        let records = try Ndef.parse(message)
        guard let engagement = Ndef.deviceEngagement(in: records) else {
            if let sp = Tnep.serviceParameter(in: records) {
                guard cc.writable, let negotiated else {
                    throw MdocProximityError.connectionFailed(
                        detail: cc.writable ? "NFC: negotiated handover not enabled"
                                            : "NFC: negotiated offered on a read-only tag")
                }
                return try await negotiate(sp, cc: cc, request: negotiated(sp))
            }
            throw MdocProximityError.malformedEngagement(detail: "NFC: no device engagement record")
        }
        return Result(engagementBytes: engagement, handoverSelectBytes: message,
                      writable: cc.writable, records: records,
                      handover: HandoverSelect.parse(records), handoverRequestBytes: nil)
    }

    private func negotiate(_ sp: Tnep.ServiceParameter, cc: CapabilityContainer,
                           request: Data) async throws -> Result {
        let writeUnit = max(1, min(Int(cc.mLc), 255))
        let readUnit = max(1, min(Int(cc.mLe), 255))
        guard request.count <= Int(sp.maxMessageSize) else {
            throw MdocProximityError.connectionFailed(detail: "NFC: Handover Request exceeds tag's max NDEF size")
        }
        try await writeNdef(Ndef.encode([Tnep.serviceSelect(sp.serviceName)]), unit: writeUnit)
        let status = try await awaitResponse(sp, unit: readUnit)
        guard Tnep.statusCode(in: try Ndef.parse(status)) == Tnep.statusSuccess else {
            throw MdocProximityError.connectionFailed(detail: "NFC: TNEP service select rejected")
        }
        try await writeNdef(request, unit: writeUnit)
        let selectBytes = try await awaitResponse(sp, unit: readUnit)
        let selectRecords = try Ndef.parse(selectBytes)
        if let status = Tnep.statusCode(in: selectRecords) {
            throw MdocProximityError.connectionFailed(detail: "NFC: TNEP rejected Handover Request (status \(status))")
        }
        guard let engagement = Ndef.deviceEngagement(in: selectRecords) else {
            throw MdocProximityError.malformedEngagement(detail: "NFC: Handover Select without device engagement")
        }
        return Result(engagementBytes: engagement, handoverSelectBytes: selectBytes,
                      writable: true, records: selectRecords,
                      handover: HandoverSelect.parse(selectRecords), handoverRequestBytes: request)
    }

    private func writeNdef(_ message: Data, unit: Int) async throws {
        try await updateBinary(offset: 0, data: Data([0x00, 0x00]), unit: unit)
        try await updateBinary(offset: 2, data: message, unit: unit)
        try await updateBinary(offset: 0, data: Data([UInt8(message.count >> 8), UInt8(message.count & 0xff)]),
                               unit: unit)
    }

    private func awaitResponse(_ sp: Tnep.ServiceParameter, unit: Int) async throws -> Data {
        for _ in 0...Int(sp.maxWaitExtensions) {
            try await Task.sleep(nanoseconds: UInt64(max(sp.minimumWaitTime, 0.001) * 1_000_000_000))
            let nlenBytes = try await readBinary(offset: 0, length: 2, unit: 2)
            let nlen = Int(nlenBytes[nlenBytes.startIndex]) << 8 | Int(nlenBytes[nlenBytes.startIndex + 1])
            if nlen > 0 { return try await readBinary(offset: 2, length: nlen, unit: unit) }
        }
        throw MdocProximityError.connectionFailed(detail: "NFC: TNEP wait exhausted (N_wait)")
    }

    public func select(fileID: UInt16) async throws {
        let r = try await channel.transceive(Apdu.selectFile(fileID))
        guard Apdu.statusWord(r) == 0x9000 else {
            throw MdocProximityError.malformedEngagement(
                detail: "NFC: SELECT \(String(fileID, radix: 16)) failed")
        }
    }

    public func readBinary(offset: Int, length: Int, unit: Int) async throws -> Data {
        var out = Data()
        var read = 0
        while read < length {
            let want = min(unit, length - read)
            guard let p1p2 = UInt16(exactly: offset + read) else {
                throw MdocProximityError.malformedEngagement(detail: "NFC: NDEF file offset out of range")
            }
            let r = try await channel.transceive(
                Apdu.readBinary(offset: p1p2, length: UInt8(want)))
            guard Apdu.statusWord(r) == 0x9000, r.count >= want + 2 else {
                throw MdocProximityError.malformedEngagement(detail: "NFC: ReadBinary failed")
            }
            out.append(r.prefix(r.count - 2))
            read += want
        }
        return out
    }

    public func updateBinary(offset: Int, data: Data, unit: Int) async throws {
        var written = 0
        while written < data.count {
            let end = min(written + unit, data.count)
            guard let p1p2 = UInt16(exactly: offset + written) else {
                throw MdocProximityError.connectionFailed(detail: "NFC: NDEF file offset out of range")
            }
            let r = try await channel.transceive(Apdu.updateBinary(
                offset: p1p2, data: data.subdata(in: written..<end)))
            guard Apdu.statusWord(r) == 0x9000 else {
                throw MdocProximityError.connectionFailed(
                    detail: "NFC: TNEP write rejected (SW \(String(Apdu.statusWord(r), radix: 16)))")
            }
            written = end
        }
    }
}
