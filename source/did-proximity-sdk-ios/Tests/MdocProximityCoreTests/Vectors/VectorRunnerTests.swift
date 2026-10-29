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

import XCTest
import CryptoKit
@_spi(MdocInternal) @testable import MdocProximityCore
// transport/* 벡터는 BLE 프레이밍을 쓴다 — 그 코드는 MdocBLE 에 있다
@_spi(MdocInternal) @testable import MdocBLE
// engagement/nfc-handover-records 는 NDEF·TNEP 레코드를 쓴다 — 그 코드는 MdocNFC 에 있다
@_spi(MdocInternal) @testable import MdocNFC

private extension TransmissionTechnology {
    var vectorName: String {
        switch self {
        case .ble(.centralClient): return "ble.centralClient"
        case .ble(.peripheralServer): return "ble.peripheralServer"
        case .nfc: return "nfc"
        case .wifiAware: return "wifiAware"
        }
    }
}

/// **파일 트리를 순회하는 데이터 주도 테스트 하나**.
/// 케이스마다 테스트 함수를 손으로 쓰지 않는다. 실패 보고는 `id` · 기대 · 실제 세 줄이다.
final class VectorRunnerTests: XCTestCase {

    // Vectors/ → MdocProximityCoreTests/ → Tests/ → did-proximity-sdk-ios/test-vectors — 폴더를
    // 옮기면 이 깊이도 같이 바뀐다
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("test-vectors")

    struct Vector {
        let id: String, kind: String, source: String
        let input: [String: Any], expect: [String: Any]
        func str(_ sec: [String: Any], _ k: String) -> String { sec[k] as! String }
    }

    func loadAll() throws -> [Vector] {
        let e = FileManager.default.enumerator(at: Self.root, includingPropertiesForKeys: nil)!
        var out: [Vector] = []
        for case let url as URL in e where url.pathExtension == "json" {
            let o = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            // 모르는 스키마는 조용히 건너뛰지 않는다 — 그 자리에서 실패한다
            XCTAssertEqual(o["schema"] as? String, "mdoc-test-vector/1", "\(url.lastPathComponent): schema")
            out.append(Vector(id: o["id"] as! String, kind: o["kind"] as! String,
                              source: o["source"] as! String,
                              input: o["input"] as! [String: Any],
                              expect: o["expect"] as! [String: Any]))
        }
        // 경로 깊이가 틀리면 enumerator 는 빈 트리를 조용히 돌려준다 — 0건은 통과가 아니라 실패다
        XCTAssertFalse(out.isEmpty, "test-vectors 를 찾지 못했다: \(Self.root.path)")
        return out
    }

    func testAllVectors() throws {
        let vectors = try loadAll()
        // 트리를 못 찾아 0건을 순회하고 "전부 통과"로 끝나는 것이 이 형태의 유일한 조용한 실패다
        XCTAssertEqual(vectors.count, 22, "발견한 벡터 수")

        var ran = 0
        for v in vectors {
            XCTContext.runActivity(named: v.id) { _ in
                do { try run(v); ran += 1 }
                catch { XCTFail("\(v.id): \(error)") }
            }
        }
        XCTAssertEqual(ran, vectors.count, "모든 벡터에 호출 지점이 있어야 한다")
    }

    private func eq(_ actual: String, _ expected: Any?, _ id: String, _ field: String) {
        XCTAssertEqual(actual, expected as? String ?? "<none>",
                       "\n  id:   \(id)\n  기대: \(expected as? String ?? "<none>")\n  실제: \(actual)")
    }

    // MARK: - id → 호출 지점
    private func run(_ v: Vector) throws {
        switch v.id {

        case "derivation/edevicekey-derivations":
            let ikm = Data(hex: v.str(v.input, "eDeviceKeyBytes"))!
            eq(KeyDerivation.bleIdent(eDeviceKeyBytes: ikm).hex, v.expect["bleIdent"], v.id, "bleIdent")
            // Wi-Fi Aware 파생 둘 — iOS 에 전송은 없지만 Android 와 같은 값을 내는지 여기서 고정한다
            let svc = KeyDerivation.nanServiceName(eDeviceKeyBytes: ikm)
            eq(svc.hex, v.expect["nanServiceName"], v.id, "nanServiceName")
            XCTAssertEqual(svc.hex.uppercased(), v.expect["nanServiceNameBase16"] as? String, "\(v.id): base16 표기")
            let pp = KeyDerivation.nanPassphrase(eDeviceKeyBytes: ikm)
            eq(pp.hex, v.expect["nanPassphrase"], v.id, "nanPassphrase")
            let b64 = pp.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(b64, v.expect["nanPassphraseBase64url"] as? String, "\(v.id): base64url 표기")

        case "session/transcript-qr":
            let st = SessionTranscriptBuilder.qr(
                deviceEngagementBytes: OpaqueCBOR(preserving: Data(hex: v.str(v.input, "deviceEngagementBytes"))!),
                eReaderKeyBytes: OpaqueCBOR(preserving: Data(hex: v.str(v.input, "eReaderKeyBytes"))!))
            eq(st.raw.hex, v.expect["sessionTranscriptBytes"], v.id, "bytes")
            eq(try SessionTranscriptBuilder.transcriptArray(st).hex, v.expect["sessionTranscript"], v.id, "array")
            eq(KeyDerivation.salt(st).hex, v.expect["sha256OfSessionTranscriptBytes"], v.id, "salt")

        case "session/transcript-nfc":
            // NFCHandover = [Hs, Hr | null] — static 과 negotiated 가 둘째 원소로만 갈린다 (9.1.5.1)
            for name in ["static", "negotiated"] {
                let inp = v.input[name] as! [String: Any]
                let st = SessionTranscriptBuilder.nfc(
                    deviceEngagementBytes: OpaqueCBOR(preserving: Data(hex: v.str(v.input, "deviceEngagementBytes"))!),
                    eReaderKeyBytes: OpaqueCBOR(preserving: Data(hex: v.str(v.input, "eReaderKeyBytes"))!),
                    handoverSelect: Data(hex: inp["handoverSelect"] as! String)!,
                    handoverRequest: (inp["handoverRequest"] as? String).flatMap { Data(hex: $0) })
                let want = v.expect[name] as! [String: Any]
                eq(st.raw.hex, want["sessionTranscriptBytes"], v.id, "\(name).bytes")
                eq(try SessionTranscriptBuilder.transcriptArray(st).hex, want["sessionTranscript"], v.id, "\(name).array")
                eq(KeyDerivation.salt(st).hex, want["sha256OfSessionTranscriptBytes"], v.id, "\(name).salt")
            }

        case "engagement/nfc-handover-records":
            // TNEP 레코드·Handover Request/Select 바이트 — 리더가 쓴 Hr 은 트랜스크립트에 그대로 들어가므로
            // 양 플랫폼 리더가 같은 바이트를 내야 한다
            let de = Data(hex: v.str(v.input, "deviceEngagement"))!
            let nfcIn = v.input["nfc"] as! [String: Int]
            let cfg = NfcCarrierConfiguration(maxCommandDataLength: UInt64(nfcIn["maxCommandDataLength"]!),
                                              maxResponseDataLength: UInt64(nfcIn["maxResponseDataLength"]!))
            let spIn = v.input["serviceParameter"] as! [String: Int]
            let sp = Tnep.ServiceParameter(serviceName: Ndef.handoverServiceName,
                                           waitTimeCode: UInt8(spIn["waitTimeCode"]!),
                                           maxWaitExtensions: UInt8(spIn["maxWaitExtensions"]!),
                                           maxMessageSize: UInt16(spIn["maxMessageSize"]!))
            eq(Ndef.encode([sp.record]).hex, v.expect["serviceParameter"], v.id, "Tp")
            eq(Ndef.encode([Tnep.serviceSelect(Ndef.handoverServiceName)]).hex, v.expect["serviceSelect"], v.id, "Ts")
            eq(Ndef.encode([Tnep.status(Tnep.statusSuccess)]).hex, v.expect["statusSuccess"], v.id, "Te")
            let hrIn = v.input["handoverRequest"] as! [String: Any]
            let carriers: [HandoverSelect.Carrier] = (hrIn["carriers"] as! [[String: Any]]).map { c in
                if let ble = c["ble"] as? [String: Any] {
                    return .ble(role: UInt8(ble["role"] as! Int), serviceUUID: Data(hex: ble["serviceUUID"] as! String))
                }
                return .nfcReader
            }
            let hr = HandoverRequest.build(carriers: carriers,
                                           collisionResolution: UInt16(hrIn["collisionResolution"] as! String, radix: 16)!)
            eq(hr.hex, v.expect["handoverRequest"], v.id, "Hr")
            let offer = HandoverRequest.parse(try Ndef.parse(hr))
            let offerWant = v.expect["handoverRequestOffer"] as! [String: Any]
            eq(offer.carriers.map(\.vectorName).joined(separator: ","),
               (offerWant["carriers"] as! [String]).joined(separator: ","), v.id, "Hr.carriers")
            eq(offer.readerServiceUUID?.hex ?? "", offerWant["readerServiceUUID"], v.id, "Hr.uuid")
            eq(HandoverSelect.build(deviceEngagement: de, carrier: .nfc(cfg)).hex, v.expect["handoverSelectNfc"], v.id, "Hs.nfc")
            let bleIn = v.input["handoverSelectBlePeripheral"] as! [String: Any]
            let hsBle = HandoverSelect.build(deviceEngagement: de, carrier: .ble(
                role: UInt8(bleIn["role"] as! Int), serviceUUID: Data(hex: bleIn["serviceUUID"] as! String)))
            eq(hsBle.hex, v.expect["handoverSelectBlePeripheral"], v.id, "Hs.ble")
            let parsed = HandoverSelect.parse(try Ndef.parse(hsBle))
            let parsedWant = v.expect["handoverSelectBlePeripheralParsed"] as! [String: Any]
            eq(parsed.carriers.map(\.vectorName).joined(separator: ","),
               (parsedWant["carriers"] as! [String]).joined(separator: ","), v.id, "Hs.ble.carriers")
            eq(parsed.bleServiceUUID?.hex ?? "", parsedWant["bleServiceUUID"], v.id, "Hs.ble.uuid")
            XCTAssertEqual(Ndef.deviceEngagement(in: try Ndef.parse(hsBle)), de, v.id)

        case "session/transcript-from-engagement-qr":
            // **입력이 맨 DeviceEngagement 다** — QR 에서 디코드한 그대로. 빌더가 아니라
            // 세션이 지나는 경로(`EngagementPayload.sessionTranscript`)가 tag 24 를 붙이는지 본다.
            // `session/transcript-qr` 은 감싼 입력을 받아 빌더 계약만 고정하므로 이 결함을 못 잡았다
            let deRaw = Data(hex: v.str(v.input, "deviceEngagement"))!
            let payload = try EngagementPayload.parse(qrString: "mdoc:" + deRaw.base64urlNoPad)
            let st = payload.sessionTranscript(
                eReaderKeyBytes: OpaqueCBOR(preserving: Data(hex: v.str(v.input, "eReaderKeyBytes"))!))
            eq(st.raw.hex, v.expect["sessionTranscriptBytes"], v.id, "bytes")
            eq(KeyDerivation.salt(st).hex, v.expect["sha256OfSessionTranscriptBytes"], v.id, "salt")

        case "session/keys":
            let st = SessionTranscriptBytes(raw: Data(hex: v.str(v.input, "sessionTranscriptBytes"))!)
            let k = KeyDerivation.sessionKeys(zab: Data(hex: v.str(v.input, "zab"))!, transcript: st)
            eq(k.skReader.hex, v.expect["skReader"], v.id, "skReader")
            eq(k.skDevice.hex, v.expect["skDevice"], v.id, "skDevice")
            eq(KeyDerivation.eMacKey(zabPrime: Data(hex: v.str(v.input, "zabPrimeForEMacKey"))!,
                                     transcript: st).hex, v.expect["eMacKey"], v.id, "eMacKey")

        case "session/emackey-short-transcript":
            // **salt 정의를 가르는 유일한 벡터다.** 트랜스크립트가 64바이트를 넘으면 HMAC 이
            // 키를 SHA-256 으로 먼저 줄여 두 정의가 같은 값을 낸다
            let st = SessionTranscriptBytes(raw: Data(hex: v.str(v.input, "sessionTranscriptBytes"))!)
            XCTAssertLessThanOrEqual(st.raw.count, 64, "\(v.id): 64바이트를 넘으면 이 축이 사라진다")
            eq(KeyDerivation.eMacKey(zabPrime: Data(hex: v.str(v.input, "zabPrime"))!,
                                     transcript: st).hex, v.expect["eMacKey"], v.id, "eMacKey")

        case "session/cipher-iv":
            for (role, key) in [(SessionRole.mdocReader, "mdocReader"), (.mdoc, "mdoc")] {
                let want = v.expect[key] as! [String]
                for (i, c) in [1, 2, 3].enumerated() {
                    eq(SessionCipher.iv(role: role, counter: UInt32(c)).hex, want[i], v.id, "\(key)/\(c)")
                }
            }

        case "session/cipher-aesgcm":
            let st = SessionTranscriptBytes(raw: Data(hex: v.str(v.input, "sessionTranscriptBytes"))!)
            let c = SessionCipher(role: .mdocReader, sharedSecret: Data(hex: v.str(v.input, "zab"))!, transcript: st)
            let pt = Data(hex: v.str(v.input, "plaintext"))!
            eq(try c.encrypt(pt).hex, v.expect["counter1"], v.id, "counter1")
            eq(try c.encrypt(pt).hex, v.expect["counter2"], v.id, "counter2")

        case "cose/device-authentication":
            let st = SessionTranscriptBytes(raw: CborEncoder.tag24(Data(hex: v.str(v.input, "sessionTranscript"))!))
            let dns = OpaqueCBOR(preserving: Data(hex: v.str(v.input, "deviceNameSpacesBytes"))!)
            eq(try DeviceAuthenticationBuilder.bytes(transcript: st, docType: v.str(v.input, "docType"),
                                                     deviceNameSpacesBytes: dns).hex,
               v.expect["deviceAuthentication"], v.id, "da")
            eq(try DeviceAuthenticationBuilder.taggedBytes(transcript: st, docType: v.str(v.input, "docType"),
                                                          deviceNameSpacesBytes: dns).hex,
               v.expect["deviceAuthenticationBytes"], v.id, "dab")

        case "cose/mac0-self":
            let st = SessionTranscriptBytes(raw: CborEncoder.tag24(Data(hex: v.str(v.input, "sessionTranscript"))!))
            let dab = try DeviceAuthenticationBuilder.taggedBytes(
                transcript: st, docType: v.str(v.input, "docType"),
                deviceNameSpacesBytes: OpaqueCBOR(preserving: Data(hex: v.str(v.input, "deviceNameSpacesBytes"))!))
            let ms = MacStructure.bytes(protected: Data(hex: v.str(v.input, "protected"))!, payload: dab)
            eq(ms.hex, v.expect["macStructure"], v.id, "macStructure")
            let tag = Data(HMAC<SHA256>.authenticationCode(
                for: ms, using: SymmetricKey(data: Data(hex: v.str(v.input, "eMacKey"))!)))
            eq(tag.hex, v.expect["tag"], v.id, "tag")

        case "cose/sign1-self":
            let st = SessionTranscriptBytes(raw: CborEncoder.tag24(Data(hex: v.str(v.input, "sessionTranscript"))!))
            let dab = try DeviceAuthenticationBuilder.taggedBytes(
                transcript: st, docType: v.str(v.input, "docType"),
                deviceNameSpacesBytes: OpaqueCBOR(preserving: Data(hex: v.str(v.input, "deviceNameSpacesBytes"))!))
            let ss = SigStructure.bytes(protected: Data(hex: v.str(v.input, "protected"))!, payload: dab)
            eq(ss.hex, v.expect["sigStructure"], v.id, "sigStructure")
            let key = try P256.Signing.PublicKey(x963Representation: Data(hex: v.str(v.input, "deviceKeyPublicSEC1"))!)
            let sig = try P256.Signing.ECDSASignature(rawRepresentation: Data(hex: v.str(v.input, "signature"))!)
            XCTAssertEqual(key.isValidSignature(sig, for: ss), v.expect["valid"] as? Bool, v.id)

        case "response/issuer-signed-namespaces":
            let items = v.input["issuedItems"] as! [[String: String]]
            let disclose = Set(v.input["disclose"] as! [String])
            let selected = items.filter { disclose.contains($0["elementIdentifier"]!) }
                .map { try! CborDecoder.decode(Data(hex: $0["issuerSignedItemBytes"]!)!) }
            let ns = v.str(v.input, "nameSpace")
            eq(CborEncoder.encode(.map([CborPair(.text(ns), .array(selected))])).hex,
               v.expect["nameSpaces"], v.id, "nameSpaces")

        case "engagement/decode-tolerant":
            let data = Data(hex: v.str(v.input, "bytes"))!
            let de = try EngagementCodec.decode(data)
            XCTAssertEqual(de.version, v.expect["version"] as? String, v.id)
            XCTAssertEqual(Int(de.cipherSuiteIdentifier), v.expect["cipherSuiteIdentifier"] as? Int, v.id)
            eq(de.eDeviceKeyBytes.raw.hex, v.expect["eDeviceKeyBytes"], v.id, "edk")
            eq(de.raw.raw.hex, v.expect["preservedBytes"], v.id, "preserved")
            XCTAssertEqual(de.unknownKeys.map(Int.init).sorted(),
                           (v.expect["ignoredIntKeys"] as! [Int]).sorted(), v.id)

        case "mso/value-digests":
            let ns = v.str(v.input, "nameSpace")
            let entries = try (v.input["issuerSignedItemBytes"] as! [String]).map { hex -> IssuerSignedItemEntry in
                let raw = Data(hex: hex)!
                guard case .tagged(24, .bytes(let inner)) = try CborDecoder.decode(raw) else {
                    throw MdocProximityError.validationFailed(detail: "not tag24")
                }
                let item = try CborDecoder.decode(inner)
                return IssuerSignedItemEntry(raw: OpaqueCBOR(preserving: raw),
                                             digestID: item.member("digestID")!.asUInt!,
                                             elementIdentifier: item.member("elementIdentifier")!.asText!,
                                             elementValue: item.member("elementValue")!)
            }
            var digests: [UInt64: Data] = [:]
            for (k, h) in ((v.expect["valueDigests"] as! [String: Any])[ns] as! [String: String]) {
                digests[UInt64(k)!] = Data(hex: h)!
            }
            let signed = IssuerSigned(nameSpaces: [ns: entries],
                                      issuerAuth: CoseSign1(protectedBytes: Data(), unprotected: .null,
                                                            payload: nil, signature: Data()))
            XCTAssertEqual(DigestChecker.check(signed, valueDigests: [ns: digests]).allMatch,
                           v.expect["valid"] as? Bool, v.id)

        case "response/zero-documents":
            let r = try ResponseCodec.decode(Data(hex: v.str(v.input, "bytes"))!)
            XCTAssertEqual(r.documents.count, v.expect["documentCount"] as? Int, v.id)
            XCTAssertEqual(Int(r.status), v.expect["status"] as? Int, v.id)

        case "response/mixed-deviceauth":
            let r = try ResponseCodec.decode(Data(hex: v.str(v.input, "bytes"))!)
            XCTAssertEqual(r.documents.count, v.expect["documentCount"] as? Int, v.id)
            let st = SessionTranscriptBytes(raw: Data(hex: v.str(v.input, "sessionTranscriptBytes"))!)
            let keys = v.input["deviceKeyPublicSEC1"] as! [String: String]
            let want = v.expect["mdocAuth"] as! [String: [String: Any]]
            for doc in r.documents {
                let res = MdocAuthVerifier.verify(
                    doc.deviceSigned.deviceAuth, transcript: st, docType: doc.docType,
                    deviceNameSpacesBytes: doc.deviceSigned.nameSpacesBytes,
                    deviceKeySEC1: Data(hex: keys[doc.docType]!),
                    eMacKey: Data(hex: v.str(v.input, "eMacKey")))
                XCTAssertEqual(res.valid, want[doc.docType]?["valid"] as? Bool, "\(v.id)/\(doc.docType)")
                XCTAssertEqual(res.method == .mac ? "mac" : "ecdsa",
                               want[doc.docType]?["method"] as? String, "\(v.id)/\(doc.docType)")
            }

        case "transport/ble-part-split":
            let msg = Data(hex: v.str(v.input, "message"))!
            for (mtuStr, cAny) in v.expect as! [String: [String: Any]] {
                let mtu = Int(mtuStr)!
                let sizes = try BleFraming.partSizes(mtu: mtu)
                XCTAssertEqual(sizes.partTotal, cAny["partTotal"] as? Int, "\(v.id)/mtu\(mtu)")
                XCTAssertEqual(sizes.partPayload, cAny["partPayload"] as? Int, "\(v.id)/mtu\(mtu)")
                let parts = try BleFraming.split(msg, mtu: mtu)
                XCTAssertEqual(parts.count, cAny["partCount"] as? Int, "\(v.id)/mtu\(mtu)")
                eq(parts.first!.hex, cAny["firstPart"], v.id, "mtu\(mtu)/first")
                eq(parts.last!.hex, cAny["lastPart"], v.id, "mtu\(mtu)/last")
            }

        case "transport/l2cap-length-header":
            for (nStr, hexStr) in (v.expect["headers"] as! [String: String]) {
                eq(L2capFraming.lengthHeader(UInt32(nStr)!).hex, hexStr, v.id, nStr)
            }

        case "transport/wifi-options":
            // Core 인코더·디코더 — iOS 전송체는 없지만 Android 와 같은 바이트를 내는지 고정한다
            for (name, want) in [("full", v.expect["full"] as! String), ("minimal", v.expect["minimal"] as! String)] {
                let inp = v.input[name] as! [String: Any]
                let opts = WifiOptions(operatingClass: (inp["operatingClass"] as? Int).map(UInt64.init),
                                       channelNumber: (inp["channelNumber"] as? Int).map(UInt64.init),
                                       supportedBands: Data(hex: inp["supportedBands"] as! String))
                let bytes = CborEncoder.encode(opts.cbor)
                eq(bytes.hex, want, v.id, name)
                // 되읽기 — 키 0 은 없고 나머지는 그대로
                let back = WifiOptions(try CborDecoder.decode(bytes))
                XCTAssertEqual(back, opts, "\(v.id): \(name) round-trip")
                XCTAssertNil(back?.passphrase)
            }
            // 키 3 이 없는 상대도 받는다 (C.2 — Annex H 는 optional)
            XCTAssertNotNil(WifiOptions(.map([CborPair(.unsigned(1), .unsigned(81))])))
            XCTAssertNil(WifiOptions(.map([CborPair(.unsigned(1), .unsigned(81))]))?.supportedBands)

        case "negative/documents-empty":
            let r = try ResponseCodec.decode(Data(hex: v.str(v.input, "bytes"))!)
            XCTAssertEqual(r.documents.count, v.expect["documentCount"] as? Int, v.id)

        case "negative/counter-rewind":
            let st = SessionTranscriptBytes(raw: CborEncoder.tag24(Data([0xa0])))
            let zab = Data(repeating: 0x33, count: 32)
            let a = SessionCipher(role: .mdocReader, sharedSecret: zab, transcript: st)
            let b = SessionCipher(role: .mdoc, sharedSecret: zab, transcript: st)
            for _ in 1...2 { _ = try b.decrypt(try a.encrypt(Data([0x01]))) }
            let next = try a.encrypt(Data([0x02]))
            let received = UInt32(v.input["receivedCounter"] as! Int)
            XCTAssertThrowsError(try b.decrypt(next, counter: received), v.id) { e in
                XCTAssertEqual("\(e)".contains("counterMismatch"), true,
                               "\n  id:   \(v.id)\n  기대: \(v.expect["error"] as! String)\n  실제: \(e)")
            }

        default:
            XCTFail("\(v.id): 러너에 호출 지점이 없다")
        }
    }
}
