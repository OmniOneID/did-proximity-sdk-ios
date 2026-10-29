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

@_spi(MdocInternal) public struct NdefRecord: Equatable {
    public let typeNameFormat: UInt8
    public let type: Data
    public let id: Data
    public let payload: Data

    public var typeText: String { String(data: type, encoding: .utf8) ?? "" }
}

@_spi(MdocInternal) public enum Ndef {

    public static let deviceEngagementType = Data("iso.org:18013:deviceengagement".utf8)
    public static let handoverServiceName = "urn:nfc:sn:handover"

    public static func parse(_ message: Data) throws -> [NdefRecord] {
        var records: [NdefRecord] = []
        var i = message.startIndex
        while i < message.endIndex {
            guard i + 2 <= message.endIndex else {
                throw MdocProximityError.malformedEngagement(detail: "NDEF: truncated header")
            }
            let header = message[i]
            let shortRecord = header & 0x10 != 0
            let hasID = header & 0x08 != 0
            guard header & 0x20 == 0 else {
                throw MdocProximityError.malformedEngagement(detail: "NDEF: chunked record")
            }
            i += 1
            let typeLength = Int(message[i]); i += 1

            var payloadLength = 0
            if shortRecord {
                guard i < message.endIndex else {
                    throw MdocProximityError.malformedEngagement(detail: "NDEF: truncated length")
                }
                payloadLength = Int(message[i]); i += 1
            } else {
                guard i + 4 <= message.endIndex else {
                    throw MdocProximityError.malformedEngagement(detail: "NDEF: truncated length")
                }
                for _ in 0..<4 { payloadLength = payloadLength << 8 | Int(message[i]); i += 1 }
            }
            var idLength = 0
            if hasID {
                guard i < message.endIndex else {
                    throw MdocProximityError.malformedEngagement(detail: "NDEF: truncated id length")
                }
                idLength = Int(message[i]); i += 1
            }
            guard i + typeLength + idLength + payloadLength <= message.endIndex else {
                throw MdocProximityError.malformedEngagement(detail: "NDEF: truncated record")
            }
            let type = message.subdata(in: i..<(i + typeLength)); i += typeLength
            let id = message.subdata(in: i..<(i + idLength)); i += idLength
            let payload = message.subdata(in: i..<(i + payloadLength)); i += payloadLength
            records.append(NdefRecord(typeNameFormat: header & 0x07,
                                      type: type, id: id, payload: payload))
            if header & 0x40 != 0 { break }
        }
        return records
    }

    public static func encode(_ records: [NdefRecord]) -> Data {
        var out = Data()
        for (index, r) in records.enumerated() {
            var header = r.typeNameFormat
            if index == 0 { header |= 0x80 }                       // MB
            if index == records.count - 1 { header |= 0x40 }       // ME
            if r.payload.count < 256 { header |= 0x10 }            // SR
            if !r.id.isEmpty { header |= 0x08 }                    // IL
            out.append(header)
            out.append(UInt8(r.type.count))
            if r.payload.count < 256 {
                out.append(UInt8(r.payload.count))
            } else {
                let n = UInt32(r.payload.count)
                out.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff),
                                        UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
            }
            if !r.id.isEmpty { out.append(UInt8(r.id.count)) }
            out.append(r.type); out.append(r.id); out.append(r.payload)
        }
        return out
    }

    public static func isNegotiated(_ records: [NdefRecord]) -> Bool {
        Tnep.serviceParameter(in: records) != nil
    }

    public static func deviceEngagement(in records: [NdefRecord]) -> Data? {
        records.first { $0.typeNameFormat == 0x04 && $0.type == deviceEngagementType }?.payload
    }
}

@_spi(MdocInternal) public enum Tnep {

    public static let version: UInt8 = 0x10
    /// Status `Te` — 0x00 success, 0x80 protocol error
    public static let statusSuccess: UInt8 = 0x00
    public static let statusProtocolError: UInt8 = 0x80

    public struct ServiceParameter: Equatable {
        public var serviceName: String
        public var communicationMode: UInt8       // 0x00 = single response
        public var waitTimeCode: UInt8             // WT, 0...63
        public var maxWaitExtensions: UInt8        // N_wait, 0...15
        public var maxMessageSize: UInt16

        public init(serviceName: String, communicationMode: UInt8 = 0x00,
                    waitTimeCode: UInt8, maxWaitExtensions: UInt8, maxMessageSize: UInt16) {
            self.serviceName = serviceName
            self.communicationMode = communicationMode
            self.waitTimeCode = waitTimeCode
            self.maxWaitExtensions = maxWaitExtensions
            self.maxMessageSize = maxMessageSize
        }

        /// t_wait = 2^(WT/4 − 1) ms (TNEP 4.1.6)
        public var minimumWaitTime: TimeInterval {
            pow(2.0, Double(waitTimeCode) / 4.0 - 1.0) / 1000.0
        }

        public var record: NdefRecord {
            var p = Data([Tnep.version])
            let name = Data(serviceName.utf8)
            p.append(UInt8(name.count)); p.append(name)
            p.append(communicationMode)
            p.append(waitTimeCode)
            p.append(maxWaitExtensions)
            p.append(UInt8(maxMessageSize >> 8)); p.append(UInt8(maxMessageSize & 0xff))
            return NdefRecord(typeNameFormat: 0x01, type: Data("Tp".utf8), id: Data(), payload: p)
        }

        public init?(payload d: Data) {
            var i = d.startIndex
            guard i + 2 <= d.endIndex, d[i] == Tnep.version else { return nil }
            i += 1
            let n = Int(d[i]); i += 1
            guard i + n + 5 <= d.endIndex,
                  let name = String(data: d.subdata(in: i..<(i + n)), encoding: .utf8) else { return nil }
            i += n
            serviceName = name
            communicationMode = d[i]; i += 1
            waitTimeCode = d[i]; i += 1
            maxWaitExtensions = d[i]; i += 1
            guard waitTimeCode <= 63, maxWaitExtensions <= 15 else { return nil }
            maxMessageSize = UInt16(d[i]) << 8 | UInt16(d[i + 1])
        }
    }

    public static func serviceParameter(in records: [NdefRecord]) -> ServiceParameter? {
        for r in records where r.typeNameFormat == 0x01 && r.typeText == "Tp" {
            if let sp = ServiceParameter(payload: r.payload), sp.serviceName == Ndef.handoverServiceName {
                return sp
            }
        }
        return nil
    }

    public static func serviceSelect(_ name: String) -> NdefRecord {
        let n = Data(name.utf8)
        return NdefRecord(typeNameFormat: 0x01, type: Data("Ts".utf8), id: Data(),
                          payload: Data([UInt8(n.count)]) + n)
    }

    public static func selectedService(in records: [NdefRecord]) -> String? {
        guard let r = records.first(where: { $0.typeNameFormat == 0x01 && $0.typeText == "Ts" }),
              let n = r.payload.first, r.payload.count >= 1 + Int(n) else { return nil }
        return String(data: r.payload.subdata(in: (r.payload.startIndex + 1)..<(r.payload.startIndex + 1 + Int(n))),
                      encoding: .utf8)
    }

    public static func status(_ code: UInt8) -> NdefRecord {
        NdefRecord(typeNameFormat: 0x01, type: Data("Te".utf8), id: Data(), payload: Data([code]))
    }

    public static func statusCode(in records: [NdefRecord]) -> UInt8? {
        records.first { $0.typeNameFormat == 0x01 && $0.typeText == "Te" }?.payload.first
    }
}
