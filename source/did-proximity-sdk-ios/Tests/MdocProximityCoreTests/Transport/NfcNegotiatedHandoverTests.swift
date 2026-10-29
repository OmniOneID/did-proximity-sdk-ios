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

/// **negotiated handover 는 TNEP 왕복이다.** 리더가 쓰고 태그가 답한다. 리더와
/// 에뮬레이터가 한 프로세스에서 APDU 로 마주 본다 (`NfcCardEmulationTests` 와 같은 틀).
final class NfcNegotiatedHandoverTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }
    override func tearDown() { SessionRegistry.release() }

    private let de = Data([0xa1, 0x00, 0x63, 0x31, 0x2e, 0x30])      // {0: "1.0"} — 내용은 무관
    private let cfg = NfcCarrierConfiguration(maxCommandDataLength: 255, maxResponseDataLength: 256)
    private let sp = Tnep.ServiceParameter(serviceName: Ndef.handoverServiceName, waitTimeCode: 4,
                                           maxWaitExtensions: 3, maxMessageSize: 1024)

    // MARK: 레코드

    func testServiceParameterRoundTripAndWaitTime() throws {
        let r = sp.record
        XCTAssertEqual(r.typeText, "Tp")
        XCTAssertEqual(Tnep.ServiceParameter(payload: r.payload), sp)
        XCTAssertEqual(Tnep.serviceParameter(in: [r]), sp)
        XCTAssertTrue(Ndef.isNegotiated([r]))
        // t_wait = 2^(WT/4 − 1) ms — WT 4 → 1ms, WT 24 → 32ms, WT 0 → 0.5ms
        XCTAssertEqual(sp.minimumWaitTime, 0.001, accuracy: 1e-9)
        XCTAssertEqual(Tnep.ServiceParameter(serviceName: "x", waitTimeCode: 24, maxWaitExtensions: 0,
                                             maxMessageSize: 0).minimumWaitTime, 0.032, accuracy: 1e-9)
        // WT 는 0...63, N_wait 는 0...15 — 태그가 준 값이 범위 밖이면 레코드가 아니다(WT 255 면 t_wait 나노초 변환이 넘친다)
        var bad = sp.record.payload; bad[bad.endIndex - 4] = 64
        XCTAssertNil(Tnep.ServiceParameter(payload: bad))
        bad = sp.record.payload; bad[bad.endIndex - 3] = 16
        XCTAssertNil(Tnep.ServiceParameter(payload: bad))
        bad = sp.record.payload; bad[bad.endIndex - 4] = 63; bad[bad.endIndex - 3] = 15
        XCTAssertNotNil(Tnep.ServiceParameter(payload: bad))
        // 다른 서비스의 Tp 는 우리 것이 아니다
        let other = Tnep.ServiceParameter(serviceName: "urn:nfc:sn:other", waitTimeCode: 4,
                                          maxWaitExtensions: 3, maxMessageSize: 64).record
        XCTAssertNil(Tnep.serviceParameter(in: [other]))
        XCTAssertFalse(Ndef.isNegotiated([other]))
        // Ts · Te
        let ts = Tnep.serviceSelect(Ndef.handoverServiceName)
        XCTAssertEqual(Tnep.selectedService(in: try Ndef.parse(Ndef.encode([ts]))), Ndef.handoverServiceName)
        XCTAssertEqual(Tnep.statusCode(in: [Tnep.status(0x80)]), 0x80)
    }

    /// 리더가 만든 Handover Request 를 mdoc 이 읽으면 **mdoc 이 서게 될 모드** 순서로 나온다
    func testHandoverRequestRoundTrip() throws {
        let uuid = Data((0..<16).map { UInt8($0) })
        let hr = HandoverRequest.build(
            carriers: [.ble(role: 0x02, serviceUUID: uuid), .nfcReader], collisionResolution: 0x1234)
        let records = try Ndef.parse(hr)
        XCTAssertEqual(records[0].typeText, "Hr")
        XCTAssertEqual(records[0].payload.first, 0x15, "Connection Handover 1.5")
        let inner = try Ndef.parse(records[0].payload.dropFirst())
        XCTAssertEqual(inner[0].typeText, "cr"); XCTAssertEqual(inner[0].payload, Data([0x12, 0x34]))
        XCTAssertEqual(inner.filter { $0.typeText == "ac" }.count, 2)
        // 캐리어 레코드 ID — Multipaz 는 BLE `"0"` · NFC `"nfc"` 만 받는다 (실기 2026-09-16)
        XCTAssertEqual(records.first { $0.type == HandoverSelect.bleOobType }?.id, Data("0".utf8))
        XCTAssertEqual(records.first { $0.type == HandoverSelect.nfcCarrierType }?.id, Data("nfc".utf8))
        let offer = HandoverRequest.parse(records)
        // 리더 LE Role 2 = 둘 다, peripheral 선호 → mdoc 은 central client 를 먼저
        XCTAssertEqual(offer.carriers, [.ble(.centralClient), .ble(.peripheralServer), .nfc])
        XCTAssertEqual(offer.readerServiceUUID, uuid, "little-endian 을 되돌린다")
        // 8.2.2.2 Table 6 — 최대 길이 두 필드는 리더가 싣지 않는다. 버전 바이트만
        XCTAssertEqual(records.first { $0.type == HandoverSelect.nfcCarrierType }?.payload, Data([0x01]))
        XCTAssertNil(offer.nfc)
        // 길이 필드를 실은 (구) 리더의 레코드도 받는다
        let legacy = HandoverRequest.parse(try Ndef.parse(HandoverRequest.build(
            carriers: [.nfc(cfg)], collisionResolution: 0)))
        XCTAssertEqual(legacy.carriers, [.nfc])
        XCTAssertEqual(legacy.nfc, cfg)
        // 리더가 central 만(0x01) — mdoc 은 peripheral server 뿐
        let only = HandoverRequest.parse(try Ndef.parse(HandoverRequest.build(
            carriers: [.ble(role: 0x01, serviceUUID: nil)], collisionResolution: 0)))
        XCTAssertEqual(only.carriers, [.ble(.peripheralServer)])
        XCTAssertNil(only.readerServiceUUID)
    }

    /// Handover Select 에 BLE 캐리어 — 리더 파서가 모드와 UUID 를 읽는다 (static 의 DE 보조 레코드 포함)
    func testHandoverSelectWithBleCarrier() throws {
        let uuid = Data((16..<32).map { UInt8($0) })
        let hs = HandoverSelect.build(deviceEngagement: de, carrier: .ble(role: 0x00, serviceUUID: uuid))
        let records = try Ndef.parse(hs)
        XCTAssertEqual(Ndef.deviceEngagement(in: records), de)
        let parsed = HandoverSelect.parse(records)
        XCTAssertEqual(parsed.carriers, [.ble(.peripheralServer)])
        XCTAssertEqual(parsed.bleServiceUUID, uuid)
        // central client 를 골랐으면 UUID 없이 role 1
        let hs2 = HandoverSelect.build(deviceEngagement: de, carrier: .ble(role: 0x01, serviceUUID: nil))
        let p2 = HandoverSelect.parse(try Ndef.parse(hs2))
        XCTAssertEqual(p2.carriers, [.ble(.centralClient)])
        XCTAssertNil(p2.bleServiceUUID)
    }

    // MARK: TNEP 왕복 — 리더 ↔ 에뮬레이터

    private func negotiatedCard(_ card: FakeCardEmulation,
                                answer: @escaping (Data) -> Data?) async throws -> NfcCardTransport {
        let transport = NfcCardTransport(emulation: card, handoverSelect: Data(),
                                         maxCommandDataLength: 255, maxResponseDataLength: 256,
                                         mode: .negotiated(sp, onHandoverRequest: answer))
        try await transport.open(TransportConfig(role: .mdoc))
        return transport
    }

    func testReaderNegotiatesHandoverSelect() async throws {
        let card = FakeCardEmulation()
        var received: Data?
        let transport = try await negotiatedCard(card) { [de, cfg] hr in
            received = hr
            return HandoverSelect.build(deviceEngagement: de, carrier: .nfc(cfg))
        }
        let channel = CardBackedChannel(card)
        var written: Data?
        let result = try await Type4TagEngagementReader(channel: channel).read(negotiated: { [cfg] sp in
            XCTAssertEqual(sp.maxWaitExtensions, 3, "Twait·N_wait 는 태그가 준 값이다")
            let hr = HandoverRequest.build(carriers: [.nfc(cfg)], collisionResolution: 0x0001)
            written = hr
            return hr
        })
        XCTAssertEqual(result.engagementBytes, de)
        XCTAssertEqual(result.handoverRequestBytes, written, "트랜스크립트 둘째 원소 = 우리가 쓴 바이트")
        XCTAssertEqual(received, written, "태그가 받은 바이트와 같다")
        XCTAssertEqual(result.handover.carriers, [.nfc])
        XCTAssertTrue(result.writable)
        // 명령 순서: NDEF SELECT → CC → CC 읽기 → NDEF SELECT → NLEN → Tp 읽기 → (Ts 쓰기 3) → NLEN → Te 읽기
        //           → (Hr 쓰기 3) → NLEN → Hs 읽기
        let updates = channel.commands.filter { $0[$0.startIndex + 1] == 0xD6 }.count
        XCTAssertEqual(updates, 6, "메시지 둘 × (NLEN 0 · 본문 · NLEN)")
        transport.close(.normal)
    }

    /// 태그가 쓰기 자체를 `6F00` 으로 거절해도(Multipaz 가 캐리어를 못 찾으면 그렇게 답한다) `connectionFailed` 다
    func testWriteRejectedWithStatusWordFails() async throws {
        final class Rejecting: Iso7816Channel {
            let inner: CardBackedChannel
            init(_ c: CardBackedChannel) { inner = c }
            var isAvailable: Bool { inner.isAvailable }
            func transceive(_ apdu: Data) async throws -> Data {
                // Handover Request 본문 쓰기(오프셋 2)만 거절한다
                if apdu[apdu.startIndex + 1] == 0xD6, apdu[apdu.startIndex + 3] == 0x02 { return Data([0x6F, 0x00]) }
                return try await inner.transceive(apdu)
            }
            func close() { inner.close() }
        }
        let card = FakeCardEmulation()
        let transport = try await negotiatedCard(card) { [de, cfg] _ in HandoverSelect.build(deviceEngagement: de, carrier: .nfc(cfg)) }
        do {
            _ = try await Type4TagEngagementReader(channel: Rejecting(CardBackedChannel(card))).read(negotiated: { [cfg] _ in
                HandoverRequest.build(carriers: [.nfc(cfg)], collisionResolution: 0)
            })
            XCTFail("6F00 은 거절이다")
        } catch {
            guard case MdocProximityError.connectionFailed(let d) = error, d.contains("6f00") else { return XCTFail("\(error)") }
        }
        transport.close(.normal)
    }

    /// 태그가 제안을 거절하면(공통 캐리어 없음) Status 가 오고 리더는 `connectionFailed` 다
    func testRejectedHandoverRequestFails() async throws {
        let card = FakeCardEmulation()
        let transport = try await negotiatedCard(card) { _ in nil }
        do {
            _ = try await Type4TagEngagementReader(channel: CardBackedChannel(card)).read(negotiated: { [cfg] _ in
                HandoverRequest.build(carriers: [.nfc(cfg)], collisionResolution: 0)
            })
            XCTFail("거절은 실패다")
        } catch {
            guard case MdocProximityError.connectionFailed(let d) = error, d.contains("rejected") else { return XCTFail("\(error)") }
        }
        transport.close(.normal)
    }

    /// negotiated 를 켜지 않은 리더(`negotiated: nil`)는 그 태그에 `connectionFailed` 다 — static 으로 내려가지 않는다
    func testNegotiatedTagWithoutRequestBuilderFails() async throws {
        let card = FakeCardEmulation()
        let transport = try await negotiatedCard(card) { _ in nil }
        do {
            _ = try await Type4TagEngagementReader(channel: CardBackedChannel(card)).read()
            XCTFail("negotiated 태그에는 요청이 있어야 한다")
        } catch {
            guard case MdocProximityError.connectionFailed = error else { return XCTFail("\(error)") }
        }
        transport.close(.normal)
    }

    /// static 태그는 그대로 읽기 전용이다 — UpdateBinary 는 6982
    func testStaticTagStaysReadOnly() throws {
        var tag = Type4TagEmulator(ndefMessage: HandoverSelect.build(deviceEngagement: de, nfc: cfg))
        _ = tag.handle(Apdu.selectFile(Type4TagEmulator.ndefFileID))
        XCTAssertEqual(tag.handle(Apdu.updateBinary(offset: 0, data: Data([0, 0]))), Data([0x69, 0x82]))
        _ = tag.handle(Apdu.selectFile(Type4TagEmulator.ccFileID))
        let cc = tag.handle(Apdu.readBinary(offset: 0, length: 15))
        XCTAssertEqual(cc[cc.startIndex + 14], 0xFF, "Write 거부")
    }

    // MARK: mdoc 세션의 선택 규칙

    /// 리더가 BLE(둘 다, peripheral 선호)와 NFC 를 제안하면 mdoc 은 **리더 선호 순으로 처음 세울 수
    /// 있는 것** — central client — 을 고르고, 그 BLE 전송체를 리더의 UUID 로 세운다
    func testMdocPicksReaderPreferredBleCarrier() async throws {
        final class Stub: DataRetrievalTransportProtocol {
            let events: AsyncStream<TransportEvent>
            private let emit: AsyncStream<TransportEvent>.Continuation
            let params: TransportParameters
            init(_ p: TransportParameters) {
                params = p
                var c: AsyncStream<TransportEvent>.Continuation!; events = AsyncStream { c = $0 }; emit = c
            }
            func open(_ config: TransportConfig) async throws { emit.yield(.ready) }
            func send(_ message: Data) async throws {}
            func close(_ reason: TransportCloseReason) { emit.finish() }
        }
        final class Factory: TransportFactoryProtocol {
            var made: [TransportParameters] = []
            var availableTechnologies: [TransmissionTechnology] { [.ble(.peripheralServer), .ble(.centralClient)] }
            func makeTransport(_ p: TransportParameters) throws -> DataRetrievalTransportProtocol {
                made.append(p); return Stub(p)
            }
        }
        let card = FakeCardEmulation()
        let factory = Factory()
        let mdoc = MdocDeviceSession(transportFactory: factory, nfcCardEmulation: card)
        let payload = try await mdoc.start(technology: .nfcNegotiatedHandover)
        XCTAssertEqual(payload.technology, .nfcNegotiatedHandover)
        XCTAssertTrue(payload.transmissions.isEmpty, "캐리어는 Handover Request 를 받아야 정해진다")
        XCTAssertEqual(mdoc.state, .engaging)

        let readerUUID = Data((0..<16).map { UInt8($0 &+ 0x40) })
        let result = try await Type4TagEngagementReader(channel: CardBackedChannel(card)).read(negotiated: { [cfg] _ in
            HandoverRequest.build(carriers: [.ble(role: 0x02, serviceUUID: readerUUID), .nfc(cfg)],
                                  collisionResolution: 0x0002)
        })
        XCTAssertEqual(result.handover.carriers, [.ble(.centralClient)], "리더가 앞세운 모드를 받았다")
        XCTAssertNil(result.handover.bleServiceUUID, "central client 는 리더의 UUID 를 쓴다 — Hs 에는 없다")
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(factory.made.first?.technology, .ble(.centralClient))
        XCTAssertEqual(factory.made.first?.serviceUUID, readerUUID)
        XCTAssertNotNil(factory.made.first?.ident, "central client 는 리더의 Ident 를 대조한다")
        // BLE 후보가 서면 세션은 그쪽을 채택한다 — 카드 전송체는 닫힌다
        for _ in 0..<50 where !card.stopped { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(card.stopped, "채택되지 않은 카드는 내린다")
        mdoc.terminate()
    }

    /// `bleAdvertiseMode = .peripheralServer` 면 리더의 central 제안은 건너뛰고 peripheral server 로 답한다 —
    /// 그때는 **mdoc 이 UUID 를 정해** Hs 에 싣는다
    func testMdocHonoursAdvertiseModeAndSuppliesUUIDForPeripheral() async throws {
        final class Factory: TransportFactoryProtocol {
            var made: [TransportParameters] = []
            var availableTechnologies: [TransmissionTechnology] { [.ble(.peripheralServer), .ble(.centralClient)] }
            func makeTransport(_ p: TransportParameters) throws -> DataRetrievalTransportProtocol {
                made.append(p); return LoopbackTransport()      // ready 를 내지 않는다 — 열어만 둔다
            }
        }
        let card = FakeCardEmulation()
        let factory = Factory()
        var cfgDevice = MdocDeviceConfiguration()
        cfgDevice.bleAdvertiseMode = .peripheralServer
        let mdoc = MdocDeviceSession(configuration: cfgDevice, transportFactory: factory, nfcCardEmulation: card)
        _ = try await mdoc.start(technology: .nfcNegotiatedHandover)
        let result = try await Type4TagEngagementReader(channel: CardBackedChannel(card)).read(negotiated: { _ in
            HandoverRequest.build(carriers: [.ble(role: 0x02, serviceUUID: Data(repeating: 1, count: 16))],
                                  collisionResolution: 0)
        })
        XCTAssertEqual(result.handover.carriers, [.ble(.peripheralServer)])
        XCTAssertEqual(result.handover.bleServiceUUID?.count, 16, "peripheral server 는 mdoc 의 UUID")
        XCTAssertEqual(factory.made.first?.serviceUUID, result.handover.bleServiceUUID)
        mdoc.terminate()
    }

    // MARK: 두 세션이 negotiated 로 끝까지 — NFC 캐리어

    func testEndToEndNegotiatedOverNfc() async throws {
        let issuerKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let did = "did:omn:issuer"
        let card = FakeCardEmulation()
        let holder = NfcCardEmulationTests.Holder(issuerKey: issuerKey, deviceKey: deviceKey, did: did)
        let mdoc = MdocDeviceSession(nfcCardEmulation: card)
        mdoc.delegate = holder
        _ = try await mdoc.start(technology: .nfcNegotiatedHandover)
        SessionRegistry.release()

        let trust = DIDIssuerKeyResolver(trustedIssuers: [did]) { _, _ in issuerKey.publicKey.x963Representation }
        var cfgReader = verifyingReaderConfiguration(responseTimeout: 3)
        cfgReader.transmissionPriority = [.nfc]                     // 제안도 NFC 하나 — BLE 는 한 프로세스에서 못 돈다
        let reader = MdocReaderSession(configuration: cfgReader, trust: trust,
                                       transportFactory: ReaderTransportFactory(),
                                       nfcTagSource: CardBackedTagSource(card: card))
        let engagement = try await reader.connectViaNFC()
        XCTAssertEqual(engagement.technology, .nfcNegotiatedHandover)
        XCTAssertEqual(engagement.transmissions, [.nfc])
        XCTAssertNotNil(engagement.handover?.handoverRequestBytes)
        XCTAssertEqual(reader.state, .connected)

        let result = try await reader.request([ItemsRequestPresets.identity], at: Date())
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.documents[0].verdict, .valid, "[Hs, Hr] 트랜스크립트가 양쪽에서 같다")
        XCTAssertNil(holder.failure)
        for _ in 0..<50 where mdoc.state != .completed { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(mdoc.state, .completed)
        reader.terminate(); mdoc.terminate()
    }
}
