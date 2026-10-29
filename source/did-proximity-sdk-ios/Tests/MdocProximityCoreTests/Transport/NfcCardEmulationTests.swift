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
@_spi(MdocInternal) @testable import MdocNFC
@_spi(MdocInternal) @testable import MdocTrust
@_spi(MdocInternal) @testable import MdocDevice
@_spi(MdocInternal) @testable import MdocReader

/// 앱이 주입하는 카드 에뮬레이션의 흉내. `CardSession` 대신 **핸들러를 그대로 노출**해 리더 쪽
/// 채널이 직접 부른다 — 두 스택이 한 프로세스에서 APDU 로 마주 본다.
final class FakeCardEmulation: NfcCardEmulationProtocol {
    private(set) var handler: ((Data) async -> Data)?
    private(set) var started = false, stopped = false
    var onDeactivated: (() -> Void)?
    func start(handler: @escaping (Data) async -> Data) async throws { self.handler = handler; started = true }
    func stop() { stopped = true }
    func fieldLost() { onDeactivated?() }
}

/// 리더가 보는 태그 = 카드 에뮬레이션의 핸들러. `close()` 는 자기장을 떠나는 것으로 친다.
final class CardBackedChannel: Iso7816Channel {
    let card: FakeCardEmulation
    private(set) var commands: [Data] = []
    var isAvailable = true
    init(_ card: FakeCardEmulation) { self.card = card }
    func transceive(_ apdu: Data) async throws -> Data {
        guard let h = card.handler else { throw MdocProximityError.peerDisconnected }
        commands.append(apdu)
        return await h(apdu)
    }
    func close() { isAvailable = false; card.fieldLost() }
}

struct CardBackedTagSource: NfcTagSource {
    let card: FakeCardEmulation
    func openChannel() async throws -> Iso7816Channel { CardBackedChannel(card) }
}

final class NfcCardEmulationTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    override func tearDown() { SessionRegistry.release() }

    // MARK: 레코드 — 만드는 쪽과 읽는 쪽이 같은 코드다

    func testCarrierConfigurationRoundTrip() {
        for (c, r) in [(UInt64(255), UInt64(256)), (65535, 65536), (300, 1024)] {
            let cfg = NfcCarrierConfiguration(maxCommandDataLength: c, maxResponseDataLength: r)
            XCTAssertEqual(NfcCarrierConfiguration(cfg.encoded), cfg)
        }
        // Table 6 — 255/256: 01 │ 02 01 FF │ 03 02 01 00
        XCTAssertEqual(NfcCarrierConfiguration(maxCommandDataLength: 255, maxResponseDataLength: 256).encoded.hex,
                       "010201ff03020100")
    }

    func testHandoverSelectRoundTrip() throws {
        let de = Data([0xa1, 0x00, 0x63, 0x31, 0x2e, 0x30])       // {0: "1.0"} — 내용은 무관
        let cfg = NfcCarrierConfiguration(maxCommandDataLength: 255, maxResponseDataLength: 256)
        let message = HandoverSelect.build(deviceEngagement: de, nfc: cfg)
        let records = try Ndef.parse(message)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].typeText, "Hs")
        XCTAssertEqual(records[0].payload.first, 0x15, "Connection Handover 1.5")
        XCTAssertEqual(Ndef.deviceEngagement(in: records), de, "리더는 타입으로 DE 를 찾는다")
        XCTAssertFalse(Ndef.isNegotiated(records), "static 이다 — Service Parameter 가 없어야 한다")
        let parsed = HandoverSelect.parse(records)
        XCTAssertEqual(parsed.carriers, [.nfc])
        XCTAssertEqual(parsed.nfc, cfg)
    }

    /// 상대가 BLE OOB 캐리어를 광고하면 LE Role 과 서비스 UUID 를 읽어낸다 — QR 의 `BleOptions` 자리
    func testParsesBleOobCarrier() throws {
        let uuid = Data((0..<16).map { UInt8($0) })
        var oob = Data([0x02, 0x1C, 0x02])                            // LE Role: both
        oob.append(0x11); oob.append(0x07); oob.append(Data(uuid.reversed()))   // 128-bit UUID (LE)
        let ac = NdefRecord(typeNameFormat: 0x01, type: Data("ac".utf8), id: Data(),
                            payload: HandoverSelect.alternativeCarrier(carrierRef: "0", auxiliaryRefs: ["mdoc"]))
        let hs = NdefRecord(typeNameFormat: 0x01, type: Data("Hs".utf8), id: Data(),
                            payload: Data([0x15]) + Ndef.encode([ac]))
        let ble = NdefRecord(typeNameFormat: 0x02, type: HandoverSelect.bleOobType, id: Data("0".utf8), payload: oob)
        let parsed = HandoverSelect.parse(try Ndef.parse(Ndef.encode([hs, ble])))
        XCTAssertEqual(parsed.carriers, [.ble(.centralClient), .ble(.peripheralServer)])
        XCTAssertEqual(parsed.bleServiceUUID, uuid, "little-endian 을 뒤집어 big-endian 으로")
    }

    // MARK: 태그 흉내 — 리더의 읽기 순서 그대로 읽힌다

    func testReaderReadsEmulatedTag() async throws {
        let card = FakeCardEmulation()
        let de = Data([0xa1, 0x00, 0x63, 0x31, 0x2e, 0x30])
        let hs = HandoverSelect.build(deviceEngagement: de,
                                      nfc: NfcCarrierConfiguration(maxCommandDataLength: 255, maxResponseDataLength: 256))
        let transport = NfcCardTransport(emulation: card, handoverSelect: hs,
                                         maxCommandDataLength: 255, maxResponseDataLength: 256)
        try await transport.open(TransportConfig(role: .mdoc))
        let channel = CardBackedChannel(card)
        let result = try await Type4TagEngagementReader(channel: channel).read()
        XCTAssertEqual(result.engagementBytes, de)
        XCTAssertEqual(result.handoverSelectBytes, hs, "트랜스크립트 재료 — 바이트가 같아야 한다")
        XCTAssertFalse(result.writable, "static 만 — CC Write 는 FF")
        XCTAssertEqual(result.handover.carriers, [.nfc])
        // NDEF 앱 SELECT → CC SELECT → CC 읽기 → NDEF SELECT → NLEN → 본문
        XCTAssertEqual(channel.commands.count, 6)
        transport.close(.normal)
    }

    /// ENVELOPE 체인 → 메시지 하나, 응답은 GET RESPONSE 로 이어 받는다 — 리더 전송체와 마주 본다
    func testEnvelopeAndGetResponseChaining() async throws {
        let card = FakeCardEmulation()
        let transport = NfcCardTransport(emulation: card, handoverSelect: Data([0xD0, 0x00, 0x00]),
                                         maxCommandDataLength: 255, maxResponseDataLength: 256)
        try await transport.open(TransportConfig(role: .mdoc))
        let reader = NfcDataRetrievalTransport(channel: CardBackedChannel(card),
                                               maxCommandDataLength: 40, maxResponseDataLength: 100)
        try await reader.open(TransportConfig(role: .mdocReader))
        let inbox = TransportEventRouter(reader); inbox.start()
        let cardInbox = TransportEventRouter(transport); cardInbox.start()

        let request = Data(repeating: 0xAB, count: 150)          // 체인 5개
        let response = Data(repeating: 0xCD, count: 700)         // GET RESPONSE 여러 번
        Task {
            let got = await cardInbox.nextMessage()
            XCTAssertEqual(got, request, "체인을 이어 붙여 TLV 하나로 읽는다")
            try await transport.send(response)
        }
        try await reader.send(request)
        let got = await inbox.nextMessage()
        XCTAssertEqual(got, response)
        transport.close(.normal); reader.close(.normal)
    }

    /// **`close()` 가 마지막 ENVELOPE 핸들러의 등록보다 먼저 와도 `9000` 이다.** `.message` 를 올린 뒤
    /// 기다리기 시작하는 사이에 펌프가 종료 통지를 처리해 `close(.remote)` 를 부르면, 등록된 뒤에는
    /// 깨울 사람이 없어 리더가 CoreNFC 타임아웃까지 기다렸다.
    func testCloseBeforeHandlerRegistersStillAnswersLastEnvelope() async throws {
        let card = FakeCardEmulation()
        let transport = NfcCardTransport(emulation: card, handoverSelect: Data([0xD0, 0x00, 0x00]),
                                         maxCommandDataLength: 255, maxResponseDataLength: 256)
        try await transport.open(TransportConfig(role: .mdoc))
        let handler = try XCTUnwrap(card.handler)
        let selected = await handler(Apdu.selectByName(NfcAid.mdocDataRetrieval))
        XCTAssertEqual(selected, Data([0x90, 0x00]))
        transport.close(.remote)                                     // 등록 전에 링크가 내려갔다
        let envelope = Data([0x00, 0xC3, 0x00, 0x00, 0x03, 0x53, 0x01, 0xAA, 0x00])   // 마지막 ENVELOPE, Le=0
        let answer = await handler(envelope)
        XCTAssertEqual(answer, Data([0x90, 0x00]), "빈 응답으로 풀린다 — 6F00 도 대기도 아니다")
        // 내려간 링크로는 보낼 수 없다
        do { try await transport.send(Data([0x01])); XCTFail("peerDisconnected") }
        catch { XCTAssertEqual(error as? MdocProximityError, .peerDisconnected) }
    }

    /// 자기장 이탈이 등록보다 먼저 와도 기다리지 않는다 — `6F00` 으로 나간다
    func testFieldLossBeforeHandlerRegistersDoesNotHang() async throws {
        let card = FakeCardEmulation()
        let transport = NfcCardTransport(emulation: card, handoverSelect: Data([0xD0, 0x00, 0x00]),
                                         maxCommandDataLength: 255, maxResponseDataLength: 256)
        try await transport.open(TransportConfig(role: .mdoc))
        let handler = try XCTUnwrap(card.handler)
        _ = await handler(Apdu.selectByName(NfcAid.mdocDataRetrieval))
        card.fieldLost()
        let envelope = Data([0x00, 0xC3, 0x00, 0x00, 0x03, 0x53, 0x01, 0xAA, 0x00])
        let answer = await handler(envelope)
        XCTAssertEqual(answer, Data([0x6F, 0x00]))
    }

    /// 리더가 자기장을 떠나면 카드 쪽 세션도 안다
    func testFieldLossSurfacesAsPeerClosed() async throws {
        let card = FakeCardEmulation()
        let transport = NfcCardTransport(emulation: card, handoverSelect: Data([0xD0, 0x00, 0x00]),
                                         maxCommandDataLength: 255, maxResponseDataLength: 256)
        try await transport.open(TransportConfig(role: .mdoc))
        let seen = XCTestExpectation(description: "peerClosed")
        let pump = Task { for await e in transport.events { if case .peerClosed = e { seen.fulfill(); break } } }
        card.fieldLost()
        await fulfillment(of: [seen], timeout: 2)
        pump.cancel()
    }

    // MARK: 두 세션이 NFC 로 끝까지 — 주입된 에뮬레이션 ↔ 리더의 connectViaNFC

    final class Holder: MdocDeviceSessionDelegate {
        var session: MdocDeviceSession?
        let issuerKey: P256.Signing.PrivateKey, deviceKey: P256.Signing.PrivateKey, did: String
        var failure: MdocProximityError?
        init(issuerKey: P256.Signing.PrivateKey, deviceKey: P256.Signing.PrivateKey, did: String) {
            self.issuerKey = issuerKey; self.deviceKey = deviceKey; self.did = did
        }
        func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState) {}
        func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data, sessionTranscript: Data) {
            let t = SessionTranscriptBytes(raw: sessionTranscript)
            Task { try? await s.respond(deviceResponse: Fixtures.response(
                transcript: t, issuerKey: issuerKey, deviceKey: deviceKey, did: did)) }
        }
        func mdocSessionDidFinish(_ s: MdocDeviceSession) {}
        func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError) { failure = error }
    }

    func testEndToEndOverInjectedCardEmulation() async throws {
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let card = FakeCardEmulation()
        let holder = Holder(issuerKey: issuerKey, deviceKey: deviceKey, did: did)
        let mdoc = MdocDeviceSession(nfcCardEmulation: card)        // 앱이 쓰는 생성자 그대로
        mdoc.delegate = holder

        let payload = try await mdoc.start(technology: .nfcStaticHandover)
        XCTAssertNil(payload.qrString, "NFC engagement 에는 QR 문자열이 없다")
        XCTAssertEqual(payload.transmissions, [.nfc], "캐리어는 Handover Select 에서 온다")
        XCTAssertTrue(payload.deviceEngagement.retrievalMethods.isEmpty, "8.2.1.1 — NFC 면 DE 에 방법이 없다")
        XCTAssertTrue(card.started)
        XCTAssertEqual(mdoc.state, .engaging)
        SessionRegistry.release()                                   // 한 프로세스에 두 역할 — 테스트 편의

        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in issuerKey.publicKey.x963Representation }
        let reader = MdocReaderSession(configuration: verifyingReaderConfiguration(responseTimeout: 3),
                                       trust: trust, transportFactory: ReaderTransportFactory(),
                                       nfcTagSource: CardBackedTagSource(card: card))
        let engagement = try await reader.connectViaNFC()            // 태그 읽기 → 목록이 NFC 를 고르면 같은 링크
        XCTAssertEqual(engagement.technology, .nfcStaticHandover)
        XCTAssertEqual(engagement.transmissions, [.nfc])
        XCTAssertEqual(reader.state, .connected)

        let result = try await reader.request([ItemsRequestPresets.identity], at: Date())
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.documents[0].verdict, .valid, "NFC 트랜스크립트(Handover Select 포함)가 양쪽에서 같다")
        XCTAssertNil(holder.failure)
        for _ in 0..<50 where mdoc.state != .completed { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(mdoc.state, .completed)
        reader.terminate(); mdoc.terminate()
    }

    /// **QR → NFC**. 주입이 있으면 QR engagement 에도 NFC 가 광고되고(`[1, 1, NfcOptions]`),
    /// 리더가 NFC 를 고르면 탭 한 번으로 데이터를 받아 간다. 주입이 없으면 QR 은 BLE 만이다.
    func testQrEngagementAdvertisesNfcWhenInjected() async throws {
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let card = FakeCardEmulation()
        let holder = Holder(issuerKey: issuerKey, deviceKey: deviceKey, did: did)
        let mdoc = MdocDeviceSession(nfcCardEmulation: card)
        mdoc.delegate = holder

        let payload = try await mdoc.start(technology: .qr)
        XCTAssertNotNil(payload.qrString)
        XCTAssertTrue(payload.transmissions.contains(.nfc), "주입이 있으면 QR 에도 NFC 를 광고한다")
        XCTAssertTrue(payload.transmissions.contains(.ble(.peripheralServer)), "BLE 는 그대로")
        XCTAssertEqual(payload.nfcMaxCommandDataLength, 255)
        XCTAssertEqual(payload.nfcMaxResponseDataLength, 256)
        XCTAssertTrue(card.started, "광고한 것은 전부 세워 둔다 — 카드도 켜 둔다")
        SessionRegistry.release()

        // 리더는 QR 을 스캔했고 NFC 를 앞세운다 → 탭 → 같은 카드로 데이터 검색
        var config = verifyingReaderConfiguration(responseTimeout: 3)
        config.transmissionPriority = [.nfc, .ble]
        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in issuerKey.publicKey.x963Representation }
        let reader = MdocReaderSession(configuration: config, trust: trust,
                                       transportFactory: ReaderTransportFactory(),
                                       nfcTagSource: CardBackedTagSource(card: card))
        try await reader.connect(to: try EngagementPayload.parse(qrString: payload.qrString!))
        XCTAssertEqual(reader.state, .connected)
        let result = try await reader.request([ItemsRequestPresets.identity], at: Date())
        XCTAssertEqual(result.documents.first?.verdict, .valid, "QR 트랜스크립트(Handover = null)가 양쪽에서 같다")
        for _ in 0..<50 where mdoc.state != .completed { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(mdoc.state, .completed)
        reader.terminate(); mdoc.terminate()
    }

    /// 주입이 없으면 QR 은 BLE 만 광고한다 — NFC 항은 주입이 있어야 "구현한 것" 이다
    func testQrEngagementWithoutInjectionHasNoNfc() async throws {
        let mdoc = MdocDeviceSession(transport: LoopbackTransport.pair().0)
        let payload = try await mdoc.start(technology: .qr)
        XCTAssertFalse(payload.transmissions.contains(.nfc))
        mdoc.terminate()
    }

    /// 주입이 없으면 지금까지처럼 `vendorPolicy` 다 — SDK 는 HCE 를 갖지 않는다
    func testWithoutInjectionNfcStaysUnavailable() async {
        let mdoc = MdocDeviceSession()
        do {
            _ = try await mdoc.start(technology: .nfcStaticHandover)
            XCTFail("주입 없이 NFC 가 되면 안 된다")
        } catch {
            guard case MdocProximityError.nfcUnavailable(.vendorPolicy) = error else { return XCTFail("\(error)") }
        }
    }
}
