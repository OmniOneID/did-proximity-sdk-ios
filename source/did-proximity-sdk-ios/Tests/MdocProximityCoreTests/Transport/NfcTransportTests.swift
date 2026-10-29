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
@_spi(MdocInternal) @testable import MdocNFC
@_spi(MdocInternal) @testable import MdocReader

/// 태그 흉내. **APDU 순서를 그대로 기록**하므로 NFC 읽기 순서가 어긋나면 여기서 걸린다.
final class FakeTag: Iso7816Channel {
    private(set) var commands: [String] = []
    private(set) var closed = false
    var ndefMessage: Data
    var writableCC: Bool
    var selectsMdocAid = true
    /// data retrieval 단계에서 돌려줄 응답. `nil` 이면 빈 응답이다
    var envelopeReply: Data?
    /// 태그가 자기장 안에 있는가 — 테스트가 `false` 로 바꿔 이탈을 흉내 낸다
    var available = true
    var isAvailable: Bool { available }
    private var selectedFile: UInt16 = 0

    init(ndefMessage: Data, writableCC: Bool = false) {
        self.ndefMessage = ndefMessage
        self.writableCC = writableCC
    }

    private var ccFile: Data {
        Data([0x00, 0x0F, 0x20, 0x00, 0x3B, 0x00, 0x34, 0x04, 0x06,
              0xE1, 0x04, 0x04, 0x00, 0x00, writableCC ? 0x00 : 0xFF])
    }
    private var ndefFile: Data {
        Data([UInt8(ndefMessage.count >> 8), UInt8(ndefMessage.count & 0xff)]) + ndefMessage
    }

    func transceive(_ apdu: Data) async throws -> Data {
        commands.append(apdu.hex)
        let ins = apdu[apdu.startIndex + 1]
        switch ins {
        case 0xA4 where apdu[apdu.startIndex + 2] == 0x04:            // SELECT by name
            let aid = apdu.suffix(from: apdu.startIndex + 5)
            if aid == NfcAid.mdocDataRetrieval, !selectsMdocAid { return Data([0x6A, 0x82]) }
            return Data([0x90, 0x00])
        case 0xA4:                                                     // SELECT by file id
            selectedFile = UInt16(apdu[apdu.startIndex + 5]) << 8 | UInt16(apdu[apdu.startIndex + 6])
            return Data([0x90, 0x00])
        case 0xB0:                                                     // ReadBinary
            let offset = Int(apdu[apdu.startIndex + 2]) << 8 | Int(apdu[apdu.startIndex + 3])
            let length = Int(apdu[apdu.startIndex + 4])
            let file = selectedFile == 0xE103 ? ccFile : ndefFile
            guard offset + length <= file.count else { return Data([0x6A, 0x82]) }
            return file.subdata(in: offset..<(offset + length)) + Data([0x90, 0x00])
        case 0xC3:                                                     // ENVELOPE
            guard apdu[apdu.startIndex] == 0x00 else { return Data([0x90, 0x00]) }  // 체인 중
            guard let reply = envelopeReply else { return Data([0x90, 0x00]) }
            return Apdu.berTlv53(reply) + Data([0x90, 0x00])
        default: return Data([0x6D, 0x00])
        }
    }

    func close() { closed = true }
}

final class NfcTransportTests: XCTestCase {

    override func setUp() { super.setUp(); MdocCapabilities.assumeAllSupportedForTests() }

    override func tearDown() { SessionRegistry.release() }

    // MARK: NDEF

    /// 레코드는 **타입으로 찾는다** — 순서는 규정되어 있지 않다.
    func testFindsEngagementRecordRegardlessOfOrder() throws {
        let engagement = Data([0xa1, 0x00, 0x63, 0x31, 0x2e, 0x30])
        let message = Ndef.encode([
            NdefRecord(typeNameFormat: 0x01, type: Data("Hs".utf8), id: Data(),
                       payload: Data([0x15])),
            NdefRecord(typeNameFormat: 0x04, type: Ndef.deviceEngagementType,
                       id: Data("mdoc".utf8), payload: engagement)
        ])
        let records = try Ndef.parse(message)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Ndef.deviceEngagement(in: records), engagement)
    }

    /// 256바이트를 넘으면 SR 이 꺼지고 길이가 4바이트가 된다 — 그 경계를 넘겨 본다
    func testParsesLongRecord() throws {
        let payload = Data(repeating: 0x7f, count: 300)
        let records = try Ndef.parse(Ndef.encode([
            NdefRecord(typeNameFormat: 0x04, type: Ndef.deviceEngagementType,
                       id: Data(), payload: payload)]))
        XCTAssertEqual(records.first?.payload, payload)
    }

    func testRejectsTruncatedMessage() {
        XCTAssertThrowsError(try Ndef.parse(Data([0xd4, 0x05, 0x10])))
    }

    /// NLEN 0xFFFF 근처 + 작은 MLe — ReadBinary 오프셋(P1P2 두 바이트)이 넘치면 트랩이 아니라
    /// `malformedEngagement` 다. 태그가 준 값이다
    func testNdefOffsetPastP1P2RangeIsRejected() async throws {
        let tag = FakeTag(ndefMessage: Data(repeating: 0x00, count: 0xFFFF))
        do {
            _ = try await Type4TagEngagementReader(channel: tag).readBinary(offset: 0xFFFE, length: 4, unit: 2)
            XCTFail("오프셋 0x10000 은 두 바이트에 안 담긴다")
        } catch {
            guard case MdocProximityError.malformedEngagement(let d) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(d.contains("offset"), d)
        }
    }

    // MARK: Type 4 Tag 읽기 순서

    /// `SELECT AID → CC → ReadBinary → NDEF → NLEN → 본문` 순서다.
    /// **NLEN 을 먼저 읽는다** — 한 번에 최대 크기로 읽으면 빈 태그에서 실패한다.
    func testReadsFilesInOrder() async throws {
        let tag = FakeTag(ndefMessage: Self.handoverMessage())
        let result = try await Type4TagEngagementReader(channel: tag).read()

        XCTAssertEqual(Array(tag.commands.prefix(5)), [
            "00a4040c07d2760000850101",     // SELECT NDEF Tag Application
            "00a4000c02e103",               // SELECT CC
            "00b000000f",                   // ReadBinary CC 15바이트
            "00a4000c02e104",               // SELECT NDEF (CC 가 알려준 File ID)
            "00b0000002"                    // NLEN 2바이트 — **본문보다 먼저다**
        ])
        // 본문은 **CC 의 `MLe`(0x3B = 59) 단위**로 잘려 나간다. 상수로 가정하면 안 되는 값이
        // 여기서 실제로 쓰인다
        let body = Array(tag.commands.dropFirst(5))
        XCTAssertEqual(body, ["00b000023b", "00b0003d3b", "00b000781b"])
        XCTAssertEqual(59 + 59 + 27, result.handoverSelectBytes.count)
        XCTAssertFalse(result.writable, "Write FF 면 static 만 가능하다")
        XCTAssertEqual(result.handoverSelectBytes, tag.ndefMessage,
                       "트랜스크립트 재료는 읽은 NDEF 메시지 전체다")
    }

    /// `6A82` 는 **에러가 아니다** — 그 태그가 mdoc 이 아닐 뿐이다.
    func testNonMdocTagIsNotAFailure() async {
        final class Empty: Iso7816Channel {
            func transceive(_ apdu: Data) async throws -> Data { Data([0x6A, 0x82]) }
            var isAvailable: Bool { true }
            func close() {}
        }
        do {
            _ = try await Type4TagEngagementReader(channel: Empty()).read()
            XCTFail("mdoc 이 아닌 태그는 읽히면 안 된다")
        } catch {
            XCTAssertTrue(error is Type4TagEngagementReader.NotAnMdocTag)
        }
    }

    // MARK: ENVELOPE 체이닝

    /// 한계를 넘는 메시지는 체인으로 나가고, 응답은 `53` TLV 에서 꺼낸다.
    func testEnvelopeChainAndResponseUnwrap() async throws {
        let tag = FakeTag(ndefMessage: Data())
        tag.envelopeReply = Data(repeating: 0xEE, count: 5)
        let transport = NfcDataRetrievalTransport(channel: tag,
                                                  maxCommandDataLength: 10,
                                                  maxResponseDataLength: 256)
        try await transport.open(TransportConfig(role: .mdocReader))
        let inbox = TransportEventRouter(transport)
        inbox.start()
        try await transport.send(Data(repeating: 0xAA, count: 20))

        let message = await inbox.nextMessage()
        XCTAssertEqual(message, tag.envelopeReply, "53 TLV 를 벗겨 올려야 한다")
        // SELECT + 체인 3개
        XCTAssertEqual(tag.commands.count, 4)
        XCTAssertEqual(tag.commands[0], "00a4040c07a0000002480400")
        XCTAssertTrue(tag.commands[1].hasPrefix("10c3"), "체인 중이면 CLA 10")
        XCTAssertTrue(tag.commands[3].hasPrefix("00c3"), "마지막은 CLA 00")
    }

    /// 태그가 자기장을 떠나면 **명령을 보내지 않아도** `peerClosed` 가 올라온다 — CoreNFC 가
    /// 이탈을 밀어주지 않으므로 전송체가 `isAvailable` 을 폴링한다.
    func testTagDepartureSurfacesWithoutACommand() async throws {
        let tag = FakeTag(ndefMessage: Data())
        let transport = NfcDataRetrievalTransport(channel: tag, maxCommandDataLength: 255,
                                                  maxResponseDataLength: 256,
                                                  presenceInterval: 0.02)
        try await transport.open(TransportConfig(role: .mdocReader))
        var closed = false
        let seen = XCTestExpectation(description: "peerClosed")
        let pump = Task {
            for await event in transport.events {
                if case .peerClosed = event { closed = true; seen.fulfill(); break }
            }
        }
        tag.available = false                       // 폰을 뗐다
        await fulfillment(of: [seen], timeout: 2)
        pump.cancel()
        XCTAssertTrue(closed)
        XCTAssertEqual(tag.commands.count, 1, "SELECT 뒤로 명령 없이 감지해야 한다")
        transport.close(.normal)
    }

    /// mdoc AID 를 못 고르면 연결 실패다 — iOS 가 이 AID 의 SELECT 를 막으면 실기기에서 여기로 온다.
    func testOpenFailsWhenMdocAidIsRejected() async {
        let tag = FakeTag(ndefMessage: Data())
        tag.selectsMdocAid = false
        let transport = NfcDataRetrievalTransport(channel: tag, maxCommandDataLength: 255,
                                                  maxResponseDataLength: 256)
        do {
            try await transport.open(TransportConfig(role: .mdocReader))
            XCTFail("SELECT 가 6A82 면 열리면 안 된다")
        } catch {
            guard case .connectionFailed = error as? MdocProximityError ?? .peerDisconnected else {
                return XCTFail("connectionFailed 여야 한다: \(error)")
            }
        }
    }

    /// negotiated 태그는 **조용히 static 으로 내려가지 않는다** — 같은 태그에서 두 방식을
    /// 섞으면 mdoc 쪽 상태가 어긋난다. Handover Request 를 만들 쪽이 없으면(`negotiated: nil`)
    /// 명시적으로 실패한다. 왕복 자체는 `NfcNegotiatedHandoverTests` 다.
    func testNegotiatedTagWithoutRequestFailsExplicitly() async {
        let serviceParameter = Tnep.ServiceParameter(serviceName: Ndef.handoverServiceName, waitTimeCode: 1,
                                                     maxWaitExtensions: 1, maxMessageSize: 10).record
        let tag = FakeTag(ndefMessage: Ndef.encode([serviceParameter]), writableCC: true)
        do {
            _ = try await Type4TagEngagementReader(channel: tag).read()
            XCTFail("negotiated 태그를 static 으로 읽으면 안 된다")
        } catch {
            guard case .connectionFailed(let detail) = error as? MdocProximityError ?? .peerDisconnected,
                  detail.contains("negotiated") else {
                return XCTFail("negotiated 를 요청 없이 읽은 것이 드러나야 한다: \(error)")
            }
        }
    }

    // MARK: connectViaNFC — 링크 연속성

    /// **읽기와 연결이 한 호출이고, 링크가 이어진다**.
    /// 같은 채널로 mdoc AID SELECT 가 이어지는지를 명령 기록으로 확인한다.
    func testConnectViaNFCKeepsTheLink() async throws {
        let tag = FakeTag(ndefMessage: Self.handoverMessage())
        let reader = MdocReaderSession(
            trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
            transportFactory: ReaderTransportFactory(),
            nfcTagSource: FixedSource(tag))

        let payload = try await reader.connectViaNFC()

        XCTAssertEqual(reader.state, .connected)
        XCTAssertEqual(payload.technology, .nfcStaticHandover)
        XCTAssertEqual(payload.transmissions, [.nfc])
        XCTAssertFalse(tag.closed, "링크 연속성 — engagement 에 쓴 링크를 그대로 유지한다")
        XCTAssertEqual(tag.commands.last, "00a4040c07a0000002480400",
                       "같은 채널에서 data retrieval AID 로 갈아 끼운다")
    }

    /// **탭은 됐는데 읽기가 실패하면 채널을 닫아야 한다.** 안 닫으면 iOS 의 NFC 세션이 열린 채
    /// 남아 다음 `begin()` 이 203 으로 재부팅 전까지 전부 실패한다 — 실기기에서 "재부팅당 NFC
    /// 한 번" 으로 나타났다 (리더 앱 세션 보고, 2026-09-14). 성공·사용자 취소·미검출은 iOS 가
    /// 스스로 invalidate 하므로 이 경로만 SDK 책임이다.
    func testConnectViaNFCClosesChannelWhenReadFails() async throws {
        let tag = FakeTag(ndefMessage: Data([0xFF]))   // NDEF 로 해석되지 않는 본문 — 읽기 실패
        let reader = MdocReaderSession(
            trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
            transportFactory: ReaderTransportFactory(),
            nfcTagSource: FixedSource(tag))
        do {
            try await reader.connectViaNFC()
            XCTFail("읽기가 실패해야 한다")
        } catch {
            XCTAssertTrue(tag.closed, "탭 뒤 실패 경로에서 채널을 닫지 않으면 NFC 세션이 샌다")
            XCTAssertEqual(reader.state, .failed)
        }
        SessionRegistry.release()
    }

    /// 읽기는 됐지만 **전송을 고르지 못한** 경우도 같다 — 전송체가 채널을 인수하기 전이라
    /// `establish` 가 직접 닫아야 한다. mdoc 이 NFC 만 광고했는데 리더가 목록에서 NFC 를 뺐다.
    func testEstablishClosesChannelWhenNoTransportSelected() async throws {
        let tag = FakeTag(ndefMessage: Self.handoverMessage())
        var cfg = MdocReaderConfiguration()
        cfg.transmissionPriority = [.ble]
        let reader = MdocReaderSession(
            configuration: cfg,
            trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
            transportFactory: ReaderTransportFactory(),
            nfcTagSource: FixedSource(tag))
        do {
            try await reader.connectViaNFC()
            XCTFail("고를 전송이 없어야 한다")
        } catch {
            XCTAssertEqual(error as? MdocProximityError, .unsupportedTransmissionTechnology)
            XCTAssertTrue(tag.closed, "전송체 인수 전 실패 — 채널은 establish 가 닫는다")
        }
        SessionRegistry.release()
    }

    /// **탭 전에 그만두는 경로.** 시트가 떠 있는 동안 `connectViaNFC` Task 가 취소되면 대기가
    /// `CancellationError` 로 끝나고 소스의 `cancel()` 이 불려야 한다 — 안 그러면 플랫폼 세션이
    /// NFC 를 점유한 채 남아 다음 `openChannel` 이 `noHardware` 다 (리더 앱 세션 보고, 2026-09-14).
    /// 14:48 의 누수 수정(채널이 생긴 뒤 실패)과 다른 경로다.
    func testCancellingBeforeTapCancelsTheSource() async throws {
        let source = NeverTapsSource()
        let reader = MdocReaderSession(
            trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
            transportFactory: ReaderTransportFactory(), nfcTagSource: source)
        let task = Task { try await reader.connectViaNFC() }
        for _ in 0..<50 where !source.opened { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(source.opened, "시트가 떠 있는 상태를 만든다")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("취소로 끝나야 한다")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(source.cancelCount, 1, "Task 취소가 소스의 cancel() 로 이어진다")
        XCTAssertEqual(reader.state, .terminated, "취소는 오류가 아니다 — terminate() 와 같은 상태")
        XCTAssertFalse(SessionRegistry.isActive, "등록도 풀려 다음 세션이 바로 열린다")
    }

    /// **명령 중 링크가 떨어지면 `peerDisconnected` 다** — CoreNFC 의 전송 오류(100·101·103·104)가 그대로
    /// 앱에 가면 SDK 밖 어휘가 새는 것이다. RF 결합이 나쁠 때 "Tag is not connected"(104) /
    /// "Session invalidated"(103) 로 여섯 번 재현됐다(리더 앱 실기, 2026-09-16).
    func testTransceiveErrorsMapToSdkVocabulary() {
        for code in [100, 101, 103, 104] {
            XCTAssertEqual(NfcTransceiveFailure.error(domain: "NFCError", code: code, description: "x"),
                           .peerDisconnected, "code \(code)")
        }
        for code in [102, 105, 2] {
            guard case .connectionFailed = NfcTransceiveFailure.error(domain: "NFCError", code: code, description: "x")
            else { return XCTFail("code \(code) 는 connectionFailed") }
        }
        XCTAssertEqual(NfcTransceiveFailure.error(domain: "Other", code: 104, description: "x"),
                       .connectionFailed(detail: "NFC transceive: x"), "도메인이 다르면 링크 상실이 아니다")
    }

    /// **시트에서 사용자가 취소한 것은 오류가 아니다.** CoreNFC 는 이것도 `didInvalidateWithError`
    /// (Code 200) 로 주는데, 다른 무효화(60초 미검출 201 · 엔타이틀먼트 2)와 같이 `connectionFailed`
    /// 로 던지면 앱이 "연결이 끊겼다" 안내를 띄운다(리더 앱 실기, 2026-09-16). 사용자 취소만
    /// `CancellationError` + `terminated`.
    func testUserCancelOnSheetIsCancellationNotFailure() async throws {
        let userCancel = NfcSessionInvalidation.error(domain: "NFCError", code: 200,
                                                      description: "Session invalidated by user")
        XCTAssertTrue(userCancel is CancellationError)
        let timeout = NfcSessionInvalidation.error(domain: "NFCError", code: 201, description: "timeout")
        XCTAssertEqual(timeout as? MdocProximityError, .connectionFailed(detail: "NFC session: timeout"))
        let entitlement = NfcSessionInvalidation.error(domain: "NFCError", code: 2, description: "missing entitlement")
        guard case MdocProximityError.connectionFailed? = entitlement as? MdocProximityError else { return XCTFail("\(entitlement)") }
        let otherDomain = NfcSessionInvalidation.error(domain: "Other", code: 200, description: "x")
        XCTAssertFalse(otherDomain is CancellationError, "도메인이 다르면 200 도 취소가 아니다")

        // 세션 끝까지 — 소스가 사용자 취소로 끝나면 connectViaNFC 는 CancellationError, 상태는 terminated
        let source = InvalidatingSource(error: userCancel)
        let reader = MdocReaderSession(
            trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
            transportFactory: ReaderTransportFactory(), nfcTagSource: source)
        do { _ = try await reader.connectViaNFC(); XCTFail("취소로 끝나야 한다") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(reader.state, .terminated)
        XCTAssertFalse(SessionRegistry.isActive)

        // 60초 미검출은 그대로 failed 다
        let reader2 = MdocReaderSession(
            trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
            transportFactory: ReaderTransportFactory(), nfcTagSource: InvalidatingSource(error: timeout))
        do { _ = try await reader2.connectViaNFC(); XCTFail("실패로 끝나야 한다") }
        catch { XCTAssertEqual(error as? MdocProximityError, .connectionFailed(detail: "NFC session: timeout")) }
        XCTAssertEqual(reader2.state, .failed)
        SessionRegistry.release()
    }

    /// Task 를 취소하지 않고 **`terminate()` 만** 부르는 앱도 있다 — 그때도 시트는 내려가야 한다.
    /// 그리고 catch 가 `terminated` 를 `failed` 로 덮거나 다음 세션의 등록을 지우면 안 된다.
    func testTerminateWhileWaitingForTapCancelsTheSource() async throws {
        let source = NeverTapsSource()
        let reader = MdocReaderSession(
            trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
            transportFactory: ReaderTransportFactory(), nfcTagSource: source)
        let task = Task { try await reader.connectViaNFC() }
        for _ in 0..<50 where !source.opened { try await Task.sleep(nanoseconds: 10_000_000) }
        reader.terminate()
        XCTAssertEqual(source.cancelCount, 1, "connecting 에서의 terminate 는 소스를 닫는다")
        _ = try? await task.value
        XCTAssertEqual(reader.state, .terminated, "terminate 가 정한 상태를 catch 가 덮지 않는다")
        // terminate 가 등록을 풀었으니 다음 세션이 바로 열려야 하고, 늦게 끝난 catch 가 그 등록을
        // 지우지 않아야 한다
        XCTAssertNoThrow(try SessionRegistry.claim("next"))
        SessionRegistry.release()
    }

    /// 트랜스크립트 셋째 원소가 **`null` 이 아니라 `NFCHandover`** 여야 한다 (9.1.5.1).
    func testNfcTranscriptCarriesHandover() throws {
        let payload = try EngagementPayload.make(
            Self.engagementBytes(), technology: .nfcStaticHandover,
            handover: EngagementArtifacts(handoverSelectBytes: Data([0x01, 0x02]),
                                          handoverRequestBytes: nil))
        let transcript = payload.sessionTranscript(
            eReaderKeyBytes: OpaqueCBOR(preserving: CborEncoder.tag24(Data([0xa0]))))
        let array = try CborDecoder.decode(try SessionTranscriptBuilder.transcriptArray(transcript))
        guard case .array(let elements) = array, elements.count == 3 else {
            return XCTFail("SessionTranscript 는 3원소 배열이다")
        }
        XCTAssertEqual(elements[2], .array([.bytes(Data([0x01, 0x02])), .null]))
    }

    // MARK: -

    /// 시트만 띄우고 탭이 오지 않는 소스 — 취소 경로를 만든다
    /// 시트를 여는 쪽(세션 Task)과 들여다보는 쪽(테스트)이 다른 스레드라 잠금으로 묶는다
    private final class NeverTapsSource: NfcTagSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _opened = false
        private var _cancelCount = 0
        private var waiter: CheckedContinuation<Iso7816Channel, Error>?
        var opened: Bool { lock.withLock { _opened } }
        var cancelCount: Int { lock.withLock { _cancelCount } }
        func openChannel() async throws -> Iso7816Channel {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { c in
                    lock.withLock {
                        _opened = true
                        waiter = c
                    }
                }
            } onCancel: {
                cancel()
            }
        }
        func cancel() {
            let w = lock.withLock { () -> CheckedContinuation<Iso7816Channel, Error>? in
                _cancelCount += 1
                let w = waiter; waiter = nil
                return w
            }
            w?.resume(throwing: CancellationError())
        }
    }

    /// 시트가 무효화로 끝나는 소스 — CoreNFC 의 `didInvalidateWithError` 자리
    private struct InvalidatingSource: NfcTagSource {
        let error: Error
        func openChannel() async throws -> Iso7816Channel { throw error }
    }

    private struct FixedSource: NfcTagSource {
        let tag: FakeTag
        init(_ tag: FakeTag) { self.tag = tag }
        func openChannel() async throws -> Iso7816Channel { tag }
    }

    /// 탭마다 다른 태그를 준다 — 첫 탭은 mdoc 이 아닌 태그, 그 다음이 mdoc
    private final class SequenceSource: NfcTagSource {
        var tags: [Iso7816Channel]
        private(set) var opened = 0
        init(_ tags: [Iso7816Channel]) { self.tags = tags }
        func openChannel() async throws -> Iso7816Channel { opened += 1; return tags.removeFirst() }
    }

    /// mdoc 이 아닌 태그(SELECT 6A82)는 놓고 다음 탭을 받는다. 세션은 실패하지 않고
    /// `connecting` 에 머물다 다음 태그로 이어진다 (BLE Ident 불일치와 대칭).
    func testNonMdocTagKeepsPollingInsideSession() async throws {
        final class Foreign: Iso7816Channel {
            private(set) var closed = false
            func transceive(_ apdu: Data) async throws -> Data { Data([0x6A, 0x82]) }
            var isAvailable: Bool { true }
            func close() { closed = true }
        }
        let foreign = Foreign()
        let mdocTag = FakeTag(ndefMessage: Self.handoverMessage())
        mdocTag.envelopeReply = nil
        let source = SequenceSource([foreign, mdocTag])
        let reader = MdocReaderSession(trust: DIDIssuerKeyResolver(trustedIssuers: []) { _, _ in Data() },
                                       transportFactory: ReaderTransportFactory(), nfcTagSource: source)
        let payload = try await reader.connectViaNFC()
        XCTAssertEqual(payload.technology, .nfcStaticHandover)
        XCTAssertEqual(source.opened, 2, "첫 태그를 놓고 두 번째 탭을 받아야 한다")
        XCTAssertTrue(foreign.closed, "놓은 태그의 채널은 닫는다")
        XCTAssertEqual(reader.state, .connected)
        reader.terminate()
    }

    /// NFC data retrieval 만 광고하는 mdoc — 링크 연속성가 작동하는 최소 형태다.
    private static func engagementBytes() -> Data {
        try! EngagementCodec.encode(
            eDeviceKeyBytes: EphemeralKeyPair().keyBytes,
            retrievalMethods: [DeviceRetrievalMethod(type: 1, version: 1, options: .map([
                CborPair(.unsigned(0), .unsigned(255)),
                CborPair(.unsigned(1), .unsigned(256))]))])
    }

    private static func handoverMessage() -> Data {
        Ndef.encode([
            NdefRecord(typeNameFormat: 0x01, type: Data("Hs".utf8), id: Data(), payload: Data([0x15])),
            NdefRecord(typeNameFormat: 0x04, type: Ndef.deviceEngagementType,
                       id: Data("mdoc".utf8), payload: engagementBytes())
        ])
    }
}
