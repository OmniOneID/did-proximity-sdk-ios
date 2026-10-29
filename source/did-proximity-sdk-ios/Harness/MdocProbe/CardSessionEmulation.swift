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
import CoreNFC
import MdocProximitySDK

/// **인가받은 앱이 복사해 갈 참조 구현.** `NfcCardEmulationProtocol` 을 CoreNFC `CardSession`(iOS 17.4+)
/// 으로 채운 것이며, SDK 가 요구하는 것은 이 한 파일 분량이 전부다 — APDU 를 핸들러에 넘기고
/// 반환값을 응답으로 보내고, 리더가 떠나면 알린다.
///
/// 이 하네스는 엔타이틀먼트(`com.apple.developer.nfc.hce`)가 없으므로 `CardSession()` 이 던진다.
/// 그래서 실기기에서 이 프로브의 결과는 "인가 전엔 여기서 막힌다"를 확인하는 것이고, 인가받은
/// 앱에 이 파일을 넣으면 그 뒤 흐름이 열린다.
@available(iOS 17.4, *)
final class CardSessionEmulation: NfcCardEmulationProtocol {

    var onDeactivated: (() -> Void)?
    var onNote: ((String) -> Void)?
    private var session: CardSession?
    private var pump: Task<Void, Never>?

    func start(handler: @escaping (Data) async -> Data) async throws {
        guard CardSession.isSupported else { throw MdocProximityError.nfcUnavailable(reason: .noHardware) }
        guard await CardSession.isEligible else { throw MdocProximityError.nfcUnavailable(reason: .vendorPolicy) }
        let session = try await CardSession()                       // 엔타이틀먼트가 없으면 여기서 던진다
        self.session = session
        session.alertMessage = "리더에 대 주세요"
        pump = Task { [weak self] in
            // iOS 26 SDK 에서 `eventStream` 이 throwing 스트림이 됐다 — 스트림 오류는
            // `sessionInvalidated` 와 같은 뜻이므로 같은 콜백으로 보낸다
            do { for try await event in session.eventStream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .sessionStarted:
                    onNote?("CardSession 시작 — 에뮬레이션 켬")
                    try? await session.startEmulation()
                case .readerDetected:
                    onNote?("리더 감지")
                case .readerDeselected:
                    onNote?("리더가 선택을 풀었다")
                    onDeactivated?()
                case .received(let apdu):
                    // SDK 가 상태 머신을 돈다 — 앱은 바이트를 넘기고 돌려주기만 한다
                    let response = await handler(apdu.payload)
                    try? await apdu.respond(response: response)
                case .sessionInvalidated(let reason):
                    onNote?("세션 무효화 — \(reason)")
                    onDeactivated?()
                @unknown default:
                    break
                }
            } } catch {
                self?.onNote?("이벤트 스트림 오류 — \(error)")
                self?.onDeactivated?()
            }
        }
    }

    func stop() {
        pump?.cancel(); pump = nil
        guard let session else { return }
        self.session = nil
        Task {
            await session.stopEmulation(status: .success)
            session.invalidate()
        }
    }
}
