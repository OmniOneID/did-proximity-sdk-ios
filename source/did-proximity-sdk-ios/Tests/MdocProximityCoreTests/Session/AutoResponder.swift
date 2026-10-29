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
@_spi(MdocInternal) @testable import MdocProximityCore
@_spi(MdocInternal) @testable import MdocDevice

/// 앱 자리 — 요청 콜백을 받으면 월렛이 만든 응답을 돌려준다.
/// **전송의 `events` 는 세션이 소유한다.** 테스트가 따로 소비하면 메시지를 빼앗는다.
final class AutoResponder: MdocDeviceSessionDelegate {
    private let make: () -> Data
    private weak var session: MdocDeviceSession?
    private(set) var finished = false
    /// `didProgress` 로 받은 (sent, total) — 마지막 값
    private(set) var progress: (sent: Int, total: Int)?

    init(session: MdocDeviceSession, make: @escaping () -> Data) {
        self.session = session; self.make = make
        session.delegate = self
    }
    func mdocSession(_ s: MdocDeviceSession, didChangeState state: MdocDeviceState) {}
    func mdocSession(_ s: MdocDeviceSession, didReceiveRequest deviceRequest: Data,
                     sessionTranscript: Data) {
        let bytes = make()
        Task { try? await s.respond(deviceResponse: bytes) }
    }
    func mdocSession(_ s: MdocDeviceSession, didProgress sent: Int, of total: Int) {
        progress = (sent, total)
    }
    func mdocSessionDidFinish(_ s: MdocDeviceSession) { finished = true }
    func mdocSession(_ s: MdocDeviceSession, didFailWith error: MdocProximityError) {}
}

/// 델리게이트는 `callbackQueue` 로 나가므로 플래그를 보기 전에 그 큐를 한 번 비운다.
/// 직렬 큐라 이 블록이 돌면 앞서 쌓인 콜백은 전부 끝난 뒤다.
func drainCallbacks(_ queue: DispatchQueue = .main) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        queue.async { c.resume() }
    }
}
