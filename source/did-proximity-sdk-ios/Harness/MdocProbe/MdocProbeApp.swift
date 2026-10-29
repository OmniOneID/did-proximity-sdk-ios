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

import SwiftUI

/// **측정용 껍데기다. 제품 앱이 아니다.** 이 앱이 하는 일은 SDK 를 실기기에서 돌려
/// 미결 항목에 PASS/FAIL 을 내는 것뿐이고, 실기기 확인이 끝나면 버린다.
///
/// 각 버튼이 미결 항목 하나에 대응한다 — 사람이 로그를 읽고 해석해야 하면 그 항목은
/// 하네스로서 실패한 것이다.
@main
struct MdocProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}
