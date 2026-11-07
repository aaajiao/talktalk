// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkSettingsUI

/// Settings › 安装与维护 › 语音资源 (ARCHITECTURE.md §7.3–§7.5, §11), on top of M0's @Observable
/// `EngineInstaller`. The engine itself belongs to EngineHost (AppDelegate), which hands in
/// `restart` and `stopEngine`; AppUIModels.shared is built before it, so both are set later.
@MainActor
@Observable
final class EngineComponentsModel {
    let paths: EnginePaths
    let installer: EngineInstaller?
    private(set) var state: EngineInstallation.State = .notInstalled
    private(set) var record: EngineInstallation.Record?
    var profile: String
    /// Set by the engine owner; nil: no engine instance. Returns nil on success, else what to show.
    @ObservationIgnored var restart: (() async -> String?)?
    /// Every installer run (install, repair, profile change, models, uninstall) stops the running
    /// engine first, so pip / python are not replaced under it and smoke_engine.py does not load
    /// a second copy of the models next to it.
    @ObservationIgnored var stopEngine: (@MainActor () async -> Void)? {
        get { stopHook.stop }
        set { stopHook.stop = newValue }
    }
    @ObservationIgnored private let stopHook: EngineStopHook
    /// Something else is using the engine installation right now: 完全卸载 (DriverComponentsPage
    /// sets it). Install, check, models, uninstall and restart wait; the closure reads observable
    /// state, so the rows update by themselves (review of 639f957 #2).
    @ObservationIgnored var blockedBy: (@MainActor () -> Bool)?
    var blocked: Bool { blockedBy?() ?? false }
    private(set) var restarting = false
    /// The last install, check, model or restart run's outcome (the 引擎 section's result row).
    private(set) var lastResult: SettingsProblem?

    static let profiles = EngineProfile.allCases.map(\.rawValue)

    init(paths: EnginePaths = .standard()) {
        self.paths = paths
        let hook = EngineStopHook()
        stopHook = hook
        installer = paths.installerScript.map { EngineInstaller(script: $0, paths: paths, stopEngine: { await hook.run() }) }
        profile = EngineProfile.standard.rawValue
        reload()
    }

    func reload() {
        let r = EngineInstallation(engineHome: paths.engineHome()).check()
        state = r.state
        record = r.record
        if let installedProfile { profile = installedProfile.rawValue }
    }

    /// Active roles describe the installed combination; a stale recorded label is not proof
    /// of a preset. A custom combination stays runnable without silently choosing a new preset.
    var installedProfile: EngineProfile? {
        guard let record else { return nil }
        return EngineProfile.matching(record: record)
    }

    var usesAppleRecognition: Bool {
        installed && installedProfile?.usesAppleRecognition == true
    }

    var installed: Bool { state.canStartEngine }
    var running: Bool { installer?.state.isRunning ?? false }
    /// No engine action can start now: one runs, the engine restarts, 完全卸载 runs, or this
    /// build has no installer.
    var busy: Bool { running || restarting || installer == nil || blocked }

    /// Pinned model bytes of a profile (the runtime comes on top).
    static func modelBytes(_ profile: String) -> Int64 {
        EngineProfile(rawValue: profile)?.modelBytes ?? 0
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    static func profileTitle(_ profile: String) -> String {
        EngineProfile.title(for: profile)
    }

    static func profileMenuTitle(_ profile: String) -> String {
        "\(profileTitle(profile)) · \(gb(modelBytes(profile)))"
    }

    static func profileSummary(_ profile: String) -> String {
        guard let choice = EngineProfile(rawValue: profile) else { return profileTitle(profile) }
        func name(_ role: String) -> String? {
            guard let id = choice.expectedRoles[role] else { return nil }
            return EnginePins.models.first { $0.key == id }?.repo.split(separator: "/").last.map(String.init)
        }
        return [name("tts").map { String(localized: "合成：\($0)") },
                (choice.usesAppleRecognition ? "Apple Speech" : name("asr")).map { String(localized: "识别：\($0)") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func confirmAndRun(_ op: InstallerOp) {
        guard let installer, !running, !restarting, !blocked else { return }
        if let (title, text, ok) = confirmation(op) {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.addButton(withTitle: ok)
            a.addButton(withTitle: String(localized: "取消"))
            NSApp.activate()
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        lastResult = nil
        Task {
            let s = await installer.run(op)
            switch s {
            case .finished: lastResult = SettingsProblem(.ok, String(localized: "完成"))
            case let .failed(why): lastResult = SettingsProblem(.failed, String(localized: "未完成"), help: why)
            case .cancelled: lastResult = SettingsProblem(.pending, String(localized: "已取消"))
            case .idle, .running: break
            }
            reload()
        }
    }

    /// The confirmations (§7.11), shortened to what the run costs.
    private func confirmation(_ op: InstallerOp) -> (String, String, String)? {
        switch op {
        case let .install(p):
            let prof = p ?? profile
            return (String(localized: "安装引擎（\(Self.profileTitle(prof))）？"),
                    String(localized: "从 Hugging Face 等下载约 \(Self.gb(Self.modelBytes(prof)))（另加运行时），可随时取消。"),
                    String(localized: "下载并安装"))
        case let .addModel(k):
            let b = EnginePins.models.first { $0.key == k }?.bytes ?? 0
            return (String(localized: "下载模型 \(k)？"), String(localized: "约 \(Self.gb(b))。"), String(localized: "下载"))
        case let .removeModel(k):
            return (String(localized: "删除模型 \(k)？"), String(localized: "以后要用时需要重新下载。"), String(localized: "删除模型"))
        case .uninstall:
            return (String(localized: "卸载引擎？"),
                    String(localized: "删除运行时和全部模型；我的声音、术语表和设置保留。"), String(localized: "卸载引擎"))
        case .check:
            return nil
        }
    }

    func cancel() { installer?.cancel() }

    func dismissResult() { lastResult = nil }

    func doRestart() {
        guard let restart, !restarting, !running, !blocked else { return }
        restarting = true
        lastResult = nil
        Task {
            let failure = await restart()
            restarting = false
            lastResult = failure.map { SettingsProblem(.failed, String(localized: "引擎未能重启"), help: $0) }
                ?? SettingsProblem(.ok, String(localized: "引擎已重启"))
        }
    }

    func revealLogs() {
        let urls = [paths.engineLog, paths.installLog].filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([paths.logs])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// The installation in the settings vocabulary (§7.11): one source for the 语音资源 card,
    /// the flow's badge and the 引擎 section's status row. Not installed is something to do
    /// (warn), a damaged record a failure; the full reason is the help.
    var status: SettingsProblem {
        switch state {
        case let .installed(p, _):
            SettingsProblem(.ok, String(localized: "已安装 · \(Self.profileTitle(p))"))
        case .notInstalled:
            SettingsProblem(.warn, String(localized: "未安装"))
        case let .outdated(p, _):
            SettingsProblem(.warn, String(localized: "可更新"), help: String(localized: "已安装 \(Self.profileTitle(p))，有新的推荐版本"))
        case let .incompatible(r):
            SettingsProblem(.warn, String(localized: "需更新运行时"), help: r)
        case let .incomplete(missing, bytes):
            SettingsProblem(.warn, String(localized: "缺 \(missing.count) 个文件 · \(Self.gb(bytes))"),
                            help: missing.joined(separator: "\n"))
        case .unfinished:
            SettingsProblem(.warn, String(localized: "未完成"), help: String(localized: "上次安装没有完成"))
        case let .damaged(r):
            SettingsProblem(.failed, String(localized: "记录损坏"), help: r)
        }
    }

    /// The card's corner: nothing once installed and current (no badge = ready).
    var problem: SettingsProblem? { status.status == .ok ? nil : status }

    /// A picker change is a pending install choice, not a change to the installed profile.
    var pendingProfileChange: SettingsProblem? {
        guard case let .installed(installedProfile, _) = state, installedProfile != profile else { return nil }
        return SettingsProblem(.pending, String(localized: "已安装 \(Self.profileTitle(installedProfile)) · 待切换为 \(Self.profileTitle(profile))"),
                               help: String(localized: "点击“换档”后安装所选档位"))
    }

    /// The installed model of a role ("asr", "tts") by its repository name, for help texts; nil
    /// while that role has no model.
    func modelName(role: String) -> String? {
        guard let key = record?.roles[role]?.id else { return nil }
        return EnginePins.models.first { $0.key == key }?.repo.split(separator: "/").last.map(String.init) ?? key
    }

    var needsRepair: Bool {
        switch state {
        case .incomplete, .unfinished, .damaged, .incompatible: true
        default: false
        }
    }

    /// The install lifecycle's steps (§7.11): 下载 → 安装 → 校验 → 就绪.
    enum Stage: Sendable {
        case download, install, verify, ready
    }

    /// The node that carries the installation's state: not installed starts at 下载, missing
    /// files and a damaged record are 校验's, the rest is 就绪's.
    var statusStage: Stage {
        switch state {
        case .notInstalled: .download
        case .incomplete, .damaged: .verify
        case .installed, .outdated, .incompatible, .unfinished: .ready
        }
    }

    /// The running step, from the installer's step names: the runtime and the models download,
    /// the packages install, the smoke test and --check verify.
    var activeStage: Stage? {
        guard case let .running(op, p)? = installer?.state else { return nil }
        switch p.step {
        case "python", "model": return .download
        case "venv": return .install
        case "smoke", "check": return .verify
        default:
            switch op {
            case .install, .addModel: return .download
            case .check: return .verify
            case .removeModel, .uninstall: return .install
            }
        }
    }

    /// The running step's progress; nil while nothing runs.
    var progress: InstallerProgress? {
        guard case let .running(_, p)? = installer?.state else { return nil }
        return p
    }

    /// "2/5 · 1.2/4.9 GB": the step count and the current file; the model's name is the help.
    static func progressText(_ p: InstallerProgress) -> String {
        var parts: [String] = []
        if let d = p.stepDone, let c = p.stepCount { parts.append("\(d)/\(c)") }
        if p.fileTotal > 0 { parts.append(fileText(p)) }
        return parts.isEmpty ? String(localized: "准备中") : parts.joined(separator: " · ")
    }

    /// "1.2/4.9 GB" of the file downloading now.
    static func fileText(_ p: InstallerProgress) -> String {
        "\(String(format: "%.1f", Double(p.fileHave) / 1e9))/\(gb(p.fileTotal))"
    }
}

private typealias Icon = SubtitleTokens.SettingsIcon
private typealias Ladder = SubtitleTokens.SettingsIcon.Size

/// The 引擎 section's rows (§7.11): 档位 with its actions (下载; or 修复 and/or 换档 / 更新) and the
/// 维护引擎 menu, the state, the running step's progress and the last outcome. Several rows: a
/// Form Section or a VStack lays them out.
struct EngineControlRows: View {
    @Bindable var model: EngineComponentsModel

    var body: some View {
        profileRow
        statusRow
        progressRow
        resultRow
    }

    private var profileRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker(String(localized: "档位"), selection: $model.profile) {
                    ForEach(EngineComponentsModel.profiles, id: \.self) { p in
                        Text(verbatim: EngineComponentsModel.profileMenuTitle(p))
                            .tag(p)
                            .help(EngineComponentsModel.profileSummary(p))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help(EngineComponentsModel.profileSummary(model.profile))
                .disabled(model.busy)
                primaryButton
                IconMenuButton(help: String(localized: "维护引擎"), items: maintenance)
                    .disabled(model.busy)
            }
        } label: {
            Label("档位", systemImage: Icon.engine)
        }
    }

    /// 下载 while nothing is installed. Otherwise 修复 when the installation needs it (it
    /// reinstalls the recorded profile) and, independently, 换档 once the picker differs from the
    /// recorded profile (also in the repair states), else 更新 for an outdated installation.
    @ViewBuilder private var primaryButton: some View {
        let recorded = model.installedProfile?.rawValue
        let custom = model.record != nil && recorded == nil
        let installing = InstallerOp.install(profile: model.profile)
        if model.state == .notInstalled {
            Button { model.confirmAndRun(installing) } label: {
                Label("下载", systemImage: Icon.download).labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
            .help(String(localized: "约 \(EngineComponentsModel.gb(EngineComponentsModel.modelBytes(model.profile)))，另加运行时"))
        } else {
            if model.needsRepair && !custom {
                Button { model.confirmAndRun(.install(profile: recorded ?? model.profile)) } label: {
                    Label("修复", systemImage: Icon.repair).labelStyle(.titleAndIcon)
                }
                .disabled(model.busy)
                .help(String(localized: "重新安装 \(EngineComponentsModel.profileTitle(recorded ?? model.profile))"))
            }
            if custom || recorded.map({ $0 != model.profile }) == true {
                Button("换档") { model.confirmAndRun(installing) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    .help(String(localized: "安装 \(EngineComponentsModel.profileTitle(model.profile))"))
            } else if case .outdated = model.state, let recorded {
                Button { model.confirmAndRun(.install(profile: recorded)) } label: {
                    Label("更新", systemImage: Icon.download).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
            }
        }
    }

    private var maintenance: [IconMenuItem] {
        let present = model.state != .notInstalled
        return [
            IconMenuItem(String(localized: "校验安装"), symbol: Icon.verify, isEnabled: present) { model.confirmAndRun(.check) },
            IconMenuItem(String(localized: "重启引擎"), symbol: Icon.restartEngine,
                         isEnabled: model.restart != nil && model.installed) { model.doRestart() },
            IconMenuItem(String(localized: "查看日志"), symbol: Icon.inspectFile) { model.revealLogs() },
            .separator,
            IconMenuItem(String(localized: "卸载引擎…"), symbol: Icon.delete, isEnabled: present,
                         isDestructive: true) { model.confirmAndRun(.uninstall) }
        ]
    }

    @ViewBuilder private var statusRow: some View {
        // The flow's ready badge and profile already describe a healthy installation.
        if let status = model.pendingProfileChange ?? model.problem {
            StatusLabel(status.text, status.status, help: status.help)
                .padding(.leading, Ladder.rowTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// While a run goes: the bar (or a spinner) and "2/5 · 1.2/4.9 GB", and 取消. While 完全卸载
    /// runs: waiting.
    @ViewBuilder private var progressRow: some View {
        if let p = model.progress {
            HStack(spacing: 8) {
                if p.fileTotal > 0 {
                    ProgressView(value: Double(p.fileHave), total: Double(p.fileTotal))
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                        .accessibilityLabel(String(localized: "下载进度"))
                } else {
                    StatusGlyph(.busy)
                }
                Text(verbatim: EngineComponentsModel.progressText(p))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(ifPresent: p.model)
                Spacer(minLength: 8)
                IconButton(Icon.cancel, help: String(localized: "取消")) { model.cancel() }
            }
            .padding(.leading, Ladder.rowTextInset)
        } else if model.blocked {
            StatusLabel(String(localized: "完全卸载中"), .waiting, help: String(localized: "结束后才能操作引擎"))
                .padding(.leading, Ladder.rowTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.restarting {
            StatusLabel(String(localized: "引擎重启中"), .busy)
                .padding(.leading, Ladder.rowTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var resultRow: some View {
        if let result = model.lastResult {
            HStack(spacing: 8) {
                StatusLabel(result.text, result.status, help: result.help)
                Spacer(minLength: 8)
                IconButton(Icon.close, help: String(localized: "知道了"),
                           accessibilityLabel: String(localized: "关闭结果")) { model.dismissResult() }
            }
            .padding(.leading, Ladder.rowTextInset)
        }
    }
}

/// The 模型 section's rows (§7.11): each pinned model with its size and revision, whether it is
/// installed, and delete or download.
struct EngineModelRows: View {
    @Bindable var model: EngineComponentsModel

    var body: some View {
        let installedKeys = Set(model.record?.models.map(\.id) ?? [])
        ForEach(EnginePins.models, id: \.key) { m in
            row(m, installed: installedKeys.contains(m.key))
        }
    }

    private func row(_ m: EnginePins.Model, installed: Bool) -> some View {
        let role = m.role == "asr" ? String(localized: "语音识别") : String(localized: "语音合成")
        // Match the installer's protection of a preset's active models before asking for
        // confirmation. Merely downloaded spare models remain independently removable.
        let protected = model.installedProfile != nil
            && (model.record?.roles.values.contains(where: { $0.id == m.key }) ?? false)
        return LabeledContent {
            HStack(spacing: 8) {
                Text(verbatim: "\(EngineComponentsModel.gb(m.bytes)) · \(m.revision.prefix(7))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if installed {
                    let word = model.installed ? String(localized: "已安装") : String(localized: "待校验")
                    StatusGlyph(model.installed ? .ok : .warn)
                        .help(word)
                        .accessibilityLabel(word)
                    IconButton(Icon.delete, help: protected
                        ? String(localized: "当前档位正在使用此模型；切换档位后可删除")
                        : String(localized: "删除模型 \(m.key)"),
                               accessibilityLabel: String(localized: "删除模型 \(m.key)"), isDestructive: true) {
                        model.confirmAndRun(.removeModel(m.key))
                    }
                    .disabled(protected)
                } else {
                    IconButton(Icon.download, help: String(localized: "下载 \(m.key)")) { model.confirmAndRun(.addModel(m.key)) }
                        .disabled(!model.installed)
                }
            }
            .disabled(model.busy)
        } label: {
            Label {
                Text(verbatim: m.key).monospaced()
            } icon: {
                Image(systemName: m.role == "asr" ? Icon.recognition : Icon.speech)
            }
            .help(role)
            .accessibilityHint(role)
        }
    }
}

/// A development binary without the installer (§5.2, §7.11): the reason is the help.
struct EngineUnavailableView: View {
    var body: some View {
        ContentUnavailableView(String(localized: "此构建不可用"), systemImage: Icon.unavailable)
            .help(String(localized: "这个构建里没有安装器（直接运行的二进制）：用 TalkTalk.app / TalkTalk-Dev.app。"))
    }
}

/// 安装与维护 › 语音资源's graphic (§7.11): the install lifecycle in one lane, every node leading to
/// the 引擎 section (`link`). The installation's state sits on its step (`statusStage`); the
/// running step shows a spinner badge and 取消, 下载 its file's progress, 就绪 the 档位 chip.
@MainActor
extension FlowGrid {
    static func engine(_ model: EngineComponentsModel, link: NodeLink) -> FlowGrid {
        let active = model.activeStage
        let status = model.pendingProfileChange ?? model.status
        func node(_ stage: EngineComponentsModel.Stage, _ title: String, _ symbol: String) -> FlowNode {
            let running = stage == active
            let badge: SettingsProblem? = running ? SettingsProblem(.busy, String(localized: "进行中"))
                : model.statusStage == stage ? status : nil
            let accessory: NodeAccessory? = running ? .controls { EngineStageProgress(model: model, stage: stage) }
                : stage == .ready ? .controls { EngineProfileChip(model: model) } : nil
            return FlowNode(title, glyph: .symbol(symbol),
                            state: badge.map { $0.status == .warn || $0.status == .failed } == true ? .needsAction : .ready,
                            badge: badge?.status, badgeReason: badge?.text,
                            // The running step keeps its width for progress and 取消: no chevron.
                            link: running ? nil : link, accessory: accessory, help: badge?.help)
        }
        return FlowGrid(String(localized: "引擎安装步骤"), lanes: [
            FlowLane(String(localized: "引擎"), cells: [
                .node(node(.download, String(localized: "下载"), Icon.download)),
                .node(node(.install, String(localized: "安装"), Icon.install)),
                .node(node(.verify, String(localized: "校验"), Icon.verify)),
                .node(node(.ready, String(localized: "就绪"), Icon.engine))
            ])
        ])
    }
}

/// The running step's accessory: 下载's progress ring and "1.2/4.9 GB" while a file downloads
/// (the ring alone when the node is narrow), and 取消.
private struct EngineStageProgress: View {
    let model: EngineComponentsModel
    let stage: EngineComponentsModel.Stage

    var body: some View {
        let p = model.progress
        let downloading = stage == .download && (p?.fileTotal ?? 0) > 0
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                if downloading, let p { ring(p); file(p) }
                cancel
            }
            HStack(spacing: 3) {
                if downloading, let p { ring(p) }
                cancel
            }
        }
    }

    private func ring(_ p: InstallerProgress) -> some View {
        ProgressView(value: Double(p.fileHave), total: Double(p.fileTotal))
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .help(EngineComponentsModel.fileText(p))
            .accessibilityLabel(String(localized: "下载进度"))
    }

    private func file(_ p: InstallerProgress) -> some View {
        Text(verbatim: EngineComponentsModel.fileText(p))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var cancel: some View {
        IconButton(Icon.cancel, help: String(localized: "取消")) { model.cancel() }
    }
}

/// 就绪's 档位 chip (§3.4), the same choice as the 档位 row's picker.
private struct EngineProfileChip: View {
    @Bindable var model: EngineComponentsModel

    var body: some View {
        NodeChip(EngineComponentsModel.profileTitle(model.profile), accessibilityLabel: String(localized: "档位"),
                 help: "\(EngineComponentsModel.profileMenuTitle(model.profile)) · \(EngineComponentsModel.profileSummary(model.profile))",
                 items: EngineComponentsModel.profiles.map { p in
                     NodeChipItem(EngineComponentsModel.profileMenuTitle(p),
                                  isOn: p == model.profile) { model.profile = p }
                 })
            .disabled(model.busy)
    }
}

/// The installer's stopEngine, set after the model is built (the installer is a `let`).
@MainActor
final class EngineStopHook {
    var stop: (@MainActor () async -> Void)?
    func run() async { await stop?() }
}
