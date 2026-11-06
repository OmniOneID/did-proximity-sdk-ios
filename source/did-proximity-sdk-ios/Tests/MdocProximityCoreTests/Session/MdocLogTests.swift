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
@_spi(MdocInternal) @testable import MdocTrust
@_spi(MdocInternal) @testable import MdocDevice
@_spi(MdocInternal) @testable import MdocReader
@_spi(MdocInternal) @testable import MdocNFC

/// 앱이 켜는 SDK 로거 — 레벨·handler 계약과 **민감 정보가 로그에 실리지 않는다**는 보장
final class MdocLogTests: XCTestCase {

    private final class Sink {
        private let lock = NSLock()
        private var stored: [MdocLogEntry] = []
        func append(_ e: MdocLogEntry) { lock.lock(); stored.append(e); lock.unlock() }
        var entries: [MdocLogEntry] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private var sink = Sink()

    override func setUp() {
        super.setUp()
        MdocCapabilities.assumeAllSupportedForTests()
        sink = Sink()
        let s = sink
        MdocLog.systemLogEnabled = false
        MdocLog.handler = { s.append($0) }
    }

    override func tearDown() {
        MdocLog.flush()
        MdocLog.level = .off
        MdocLog.handler = nil
        MdocLog.systemLogEnabled = true
        SessionRegistry.release()
        super.tearDown()
    }

    func testOffByDefaultLogsNothing() {
        MdocLog.level = .off
        MdocLog.error(.session, "x")
        MdocLog.flush()
        XCTAssertTrue(sink.entries.isEmpty)
    }

    func testLevelFiltersLowerPriorityEntries() {
        MdocLog.level = .warning
        MdocLog.error(.session, "e")
        MdocLog.warning(.ble, "w")
        MdocLog.info(.nfc, "i")
        MdocLog.debug(.transport, "d")
        MdocLog.flush()
        XCTAssertEqual(sink.entries.map(\.message), ["e", "w"])
        XCTAssertEqual(sink.entries.map(\.level), [.error, .warning])
        XCTAssertEqual(sink.entries.map(\.category), [.session, .ble])
    }

    func testOffIsNeverAnEntryLevel() {
        MdocLog.level = .debug
        MdocLog.log(.off, .session, "never")
        MdocLog.flush()
        XCTAssertTrue(sink.entries.isEmpty)
    }

    func testDisabledLevelDoesNotBuildTheMessage() {
        MdocLog.level = .error
        var built = false
        MdocLog.debug(.session, { built = true; return "expensive" }())
        XCTAssertFalse(built, "걸러지는 레벨의 메시지는 만들지 않아야 한다")
    }

    func testHandlerKeepsOrderAndRunsOffTheCallerThread() {
        MdocLog.level = .debug
        let caller = Thread.current
        var handlerThreads: [Thread] = []
        let s = sink
        MdocLog.handler = { e in handlerThreads.append(Thread.current); s.append(e) }
        for i in 0..<50 { MdocLog.info(.session, "\(i)") }
        MdocLog.flush()
        XCTAssertEqual(sink.entries.map(\.message), (0..<50).map { "\($0)" })
        XCTAssertFalse(handlerThreads.contains { $0 === caller })
    }

    func testFormattedLine() {
        let e = MdocLogEntry(date: Date(timeIntervalSince1970: 0), level: .warning,
                             category: .ble, message: "m")
        XCTAssertEqual(e.formatted, "1970-01-01T00:00:00.000Z [WARN] [ble] m")
    }

    func testTransportEventDescriptionCarriesNoPayload() {
        let secret = Data("SECRET-PAYLOAD".utf8)
        XCTAssertEqual(TransportEvent.message(secret).logDescription, "message(\(secret.count)B)")
    }

    func testApduSummaryCarriesNoDataField() {
        let aid = Data([0xA0, 0x00, 0x00, 0x02, 0x48, 0x04, 0x00])
        let line = Apdu.logSummary(command: Apdu.selectByName(aid),
                                   response: Data([0xDE, 0xAD, 0x90, 0x00]))
        XCTAssertEqual(line, "INS A4 P1P2 040C cmd 12B → SW 9000 resp 2B")
    }

    /// 전 세션을 `debug` 로 돌려도 키·트랜스크립트·요소 값이 로그에 실리지 않는다
    func testFullSessionAtDebugLeaksNothingSensitive() async throws {
        MdocLog.level = .debug
        let marker = "LOG-LEAK-MARKER-7f3a"
        let eDevice = P256.KeyAgreement.PrivateKey(), eReader = P256.KeyAgreement.PrivateKey()
        let zab = try eReader.sharedSecretFromKeyAgreement(with: eDevice.publicKey)
            .withUnsafeBytes { Data($0) }
        let transcript = SessionTranscriptBuilder.qr(
            deviceEngagementBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0]))),
            eReaderKeyBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa1, 0x01, 0x02]))))
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in
            issuerKey.publicKey.x963Representation
        }

        let (readerLink, mdocLink) = LoopbackTransport.pair()
        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(),
                                       transport: readerLink, trust: trust)
        let mdoc = MdocDeviceSession(transport: mdocLink)
        let responder = AutoResponder(session: mdoc) {
            Fixtures.response(transcript: transcript, issuerKey: issuerKey, deviceKey: deviceKey, did: did,
                              extraIssuerItems: [("org.iso.18013.5.1", "given_name", .text(marker))])
        }
        mdoc.begin(transcript: transcript, sharedSecret: zab)
        reader.begin(transcript: transcript, sharedSecret: zab,
                     eReaderKeyBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0]))))
        let spec = ItemsRequestSpec(docType: "org.iso.18013.5.1.mDL",
                                    items: ["org.iso.18013.5.1": ["family_name": false, "given_name": false]])
        let result = try await reader.request([spec], at: Date())
        await drainCallbacks()
        XCTAssertTrue(responder.finished)
        XCTAssertEqual(result.documents.first?.issuerSignedElements["org.iso.18013.5.1"]?["given_name"]?.asText,
                       marker)
        MdocLog.flush()

        let lines = sink.entries.map(\.formatted)
        let all = lines.joined(separator: "\n")
        // 생애주기가 실제로 남는다
        XCTAssertTrue(all.contains("reader state connected -> awaitingResponse"), all)
        XCTAssertTrue(all.contains("mdoc state sessionEstablished -> awaitingResponse"), all)
        XCTAssertTrue(all.contains("DeviceRequest received"), all)
        XCTAssertTrue(all.contains("[verify]"), all)

        // 민감 정보는 없다 — 요소 값, 공유 비밀, 트랜스크립트, 키
        let hex: (Data) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        let forbidden = [marker,
                         hex(zab), zab.base64EncodedString(),
                         hex(transcript.raw),
                         hex(issuerKey.publicKey.x963Representation),
                         hex(deviceKey.publicKey.x963Representation)]
        for f in forbidden {
            XCTAssertFalse(all.localizedCaseInsensitiveContains(f), "로그에 민감 정보가 실렸다: \(f)")
        }
    }
}
