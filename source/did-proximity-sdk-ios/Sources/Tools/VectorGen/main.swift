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
import CryptoKit
@_spi(MdocInternal) import MdocProximityCore

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func fromHex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let n = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<n], radix: 16)!); i = n }
    return d
}
// Run from the repository root (`swift run VectorGen`)
let out = URL(fileURLWithPath: "source/did-proximity-sdk-ios/test-vectors")
func write(_ id: String, _ obj: [String: Any]) {
    let url = out.appendingPathComponent(id + ".json")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: obj,
                                           options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try! data.write(to: url)
    print("  \(id).json")
}

let deHex = "d8185858a20063312e30018201d818584ba401022001215820101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f225820303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"
let erHex = "d818584ba401022001215820505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f225820707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f"
let transcript = SessionTranscriptBuilder.qr(
    deviceEngagementBytes: OpaqueCBOR(preserving: fromHex(deHex)),
    eReaderKeyBytes: OpaqueCBOR(preserving: fromHex(erHex)))
let docType = "org.iso.18013.5.1.mDL"
let dns = OpaqueCBOR(preserving: fromHex("d81841a0"))
let dab = try! DeviceAuthenticationBuilder.taggedBytes(
    transcript: transcript, docType: docType, deviceNameSpacesBytes: dns)

print("Generated:")

let devKey = try! P256.Signing.PrivateKey(rawRepresentation: fromHex(
    "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"))
let sigStructure = SigStructure.bytes(protected: CoseConstants.protectedES256, payload: dab)
let signature = try! devKey.signature(for: sigStructure)
write("cose/sign1-self", [
    "schema": "mdoc-test-vector/1", "id": "cose/sign1-self", "kind": "verify", "source": "self",
    "note": "ECDSA signatures are randomized, so the signature value cannot be an expected value — the Sig_structure bytes are pinned and the verdict is whether verification passes. Same input as cose/mac0-self",
    "input": ["sessionTranscript": hex(try! SessionTranscriptBuilder.transcriptArray(transcript)),
              "docType": docType, "deviceNameSpacesBytes": hex(dns.raw),
              "protected": hex(CoseConstants.protectedES256),
              "deviceKeyPublicSEC1": hex(devKey.publicKey.x963Representation),
              "signature": hex(signature.rawRepresentation)],
    "expect": ["sigStructure": hex(sigStructure), "sigStructureLength": sigStructure.count,
               "deviceAuthenticationBytes": hex(dab), "valid": true]])

let zab = fromHex("926ae1957d389db74c4822d7df7c992c4f248579806586b7306c250d843ebd5c")
let readerCipher = SessionCipher(role: .mdocReader, sharedSecret: zab, transcript: transcript)
let plaintext = Data("DeviceRequest".utf8)
let ct1 = try! readerCipher.encrypt(plaintext)
let ct2 = try! readerCipher.encrypt(plaintext)
write("session/cipher-aesgcm", [
    "schema": "mdoc-test-vector/1", "id": "session/cipher-aesgcm", "kind": "derive", "source": "self",
    "note": "The data element is ciphertext ‖ the full 16-byte tag. AAD is zero-length. The same plaintext yields a different result as the counter increases",
    "input": ["zab": hex(zab), "role": "mdocReader",
              "sessionTranscriptBytes": hex(transcript.raw), "plaintext": hex(plaintext)],
    "expect": ["counter1": hex(ct1), "counter2": hex(ct2),
               "iv1": hex(SessionCipher.iv(role: .mdocReader, counter: 1)),
               "iv2": hex(SessionCipher.iv(role: .mdocReader, counter: 2))]])

print("Done")

let zeroDocs = CborValue.map([
    CborPair(.text("version"), .text("1.0")),
    CborPair(.text("documentErrors"), .array([
        .map([CborPair(.text(docType), .unsigned(0))])
    ])),
    CborPair(.text("status"), .unsigned(0))
])
let zeroDocsBytes = CborEncoder.encode(zeroDocs)
write("response/zero-documents", [
    "schema": "mdoc-test-vector/1", "id": "response/zero-documents", "kind": "decode", "source": "self",
    "note": "Zero documents are expressed only by omitting the documents key — an empty array violates the CDDL. status is 0 and the session completes normally",
    "input": ["bytes": hex(zeroDocsBytes)],
    "expect": ["documentCount": 0, "status": 0, "version": "1.0",
               "documentErrors": [docType: 0], "error": NSNull()]])

let issuerKey = try! P256.Signing.PrivateKey(rawRepresentation: fromHex(
    "3f49a5e7c6b2d1084f3a9c5e7b1d6f2048c3e5a7091b2d4f6183a5c7e9012b4d"))

func issuerSignedItem(_ digestID: UInt64, _ id: String, _ value: CborValue) -> Data {
    let inner = CborEncoder.encode(.map([
        CborPair(.text("digestID"), .unsigned(digestID)),
        CborPair(.text("random"), .bytes(Data(repeating: UInt8(digestID), count: 16))),
        CborPair(.text("elementIdentifier"), .text(id)),
        CborPair(.text("elementValue"), value)
    ]))
    return CborEncoder.tag24(inner)
}

func coseKey(_ pub: P256.Signing.PublicKey) -> CborValue {
    let r = pub.x963Representation
    return .map([CborPair(.unsigned(1), .unsigned(2)), CborPair(.negative(0), .unsigned(1)),
                 CborPair(.negative(1), .bytes(r.subdata(in: 1..<33))),
                 CborPair(.negative(2), .bytes(r.subdata(in: 33..<65)))])
}

func makeDocument(docType: String, useMac: Bool, deviceKey: P256.Signing.PrivateKey,
                  eMacKey: Data) -> (CborValue, String) {
    let ns = "org.iso.18013.5.1"
    let itemBytes = issuerSignedItem(1, "family_name", .text("Doe"))
    let digest = Data(SHA256.hash(data: itemBytes))

    let mso = CborEncoder.encode(.map([
        CborPair(.text("version"), .text("1.0")),
        CborPair(.text("digestAlgorithm"), .text("SHA-256")),
        CborPair(.text("valueDigests"), .map([CborPair(.text(ns), .map([CborPair(.unsigned(1), .bytes(digest))]))])),
        CborPair(.text("deviceKeyInfo"), .map([CborPair(.text("deviceKey"), coseKey(deviceKey.publicKey))])),
        CborPair(.text("docType"), .text(docType)),
        CborPair(.text("validityInfo"), .map([
            CborPair(.text("signed"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
            CborPair(.text("validFrom"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
            CborPair(.text("validUntil"), .tagged(0, .text("2027-01-01T00:00:00Z")))]))
    ]))
    let msoBytes = CborEncoder.tag24(mso)
    let issuerSig = try! issuerKey.signature(for: SigStructure.bytes(
        protected: CoseConstants.protectedES256, payload: msoBytes))
    let issuerAuth = CborValue.array([
        .bytes(CoseConstants.protectedES256),
        .map([CborPair(.unsigned(4), .bytes(Data("did:omn:issuer?versionId=1#assert".utf8)))]),
        .bytes(msoBytes),
        .bytes(issuerSig.rawRepresentation)])

    let dabDoc = try! DeviceAuthenticationBuilder.taggedBytes(
        transcript: transcript, docType: docType, deviceNameSpacesBytes: dns)
    let deviceAuth: CborValue
    if useMac {
        let tag = Data(HMAC<SHA256>.authenticationCode(
            for: MacStructure.bytes(protected: CoseConstants.protectedHMAC256, payload: dabDoc),
            using: SymmetricKey(data: eMacKey)))
        deviceAuth = .map([CborPair(.text("deviceMac"), .array([
            .bytes(CoseConstants.protectedHMAC256), .map([]), .null, .bytes(tag)]))])
    } else {
        let s = try! deviceKey.signature(for: SigStructure.bytes(
            protected: CoseConstants.protectedES256, payload: dabDoc))
        deviceAuth = .map([CborPair(.text("deviceSignature"), .array([
            .bytes(CoseConstants.protectedES256), .map([]), .null, .bytes(s.rawRepresentation)]))])
    }

    let doc = CborValue.map([
        CborPair(.text("docType"), .text(docType)),
        CborPair(.text("issuerSigned"), .map([
            CborPair(.text("nameSpaces"), .map([CborPair(.text(ns), .array([try! CborDecoder.decode(itemBytes)]))])),
            CborPair(.text("issuerAuth"), issuerAuth)])),
        CborPair(.text("deviceSigned"), .map([
            CborPair(.text("nameSpaces"), try! CborDecoder.decode(dns.raw)),
            CborPair(.text("deviceAuth"), deviceAuth)]))
    ])
    return (doc, useMac ? "mac" : "ecdsa")
}

let eMacKey = KeyDerivation.eMacKey(
    zabPrime: fromHex("a95137b042ccb44b378c7c0c9182164fc1b54afc9c6e154ca77958ddd681bd34"),
    transcript: transcript)
let keyA = try! P256.Signing.PrivateKey(rawRepresentation: fromHex(
    "1111111111111111111111111111111111111111111111111111111111111111"))
let keyB = try! P256.Signing.PrivateKey(rawRepresentation: fromHex(
    "2222222222222222222222222222222222222222222222222222222222222222"))
let (docA, mA) = makeDocument(docType: docType, useMac: true, deviceKey: keyA, eMacKey: eMacKey)
let (docB, mB) = makeDocument(docType: "org.iso.23220.photoID.1", useMac: false, deviceKey: keyB, eMacKey: eMacKey)

let mixed = CborEncoder.encode(.map([
    CborPair(.text("version"), .text("1.0")),
    CborPair(.text("documents"), .array([docA, docB])),
    CborPair(.text("status"), .unsigned(0))]))
write("response/mixed-deviceauth", [
    "schema": "mdoc-test-vector/1", "id": "response/mixed-deviceauth", "kind": "verify", "source": "self",
    "note": "The mdoc-side fallback is per runtime and per document, so one response mixes both methods. Testing only with single-method responses would pass a reader that locks the method per response",
    "input": ["bytes": hex(mixed), "sessionTranscriptBytes": hex(transcript.raw),
              "deviceNameSpacesBytes": hex(dns.raw), "eMacKey": hex(eMacKey),
              "deviceKeyPublicSEC1": [docType: hex(keyA.publicKey.x963Representation),
                                      "org.iso.23220.photoID.1": hex(keyB.publicKey.x963Representation)],
              "issuerKeyPublicSEC1": hex(issuerKey.publicKey.x963Representation)],
    "expect": ["documentCount": 2,
               "mdocAuth": [docType: ["method": mA, "valid": true],
                            "org.iso.23220.photoID.1": ["method": mB, "valid": true]]]])

let nsID = "org.iso.18013.5.1"
let issued: [(String, CborValue)] = [
    ("family_name", .text("Doe")), ("given_name", .text("Jane")),
    ("birth_date", .text("1990-01-01")), ("age_over_18", .bool(true)),
    ("portrait", .bytes(Data(repeating: 0, count: 64)))
]
let allItems = issued.enumerated().map { (i, e) in issuerSignedItem(UInt64(i + 1), e.0, e.1) }
let discloseIDs = ["family_name", "age_over_18"]
let selected = zip(issued, allItems).filter { discloseIDs.contains($0.0.0) }.map { $0.1 }
let nameSpaces = CborEncoder.encode(.map([
    CborPair(.text(nsID), .array(selected.map { try! CborDecoder.decode($0) }))]))
write("response/issuer-signed-namespaces", [
    "schema": "mdoc-test-vector/1", "id": "response/issuer-signed-namespaces",
    "kind": "encode", "source": "self",
    "note": "Selective disclosure — only the chosen IssuerSignedItemBytes from the issued data are copied as-is. Array elements are the #6.24 tagged values as they are, not re-wrapped in bstr. Re-encoding breaks the MSO digest",
    "input": ["nameSpace": nsID,
              "issuedItems": zip(issued, allItems).map { ["elementIdentifier": $0.0.0,
                                                          "issuerSignedItemBytes": hex($0.1)] },
              "disclose": discloseIDs],
    "expect": ["nameSpaces": hex(nameSpaces), "disclosedCount": selected.count,
               "digestsOfDisclosed": selected.map { hex(Data(SHA256.hash(data: $0))) }]])
