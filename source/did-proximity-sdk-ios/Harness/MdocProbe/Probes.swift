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
import CoreBluetooth
import CryptoKit
// 프로브는 전송 계층을 직접 찌른다 — 앱 표면이 아니라 **SPI** 다.
// 앱이 이 import 를 쓸 일은 없다.
@_spi(MdocInternal) import MdocProximitySDK

/// 각 프로브는 **하나의 미결 항목**에 답한다.
@MainActor
final class Probes: ObservableObject {

    @Published var qrString: String?
    /// **L2CAP 측정 스위치.** 켜면 mdoc 이 PSM 을 게시하고 리더가 같은 모드 안에서 L2CAP 을
    /// 먼저 시도한다. 꺼져 있으면 순수 GATT 라 GATT 측정과 변수가 같다.
    @Published var l2capUpgrade = false
    /// 화면이 정한 역할. **로그에도 실린다** — 두 대를 나란히 놓고 보면 어느 쪽 기록인지
    /// 헷갈리는 것이 이 시험에서 제일 잦은 사고였다
    @Published var role: ProbeRole = .mdoc
    /// QR 팝업이 떠 있는가. **연결되면 스스로 닫힌다** — 붙은 뒤에도 QR 이 떠 있으면
    /// 기기를 다시 집어 화면을 내려야 로그를 볼 수 있다
    @Published var showQR = false
    @Published var connected = false
    /// mdoc 이 광고할 모드. **좁히기 전용 정책**(`advertisedTransmissions`)으로 나간다 —
    /// 표준상 mdoc 은 C(a) 라 하나만 광고해도 적합하다
    @Published var advertiseMode: BleAdvertiseMode = .both
    /// 리더가 상대의 두 GATT 모드 중 무엇을 앞세울지. SDK 기본과 같은 peripheral 로 시작하고,
    /// central 로 바꾸면 같은 mdoc 상대로 반대 모드를 실기기에서 돌려 볼 수 있다
    @Published var preferredMode: BleModePreference = .peripheral
    /// 응답에 `portrait` 20 KiB 를 실을지. **SDK 설정이 아니라 시험 부하다** — 전송 계층은
    /// 크기에 따라 갈리는 것을 자동으로 한다(GATT 는 프래그멘테이션, L2CAP 은 길이 헤더).
    /// 프래그멘테이션이 실제로 도는 크기여야 L2CAP 비교가 성립한다
    @Published var includePortrait = false
    /// 켜면 리더가 정상 요청 **앞에** 입구 포맷 오류를 일부러 두 번 낸다(빈 목록·`docType` 중복).
    /// 둘 다 세션을 소비하지 않아야 같은 세션의 정상 요청이 성공한다
    @Published var probeEntryRetry = false
    private var mdoc: MdocDeviceSession?
    private var reader: MdocReaderSession?
    private var wallet: WalletStub?
    private var advertiser: BleAdvertiseProbe?
    private var readerObserver: ReaderObserver?

    func reset() {
        showQR = false
        connected = false
        mdoc?.terminate(); reader?.terminate()
        mdoc = nil; reader = nil; wallet = nil; advertiser = nil
        qrString = nil
        SessionRegistry.release()
    }

    // MARK: 1 — NFC mdoc AID SELECT

    /// **엔타이틀먼트 거부는 태그에 닿기 전에 난다.** 그래서 mdoc 이 없어도 답이 나온다 —
    /// 아무 ISO7816 카드에 SELECT 를 보내 SW 가 돌아오면 "허용됨"이다.
    func nfcSelect(_ log: ProbeLog) async {
        log.running = "nfc"; defer { log.running = nil }
        log.info("태그를 대 주세요 — 어떤 ISO7816 카드든 됩니다")
        do {
            let source = CoreNfcTagSource()
            source.onTagSeen = { [weak log] seen in
                Task { @MainActor in log?.info(seen) }
            }
            let channel = try await source.openChannel()
            defer { channel.close() }
            let response = try await channel.transceive(Apdu.selectByName(NfcAid.mdocDataRetrieval))
            let sw = String(format: "%04x", Apdu.statusWord(response))
            // 6a82(파일 없음)·6d00(미지원)도 **허용됐다는 증거**다 — 카드가 답한 것이므로
            log.pass("SELECT A0000002480400 이 나갔다 — SW \(sw)")
            log.info("→ 닫힘: iOS 가 이 AID 의 SELECT 를 막지 않는다")

            // 명령 없이 `isAvailable` 만으로 이탈이 잡히는가. SDK 의 NFC 유휴 감지가
            // 이 값에 기대므로, 실기기에서 실제로 false 로 바뀌는지와 얼마나 늦는지를 잰다
            log.info("이제 카드를 떼 주세요 — 10초 안에 이탈이 잡히는지 봅니다")
            let departed = Date()
            var ticks = 0
            while channel.isAvailable, ticks < 40 {
                try await Task.sleep(nanoseconds: 250_000_000); ticks += 1
            }
            if channel.isAvailable {
                log.fail("10초 동안 isAvailable 이 true 로 남았다 — 폴링 감지가 이 기기에서 성립하지 않는다")
            } else {
                log.pass("태그 이탈 감지 — isAvailable=false, \(ms(since: departed)) (폴링 250ms)")
                log.info("→ 닫힘: 명령 없이도 이탈이 보인다")
            }
        } catch {
            log.fail("SELECT 실패 — \(error)")
            log.info("→ Code=2(Missing required entitlement) 면 D.9 #2 는 부정. "
                     + "Code=204(timeout) 면 태그가 전달되지 않은 것이고 카드 문제다")
        }
    }

    // MARK: 2 — 지원 매트릭스

    func bleAdvertise(_ log: ProbeLog) async {
        log.running = "ble"; defer { log.running = nil }
        let probe = BleAdvertiseProbe()
        advertiser = probe
        switch await probe.run() {
        case .success(let detail): log.pass("광고 + GATT server 열림 — \(detail)")
        case .failure(let error): log.fail("열리지 않음 — \(error.localizedDescription)")
        }
    }

    // MARK: 3·5 — GATT / L2CAP

    func startMdoc(_ log: ProbeLog) async {
        log.running = "mdoc"; defer { log.running = nil }
        let large = includePortrait
        reset()
        let stub = WalletStub(large: large)
        wallet = stub
        var configuration = MdocDeviceConfiguration()
        configuration.bleAdvertiseMode = advertiseMode
        configuration.l2capUpgrade = l2capUpgrade       // 앱이 쓰는 생성자로 간다
        let session = MdocDeviceSession(configuration: configuration)
        session.delegate = stub
        session.onTransportEvent = { [weak self, weak log] event in
            Probes.note(event, "mdoc", log)
            // 링크가 서면 QR 은 할 일이 끝났다
            if case .ready = event {
                Task { @MainActor in self?.connected = true; self?.showQR = false }
            }
        }
        session.onCandidateEvent = { [weak log] label, event in
            Probes.note(event, "mdoc/" + label.replacingOccurrences(of: "MdocProximitySDK.", with: ""), log)
        }
        mdoc = session
        stub.log = log
        do {
            let payload = try await session.start(technology: .qr)
            qrString = payload.qrString
            showQR = payload.qrString != nil
            log.pass("[\(role.short)/\(advertiseMode.title)] engagement 생성 — 광고: \(payload.transmissions)"
                     + (l2capUpgrade ? " · L2CAP 승격 켬" : " · GATT"))
            log.info(large ? "portrait 포함 응답으로 시간을 잰다" : "리더가 붙기를 기다린다")
        } catch {
            log.fail("start 실패 — \(error)")
        }
    }

    // MARK: 6 — 카드 에뮬레이션 주입 (iOS 17.4+ CardSession)

    /// **인가받은 앱의 자리를 하네스가 대신 밟아 본다.** 이 앱엔 HCE 엔타이틀먼트가 없으므로
    /// 실기기 결과는 `CardSession()` 이 던지는 지점까지다 — 그 앞(isSupported · isEligible)과
    /// 던지는 이유(엔타이틀먼트 / 지역)가 답이다. 인가받은 앱에서는 그대로 engagement 가 선다.
    /// - Parameter negotiated: `true` 면 TNEP(negotiated handover)로 — 리더가 Handover Request 를 써
    ///   넣고 이 mdoc 이 캐리어를 고른다. BLE 를 고르면 그때 BLE 가 선다
    func nfcCard(_ log: ProbeLog, negotiated: Bool = false) async {
        log.running = "nfccard"; defer { log.running = nil }
        reset()
        guard #available(iOS 17.4, *) else { return log.fail("CardSession 은 iOS 17.4+ 다") }
        let emulation = CardSessionEmulation()
        emulation.onNote = { [weak log] in let t = $0; Task { @MainActor in log?.info("[card] " + t) } }
        let stub = WalletStub(large: false)
        wallet = stub
        stub.log = log
        let session = MdocDeviceSession(configuration: MdocDeviceConfiguration(),
                                        nfcCardEmulation: emulation)
        session.delegate = stub
        session.onTransportEvent = { [weak log] in Probes.note($0, "mdoc/nfc", log) }
        mdoc = session
        do {
            let payload = try await session.start(technology: negotiated ? .nfcNegotiatedHandover : .nfcStaticHandover)
            log.pass(negotiated
                     ? "NFC negotiated engagement 생성 — 캐리어는 리더의 Handover Request 를 받아 정한다. 리더를 대 주세요"
                     : "NFC engagement 생성 — 캐리어: \(payload.transmissions). 리더를 대 주세요")
        } catch MdocProximityError.nfcUnavailable(let reason) {
            log.fail("카드 에뮬레이션 불가 — \(reason)")
            log.info(reason == .vendorPolicy
                     ? "→ 엔타이틀먼트(com.apple.developer.nfc.hce) 미보유 또는 지역 미지원. 인가받은 앱에서만 열린다"
                     : "→ 이 기기에 카드 에뮬레이션 하드웨어 지원이 없다")
        } catch {
            log.fail("start 실패 — \(error)")
            log.info("→ CardSession() 이 던졌다면 엔타이틀먼트 문제다. 인가 후 같은 코드로 다시 잰다")
        }
    }

    /// 리더 쪽 짝 — **NFC 로 읽고 같은 링크로 요청까지**. 상대가 Android HCE 든 인가받은
    /// iOS 앱이든 같다.
    func runReaderNFC(_ log: ProbeLog) async {
        log.running = "reader"; defer { log.running = nil }
        reset()
        let trust = DIDIssuerKeyResolver(trustedIssuers: [HarnessIssuer.did]) { _, _ in HarnessIssuer.publicSEC1 }
        var configuration = MdocReaderConfiguration()
        configuration.skipIssuerAuth = false
        configuration.l2capUpgrade = l2capUpgrade       // 앱이 쓰는 생성자로 간다
        configuration.blePreferredMode = preferredMode
        let session = MdocReaderSession(configuration: configuration, trust: trust)
        reader = session
        let observer = ReaderObserver(log: log)
        readerObserver = observer
        session.delegate = observer
        session.onTransportEvent = { [weak log] in Probes.note($0, "reader", log) }
        let started = Date()
        do {
            log.info("mdoc 에 대 주세요")
            let payload = try await session.connectViaNFC()
            log.pass("NFC engagement 읽고 연결 \(ms(since: started)) — 캐리어: \(payload.transmissions)")
            if probeEntryRetry { try await probeEntryErrors(session, log) }
            let requested = Date()
            let result = try await session.request([ItemsRequestPresets.identity], at: Date())
            log.pass("응답 수신·검증 \(ms(since: requested)) — 문서 \(result.documents.count)건")
            for doc in result.documents {
                log.info("\(doc.docType): verdict=\(doc.verdict) · digests=\(doc.digests?.allMatch ?? false)"
                         + (doc.warnings.isEmpty ? "" : " · warnings=\(doc.warnings)"))
            }
        } catch {
            logFailure(error, session, log, started)
        }
        session.terminate()
    }

    // MARK: 4 — 리더 GATT

    func runReader(_ log: ProbeLog, qrString: String) async {
        log.running = "reader"; defer { log.running = nil }
        reset()
        // **하네스의 스텁 발급자를 신뢰 목록에 넣는다.** 안 넣으면 검증할 공개키가 없어
        // `issuerSig` 가 항상 false 로 나오고, 발급자 서명 경로가 실기기에서 한 번도
        // 돌지 않는다 (빈 목록은 전부 거부다)
        let trust = DIDIssuerKeyResolver(trustedIssuers: [HarnessIssuer.did]) { _, _ in
            HarnessIssuer.publicSEC1
        }
        // **발급자 검증을 켠다.** 기본은 건너뛰기(`skipIssuerAuth = true`)라 그대로 두면
        // 위 신뢰 목록이 쓰이지도 않고 `issuerSig` 가 늘 false 다 — 하네스는 그 경로를
        // 실기기에서 돌리려고 있는 것이므로 명시적으로 켠다
        var configuration = MdocReaderConfiguration()
        configuration.skipIssuerAuth = false
        configuration.l2capUpgrade = l2capUpgrade       // 앱이 쓰는 생성자로 간다
        configuration.blePreferredMode = preferredMode
        let session = MdocReaderSession(configuration: configuration, trust: trust)
        reader = session
        let observer = ReaderObserver(log: log)
        readerObserver = observer
        session.delegate = observer          // 상태 머신을 그대로 로그로 낸다
        session.onTransportEvent = { [weak log] in Probes.note($0, "reader", log) }
        let started = Date()
        do {
            let payload = try EngagementPayload.parse(qrString: qrString)
            log.info("[\(role.short)] engagement 해석 — 상대 광고: \(payload.transmissions)")
            try await session.connect(to: payload)
            log.pass("링크 수립 \(ms(since: started))")
            if probeEntryRetry { try await probeEntryErrors(session, log) }

            let requested = Date()
            let result = try await session.request([ItemsRequestPresets.identity], at: Date())
            log.pass("응답 수신·검증 \(ms(since: requested)) — 문서 \(result.documents.count)건")
            for doc in result.documents {
                log.info("\(doc.docType): mdocAuth=\(doc.mdocAuth.method) \(doc.mdocAuth.valid ? "valid" : "INVALID")"
                         + " · issuerSig=\(doc.issuerDataAuth.signatureValid)"
                         + " · docType=\(doc.issuerDataAuth.docTypeChecked ? (doc.issuerDataAuth.docTypeMatches ? "match" : "MISMATCH") : "unchecked")"
                         + " · digests=\(doc.digests?.allMatch ?? false)"
                         + " · verdict=\(doc.verdict)"
                         + (doc.warnings.isEmpty ? "" : " · warnings=\(doc.warnings)"))
            }
            log.pass("트랜잭션 완료 — 상태 \(session.state.rawValue) · 전체 \(ms(since: started))")
        } catch {
            logFailure(error, session, log, started)
        }
        session.terminate()
    }

    /// **입구 오류는 세션을 소비하지 않는다**. 연결된 세션에 포맷 오류 요청을 두 번 넣고,
    /// 둘 다 `validationFailed` 로 거절되면서 상태가 `connected` 에 남는지 본다. 뒤따르는 정상
    /// 요청이 성공하면 "다시 부를 수 있다"까지 닫힌다. 하나라도 어긋나면 throw 해서 정상 요청을
    /// 건너뛴다 — 이미 소비된 세션에 요청을 넣으면 원인이 섞인다
    private func probeEntryErrors(_ session: MdocReaderSession, _ log: ProbeLog) async throws {
        let bad: [(String, [ItemsRequestSpec])] = [
            ("빈 목록", []),
            ("docType 중복", [ItemsRequestPresets.identity, ItemsRequestPresets.identity]),
        ]
        for (label, specs) in bad {
            do {
                _ = try await session.request(specs, at: Date())
                log.fail("입구 오류(\(label))가 통과했다 — 거절되어야 한다")
                throw ProbeAbort()
            } catch MdocProximityError.validationFailed(let detail) {
                guard session.state == .connected else {
                    log.fail("입구 오류(\(label))가 세션을 소비했다 — 상태 \(session.state.rawValue)")
                    throw ProbeAbort()
                }
                log.pass("입구 오류(\(label)) 거절, 상태 connected 유지 — \(detail)")
            }
        }
        log.info("→ 같은 세션으로 정상 요청을 다시 부른다")
    }

    /// 취소는 실패가 아니다 — NFC 시트의 사용자 취소·Task 취소는 `CancellationError` 로
    /// 오고 상태는 `terminated` 다. 실패 로그로 찍으면 실기 결과표에서 둘이 섞인다
    private func logFailure(_ error: Error, _ session: MdocReaderSession, _ log: ProbeLog, _ started: Date) {
        if error is CancellationError {
            log.info("사용자 취소 — CancellationError · 상태 \(session.state.rawValue) (\(ms(since: started)))")
        } else if error is ProbeAbort {
            // 원인은 이미 로그에 남겼다
        } else {
            log.fail("실패 — \(error) · 상태 \(session.state.rawValue) (\(ms(since: started)))")
        }
    }

    /// 전송 이벤트를 한 줄로 남긴다. **진행률은 마지막 것만** — 21KB 를 GATT 로 나르면
    /// part 가 수백 개라 로그가 그것으로 덮인다.
    nonisolated static func note(_ event: TransportEvent, _ who: String, _ log: ProbeLog?) {
        let text: String?
        switch event {
        case .ready: text = "링크 준비됨"
        case .downgradedToGatt(let reason): text = "**L2CAP 실패 → GATT 복귀** — \(reason)"
        case .peerClosed(let reason): text = "상대가 닫음 — \(reason)"
        case .failed(let error): text = "전송 실패 — \(error)"
        case .progress(let sent, let total): text = sent >= total ? "전송 \(total)바이트 완료" : nil
        case .downgradedToGatt(let reason) where who.contains("/"): text = "복귀 — \(reason)"
        case .message(let d): text = "메시지 수신 \(d.count)바이트"
        }
        guard let text else { return }
        Task { @MainActor in log?.info("[\(who)] " + text) }
    }

    private func ms(since: Date) -> String {
        String(format: "%.0f ms", Date().timeIntervalSince(since) * 1000)
    }
}

/// 리더 세션의 상태 전이를 로그로 낸다. **어디까지 갔는지**가 실패했을 때 제일 먼저
/// 보고 싶은 값이고, 성공했을 때는 그 자체가 완료 표시다.
final class ReaderObserver: MdocReaderSessionDelegate {
    /// 델리게이트는 아무 컨텍스트에서나 불릴 수 있으므로 **로그로 넘길 때 메인으로 옮긴다**
    /// (활성 세션을 프로세스당 하나로 두는 것과 같은 이유다).
    private let log: ProbeLog
    init(log: ProbeLog) { self.log = log }

    func readerSession(_ s: MdocReaderSession, didChangeState state: MdocReaderState) {
        let text = "[reader] 상태 → \(state.rawValue)"
        Task { @MainActor in log.info(text) }
    }
    func readerSessionDidConnect(_ s: MdocReaderSession) {}
    func readerSession(_ s: MdocReaderSession, didProgress received: Int, of total: Int) {}
    func readerSession(_ s: MdocReaderSession, didFailWith error: MdocProximityError) {
        let text = "[reader] \(error)"
        Task { @MainActor in log.fail(text) }
    }
}

/// 광고와 GATT 서버가 실제로 열리는지만 본다. **전송체를 쓰지 않는다** — 여기서 재는 것은
/// 기기 능력이지 우리 프로토콜이 아니다.
final class BleAdvertiseProbe: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager?
    private var waiter: CheckedContinuation<Result<String, Error>, Never>?
    private let serviceUUID = CBUUID(nsuuid: UUID())

    func run() async -> Result<String, Error> {
        await withCheckedContinuation { c in
            waiter = c
            manager = CBPeripheralManager(delegate: self, queue: nil)
        }
    }

    private func finish(_ r: Result<String, Error>) {
        manager?.stopAdvertising(); manager?.removeAllServices()
        waiter?.resume(returning: r); waiter = nil
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            let service = CBMutableService(type: serviceUUID, primary: true)
            service.characteristics = [
                CBMutableCharacteristic(type: CBUUID(string: "0000000A-A123-48CE-896B-4C76973373E6"),
                                        properties: [.notify], value: nil, permissions: [])
            ]
            peripheral.add(service)
        case .unsupported: finish(.failure(MdocProximityError.bleUnavailable(reason: .noHardware)))
        case .unauthorized:
            finish(.failure(MdocProximityError.configurationRequired(action: .grantPermission("bluetooth"))))
        case .poweredOff:
            finish(.failure(MdocProximityError.configurationRequired(action: .enableBluetooth)))
        default: break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { return finish(.failure(error)) }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { return finish(.failure(error)) }
        finish(.success("service + advertising"))
    }
}

/// 프로브가 스스로 중단할 때 던진다. 원인은 던지기 전에 로그로 남기므로 catch 에서는 다시 찍지 않는다
struct ProbeAbort: Error {}
