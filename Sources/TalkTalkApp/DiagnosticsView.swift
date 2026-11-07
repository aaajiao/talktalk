// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkSettingsUI

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
        case .privacy: SubtitleTokens.SettingsIcon.Page.privacy
        case .subtitles: SubtitleTokens.SettingsIcon.subtitles
        case .troubleshooting: SubtitleTokens.SettingsIcon.troubleshooting
        }
    }
    /// The card's help and VoiceOver hint (settings visual system §3.1).
    var summary: String {
        switch self {
        case .privacy: String(localized: "去向与保留")
        case .subtitles: String(localized: "检查本次字幕")
        case .troubleshooting: String(localized: "自检与导出")
        }
    }
}

/// Settings › 隐私与诊断 (ARCHITECTURE.md §11, §12; settings visual system §7.14–§7.16). View
/// state lives in `PrivacySettings` (an @Observable model): CLT has no SwiftUI macro plugin, so
/// no @State here. The sub-page cards and `DiagnosticsBanners` sit in the window's fixed band.
/// 数据与隐私 opens with DataBoundary, 字幕分析 is one flow, 故障检查 a flow whose nodes scroll to
/// the sections below; no footers or explanation lines, the long sentences are help.
struct DiagnosticsView: View {
    @Bindable var model: PrivacySettings
    @Bindable var navigation: SettingsNavigation
    @Bindable var state: AppState
    /// DataBoundary's right panel and the cloud self-test's consent and key presence (never the key).
    let translation: TranslationPage
    /// 技术详情 › 声音档案: the saved profile's numbers (moved here from 我的声音, §7.7).
    let voice: MyVoiceModel

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    private enum Anchor {
        static let selfTest = "diagnostics.selfTest"
        static let results = "diagnostics.results"
        static let export = "diagnostics.export"
    }

    /// The running session's start, for the translation model's baseline (DataBoundary stays
    /// connected while a session keeps the OpenAI directions it started with).
    private var session: Date? { state.meetingActive ? state.meetingStartedAt : nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Group {
                    switch navigation.diagnosticsTab {
                    case .privacy: privacyPage
                    case .subtitles: subtitlesPage
                    case .troubleshooting: troubleshootingPage(proxy)
                    }
                }
                .id(navigation.diagnosticsTab)
                // A menu recording row lands on 诊断录音 or 字幕分析 and flashes it (§8.1).
                .settingsAnchorTarget(navigation, proxy)
            }
        }
        .settingsPageScroll(navigation, subpage: navigation.diagnosticsTab)
        .onAppear {
            model.diagnosticsStatus.refresh()
            voice.reload()
            translation.load()
            translation.model?.trackSession(session)
        }
        .onChange(of: session) { _, start in translation.model?.trackSession(start) }
        .confirmationDialog(String(localized: "删除本场诊断录音？"), isPresented: $model.confirmDiscardRecording) {
            Button(String(localized: "删除"), role: .destructive) { model.recorder.discardCurrent() }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "本场已录的诊断音频会从这台 Mac 上删除。"))
        }
        .alert(String(localized: "会议没有在进行"), isPresented: $model.showRemoteRefused) {
            Button(String(localized: "好")) {}
        } message: {
            Text(String(localized: "对方的声音只能在会议进行时、经你当场确认所有参与者都同意之后才录。"))
        }
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .labelStyle(.settingsRow)
    }

    /// A node's in-page link (§6.3): scroll to its section and flash the anchor once.
    private func jump(_ anchor: String, _ proxy: ScrollViewProxy) {
        proxy.scrollTo(anchor, anchor: .top)
        navigation.flow.flash(anchor)
    }

    /// 本机 · <retention> · 不进诊断包: where a kind of data stays.
    private func retentionChips(_ duration: String, _ durationHelp: String, bundleHelp: String) -> [FactChip] {
        [FactChip(String(localized: "本机"), symbol: Icon.thisMac, help: String(localized: "仅存这台 Mac，只有你能读，不进备份")),
         FactChip(duration, symbol: Icon.duration, help: durationHelp),
         FactChip(String(localized: "不进诊断包"), symbol: Icon.diagnosticsBundle, help: bundleHelp)]
    }

    // MARK: 数据与隐私 (§7.14)

    private var privacyPage: some View {
        page {
            Section {
                // Drawn once the translation model has answered (a synchronous load on appear), so
                // the right panel never flashes "未连接" while text may still go to OpenAI.
                if translation.model != nil || translation.problem != nil {
                    DataBoundary(cloudEnabled: translation.model?.flowFacts.cloudConnected ?? false,
                                 info: [TranslationSettingsText.cloudNotice],
                                 link: NodeLink(String(localized: "识别与翻译 · 文本翻译")) {
                                     navigation.open(.translation, .model(.translation))
                                 })
                        .padding(.vertical, 4)
                }
            }
            Section {
                transcriptsToggle
                FactRow(retentionChips(String(localized: "30 天"), String(localized: "30 天后自动删除"),
                                       bundleHelp: String(localized: "诊断包不含文字记录")), indented: true)
            } header: {
                SectionHeader(String(localized: "文字记录"), symbol: Icon.transcripts)
            }
            Section {
                Label("Key：仅钥匙串", systemImage: Icon.apiKey)
                    .help("不进日志、不进诊断包")
                    .accessibilityHint(String(localized: "OpenAI key 只在登录钥匙串里，不进日志，也不进诊断包。"))
                Label("日志：不含文字和音频", systemImage: Icon.logs)
                    .help("只记 id、长度、耗时和错误码")
                    .accessibilityHint(String(localized: "常规日志只记 id、长度、耗时和错误码，不记文字、音频和路径。只有明确开启的本次字幕分析会另外保存文字。"))
            }
            Section {
                LabeledContent {
                    Text("24 小时")
                } label: {
                    Label("诊断录音 · 字幕分析", systemImage: Icon.recording)
                }
                LabeledContent {
                    Text("30 天")
                } label: {
                    Label("文字记录", systemImage: Icon.transcripts)
                }
                LabeledContent {
                    Text("20 场 · 14 天 · 200 MB").monospacedDigit()
                } label: {
                    Label("延迟事件", systemImage: Icon.performance)
                }
                .help("最近 20 场、14 天内、合计不超过 200 MB")
                HStack(spacing: 8) {
                    Button { model.sweepNow() } label: {
                        Label("立即清理", systemImage: Icon.delete).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("按以上期限清理")
                    Spacer(minLength: 8)
                    if let t = model.lastSweep {
                        Text(String(localized: "\(t.formatted(date: .omitted, time: .shortened)) · 删除 \(model.lastSweepRemoved)"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("上次清理的时间和删除的项数")
                    }
                }
            } header: {
                SectionHeader(String(localized: "自动清理"), symbol: Icon.autoCleanup,
                              info: [String(localized: "启动时及之后每小时检查一次。")])
            }
        }
    }

    /// §16 decision 7: off by default; the Finder button while saving is on or the folder exists.
    private var transcriptsToggle: some View {
        LabeledContent {
            HStack(spacing: 8) {
                IconButton(Icon.finder, help: String(localized: "在 Finder 中显示"),
                           accessibilityLabel: String(localized: "在 Finder 中显示文字记录")) { model.revealTranscripts() }
                    .disabled(!model.canRevealTranscripts)
                InfoButton(topic: String(localized: "文字记录"), lines: [String(localized: "文件仅当前用户可读，不进入备份。")])
                Toggle(String(localized: "保存文字记录"), isOn: $model.saveTranscripts)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityHint(String(localized: "保存会议原文和译文"))
            }
        } label: {
            Label("保存文字记录", systemImage: Icon.transcripts)
        }
    }

    // MARK: 字幕分析 (§7.15)

    private var subtitlesPage: some View {
        page {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    analysisFlow
                    // Six chips: one line when they fit, else two rows of three.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { ForEach(analysisChips.indices, id: \.self) { analysisChips[$0] } }
                        VStack(alignment: .leading, spacing: 6) {
                            FactRow(Array(analysisChips.prefix(3)))
                            FactRow(Array(analysisChips.suffix(3)))
                        }
                    }
                }
                .padding(.vertical, 4)
                .flowFlash(SettingsAnchor.subtitleAnalysis, in: navigation.flow)
            }
            .id(SettingsAnchor.subtitleAnalysis)
        }
    }

    private var analysisChips: [FactChip] {
        [FactChip(String(localized: "仅文字"), symbol: Icon.textOnly, help: String(localized: "记录原文、译文和各阶段耗时")),
         FactChip(String(localized: "不录音"), symbol: Icon.noMicrophone, help: String(localized: "不保存任何音频")),
         FactChip(String(localized: "仅本次"), symbol: Icon.oneSession, help: String(localized: "会话结束自动停止；每次会话需单独开启"))]
            + retentionChips(String(localized: "24 小时"), String(localized: "24 小时后自动清理"),
                             bundleHelp: String(localized: "诊断包不含字幕分析"))
    }

    private var analysisFlow: FlowGrid {
        let analysis = model.subtitleAnalysis
        let running = model.recorder.meetingRunning
        let listen = FlowNode(String(localized: "收听"), glyph: .symbol(Icon.listen), state: running ? .live : .off,
                              link: running ? nil : NodeLink(SettingsSection.meeting.title) { navigation.open(.meeting) },
                              help: running ? String(localized: "会话进行中") : String(localized: "先开始会话"))
        let badge = Self.analysisBadge(analysis.outcome)
        let analyse = FlowNode(String(localized: "分析"), glyph: .symbol(Icon.recording), badge: badge.status,
                               badgeReason: badge.text, accessory: .controls { analysisButton },
                               help: badge.help ?? (running ? nil : String(localized: "先开始会话")))
        let record = FlowNode(String(localized: "记录"), glyph: .symbol(Icon.inspectFile), accessory: .controls { recordControls })
        return FlowGrid(String(localized: "字幕分析步骤"), lanes: [
            FlowLane(String(localized: "字幕分析"), cells: [.node(listen), .node(analyse), .node(record)])
        ])
    }

    /// The 分析 node's badge: its word, and the recorder's old sentence as help.
    static func analysisBadge(_ outcome: SubtitleAnalysisRecorder.Outcome) -> SettingsProblem {
        switch outcome {
        case .off: SettingsProblem(.pending, String(localized: "未开启"))
        case .starting: SettingsProblem(.busy, String(localized: "准备中"), help: String(localized: "正在创建分析文件"))
        case .recording: SettingsProblem(.recording, String(localized: "记录中"))
        case .stopped: SettingsProblem(.ok, String(localized: "已停止"))
        case .sessionEnded: SettingsProblem(.ok, String(localized: "已停止"), help: String(localized: "本次会话已结束，分析已停止"))
        case .limitReached: SettingsProblem(.warn, String(localized: "达上限"),
                                            help: String(localized: "已达到 8 MiB 或 10,000 行上限，分析自动停止"))
        case .failed: SettingsProblem(.failed, String(localized: "写入失败"), help: String(localized: "无法写入分析文件，分析已停止"))
        }
    }

    @ViewBuilder private var analysisButton: some View {
        let analysis = model.subtitleAnalysis
        if analysis.isRecording || analysis.isStarting {
            Button(String(localized: "停止")) { analysis.stop() }
                .controlSize(.small)
                .accessibilityLabel(String(localized: "停止字幕分析"))
        } else {
            // "（含文字）" is a privacy fact: it goes only when the node is too narrow, and stays in
            // the help and the VoiceOver label.
            ViewThatFits(in: .horizontal) {
                startButton(String(localized: "开始分析（含文字）"))
                startButton(String(localized: "开始分析"))
            }
        }
    }

    private func startButton(_ title: String) -> some View {
        let running = model.recorder.meetingRunning
        return Button(title) { model.startSubtitleAnalysis() }
            .controlSize(.small)
            .disabled(!running)
            .help(running ? String(localized: "开始分析（含文字）：记录本次原文和译文，不录音") : String(localized: "先开始会话"))
            .accessibilityLabel(String(localized: "开始分析（含文字）"))
            .accessibilityHint(String(localized: "显示时间是字幕面板提交更新的时间；隐藏面板会另行标记。没有参考原文时，耗时和文字记录不代表翻译准确率。每次会话都需要单独开启分析。"))
    }

    private var recordControls: some View {
        let analysis = model.subtitleAnalysis
        let copyHelp = analysis.fileURL.map { String(localized: "复制分析文件路径：\($0.path)") }
            ?? String(localized: "复制分析文件路径")
        return HStack(spacing: 0) {
            Text(String(localized: "\(analysis.recordCount) 行"))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            IconButton(Icon.copy, help: copyHelp, accessibilityLabel: String(localized: "复制分析文件路径")) { analysis.copyPath() }
                .disabled(analysis.fileURL == nil)
            IconButton(Icon.finder, help: String(localized: "在 Finder 中显示"),
                       accessibilityLabel: String(localized: "在 Finder 中显示分析文件")) { analysis.revealFile() }
                .disabled(analysis.fileURL == nil)
            InfoButton(topic: String(localized: "记录"),
                       lines: [String(localized: "记录原文、译文和各阶段耗时，用于检查漏句与积压；8 MiB 或 1 万行自动停止。")])
        }
    }

    // MARK: 故障检查 (§7.16)

    private func troubleshootingPage(_ proxy: ScrollViewProxy) -> some View {
        page {
            Section {
                troubleshootingFlow(proxy).padding(.vertical, 4)
            }
            Section {
                selfTestRows
                selfTestResults
            } header: {
                SectionHeader(String(localized: "自检"), symbol: Icon.verify)
                    .flowFlash(Anchor.selfTest, in: navigation.flow)
            }
            .id(Anchor.selfTest)
            Section {
                exportRows
            } header: {
                SectionHeader(String(localized: "导出"), symbol: Icon.export, info: [
                    String(localized: "包含日志、延迟事件、版本、install.json 和设备名；发现疑似 key 时停止导出。")
                ])
                .flowFlash(Anchor.export, in: navigation.flow)
            }
            .id(Anchor.export)
            Section {
                recordingRows
            } header: {
                SectionHeader(String(localized: "诊断录音"), symbol: Icon.recording, info: [
                    String(localized: "录音存在本机 diagnostics 文件夹，只有你能读，不进备份。")
                ])
                .flowFlash(SettingsAnchor.diagnosticRecording, in: navigation.flow)
            }
            .id(SettingsAnchor.diagnosticRecording)
            Section {
                DisclosureGroup {
                    latency
                    offlineCommands
                    voiceProfile
                } label: {
                    Label("技术详情", systemImage: Icon.performance)
                }
            }
        }
    }

    /// 通过 / 未通过 / 未完成 of the last report, nil before one.
    private var selfTestSummary: SettingsProblem? {
        guard let report = model.diagnosticsStatus.report else { return nil }
        if report.ok { return SettingsProblem(.ok, String(localized: "通过")) }
        if report.checks.contains(where: { $0.ok == false }) { return SettingsProblem(.failed, String(localized: "未通过")) }
        return SettingsProblem(.warn, String(localized: "未完成"))
    }

    private func troubleshootingFlow(_ proxy: ScrollViewProxy) -> FlowGrid {
        let status = model.diagnosticsStatus
        let running = status.runningPart != nil
        let summary = selfTestSummary
        let test = FlowNode(String(localized: "自检"), glyph: .symbol(Icon.verify),
                            badge: running ? .busy : summary?.status,
                            badgeReason: running ? String(localized: "检查中") : summary?.text,
                            link: NodeLink(String(localized: "自检")) { jump(Anchor.selfTest, proxy) })
        let results = FlowNode(String(localized: "结果"), glyph: .symbol(Icon.results),
                               state: summary == nil ? .dimmed : .ready,
                               link: summary == nil ? nil : NodeLink(String(localized: "结果")) { jump(Anchor.results, proxy) },
                               help: summary == nil ? String(localized: "先运行自检") : nil)
        let export = FlowNode(String(localized: "导出"), glyph: .symbol(Icon.export),
                              badge: model.exporting ? .busy : model.exportResult?.status,
                              badgeReason: model.exporting ? String(localized: "导出中") : model.exportResult?.text,
                              link: NodeLink(String(localized: "导出")) { jump(Anchor.export, proxy) })
        return FlowGrid(String(localized: "故障检查步骤"), lanes: [
            FlowLane(String(localized: "故障检查"), cells: [.node(test), .node(results), .node(export)])
        ])
    }

    /// Why the cloud self-test cannot run, in the runner's order (`cloudSelfTest`): consent, a
    /// direction on OpenAI, a key (its presence only). nil when it can, or while the translation
    /// model has not answered (the test reports it).
    private var cloudBlocked: String? {
        guard let m = translation.model, m.keyStateKnown else { return nil }
        if !m.preferences.cloudConsentGiven { return String(localized: "先同意发送文字") }
        if !m.preferences.anyCloud { return String(localized: "先开启 OpenAI 翻译") }
        if !m.hasKey { return String(localized: "先保存 key") }
        return nil
    }

    /// Why the engine self-test cannot run; nil when it can (it stops the engine first).
    private var engineBlocked: String? {
        let status = model.diagnosticsStatus
        if model.recorder.meetingRunning { return String(localized: "先结束会话") }
        if status.runningPart == nil, !status.audioSelfTestAvailable { return String(localized: "先结束说话测试、录音和试听") }
        return nil
    }

    @ViewBuilder private var selfTestRows: some View {
        let status = model.diagnosticsStatus
        HStack(spacing: 8) {
            Button { status.runEngine() } label: {
                Label("本地引擎", systemImage: Icon.engine).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(engineBlocked != nil || status.runningPart != nil)
            Spacer(minLength: 8)
            if status.runningPart == "--engine" {
                StatusGlyph(.busy).accessibilityLabel(String(localized: "正在检查本地引擎"))
            }
        }
        .help(engineBlocked ?? String(localized: "会先停止引擎"))
        HStack(spacing: 8) {
            Button { status.runCloud() } label: {
                Label("云端翻译", systemImage: Icon.cloud).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(cloudBlocked != nil || status.runningPart != nil)
            FactChip(String(localized: "计费"), symbol: Icon.cost, help: String(localized: "发送少量测试文字，产生费用"))
            Spacer(minLength: 8)
            if status.runningPart == "--cloud" {
                StatusGlyph(.busy).accessibilityLabel(String(localized: "正在检查云端翻译"))
            }
        }
        .help(cloudBlocked ?? String(localized: "发送少量测试文字，产生费用"))
    }

    @ViewBuilder private var selfTestResults: some View {
        if let report = model.diagnosticsStatus.report, let summary = selfTestSummary {
            StatusLabel(summary.text, summary.status)
                .padding(.leading, Ladder.rowTextInset)
                .flowFlash(Anchor.results, in: navigation.flow)
                .id(Anchor.results)
            ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                HStack(spacing: 8) {
                    StatusGlyph(check.ok == true ? .ok : check.ok == false ? .failed : .pending)
                    Text(verbatim: check.name).font(.callout.monospaced())
                    Spacer(minLength: 8)
                    if let detail = check.detail {
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            .help(detail)
                    }
                }
                .padding(.leading, Ladder.rowTextInset)
            }
            if report.checks.contains(where: { !$0.values.isEmpty }) {
                DisclosureGroup {
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
                } label: {
                    Label("数值", systemImage: Icon.checkValues)
                }
            }
        }
    }

    @ViewBuilder private var exportRows: some View {
        HStack(spacing: 8) {
            Button { model.exportBundle() } label: {
                Label("导出诊断包…", systemImage: Icon.export).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.exporting)
            FactChip(String(localized: "不含 key 与文字"), symbol: Icon.privacyPromise,
                     help: String(localized: "不含声音档案、文字记录、字幕分析、诊断录音、术语表、OpenAI key 或请求头"))
            Spacer(minLength: 8)
            if model.exporting {
                StatusGlyph(.busy).accessibilityLabel(String(localized: "正在导出诊断包"))
            }
        }
        if let result = model.exportResult {
            StatusLabel(result.text, result.status, help: result.help)
                .padding(.leading, Ladder.rowTextInset)
        }
    }

    @ViewBuilder private var recordingRows: some View {
        let r = model.recorder
        LabeledContent {
            HStack(spacing: 8) {
                FactChip(r.meetingRunning ? String(localized: "仅本场") : String(localized: "仅下一场"), symbol: Icon.oneSession,
                         help: r.meetingRunning ? String(localized: "本场会议正在进行，选择只对这一场有效，会议结束就恢复为不录")
                                                : String(localized: "现在没有会议，选择只对下一场会议有效"))
                Toggle(String(localized: "录我这边（麦克风＋译音）"),
                       isOn: Binding(get: { r.micAndTTSArmed }, set: { r.setMicAndTTS($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        } label: {
            Label("录我这边（麦克风＋译音）", systemImage: Icon.physicalMic)
        }
        if r.recordingTracks.contains(.remote) {
            HStack(spacing: 8) {
                Label {
                    Text("正在录对方的声音").foregroundStyle(.red)
                } icon: {
                    Image(systemName: Icon.recordingActive).foregroundStyle(.red)
                }
                Spacer(minLength: 8)
                Button(String(localized: "停止")) { r.stopRemote() }
                    .accessibilityLabel(String(localized: "停止录对方的声音"))
            }
        } else {
            HStack(spacing: 8) {
                Button { model.requestRemoteRecording() } label: {
                    Label("录对方的声音…", systemImage: Icon.remote).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!r.meetingRunning)
                .help(r.meetingRunning ? String(localized: "先当场确认所有参与者都已同意录音") : String(localized: "会议进行时才能录"))
                FactChip(String(localized: "需全员同意（§201）"), symbol: Icon.consent, tone: .warn,
                         help: String(localized: "对方的声音只在会议进行时、你当场确认“所有参与者都已同意录音”之后才录（德国《刑法典》§201）。"))
                Spacer(minLength: 8)
            }
        }
        HStack(spacing: 8) {
            Button(role: .destructive) { model.confirmDiscardRecording = true } label: {
                Label("删除本场录音…", systemImage: Icon.delete).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .labelStyle(.settingsRowDestructive)
            .disabled(r.sessionDirectory == nil)
            .help("停止并删除本场诊断录音")
            Spacer(minLength: 8)
            IconButton(Icon.finder, help: String(localized: "在 Finder 中显示"),
                       accessibilityLabel: String(localized: "在 Finder 中显示诊断录音")) { model.revealDiagnostics() }
                .disabled(!model.hasDiagnostics)
        }
        FactRow(retentionChips(String(localized: "24 小时"), String(localized: "24 小时后自动删除"),
                               bundleHelp: String(localized: "诊断包不含诊断录音")), indented: true)
        if let e = r.lastError {
            StatusLabel(String(localized: "诊断录音无法开始"), .failed, help: e)
                .padding(.leading, Ladder.rowTextInset)
        }
    }

    // MARK: 技术详情

    /// 性能: one table (the p50 | p90 header once) over the last 3 sessions' log tails.
    private var latency: some View {
        let status = model.diagnosticsStatus
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionHeader(String(localized: "性能"), symbol: Icon.performance)
                    .help("最近 3 场日志末尾；原始时延")
                    .accessibilityHint(String(localized: "只读取最近 3 场日志的末尾，每场最多 512 KiB。时延是原始记录，尚未扣除队列、直通或告知语时间；缺少记录的指标显示 —，不会由其他时延推算。"))
                if status.snapshot.truncated {
                    StatusLabel(String(localized: "仅末尾"), .warn, help: String(localized: "较大的日志只读取末尾，统计不代表全场。"))
                }
                Spacer(minLength: 8)
                if let date = status.refreshedAt {
                    let time = date.formatted(date: .omitted, time: .shortened)
                    HStack(spacing: 4) {
                        Image(systemName: Icon.duration)
                            .font(.system(size: Ladder.inline))
                            .accessibilityHidden(true)
                        Text(verbatim: time).font(.caption).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .help("上次读取的时间")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(String(localized: "上次读取 \(time)")))
                }
                if status.refreshing {
                    // In the refresh button's 22 pt place, so the header does not shift.
                    StatusGlyph(.busy)
                        .frame(width: Ladder.hitArea, height: Ladder.hitArea)
                        .accessibilityLabel(String(localized: "正在读取延迟记录"))
                } else {
                    IconButton(Icon.refresh, help: String(localized: "重新读取延迟记录")) { status.refresh() }
                }
            }
            if status.snapshot.rows.isEmpty {
                Text("无记录").foregroundStyle(.secondary).padding(.leading, Ladder.rowTextInset)
            } else {
                metrics(status)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(status.snapshot.rows.reversed()) { row in
                        HStack(spacing: 8) {
                            Image(systemName: row.kind == .speak ? Icon.physicalMic : Icon.listen)
                                .font(.system(size: Ladder.inline))
                                .foregroundStyle(.secondary)
                                .frame(width: Ladder.rowColumn)
                                .accessibilityLabel(row.kind == .speak ? String(localized: "说") : String(localized: "听"))
                            Text("段 \(row.segment)").font(.caption)
                            Spacer(minLength: 8)
                            Text(verbatim: milliseconds(row.milliseconds)).font(.caption.monospacedDigit())
                            if row.kind == .speak {
                                Text(verbatim: "RTF \(ratio(row.computeRTF))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func metrics(_ status: DiagnosticsStatus) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            // Modifiers go on the cells: one on a GridRow would make it a single cell.
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                columnTitle("p50")
                columnTitle("p90")
            }
            metricRow(Icon.physicalMic, Icon.speech, String(localized: "提交 → 首声"),
                      milliseconds(status.percentile(.speak, 0.5)), milliseconds(status.percentile(.speak, 0.9)),
                      help: String(localized: "SPEAK 提交到首声"))
            metricRow(Icon.listen, Icon.subtitles, String(localized: "定稿 → 译文"),
                      milliseconds(status.percentile(.listen, 0.5)), milliseconds(status.percentile(.listen, 0.9)),
                      help: String(localized: "LISTEN 定稿触发到译文"))
            metricRow(Icon.stop, Icon.speech, String(localized: "结束 → 首声"),
                      milliseconds(status.releasePercentile(0.5)), milliseconds(status.releasePercentile(0.9)),
                      help: String(localized: "结束翻译到首声；结束前已出声或强制结束的发言不计入"))
            metricRow(Icon.engine, nil, "RTF", ratio(status.rtfPercentile(0.5)), ratio(status.rtfPercentile(0.9)),
                      help: String(localized: "TTS GPU 实时率"))
            GridRow {
                pairIcon(Icon.speaker, nil)
                Text("欠载").help("最近首声时的本场累计欠载，不是每段欠载率")
                let underruns = status.latestUnderrunsTotal.map { String($0) } ?? "—"
                Text(verbatim: underruns)
                    .monospacedDigit()
                    .gridCellColumns(2)
                    .gridCellAnchor(.trailing)
                    .accessibilityLabel(Text(String(localized: "本场累计欠载 \(underruns)")))
            }
        }
    }

    private func columnTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func metricRow(_ from: String, _ to: String?, _ title: String, _ p50: String, _ p90: String,
                           help: String) -> some View {
        GridRow {
            pairIcon(from, to)
            Text(verbatim: title).help(help)
            // The p50 / p90 header is written once; VoiceOver hears it on every cell.
            Text(verbatim: p50).monospacedDigit().accessibilityLabel(Text(verbatim: "p50 \(p50)"))
            Text(verbatim: p90).monospacedDigit().accessibilityLabel(Text(verbatim: "p90 \(p90)"))
        }
    }

    /// The metric's icon pair (`mic → speaker.wave.2`) at 13 pt.
    private func pairIcon(_ from: String, _ to: String?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: from)
            if let to {
                Image(systemName: Icon.flowArrow).font(.system(size: Ladder.micro, weight: .semibold))
                Image(systemName: to)
            }
        }
        .font(.system(size: Ladder.inline))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "—"
    }

    private func ratio(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }

    /// 离线命令: copy a Terminal command; the tests need TalkTalk to have quit.
    private var offlineCommands: some View {
        let status = model.diagnosticsStatus
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(String(localized: "离线命令"), symbol: Icon.offlineCommands,
                          info: [String(localized: "先退出 TalkTalk，再在终端执行复制的命令。")])
            HStack(spacing: 8) {
                commandButton(String(localized: "驱动"), "--driver", help: String(localized: "复制驱动自检命令"))
                commandButton(String(localized: "声音"), "--voice", help: String(localized: "复制声音自检命令"))
                commandButton(String(localized: "回环"), "--loop", help: String(localized: "复制回环自检命令"))
                commandButton(String(localized: "直通"), "--passthrough", help: String(localized: "仅离线独占；会中检查在“组件”页"))
                Spacer(minLength: 8)
                if status.copied {
                    StatusLabel(String(localized: "已复制"), .ok,
                                help: String(localized: "先退出 TalkTalk，再在终端执行；结果写入命令指定的文件。"))
                }
            }
            .padding(.leading, Ladder.rowTextInset)
        }
    }

    private func commandButton(_ title: String, _ part: String, help: String) -> some View {
        Button { model.diagnosticsStatus.copyCommand(part) } label: {
            Label(title, systemImage: Icon.copy).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The saved profile (§7.16): reference length and speaking rate, the automatic checks and the
    /// voice cache as glyphs with their words in help. Nothing without a profile.
    @ViewBuilder private var voiceProfile: some View {
        if let p = voice.profile {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(verbatim: p.referenceText).monospacedDigit().foregroundStyle(.secondary)
                    StatusGlyph(p.checkWarnings == 0 ? .ok : .warn)
                        .help(p.checksText)
                        .accessibilityLabel(p.checksText)
                    StatusGlyph(p.conditioningBuilt ? .ok : .waiting)
                        .help(p.conditioningBuilt ? String(localized: "声音缓存已建立") : String(localized: "声音缓存在引擎预热时建立"))
                        .accessibilityLabel(p.conditioningBuilt ? String(localized: "声音缓存已建立")
                                                                : String(localized: "声音缓存在引擎预热时建立"))
                }
            } label: {
                Label("声音档案", systemImage: Icon.myVoice)
            }
        } else if voice.profileUnreadable {
            LabeledContent {
                StatusLabel(String(localized: "无法读取"), .warn)
            } label: {
                Label("声音档案", systemImage: Icon.myVoice)
            }
        }
    }
}

/// Z1b of 隐私与诊断 (settings visual system §2, §3.14): pinned under the card row on all three
/// sub-pages while a diagnostic recording runs or is set, and while the subtitle analysis saves
/// text. Each banner leads to the sub-page that controls it, except on that sub-page.
struct DiagnosticsBanners: View {
    let model: PrivacySettings
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        let recorder = model.recorder
        let analysis = model.subtitleAnalysis
        VStack(spacing: 0) {
            if !recorder.recordingTracks.isEmpty {
                RecordingBanner(String(localized: "录音中：") + DiagnosticRecorder.Track.allCases
                                    .filter(recorder.recordingTracks.contains)
                                    .map(\.label)
                                    .joined(separator: " · "),
                                kind: .recording, link: link(.troubleshooting, String(localized: "查看诊断录音")))
            } else if recorder.micAndTTSArmed {
                RecordingBanner(recorder.meetingRunning ? String(localized: "本场将录音") : String(localized: "下场将录音"),
                                kind: .planned, link: link(.troubleshooting, String(localized: "查看诊断录音")))
            }
            if analysis.isStarting || analysis.isRecording {
                RecordingBanner(String(localized: "正在保存字幕文字"), kind: analysis.isStarting ? .preparing : .analysing,
                                link: link(.subtitles, String(localized: "查看字幕分析")))
            }
        }
    }

    private func link(_ tab: DiagnosticsSettingsTab, _ destination: String) -> NodeLink? {
        guard navigation.diagnosticsTab != tab else { return nil }
        return NodeLink(destination) { navigation.diagnosticsTab = tab }
    }
}

extension DiagnosticRecorder.Track {
    /// The banner's track names (录音中：我 · 译音 · 对方).
    var label: String {
        switch self {
        case .mic: String(localized: "我")
        case .tts: String(localized: "译音")
        case .remote: String(localized: "对方")
        }
    }
}
