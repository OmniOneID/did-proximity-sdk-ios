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
@_spi(MdocInternal) import MdocProximitySDK  // 월렛 SDK 자리 — CBOR·COSE 조립은 앱 표면이 아니다

/// 월렛 자리를 대신한다. **이 SDK 는 `DeviceResponse` 를 만들지 않으므로**
/// 하네스가 그 자리를 채워야 두 대 시험이 성립한다.
///
/// 발급자 키도 device key 도 **실행할 때마다 새로 만든다** — 신뢰 판정은 이 하네스의
/// 대상이 아니고, 여기서 재는 것은 링크·세션·전송 시간이다.
/// 발급자 키를 **고정한다.** 실행할 때마다 새로 만들면 두 기기가 서로 다른 키를 갖게 되어
/// 리더가 발급자 서명을 검증할 방법이 없다 — `issuerSig=false` 가 그것 때문이었다.
/// 하네스 전용 값이고 어디에도 배포되지 않는다.
enum HarnessIssuer {
    static let did = "did:omn:probe"
    static let kid = "did:omn:probe#assert"
    static let privateKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(
        (0..<32).map { UInt8(($0 * 7 + 13) % 251 + 1) }))
    static var publicSEC1: Data { privateKey.publicKey.x963Representation }
}

@MainActor
final class WalletStub: NSObject, MdocDeviceSessionDelegate {

    weak var log: ProbeLog?
    private let large: Bool
    private let issuerKey = HarnessIssuer.privateKey
    private let deviceKey = P256.Signing.PrivateKey()
    private var receivedAt: Date?

    init(large: Bool) { self.large = large }

    nonisolated func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState) {
        Task { @MainActor [weak self] in
            self?.log?.info("[mdoc] 상태 → \(state.rawValue)")
            // **상대가 종료를 보내면 트랜잭션이 끝난 것이다** — 응답을 보낸 뒤(`completed`)
            // 받는 것이 정상 순서다
            if state == .terminated { self?.log?.pass("[mdoc] 트랜잭션 완료 — 상대가 세션을 닫음") }
        }
    }

    nonisolated func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data,
                                 sessionTranscript: Data) {
        Task { @MainActor in
            receivedAt = Date()
            log?.pass("요청 수신 \(deviceRequest.count)바이트 — 응답을 만든다")
            do {
                let bytes = try response(transcript: sessionTranscript)
                log?.info("DeviceResponse \(bytes.count)바이트")
                try await s.respond(deviceResponse: bytes)
                // **일부러 바로 닫는다.** respond 가 돌아온 시점에 응답은 아직 CoreBluetooth 큐에
                // 있을 수 있고, 예전 close 는 큐째 서비스를 걷어 리더가 0바이트를 받았다(CA 앱
                // 실기기 재현). 이 한 줄이 그 회귀 시험이다 — 리더 프로브가 응답을 받으면 PASS
                log?.info("respond 직후 terminate — 큐 비움 대기가 응답을 지켜야 한다")
                s.terminate()
            } catch {
                log?.fail("응답 실패 — \(error)")
            }
        }
    }

    nonisolated func mdocSessionDidFinish(_ s: MdocDeviceSession) {
        Task { @MainActor in
            if let receivedAt {
                log?.pass(String(format: "전송 완료 %.0f ms", Date().timeIntervalSince(receivedAt) * 1000))
            }
        }
    }

    nonisolated func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError) {
        Task { @MainActor in log?.fail("mdoc 실패 — \(error)") }
    }

    // MARK: -

    /// **공개 API 만으로 만든다** — 월렛이 실제로 놓이는 자리와 같은 조건이다.
    /// `SessionTranscriptBytes` 를 만들 수단이 없는 것도 의도된 경계다.
    private func response(transcript raw: Data) throws -> Data {
        let ns = "org.iso.18013.5.1", docType = "org.iso.18013.5.1.mDL"

        var items: [CborValue] = [issuerItem(1, "family_name", .text("Doe"))]
        if large {
            // portrait 은 프래그멘테이션이 실제로 도는 크기다
            items.append(issuerItem(2, "portrait", .bytes(Data(repeating: 0x7f, count: 20 * 1024))))
        }
        var digests: [CborPair] = []
        for (index, item) in items.enumerated() {
            guard case .tagged(24, .bytes(let inner)) = item else { continue }
            digests.append(CborPair(.unsigned(UInt64(index + 1)),
                                    .bytes(Data(SHA256.hash(data: CborEncoder.tag24(inner))))))
        }

        let sec1 = deviceKey.publicKey.x963Representation
        let mso = CborEncoder.tag24(CborEncoder.encode(.map([
            CborPair(.text("version"), .text("1.0")),
            CborPair(.text("digestAlgorithm"), .text("SHA-256")),
            CborPair(.text("valueDigests"), .map([CborPair(.text(ns), .map(digests))])),
            CborPair(.text("deviceKeyInfo"), .map([CborPair(.text("deviceKey"), .map([
                CborPair(.unsigned(1), .unsigned(2)), CborPair(.negative(0), .unsigned(1)),
                CborPair(.negative(1), .bytes(sec1.subdata(in: 1..<33))),
                CborPair(.negative(2), .bytes(sec1.subdata(in: 33..<65)))]))])),
            CborPair(.text("docType"), .text(docType)),
            CborPair(.text("validityInfo"), .map([
                CborPair(.text("signed"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
                CborPair(.text("validFrom"), .tagged(0, .text("2026-01-01T00:00:00Z"))),
                CborPair(.text("validUntil"), .tagged(0, .text("2030-01-01T00:00:00Z")))]))])))
        let issuerSignature = try issuerKey.signature(
            for: SigStructure.bytes(protected: CoseConstants.protectedES256, payload: mso))

        // DeviceAuthentication = [ "DeviceAuthentication", SessionTranscript, docType,
        //                          DeviceNameSpacesBytes ] — **셋째 원소는 해석하지 않는다**
        let deviceNameSpacesBytes = CborEncoder.tag24(CborEncoder.encode(.map([])))
        guard case .tagged(24, .bytes(let transcriptArray)) = try CborDecoder.decode(raw) else {
            throw MdocProximityError.validationFailed(detail: "transcript is not #6.24(bstr)")
        }
        let dab = CborEncoder.tag24(CborEncoder.encode(.array([
            .text("DeviceAuthentication"),
            try CborDecoder.decode(transcriptArray),
            .text(docType),
            try CborDecoder.decode(deviceNameSpacesBytes)])))
        let deviceSignature = try deviceKey.signature(
            for: SigStructure.bytes(protected: CoseConstants.protectedES256, payload: dab))

        return CborEncoder.encode(.map([
            CborPair(.text("version"), .text("1.0")),
            CborPair(.text("documents"), .array([.map([
                CborPair(.text("docType"), .text(docType)),
                CborPair(.text("issuerSigned"), .map([
                    CborPair(.text("nameSpaces"), .map([CborPair(.text(ns), .array(items))])),
                    CborPair(.text("issuerAuth"), .array([
                        .bytes(CoseConstants.protectedES256),
                        .map([CborPair(.unsigned(4), .bytes(Data(HarnessIssuer.kid.utf8)))]),
                        .bytes(mso), .bytes(issuerSignature.rawRepresentation)]))])),
                CborPair(.text("deviceSigned"), .map([
                    CborPair(.text("nameSpaces"), try CborDecoder.decode(deviceNameSpacesBytes)),
                    CborPair(.text("deviceAuth"), .map([
                        CborPair(.text("deviceSignature"), .array([
                            .bytes(CoseConstants.protectedES256), .map([]), .null,
                            .bytes(deviceSignature.rawRepresentation)]))]))]))])])),
            CborPair(.text("status"), .unsigned(0))]))
    }

    private func issuerItem(_ digestID: UInt64, _ id: String, _ value: CborValue) -> CborValue {
        let encoded = CborEncoder.encode(.map([
            CborPair(.text("digestID"), .unsigned(digestID)),
            CborPair(.text("random"), .bytes(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))),
            CborPair(.text("elementIdentifier"), .text(id)),
            CborPair(.text("elementValue"), value)]))
        return .tagged(24, .bytes(encoded))
    }
}
