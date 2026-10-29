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

@_spi(MdocInternal) public struct NfcCarrierConfiguration: Equatable {
    public let maxCommandDataLength: UInt64
    public let maxResponseDataLength: UInt64

    public init(maxCommandDataLength: UInt64, maxResponseDataLength: UInt64) {
        self.maxCommandDataLength = maxCommandDataLength
        self.maxResponseDataLength = maxResponseDataLength
    }

    public var encoded: Data {
        var out = Data([0x01])
        for (type, value) in [(UInt8(0x01), maxCommandDataLength), (UInt8(0x02), maxResponseDataLength)] {
            let bytes = Self.unsigned(value)
            out.append(UInt8(1 + bytes.count)); out.append(type); out.append(bytes)
        }
        return out
    }

    public init?(_ d: Data) {
        var i = d.startIndex
        guard i < d.endIndex, d[i] == 0x01 else { return nil }
        i += 1
        var command: UInt64?, response: UInt64?
        while i < d.endIndex {
            let len = Int(d[i]); i += 1
            guard len >= 1, i + len <= d.endIndex else { return nil }
            let type = d[i]
            let value = d.subdata(in: (i + 1)..<(i + len)).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if type == 0x01 { command = value } else if type == 0x02 { response = value }
            i += len
        }
        guard let command, let response else { return nil }
        self.init(maxCommandDataLength: command, maxResponseDataLength: response)
    }

    private static func unsigned(_ v: UInt64) -> Data {
        var out = Data(); var x = v
        repeat { out.insert(UInt8(x & 0xff), at: 0); x >>= 8 } while x > 0
        return out
    }
}

@_spi(MdocInternal) public enum HandoverSelect {

    public static let nfcCarrierType = Data("iso.org:18013:nfc".utf8)
    public static let bleOobType = Data("application/vnd.bluetooth.le.oob".utf8)
    /// Connection Handover 1.5 (8.2.2.1)
    public static let version: UInt8 = 0x15

    public struct Parsed: Equatable {
        public var carriers: [TransmissionTechnology] = []
        public var nfc: NfcCarrierConfiguration?
        public var bleServiceUUID: Data?
        public init() {}
    }

    public static func build(deviceEngagement: Data, nfc: NfcCarrierConfiguration) -> Data {
        build(deviceEngagement: deviceEngagement, carrier: .nfc(nfc))
    }

    public static func build(deviceEngagement: Data, carrier: Carrier) -> Data {
        let ac = NdefRecord(typeNameFormat: 0x01, type: Data("ac".utf8), id: Data(),
                            payload: alternativeCarrier(carrierRef: carrier.reference, auxiliaryRefs: ["mdoc"]))
        let hs = NdefRecord(typeNameFormat: 0x01, type: Data("Hs".utf8), id: Data(),
                            payload: Data([version]) + Ndef.encode([ac]))
        let engagement = NdefRecord(typeNameFormat: 0x04, type: Ndef.deviceEngagementType,
                                    id: Data("mdoc".utf8), payload: deviceEngagement)
        return Ndef.encode([hs, carrier.record, engagement])
    }

    public enum Carrier: Equatable {
        case nfc(NfcCarrierConfiguration)
        /// The NFC carrier the reader puts in a Handover Request — version only. The two maximum-length fields are "mandatory for
        /// the mdoc and shall not be used by the mdoc reader" (8.2.2.2 Table 6).
        case nfcReader
        case ble(role: UInt8, serviceUUID: Data?)

        var reference: String {
            switch self {
            case .nfc, .nfcReader: return "nfc"
            case .ble: return "0"
            }
        }

        var record: NdefRecord {
            switch self {
            case .nfc(let cfg):
                return NdefRecord(typeNameFormat: 0x04, type: nfcCarrierType, id: Data("nfc".utf8),
                                  payload: cfg.encoded)
            case .nfcReader:
                return NdefRecord(typeNameFormat: 0x04, type: nfcCarrierType, id: Data("nfc".utf8),
                                  payload: Data([0x01]))
            case .ble(let role, let uuid):
                return NdefRecord(typeNameFormat: 0x02, type: bleOobType, id: Data(reference.utf8),
                                  payload: bleOob(role: role, serviceUUID: uuid))
            }
        }
    }

    public static func bleOob(role: UInt8, serviceUUID: Data?) -> Data {
        var out = Data([0x02, 0x1C, role])
        if let uuid = serviceUUID, uuid.count == 16 {
            out.append(0x11); out.append(0x07); out.append(Data(uuid.reversed()))
        }
        return out
    }

    static func alternativeCarrier(carrierRef: String, auxiliaryRefs: [String]) -> Data {
        var out = Data([0x01])
        out.append(UInt8(carrierRef.utf8.count)); out.append(Data(carrierRef.utf8))
        out.append(UInt8(auxiliaryRefs.count))
        for ref in auxiliaryRefs { out.append(UInt8(ref.utf8.count)); out.append(Data(ref.utf8)) }
        return out
    }

    public static func parse(_ records: [NdefRecord]) -> Parsed {
        var out = Parsed()
        guard let hs = records.first(where: { $0.typeNameFormat == 0x01 && $0.typeText == "Hs" }),
              hs.payload.count > 1,
              let acs = try? Ndef.parse(hs.payload.dropFirst()) else { return out }
        for ac in acs where ac.typeNameFormat == 0x01 && ac.typeText == "ac" {
            guard let ref = carrierReference(ac.payload),
                  let carrier = records.first(where: { $0.id == Data(ref.utf8) }) else { continue }
            if carrier.type == nfcCarrierType {
                if let cfg = NfcCarrierConfiguration(carrier.payload) {
                    out.nfc = cfg
                    out.carriers.append(.nfc)
                }
            } else if carrier.type == bleOobType {
                let oob = parseOob(carrier.payload)
                if let uuid = oob.serviceUUID { out.bleServiceUUID = uuid }
                switch oob.role {
                case 0: out.carriers.append(.ble(.peripheralServer))
                case 1: out.carriers.append(.ble(.centralClient))
                case 2, 3: out.carriers.append(contentsOf: [.ble(.centralClient), .ble(.peripheralServer)])
                default: break
                }
            }
        }
        return out
    }

    static func carrierReference(_ payload: Data) -> String? {
        var i = payload.startIndex + 1                       // CPS
        guard i < payload.endIndex else { return nil }
        let len = Int(payload[i]); i += 1
        guard i + len <= payload.endIndex else { return nil }
        return String(data: payload.subdata(in: i..<(i + len)), encoding: .utf8)
    }

    static func parseOob(_ d: Data) -> (role: UInt8?, serviceUUID: Data?) {
        var role: UInt8?, uuid: Data?
        var i = d.startIndex
        while i < d.endIndex {
            let len = Int(d[i]); i += 1
            guard len >= 1, i + len <= d.endIndex else { break }
            let type = d[i]
            let value = d.subdata(in: (i + 1)..<(i + len))
            if type == 0x1C, let r = value.first { role = r }
            if type == 0x07, value.count == 16 { uuid = Data(value.reversed()) }
            i += len
        }
        return (role, uuid)
    }
}

@_spi(MdocInternal) public enum HandoverRequest {

    public struct Offer: Equatable {
        public var carriers: [TransmissionTechnology] = []
        public var nfc: NfcCarrierConfiguration?
        public var readerServiceUUID: Data?
        public init() {}
    }

    public static func build(carriers: [HandoverSelect.Carrier], collisionResolution: UInt16) -> Data {
        let cr = NdefRecord(typeNameFormat: 0x01, type: Data("cr".utf8), id: Data(),
                            payload: Data([UInt8(collisionResolution >> 8), UInt8(collisionResolution & 0xff)]))
        let acs = carriers.map { c in
            NdefRecord(typeNameFormat: 0x01, type: Data("ac".utf8), id: Data(),
                       payload: HandoverSelect.alternativeCarrier(carrierRef: c.reference, auxiliaryRefs: []))
        }
        let hr = NdefRecord(typeNameFormat: 0x01, type: Data("Hr".utf8), id: Data(),
                            payload: Data([HandoverSelect.version]) + Ndef.encode([cr] + acs))
        return Ndef.encode([hr] + carriers.map(\.record))
    }

    public static func parse(_ records: [NdefRecord]) -> Offer {
        var out = Offer()
        guard let hr = records.first(where: { $0.typeNameFormat == 0x01 && $0.typeText == "Hr" }),
              hr.payload.count > 1,
              let inner = try? Ndef.parse(hr.payload.dropFirst()) else { return out }
        for ac in inner where ac.typeNameFormat == 0x01 && ac.typeText == "ac" {
            guard let ref = HandoverSelect.carrierReference(ac.payload),
                  let carrier = records.first(where: { $0.id == Data(ref.utf8) }) else { continue }
            if carrier.type == HandoverSelect.nfcCarrierType {
                // Per the standard a reader record carries only the version — length fields are read if present but not required
                if carrier.payload.first == 0x01 {
                    out.nfc = NfcCarrierConfiguration(carrier.payload)
                    out.carriers.append(.nfc)
                }
            } else if carrier.type == HandoverSelect.bleOobType {
                let oob = HandoverSelect.parseOob(carrier.payload)
                if let uuid = oob.serviceUUID { out.readerServiceUUID = uuid }
                switch oob.role {
                case 0: out.carriers.append(.ble(.centralClient))
                case 1: out.carriers.append(.ble(.peripheralServer))
                case 2: out.carriers.append(contentsOf: [.ble(.centralClient), .ble(.peripheralServer)])
                case 3: out.carriers.append(contentsOf: [.ble(.peripheralServer), .ble(.centralClient)])
                default: break
                }
            }
        }
        return out
    }
}
