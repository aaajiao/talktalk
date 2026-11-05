// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore

enum DiagnosticsSettingsTab: String, CaseIterable, Identifiable {
    case privacy, subtitles, troubleshooting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .privacy: String(localized: "数据与隐私")
        case .subtitles: String(localized: "字幕分析")
        case .troubleshooting: String(localized: "故障检查")
        }
    }
    var symbol: String {
        switch self {
        case .privacy: "hand.raised"
        case .subtitles: "captions.bubble"
        case .troubleshooting: "stethoscope"
        }
    }
    var summary: String {
        switch self {
        case .privacy: String(localized: "存储与清理")
        case .subtitles: String(localized: "检查本次字幕")
        case .troubleshooting: String(localized: "自检与导出")
        }
    }
}

/// Settings › 隐私与诊断 (ARCHITECTURE.md §11, §12). View state lives in `PrivacySettings`
/// (an @Observable model): CLT has no SwiftUI macro plugin, so no @State here.
struct DiagnosticsView: View {
    @Bindable var model: PrivacySettings
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ForEach(DiagnosticsSettingsTab.allCases) { tab in
                    SettingsTabButton(title: tab.title, symbol: tab.symbol, summary: tab.summary,
                                      selected: navigation.diagnosticsTab == tab) {
                        navigation.diagnosticsTab = tab
                    }
                }
            }
            .padding([.horizontal, .top], 20)
            activeRecordingStatus.padding(.horizontal, 20)
            Form {
                switch navigation.diagnosticsTab {
                case .privacy:
                    Section { whatStays } header: { Label("声音与文字的去向", systemImage: "hand.raised") }
                    Section { transcripts } header: { Label("文字记录", systemImage: "text.document") }
                    Section { retention } header: { Label("自动清理", systemImage: "clock.arrow.circlepath") }
                case .subtitles:
                    Section {
                        SpeechFlow(steps: [("play.rectangle", String(localized: "开始收听")),
                                           ("record.circle", String(localized: "开启本次分析")),
                                           ("doc.text.magnifyingglass", String(localized: "查看本地记录"))], links: [
                            0: .init(String(localized: "选择使用场景")) { navigation.selection = .meeting }
                        ])
                        note(String(localized: "检查本次原文、译文和字幕节奏。只在你开启后记录文字，不录音；会话结束后自动停止。"))
                    }
                    Section { subtitleAnalysis } header: { Label("本次分析", systemImage: "captions.bubble") }
                case .troubleshooting:
                    Section {
                        SpeechFlow(steps: [("checklist", String(localized: "选择检查项目")),
                                           ("list.bullet.rectangle", String(localized: "查看结果")),
                                           ("square.and.arrow.up", String(localized: "按需导出"))])
                        note(String(localized: "下面的检查与导出都由你手动开始。打开此页不会启动录音或发送测试请求。"))
                    }
                    Section { selfTests } header: { Label("运行自检", systemImage: "checkmark.shield") }
                    Section { selfTestResults } header: { Label("检查结果", systemImage: "list.bullet.rectangle") }
                    Section { bundle } header: { Label("导出诊断包", systemImage: "square.and.arrow.up") }
                    Section {
                        DisclosureGroup("详细性能记录") { latency.padding(.top, 8) }
                        DisclosureGroup("离线音频自检命令") { offlineCommands.padding(.top, 8) }
                    } header: { Text("技术详情") }
                    Section {
                        if model.recorder.micAndTTSArmed || !model.recorder.recordingTracks.isEmpty {
                            recording
                        } else {
                            DisclosureGroup("按需记录音频") { recording.padding(.top, 8) }
                        }
                    } header: { Label("诊断录音", systemImage: "waveform") }
                }
            }
            .formStyle(.grouped)
            .id(navigation.diagnosticsTab)
        }
        .onAppear { model.diagnosticsStatus.refresh() }
        .alert(String(localized: "会议没有在进行"), isPresented: $model.showRemoteRefused) {
            Button(String(localized: "好")) {}
        } message: {
            Text(String(localized: "对方的声音只能在会议进行时、经你当场确认所有参与者都同意之后才录。"))
        }
    }

    @ViewBuilder private var activeRecordingStatus: some View {
        let analysis = model.subtitleAnalysis
        let recorder = model.recorder
        if analysis.isStarting || analysis.isRecording {
            HStack {
                Label(analysis.isStarting ? String(localized: "字幕分析正在准备") : String(localized: "正在保存本次字幕文字"),
                      systemImage: analysis.isStarting ? "hourglass" : "record.circle")
                    .font(.callout).foregroundStyle(.orange)
                Spacer()
                Button("查看字幕分析") { navigation.diagnosticsTab = .subtitles }
            }
        }
        if !recorder.recordingTracks.isEmpty {
            HStack {
                Label(String(localized: "正在录音：") + recorder.recordingTracks.map(\.label).sorted().joined(separator: String(localized: "、")),
                      systemImage: "record.circle.fill").font(.callout).foregroundStyle(.red)
                Spacer()
                Button("查看诊断录音") { navigation.diagnosticsTab = .troubleshooting }
            }
        } else if recorder.micAndTTSArmed {
            HStack {
                Label(recorder.meetingRunning ? String(localized: "已启用本场诊断录音") : String(localized: "已启用下场诊断录音"),
                      systemImage: "mic").font(.callout).foregroundStyle(.orange)
                Spacer()
                Button("查看诊断录音") { navigation.diagnosticsTab = .troubleshooting }
            }
        }
    }

    private var selfTests: some View {
        let status = model.diagnosticsStatus
        return VStack(alignment: .leading, spacing: 12) {
            note(String(localized: "自检只在点击后运行。引擎自检先停止当前引擎；请先结束会议、说话测试、录音和试听。"))
            HStack {
                Button { status.runEngine() } label: { Label("检查本地引擎", systemImage: "cpu") }
                    .disabled(!status.audioSelfTestAvailable || model.recorder.meetingRunning)
                Button { status.runCloud() } label: { Label("检查云端翻译", systemImage: "cloud") }
                    .disabled(status.runningPart != nil)
                if status.runningPart != nil { ProgressView().controlSize(.small) }
            }
            note(String(localized: "云端自检需已同意云翻译并配置 key，会发送少量合成测试文字并产生 API 费用。"))
            if let part = status.runningPart {
                Label(part == "--engine" ? String(localized: "正在检查本地引擎…") : String(localized: "正在检查云端翻译…"),
                      systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
            }
            if let notice = status.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var offlineCommands: some View {
        let status = model.diagnosticsStatus
        return VStack(alignment: .leading, spacing: 8) {
            note(String(localized: "先退出 TalkTalk，再在终端执行复制的命令，避免与采集、播放或引擎占用冲突。"))
            HStack {
                Button("复制驱动自检命令") { status.copyCommand("--driver") }
                Button("复制声音自检命令") { status.copyCommand("--voice") }
            }
            HStack {
                Button("复制回环自检命令") { status.copyCommand("--loop") }
                Button("复制直通自检命令") { status.copyCommand("--passthrough") }
            }
            note(String(localized: "直通自检仅适用于离线独占；会议中的驱动隔离检查从“组件”页运行。"))
            note(String(localized: "共载自检：已跳过（按你的决定，不做负载测试）。"))
        }
    }

    private var selfTestResults: some View {
        let status = model.diagnosticsStatus
        return VStack(alignment: .leading, spacing: 10) {
            if let report = status.report {
                Label(report.ok ? String(localized: "自检通过") : String(localized: "自检未通过或未完成"),
                      systemImage: report.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout.bold())
                    .foregroundStyle(report.ok ? Color.green : report.checks.contains(where: { $0.ok == false }) ? Color.red : Color.orange)
                ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: check.ok == true ? "checkmark.circle" : check.ok == false ? "xmark.circle" : "minus.circle")
                                .foregroundStyle(check.ok == true ? Color.green : check.ok == false ? Color.red : Color.secondary)
                            Text(verbatim: check.name).font(.callout.monospaced())
                        }
                        if let detail = check.detail { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if report.checks.contains(where: { !$0.values.isEmpty }) {
                    DisclosureGroup("原始检查数值") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                                if !check.values.isEmpty {
                                    Text(verbatim: check.name).font(.caption.weight(.medium))
                                    Text(verbatim: check.values.keys.sorted().map { "\($0): \(check.values[$0]!.formatted())" }.joined(separator: " · "))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            } else {
                Text(status.runningPart == nil ? String(localized: "尚未运行自检。请在上方选择检查项目。") : String(localized: "检查完成后，结果会显示在这里。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var latency: some View {
        let status = model.diagnosticsStatus
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近 20 段延迟").font(.headline)
                Spacer()
                Button("刷新") { status.refresh() }.disabled(status.refreshing)
                if status.refreshing { ProgressView().controlSize(.small) }
            }
            note(String(localized: "只读取最近 3 场日志的末尾，每场最多 512 KiB；页面打开或手动刷新时读取。提交到首声与松键到首声不是同一个指标。"))
            LabeledContent("SPEAK 提交 → 首声 p50 / p90") {
                Text(verbatim: "\(milliseconds(status.percentile(.speak, 0.5))) / \(milliseconds(status.percentile(.speak, 0.9)))")
            }
            LabeledContent("LISTEN 定稿触发 → 译文 p50 / p90") {
                Text(verbatim: "\(milliseconds(status.percentile(.listen, 0.5))) / \(milliseconds(status.percentile(.listen, 0.9)))")
            }
            LabeledContent("SPEAK 松键 → 首声 p50 / p90（可测按压）") {
                Text(verbatim: "\(milliseconds(status.releasePercentile(0.5))) / \(milliseconds(status.releasePercentile(0.9)))")
            }
            LabeledContent("TTS GPU RTF p50 / p90") {
                Text(verbatim: "\(ratio(status.rtfPercentile(0.5))) / \(ratio(status.rtfPercentile(0.9)))")
            }
            LabeledContent("最近首声记录的累计欠载") { Text(verbatim: status.latestUnderrunsTotal.map { String($0) } ?? "—") }
            LabeledContent("EVS") { Text(verbatim: "—") }
            note(String(localized: "EVS 尚无可靠的原声结束时间，暂不计算。"))
            note(String(localized: "时延是原始记录，尚未扣除队列、直通或告知语时间；按住期间已出声或强制释放的按压不计入松键到首声。累计欠载来自最近首声时的本场快照，不是每段欠载率。"))
            note(String(localized: "缺少记录的指标显示 —，不会由其他时延推算。"))
            if status.snapshot.rows.isEmpty {
                Text("还没有可显示的延迟记录。").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(status.snapshot.rows.reversed()) { row in
                HStack {
                    Text(verbatim: row.kind == .speak ? "SPEAK" : "LISTEN").font(.caption.monospaced())
                    Text("段 \(row.segment)").font(.caption)
                    Spacer()
                    Text(verbatim: milliseconds(row.milliseconds)).font(.caption.monospacedDigit())
                    if row.kind == .speak {
                        Text(verbatim: "RTF \(ratio(row.computeRTF))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if status.snapshot.truncated {
                note(String(localized: "较大的日志只读取末尾，统计不代表全场。"))
            }
            if let date = status.refreshedAt {
                Text("上次读取：\(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "—"
    }

    private func ratio(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }

    private var subtitleAnalysis: some View {
        let analysis = model.subtitleAnalysis
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent("收听状态", value: model.recorder.meetingRunning ? String(localized: "会话进行中") : String(localized: "尚未开始收听"))
            Label(analysis.status, systemImage: analysis.isRecording ? "record.circle" : "info.circle")
                .font(.callout).foregroundStyle(analysis.isRecording || analysis.isStarting ? Color.orange : Color.secondary)
            note(String(localized: "分析文件包含本次原文和译文，仅保存在这台 Mac；24 小时后清理，不进入诊断包。"))
            HStack {
                if analysis.isRecording || analysis.isStarting {
                    Button("停止字幕分析") { analysis.stop() }
                } else {
                    Button("开启本次字幕分析（包含文字）") { model.startSubtitleAnalysis() }
                        .disabled(!model.recorder.meetingRunning)
                }
                if analysis.isStarting { ProgressView().controlSize(.small) }
            }
            if !model.recorder.meetingRunning {
                note(String(localized: "请先开始会议同传或视频字幕，再开启本次分析。"))
            }
            if let file = analysis.fileURL {
                Text("已接收 \(analysis.recordCount) 行").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("复制分析文件路径") { analysis.copyPath() }
                    Button("在 Finder 中显示分析文件") { analysis.revealFile() }
                }
                DisclosureGroup(String(localized: "分析文件位置")) {
                    Text(verbatim: file.path).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            DisclosureGroup(String(localized: "分析内容与保留方式")) {
                note(String(localized: "记录原文、译文和识别、翻译、显示各阶段耗时，用于检查漏句与字幕积压。文件仅当前用户可读，不进备份；达到 8 MiB 或 10,000 行自动停止。"))
                note(String(localized: "显示时间是字幕面板提交更新的时间；隐藏面板会另行标记。没有参考原文时，耗时和文字记录不代表翻译准确率。每次会话都需要单独开启分析。"))
            }
        }
    }

    private var whatStays: some View {
        VStack(alignment: .leading, spacing: 12) {
            SpeechFlow(steps: [("desktopcomputer", String(localized: "声音留在本机")),
                               ("text.bubble", String(localized: "识别为文字")),
                               ("cloud", String(localized: "可选云端翻译"))], links: [
                2: .init(String(localized: "翻译设置")) { navigation.openModel(.translation) }
            ])
            note(String(localized: "语音识别与合成在本机完成，音频和声音档案不上传。只有启用 OpenAI 时，才发送待翻译文字、短上下文和相关术语。"))
            DisclosureGroup(String(localized: "密钥与常规日志")) {
                note(String(localized: "OpenAI key 只在登录钥匙串里，不进日志，也不进诊断包。"))
                note(String(localized: "常规日志只记 id、长度、耗时和错误码，不记文字、音频和路径。只有明确开启的本次字幕分析会另外保存文字。延迟事件保留最近 20 场、14 天内、合计不超过 200 MB。"))
            }
        }
    }

    private var transcripts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "保存文字记录"), isOn: $model.saveTranscripts)
            note(String(localized: "默认关闭。开启后保存会议原文和译文，仅在本机保留 30 天，不进入诊断包。"))
            DisclosureGroup("文字记录的存放方式") {
                note(String(localized: "文件保存在 transcripts 文件夹，仅当前用户可读，不进入备份。"))
            }
        }
    }

    private var recording: some View {
        let r = model.recorder
        return VStack(alignment: .leading, spacing: 8) {
            note(r.meetingRunning ? String(localized: "本场会议正在进行。选择只对这一场有效，会议结束就恢复为不录。")
                                  : String(localized: "现在没有会议。这里的选择只对下一场会议有效。"))
            Toggle(String(localized: "录麦克风和合成语音（我这边）"), isOn: Binding(get: { r.micAndTTSArmed }, set: { r.setMicAndTTS($0) }))
            HStack(spacing: 10) {
                if r.recordingTracks.contains(.remote) {
                    Label(String(localized: "正在录对方的声音"), systemImage: "record.circle").foregroundStyle(.red)
                    Button(String(localized: "停止")) { r.stopRemote() }
                } else {
                    Button(String(localized: "录对方的声音…")) { model.requestRemoteRecording() }
                        .disabled(!r.meetingRunning)
                }
            }
            note(String(localized: "对方的声音只在会议进行时、你当场确认“所有参与者都已同意录音”之后才录（德国《刑法典》§201）。"))
            if !r.recordingTracks.isEmpty {
                Label(String(localized: "正在录：") + r.recordingTracks.map(\.label).sorted().joined(separator: String(localized: "、")),
                      systemImage: "record.circle.fill").font(.callout).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button(String(localized: "在 Finder 中显示")) { model.revealDiagnostics() }
                Button(String(localized: "停止并删除本场录音")) { r.discardCurrent() }
                    .disabled(r.sessionDirectory == nil)
            }
            note(String(localized: "录音存在本机 diagnostics 文件夹（只有你能读，不进备份），24 小时后自动删除，不进诊断包。"))
            if let e = r.lastError { Text(e).font(.callout).foregroundStyle(.red) }
        }
    }

    private var bundle: some View {
        VStack(alignment: .leading, spacing: 8) {
            note(String(localized: "用于排查运行问题。不含声音档案、文字记录、字幕分析、诊断录音、术语表、OpenAI key 或请求头。"))
            HStack(spacing: 10) {
                Button(String(localized: "导出诊断包…")) { model.exportBundle() }
                    .disabled(model.exporting)
                if model.exporting { ProgressView().controlSize(.small) }
            }
            if let m = model.exportMessage {
                Text(m).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("诊断包包含什么") {
                note(String(localized: "包含日志、延迟事件、版本信息、install.json 和设备名列表。导出前会扫描内容；发现疑似 key 时停止导出。"))
            }
        }
    }

    private var retention: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("诊断录音与字幕分析", value: String(localized: "24 小时"))
            LabeledContent("文字记录", value: String(localized: "30 天"))
            LabeledContent("延迟事件", value: String(localized: "最近 20 场 · 14 天 · 最多 200 MB"))
            note(String(localized: "启动时及之后每小时检查一次，按以上期限自动清理。"))
            HStack(spacing: 10) {
                Button(String(localized: "立即清理")) { model.sweepNow() }
                if let t = model.lastSweep {
                    Text(String(localized: "上次：\(t.formatted(date: .omitted, time: .shortened))，删除 \(model.lastSweepRemoved) 项"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension DiagnosticRecorder.Track {
    var label: String {
        switch self {
        case .mic: String(localized: "麦克风")
        case .tts: String(localized: "合成语音")
        case .remote: String(localized: "对方")
        }
    }
}
