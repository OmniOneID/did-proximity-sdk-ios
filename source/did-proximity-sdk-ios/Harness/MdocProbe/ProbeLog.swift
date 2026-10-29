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

/// 판정은 **코드가 내린다.** 사람은 색만 본다.
enum Verdict: String {
    case pass = "PASS"
    case fail = "FAIL"
    case info = "····"
}

struct LogLine: Identifiable {
    let id = UUID()
    let at = Date()
    let verdict: Verdict
    let text: String
}

@MainActor
final class ProbeLog: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    @Published var running: String?

    func pass(_ t: String) { append(.pass, t) }
    func fail(_ t: String) { append(.fail, t) }
    func info(_ t: String) { append(.info, t) }
    func clear() { lines.removeAll() }

    private func append(_ v: Verdict, _ t: String) {
        lines.append(LogLine(verdict: v, text: t))     // **최신이 아래다** — 읽는 방향과 같다
        let line = "[probe] \(v.rawValue) \(t)"
        // **셋 다 남긴다 — 회수 경로가 서로 다르다.** `NSLog` 는 os_log(Console.app),
        // `print` 는 stdout(`devicectl … --console`), 파일은 `devicectl device copy from`.
        // 기기에서 사람이 읽어 옮기는 단계를 없애는 것이 이 앱의 목적이다.
        NSLog("%@", line)
        print(line)
        Self.appendToFile(line)
    }

    private static let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.log")

    private static func appendToFile(_ line: String) {
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
