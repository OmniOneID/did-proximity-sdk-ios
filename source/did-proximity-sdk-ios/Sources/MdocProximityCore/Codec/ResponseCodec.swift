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

@_spi(MdocInternal) public enum ResponseCodec {

    public static func decode(_ data: Data) throws -> DeviceResponse {
        let node = try CborDecoder.decodeNode(data)
        guard case .map = node.value else {
            throw MdocProximityError.validationFailed(detail: "DeviceResponse: not a map")
        }
        guard let version = node.value(for: "version")?.value.asText else {
            throw MdocProximityError.validationFailed(detail: "DeviceResponse: missing version")
        }
        guard let status = node.value(for: "status")?.value.asUInt else {
            throw MdocProximityError.validationFailed(detail: "DeviceResponse: missing status")
        }

        var documents: [Document] = []
        if let docs = node.value(for: "documents") {
            guard case .array = docs.value else {
                throw MdocProximityError.validationFailed(detail: "DeviceResponse: documents not an array")
            }
            documents = try docs.children.map { try decodeDocument($0, in: data) }
        }

        var documentErrors: [DocType: Int64] = [:]
        if let errs = node.value(for: "documentErrors"), case .array = errs.value {
            for entry in errs.children {
                for (k, v) in entry.pairs {
                    if let dt = k.value.asText { documentErrors[dt] = try signedInt(v.value) }
                }
            }
        }
        return DeviceResponse(version: version, documents: documents,
                              documentErrors: documentErrors, status: status)
    }

    private static func decodeDocument(_ n: CborNode, in data: Data) throws -> Document {
        let docType = try n.require("docType", "Document").value.asText ?? ""
        let issuer = try decodeIssuerSigned(try n.require("issuerSigned", "Document"), in: data)
        let device = try decodeDeviceSigned(try n.require("deviceSigned", "Document"), in: data)

        var errors: [NameSpace: [DataElementIdentifier: Int64]] = [:]
        if let e = n.value(for: "errors") {
            for (ns, elems) in e.pairs {
                guard let nsName = ns.value.asText else { continue }
                var m: [DataElementIdentifier: Int64] = [:]
                for (id, code) in elems.pairs {
                    if let name = id.value.asText { m[name] = try signedInt(code.value) }
                }
                errors[nsName] = m
            }
        }
        return Document(docType: docType, issuerSigned: issuer, deviceSigned: device, errors: errors)
    }

    private static func decodeIssuerSigned(_ n: CborNode, in data: Data) throws -> IssuerSigned {
        var spaces: [NameSpace: [IssuerSignedItemEntry]] = [:]
        if let ns = n.value(for: "nameSpaces") {
            for (name, list) in ns.pairs {
                guard let nsName = name.value.asText, case .array = list.value else { continue }
                let items: [IssuerSignedItemEntry] = list.children.compactMap { itemNode in
                    // IssuerSignedItemBytes = #6.24(bstr .cbor IssuerSignedItem)
                    guard case .tagged(24, .bytes(let inner)) = itemNode.value,
                          let item = try? CborDecoder.decode(inner),
                          let digestID = item.member("digestID")?.asUInt,
                          let id = item.member("elementIdentifier")?.asText,
                          let value = item.member("elementValue") else { return nil }
                    return IssuerSignedItemEntry(raw: OpaqueCBOR(itemNode, in: data),
                                                 digestID: digestID,
                                                 elementIdentifier: id,
                                                 elementValue: value)
                }
                var seen = Set<DataElementIdentifier>()
                for item in items where !seen.insert(item.elementIdentifier).inserted {
                    throw MdocProximityError.validationFailed(
                        detail: "IssuerSignedItem: duplicate elementIdentifier '\(item.elementIdentifier)' in \(nsName)")
                }
                spaces[nsName] = items
            }
        }
        let auth = try decodeCoseSign1(try n.require("issuerAuth", "IssuerSigned"))
        return IssuerSigned(nameSpaces: spaces, issuerAuth: auth)
    }

    private static func decodeDeviceSigned(_ n: CborNode, in data: Data) throws -> DeviceSigned {
        let ns = try n.require("nameSpaces", "DeviceSigned")
        let authNode = try n.require("deviceAuth", "DeviceSigned")
        let auth: DeviceAuth
        if let sig = authNode.value(for: "deviceSignature") {
            auth = .deviceSignature(try decodeCoseSign1(sig))
        } else if let mac = authNode.value(for: "deviceMac") {
            auth = .deviceMac(try decodeCoseMac0(mac))
        } else {
            throw MdocProximityError.validationFailed(detail: "DeviceAuth: neither signature nor mac")
        }
        return DeviceSigned(nameSpacesBytes: OpaqueCBOR(ns, in: data), deviceAuth: auth)
    }

    /// `COSE_Sign1 = [ protected: bstr, unprotected: map, payload: bstr/null, signature: bstr ]`
    static func decodeCoseSign1(_ n: CborNode) throws -> CoseSign1 {
        guard case .array(let f) = n.value, f.count == 4,
              let prot = f[0].asBytes, let sig = f[3].asBytes else {
            throw MdocProximityError.validationFailed(detail: "COSE_Sign1: bad structure")
        }
        return CoseSign1(protectedBytes: prot, unprotected: f[1], payload: f[2].asBytes, signature: sig)
    }

    static func decodeCoseMac0(_ n: CborNode) throws -> CoseMac0 {
        guard case .array(let f) = n.value, f.count == 4,
              let prot = f[0].asBytes, let tag = f[3].asBytes else {
            throw MdocProximityError.validationFailed(detail: "COSE_Mac0: bad structure")
        }
        return CoseMac0(protectedBytes: prot, unprotected: f[1], payload: f[2].asBytes, tag: tag)
    }

    private static func signedInt(_ v: CborValue) throws -> Int64 {
        switch v {
        case .unsigned(let n):
            guard let i = Int64(exactly: n) else { throw outOfRange }
            return i
        case .negative(let n):
            guard let i = Int64(exactly: n) else { throw outOfRange }
            return -1 - i
        default: return 0
        }
    }

    private static var outOfRange: MdocProximityError {
        .validationFailed(detail: "DeviceResponse: ErrorCode out of Int64 range")
    }
}
