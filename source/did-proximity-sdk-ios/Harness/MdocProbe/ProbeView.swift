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
@_spi(MdocInternal) import MdocProximitySDK

/// 이 기기가 **어느 쪽으로 서 있는지**를 먼저 정한다. 역할마다 되는 기능이 다르고
/// (iOS mdoc 의 NFC 는 앱이 주입하는 카드 에뮬레이션뿐이다), 활성 세션은 프로세스당 하나다.
enum ProbeRole: String, CaseIterable, Identifiable {
    case mdoc, reader
    var id: String { rawValue }
    var title: String { self == .mdoc ? "mdoc (제시)" : "reader (검증)" }
    var short: String { rawValue }
    /// Capability 모델 — 사실만 말한다. 판단은 보는 사람이 한다
    var capabilities: RoleCapabilities {
        self == .mdoc ? MdocCapabilities.current().mdoc : MdocCapabilities.current().mdocReader
    }
}

/// 화면 표시만 얹는다 — 값은 SDK 의 `BleAdvertiseMode` 를 그대로 쓴다.
extension BleAdvertiseMode: @retroactive Identifiable, @retroactive CaseIterable {
    public static var allCases: [BleAdvertiseMode] { [.peripheralServer, .centralClient, .both] }
    public var id: String { title }
    var title: String {
        switch self {
        case .peripheralServer: return "peripheral"
        case .centralClient: return "central"
        case .both: return "둘 다"
        }
    }
}

extension BleModePreference: @retroactive Identifiable, @retroactive CaseIterable {
    public static var allCases: [BleModePreference] { [.central, .peripheral] }
    public var id: String { title }
    var title: String {
        switch self {
        case .central: return "central"
        case .peripheral: return "peripheral"
        }
    }
}

struct ProbeView: View {
    @StateObject private var log = ProbeLog()
    @StateObject private var probes = Probes()
    @State private var role: ProbeRole = .mdoc
    @State private var scanning = false
    /// 로그는 **접힌 채로 시작한다** — 처음 보는 화면은 조작하는 화면이다.
    /// 상태가 둘뿐이라 버튼도 하나면 된다(펼치기 / 접기).
    @State private var logExpanded = false
    private var logHeight: CGFloat { logExpanded ? 420 : 96 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                roleHeader
                List {
                    Section(role == .mdoc ? "mdoc 으로 할 것" : "reader 로 할 것") {
                        if role == .mdoc {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("광고할 BLE 모드").font(.caption).foregroundStyle(.secondary)
                                Picker("모드", selection: $probes.advertiseMode) {
                                    ForEach(BleAdvertiseMode.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented)
                            }
                            row("대기 시작 — QR 표시", "BLE peripheral · central · L2CAP") {
                                await probes.startMdoc(log)
                            }
                            Toggle("portrait 포함 (21 KB)", isOn: $probes.includePortrait)
                                .font(.callout)
                            row("NFC 카드 에뮬레이션 — 주입 경로", "인가 전엔 CardSession 에서 막힌다") {
                                await probes.nfcCard(log)
                            }
                            row("NFC negotiated — TNEP 왕복", "리더의 Handover Request 를 받아 캐리어 선택") {
                                await probes.nfcCard(log, negotiated: true)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("상대가 둘 다 광고하면 고를 BLE 모드").font(.caption).foregroundStyle(.secondary)
                                Picker("모드", selection: $probes.preferredMode) {
                                    ForEach(BleModePreference.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented)
                            }
                            Toggle("입구 오류 재시도 먼저", isOn: $probes.probeEntryRetry)
                                .font(.callout)
                            Button("QR 스캔하고 요청") { scanning = true }
                                .disabled(log.running != nil)
                            row("NFC 로 읽고 요청", "같은 링크로 data retrieval") {
                                await probes.runReaderNFC(log)
                            }
                            row("NFC — mdoc AID SELECT", "AID SELECT 통과 · 명령 없이 이탈 감지") {
                                await probes.nfcSelect(log)
                            }
                        }
                        Toggle("L2CAP 승격", isOn: $probes.l2capUpgrade).font(.callout)
                    }
                    // **점검이지 설정이 아니다.** GATT 는 끄고 켜는 값이 아니라 리더 측 필수다
                    // (DIS Table 19). 두 역할 다 어느 모드에선가 GATT server 가 되므로
                    // 이 점검은 역할과 무관하다
                    Section("기기 점검 — 켜고 끄는 값이 아니다") {
                        row("BLE 광고 + GATT server 가 열리는가", "지원 매트릭스 · 열어 보고 바로 닫는다") {
                            await probes.bleAdvertise(log)
                        }
                    }
                    // QR 은 팝업으로 띄운다. 닫아 버렸으면 여기서 다시 연다 —
                    // **세션은 살아 있으므로 engagement 를 새로 만들면 안 된다**
                    if role == .mdoc, probes.qrString != nil, !probes.showQR {
                        Section("engagement") {
                            Button("QR 다시 열기") { probes.showQR = true }
                            if probes.connected { Text("연결됨").font(.caption).foregroundStyle(.green) }
                        }
                    }
                }
                logPane
            }
            .navigationTitle("mdoc probe")
            .sheet(isPresented: $probes.showQR) {
                QRSheet(text: probes.qrString ?? "", connected: probes.connected) {
                    probes.showQR = false
                }
            }
            .sheet(isPresented: $scanning) {
                QRScannerView { value in
                    scanning = false
                    Task { await probes.runReader(log, qrString: value) }
                }
            }
        }
    }

    /// **이 기기가 무엇인지**와 **그래서 무엇이 되는지**를 같은 자리에 둔다.
    private var roleHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("역할", selection: $role) {
                ForEach(ProbeRole.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: role) { _, new in
                probes.reset()                     // 활성 세션은 프로세스당 하나다
                probes.role = new
                log.info("역할 전환 — \(new.title)")
            }
            HStack(spacing: 14) {
                capability("BLE", role.capabilities.ble)
                capability("NFC", role.capabilities.nfc)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func capability(_ name: String, _ c: TransportCapability) -> some View {
        let text: String
        let color: Color
        switch c {
        case .supported: text = "가능"; color = .green
        case .unsupported(let reason): text = "불가(\(reason))"; color = .red
        case .configurationRequired: text = "설정 필요"; color = .orange
        }
        return VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.caption2.bold()).foregroundStyle(color)
        }
    }

    private func row(_ title: String, _ ref: String,
                     _ action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(ref).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(log.running != nil)
    }

    /// 머리글 + 로그. **지우는 대상이 로그이므로 버튼도 로그 옆에 둔다.**
    private var logPane: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("로그").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                // 접기/펼치기 하나. **두 방향을 같이 보여 주지 않는다** — 지금 무엇이 되는지가
                // 아이콘 하나로 드러나는 편이 낫다
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { logExpanded.toggle() }
                } label: {
                    Image(systemName: logExpanded ? "chevron.compact.down" : "chevron.compact.up")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 80, height: 22)      // 가로로 긴 손잡이 자리
                        .contentShape(Rectangle())
                }
                Spacer()
                Button("지우기") { log.clear() }
                    .font(.caption)
                    .disabled(log.lines.isEmpty)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal)
            .padding(.vertical, 4)

            ScrollViewReader { proxy in
                List(log.lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.verdict.rawValue)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(color(line.verdict))
                        Text(line.text).font(.system(size: 12, design: .monospaced))
                    }
                    .listRowSeparator(.hidden)
                    .id(line.id)
                }
                .listStyle(.plain)
                // 크기가 바뀔 때 **아래를 기준으로** 다시 잡는다. 이것이 없으면 접는 순간
                // 스크롤이 맨 위로 튀어 최신 줄이 화면 밖으로 나간다
                .defaultScrollAnchor(.bottom)
                // **언제나 최하단을 보여준다** — 줄이 늘 때도, 접었다 펼칠 때도, 처음 그릴 때도
                .onChange(of: log.lines.count) { _, _ in pin(proxy) }
                // 접기/펴기는 **레이아웃이 끝난 뒤** 다시 잡아야 한다 — 애니메이션 도중에
                // 잡으면 옛 높이 기준으로 계산돼 위로 밀린다
                .onChange(of: logExpanded) { _, _ in
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 220_000_000)
                        pin(proxy, animated: false)
                    }
                }
                .onAppear { pin(proxy) }
            }
            .frame(height: logHeight)
        }
        .background(.bar)
    }

    private func pin(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = log.lines.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private func color(_ v: Verdict) -> Color {
        switch v {
        case .pass: return .green
        case .fail: return .red
        case .info: return .secondary
        }
    }
}


/// engagement QR 팝업. **연결되면 자동으로 닫히고**, 그 전에는 닫기 버튼으로 닫는다.
/// 닫아도 세션은 살아 있다 — 다시 열 수 있다.
struct QRSheet: View {
    let text: String
    let connected: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(connected ? "연결됨" : "리더가 스캔하기를 기다립니다")
                .font(.headline)
                .foregroundStyle(connected ? .green : .primary)
            QRCodeView(text: text)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal)
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal)
            Button("닫기", action: onClose)
                .buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }
}
