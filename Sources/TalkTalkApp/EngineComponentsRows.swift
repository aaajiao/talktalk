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
    /// Current pinned files that are ready, including downloads not active in install.json.
    private(set) var readyModelIDs: Set<String> = []
    /// A preset is pending only after an explicit picker action. Custom installed roles are
    /// shown as custom until the user chooses a preset, never as an implied standard install.
    private(set) var pendingPresetID: String?
    var profile: String {
        get { EnginePresetSelection.pickerID(activeRoles: record?.roles.mapValues(\.id), pendingID: pendingPresetID) }
        set {
            guard Self.profiles.contains(newValue) else { return }
            pendingPresetID = newValue == installedProfile?.rawValue ? nil : newValue
        }
    }
    /// Missing models wait for Download and Use. The installed role stays authoritative.
    private(set) var pendingSynthesisID: String?
    /// Set by the engine owner; nil: no engine instance. Returns nil on success, else what to show.
    @ObservationIgnored var restart: (() async -> String?)?
    /// Every installer run (install, repair, profile change, models, uninstall) stops the running
    /// engine first, so pip / python are not replaced under it and smoke_engine.py does not load
    /// a second copy of the models next to it.
    @ObservationIgnored var stopEngine: (@MainActor () async -> Void)? {
        get { stopHook.stop }
        set { stopHook.stop = newValue }
    }
    @ObservationIgnored var beginMaintenance: (@MainActor () async -> Void)? {
        get { stopHook.beginMaintenance }
        set { stopHook.beginMaintenance = newValue }
    }
    @ObservationIgnored var maintenanceFinished: (@MainActor () -> Void)? {
        get { stopHook.maintenanceFinished }
        set { stopHook.maintenanceFinished = newValue }
    }
    @ObservationIgnored private let stopHook: EngineStopHook
    private(set) var maintenanceRunning = false
    /// Something else is using the engine installation right now: 完全卸载 (DriverComponentsPage
    /// sets it). Install, check, models, uninstall and restart wait; the closure reads observable
    /// state, so the rows update by themselves (review of 639f957 #2).
    @ObservationIgnored var blockedBy: (@MainActor () -> Bool)?
    var blocked: Bool { blockedBy?() ?? false }
    /// Session ownership is supplied by the app; a model in use cannot be removed mid-session.
    @ObservationIgnored var sessionActive: (@MainActor () -> Bool)?
    var sessionInProgress: Bool { sessionActive?() ?? false }
    private(set) var restarting = false
    /// The last install, check, model or restart run's outcome (the 引擎 section's result row).
    private enum Outcome {
        case finished, failed(String), cancelled, restarted, restartFailed(String)
        var presentation: SettingsProblem {
            switch self {
            case .finished: SettingsProblem(.ok, String(appLocalized: "完成"))
            case let .failed(why): SettingsProblem(.failed, String(appLocalized: "未完成"), help: why)
            case .cancelled: SettingsProblem(.pending, String(appLocalized: "已取消"))
            case .restarted: SettingsProblem(.ok, String(appLocalized: "引擎已重启"))
            case let .restartFailed(why): SettingsProblem(.failed, String(appLocalized: "引擎未能重启"), help: why)
            }
        }
    }
    private var outcome: Outcome?
    var lastResult: SettingsProblem? { outcome?.presentation }

    static let profiles = EngineProfile.selectablePresets.map(\.rawValue)

    init(paths: EnginePaths = .standard()) {
        self.paths = paths
        let hook = EngineStopHook()
        stopHook = hook
        installer = paths.installerScript.map {
            EngineInstaller(script: $0, paths: paths, stopEngine: { await hook.begin() },
                            finishMaintenance: { await hook.finished() })
        }
        reload()
    }

    func reload() {
        let installation = EngineInstallation(engineHome: paths.engineHome())
        let r = installation.check()
        state = r.state
        record = r.record
        pendingSynthesisID = nil
        pendingPresetID = nil
        readyModelIDs = Set(EnginePins.models.filter { installation.isModelReady(id: $0.key) }.map(\.key))
    }

    /// Active roles describe the installed combination; a stale recorded label is not proof
    /// of a preset. A custom combination stays runnable without silently choosing a new preset.
    var installedProfile: EngineProfile? {
        guard let record else { return nil }
        return EngineProfile.matching(record: record)
    }

    var usesAppleRecognition: Bool {
        installed && record?.roles["tts"] != nil && record?.roles["asr"] == nil
    }

    var legacyProfile: EngineProfile? {
        guard let installedProfile, !EngineProfile.selectablePresets.contains(installedProfile) else { return nil }
        return installedProfile
    }

    var installed: Bool { state.canStartEngine }
    var running: Bool { maintenanceRunning || (installer?.state.isRunning ?? false) }
    /// No engine action can start now: one runs, the engine restarts, 完全卸载 runs, or this
    /// build has no installer.
    var busy: Bool { running || restarting || installer == nil || blocked }
    /// Every maintenance operation stops the engine, including check and inactive downloads.
    var maintenanceBlocked: Bool { busy || sessionInProgress }

    var synthesisModels: [EnginePins.Model] { EngineSynthesisSelection.models() }
    var canSelectSynthesis: Bool {
        EngineSynthesisSelection.canSelect(state: state, activeRoles: record?.roles.mapValues(\.id) ?? [:])
    }
    var synthesisRepairID: String? {
        guard case .incomplete = state, canSelectSynthesis else { return nil }
        return record?.roles["tts"]?.id
    }
    var synthesisSelectionID: String {
        EngineSynthesisSelection.pickerID(activeRoles: record?.roles.mapValues(\.id) ?? [:], pendingID: pendingSynthesisID)
    }
    func synthesisAction(_ id: String) -> EngineSynthesisSelection.Action {
        EngineSynthesisSelection.action(for: id, activeRoles: record?.roles.mapValues(\.id) ?? [:],
                                         readyModelIDs: readyModelIDs, installationReady: canSelectSynthesis,
                                         busy: busy, sessionActive: sessionInProgress)
    }
    func chooseSynthesis(_ id: String) {
        guard !busy, !sessionInProgress else { return }
        switch synthesisAction(id) {
        case .current:
            pendingSynthesisID = nil
        case .activate:
            pendingSynthesisID = id
            confirmAndRun(.selectTTS(id))
        case .downloadAndActivate:
            pendingSynthesisID = id
            outcome = nil
        case .unavailable:
            break
        }
    }

    func isModelActive(_ id: String) -> Bool {
        record?.roles.values.contains { $0.id == id } ?? false
    }

    func confirmRemoveModel(_ id: String) {
        confirmAndRun(isModelActive(id) ? .removeActiveModel(id) : .removeModel(id))
    }

    private func canRun(_ op: InstallerOp) -> Bool {
        guard !maintenanceBlocked else { return false }
        switch op {
        case let .selectTTS(id):
            let action = synthesisAction(id)
            return action == .activate || action == .downloadAndActivate
        case .removeActiveModel: return true
        // A normal-delete confirmation must not acquire permission to remove a role that
        // became active while the modal alert was open.
        case let .removeModel(id): return !isModelActive(id)
        default: return true
        }
    }

    /// Pinned model bytes of a profile (the runtime comes on top).
    static func modelBytes(_ profile: String) -> Int64 {
        EngineProfile(rawValue: profile)?.modelBytes ?? 0
    }

    func missingModelBytes(_ profile: String) -> Int64 {
        let required = Set(EngineProfile(rawValue: profile)?.modelIDs ?? [])
        return EnginePins.models.filter { required.contains($0.key) && !readyModelIDs.contains($0.key) }
            .reduce(0) { $0 + $1.bytes }
    }

    func downloadSummary(_ profile: String) -> String {
        let bytes = missingModelBytes(profile)
        if bytes == 0 {
            return String(appLocalized: "将复用已下载的模型并应用所选档位；运行时如需安装或更新会另外下载。")
        }
        return String(appLocalized: "仍需下载约 \(Self.gb(bytes)) 的模型；已就绪的模型会复用，运行时如需安装或更新会另外下载。")
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    static func profileTitle(_ profile: String) -> String {
        EngineProfile.title(for: profile)
    }

    static func profileMenuTitle(_ profile: String) -> String {
        EngineProfile(rawValue: profile) == nil ? profileTitle(profile)
            : "\(profileTitle(profile)) · \(gb(modelBytes(profile)))"
    }

    static func profileSummary(_ profile: String) -> String {
        guard let choice = EngineProfile(rawValue: profile) else { return profileTitle(profile) }
        func name(_ role: String) -> String? {
            guard let id = choice.expectedRoles[role] else { return nil }
            return EnginePins.models.first { $0.key == id }?.repo.split(separator: "/").last.map(String.init)
        }
        return [name("tts").map { String(appLocalized: "合成：\($0)") },
                (choice.usesAppleRecognition ? "Apple Speech" : name("asr")).map { String(appLocalized: "识别：\($0)") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func confirmAndRun(_ op: InstallerOp) {
        guard let installer, canRun(op) else { return }
        if let (title, text, ok) = confirmation(op) {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.addButton(withTitle: ok)
            a.addButton(withTitle: String(appLocalized: "取消"))
            NSApp.activate()
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        guard canRun(op) else { return }
        outcome = nil
        Task {
            guard canRun(op) else { return }
            maintenanceRunning = true
            defer {
                reload()
                maintenanceRunning = false
            }
            let s = await installer.run(op)
            switch s {
            case .finished: outcome = .finished
            case let .failed(why): outcome = .failed(why)
            case .cancelled: outcome = .cancelled
            case .idle, .running: break
            }
        }
    }

    /// The confirmations (§7.11), shortened to what the run costs.
    private func confirmation(_ op: InstallerOp) -> (String, String, String)? {
        switch op {
        case let .install(p):
            let prof = p ?? profile
            return (String(appLocalized: "安装引擎（\(Self.profileTitle(prof))）？"),
                    downloadSummary(prof),
                    missingModelBytes(prof) == 0 ? String(appLocalized: "应用档位") : String(appLocalized: "下载并安装"))
        case let .addModel(k):
            let b = EnginePins.models.first { $0.key == k }?.bytes ?? 0
            return (String(appLocalized: "下载模型 \(k)？"), String(appLocalized: "约 \(Self.gb(b))。"), String(appLocalized: "下载"))
        case let .selectTTS(k):
            guard !readyModelIDs.contains(k), let model = synthesisModels.first(where: { $0.key == k }) else { return nil }
            if synthesisRepairID == k, case let .incomplete(_, bytes) = state {
                return (String(appLocalized: "修复 \(EngineSynthesisSelection.title(for: model))？"),
                        String(appLocalized: "约 \(Self.gb(bytes))。继续使用当前识别、合成模型与声音录音。"),
                        String(appLocalized: "修复"))
            }
            return (String(appLocalized: "下载并使用 \(EngineSynthesisSelection.title(for: model))？"),
                    String(appLocalized: "约 \(Self.gb(model.bytes))。切换语音合成后，继续使用当前识别模型与声音录音。"),
                    String(appLocalized: "下载并使用"))
        case let .removeModel(k):
            return (String(appLocalized: "删除模型 \(k)？"), String(appLocalized: "以后要用时需要重新下载。"), String(appLocalized: "删除模型"))
        case let .removeActiveModel(k):
            let isASR = EnginePins.models.first { $0.key == k }?.role == "asr"
            let impact = isASR
                ? String(appLocalized: "将停止本地引擎并删除当前使用的识别模型。Qwen 识别将不可用，语音合成模型保留；可使用 Apple Speech，或重新下载并选择档位恢复。")
                : String(appLocalized: "将停止本地引擎并删除当前使用的合成模型。本地语音合成将不可用，识别模型保留；重新下载并选择合成模型后可恢复。")
            return (String(appLocalized: "删除正在使用的模型 \(k)？"), impact, String(appLocalized: "删除模型"))
        case .uninstall:
            return (String(appLocalized: "卸载引擎？"),
                    String(appLocalized: "删除运行时和全部模型；我的声音、术语表和设置保留。"), String(appLocalized: "卸载引擎"))
        case .check:
            return nil
        }
    }

    func cancel() { installer?.cancel() }

    func dismissResult() { outcome = nil }

    func doRestart() {
        guard let restart, !maintenanceBlocked else { return }
        restarting = true
        outcome = nil
        Task {
            guard !sessionInProgress, !running, !blocked else { restarting = false; return }
            let failure = await restart()
            restarting = false
            outcome = failure.map(Outcome.restartFailed) ?? .restarted
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
            SettingsProblem(.ok, String(appLocalized: "已安装 · \(Self.profileTitle(p))"))
        case .notInstalled:
            SettingsProblem(.warn, String(appLocalized: "未安装"))
        case let .outdated(p, _):
            SettingsProblem(.warn, String(appLocalized: "可更新"), help: String(appLocalized: "已安装 \(Self.profileTitle(p))，有新的推荐版本"))
        case let .incompatible(r):
            SettingsProblem(.warn, String(appLocalized: "需更新运行时"), help: r)
        case let .incomplete(missing, bytes):
            SettingsProblem(.warn, String(appLocalized: "缺 \(missing.count) 个文件 · \(Self.gb(bytes))"),
                            help: missing.joined(separator: "\n"))
        case .unfinished:
            SettingsProblem(.warn, String(appLocalized: "未完成"), help: String(appLocalized: "上次安装没有完成"))
        case let .damaged(r):
            SettingsProblem(.failed, String(appLocalized: "记录损坏"), help: r)
        }
    }

    /// The card's corner: nothing once installed and current (no badge = ready).
    var problem: SettingsProblem? { status.status == .ok ? nil : status }

    /// A picker change is a pending install choice, not a change to the installed profile.
    var pendingProfileChange: SettingsProblem? {
        guard let profile = pendingPresetID, case let .installed(installedProfile, _) = state,
              installedProfile != profile else { return nil }
        return SettingsProblem(.pending, String(appLocalized: "已安装 \(Self.profileTitle(installedProfile)) · 待切换为 \(Self.profileTitle(profile))"),
                               help: String(appLocalized: "点击“换档”后安装所选档位"))
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

    var customRepairRequiresPreset: Bool {
        record != nil && installedProfile == nil && needsRepair && synthesisRepairID == nil
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
            case .install, .addModel, .selectTTS: return .download
            case .check: return .verify
            case .removeModel, .removeActiveModel, .uninstall: return .install
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
        return parts.isEmpty ? String(appLocalized: "准备中") : parts.joined(separator: " · ")
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
        FlowGrid.engineRequirements(model)
            .padding(.vertical, 4)
        independentSynthesisRow
        statusRow
        EngineOperationRows(model: model)
    }

    private var profileRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker(String(appLocalized: "档位"), selection: $model.profile) {
                    if model.record != nil && model.installedProfile == nil {
                        Text(verbatim: EngineComponentsModel.profileTitle(EngineProfile.customID))
                            .tag(EngineProfile.customID)
                            .disabled(true)
                    }
                    if let legacy = model.legacyProfile {
                        Text(verbatim: EngineComponentsModel.profileMenuTitle(legacy.rawValue))
                            .tag(legacy.rawValue)
                            .disabled(true)
                    }
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
                .disabled(model.maintenanceBlocked)
                primaryButton
                IconMenuButton(help: String(appLocalized: "维护引擎"), items: maintenance)
                    .disabled(model.maintenanceBlocked)
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
            .disabled(model.maintenanceBlocked)
            .help(model.downloadSummary(model.profile))
        } else {
            if let id = model.synthesisRepairID {
                Button { model.confirmAndRun(.selectTTS(id)) } label: {
                    Label("修复", systemImage: Icon.repair).labelStyle(.titleAndIcon)
                }
                .disabled(model.maintenanceBlocked)
            } else if model.needsRepair && !custom {
                Button { model.confirmAndRun(.install(profile: recorded ?? model.profile)) } label: {
                    Label("修复", systemImage: Icon.repair).labelStyle(.titleAndIcon)
                }
                .disabled(model.maintenanceBlocked)
                .help(String(appLocalized: "重新安装 \(EngineComponentsModel.profileTitle(recorded ?? model.profile))"))
            }
            if model.pendingPresetID != nil {
                Button("换档") { model.confirmAndRun(installing) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.maintenanceBlocked)
                    .help(String(appLocalized: "安装 \(EngineComponentsModel.profileTitle(model.profile))"))
            } else if case .outdated = model.state, let recorded {
                Button { model.confirmAndRun(.install(profile: recorded)) } label: {
                    Label("更新", systemImage: Icon.download).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.maintenanceBlocked)
            }
        }
    }

    private var maintenance: [IconMenuItem] {
        let present = model.state != .notInstalled
        return [
            IconMenuItem(String(appLocalized: "校验安装"), symbol: Icon.verify, isEnabled: present) { model.confirmAndRun(.check) },
            IconMenuItem(String(appLocalized: "重启引擎"), symbol: Icon.restartEngine,
                         isEnabled: model.restart != nil && model.installed) { model.doRestart() },
            IconMenuItem(String(appLocalized: "查看日志"), symbol: Icon.inspectFile) { model.revealLogs() },
            .separator,
            IconMenuItem(String(appLocalized: "卸载引擎…"), symbol: Icon.delete, isEnabled: present,
                         isDestructive: true) { model.confirmAndRun(.uninstall) }
        ]
    }

    /// Persistent installation facts, not the last action's temporary result or a pending
    /// preset. Named presets already explain their composition in the model cards above.
    @ViewBuilder private var independentSynthesisRow: some View {
        if model.installed, model.installedProfile == nil, let id = model.record?.roles["tts"]?.id {
            let name = model.synthesisModels.first { $0.key == id }.map { EngineSynthesisSelection.title(for: $0) } ?? id
            VStack(alignment: .leading, spacing: 4) {
                StatusLabel(String(appLocalized: "独立合成：\(name)"), .ok)
                Text(String(appLocalized: "识别模型保持原有配置"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Ladder.inline + 4)
                    .help(model.modelName(role: "asr") ?? "Apple Speech")
            }
            .padding(.leading, Ladder.rowTextInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var statusRow: some View {
        // The flow's ready badge and profile already describe a healthy installation.
        if model.sessionInProgress {
            StatusLabel(String(appLocalized: "当前操作结束后可维护"), .waiting,
                        help: String(appLocalized: "结束当前会话、录音或试听后维护引擎"))
                .padding(.leading, Ladder.rowTextInset)
        } else if model.customRepairRequiresPreset && model.pendingPresetID == nil {
            StatusLabel(String(appLocalized: "选择组合以修复引擎"), .warn,
                        help: String(appLocalized: "请选择安装组合并点击“换档”；识别与合成模型将按所选组合配置。"))
                .padding(.leading, Ladder.rowTextInset)
        } else if let status = model.pendingProfileChange ?? model.problem {
            StatusLabel(status.text, status.status, help: status.help)
                .padding(.leading, Ladder.rowTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Shared installer feedback in resource maintenance and the synthesis model selector.
struct EngineOperationRows: View {
    @Bindable var model: EngineComponentsModel

    var body: some View {
        progressRow
        resultRow
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
                        .accessibilityLabel(String(appLocalized: "下载进度"))
                } else {
                    StatusGlyph(.busy)
                }
                Text(verbatim: EngineComponentsModel.progressText(p))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(ifPresent: p.model)
                Spacer(minLength: 8)
                IconButton(Icon.cancel, help: String(appLocalized: "取消")) { model.cancel() }
            }
            .padding(.leading, Ladder.rowTextInset)
        } else if model.blocked {
            StatusLabel(String(appLocalized: "完全卸载中"), .waiting, help: String(appLocalized: "结束后才能操作引擎"))
                .padding(.leading, Ladder.rowTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.restarting {
            StatusLabel(String(appLocalized: "引擎重启中"), .busy)
                .padding(.leading, Ladder.rowTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var resultRow: some View {
        if let result = model.lastResult {
            HStack(spacing: 8) {
                StatusLabel(result.text, result.status, help: result.help)
                Spacer(minLength: 8)
                IconButton(Icon.close, help: String(appLocalized: "知道了"),
                           accessibilityLabel: String(appLocalized: "关闭结果")) { model.dismissResult() }
            }
            .padding(.leading, Ladder.rowTextInset)
        }
    }
}

/// The model picker changes only TTS. Already downloaded choices apply directly; a missing
/// model waits for the explicit download action while the current role remains visible.
struct SynthesisModelRows: View {
    @Bindable var model: EngineComponentsModel

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker(String(appLocalized: "合成模型"), selection: Binding(
                    get: { model.synthesisSelectionID }, set: { model.chooseSynthesis($0) }
                )) {
                    if model.record?.roles["tts"] == nil {
                        Text(String(appLocalized: "未选择")).tag("").disabled(true)
                    }
                    ForEach(model.synthesisModels, id: \.key) { choice in
                        Text(verbatim: EngineSynthesisSelection.title(for: choice)).tag(choice.key)
                            .help("\(choice.repo) · \(EngineComponentsModel.gb(choice.bytes))")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.maintenanceBlocked || !model.canSelectSynthesis)
                .help(String(appLocalized: "选择已下载的模型后立即切换语音合成"))
                if model.synthesisAction(model.synthesisSelectionID) == .downloadAndActivate {
                    Button(model.synthesisRepairID == model.synthesisSelectionID
                           ? String(appLocalized: "修复") : String(appLocalized: "下载并使用")) {
                        model.confirmAndRun(.selectTTS(model.synthesisSelectionID))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } label: {
            Label("合成模型", systemImage: Icon.speech)
        }
        if model.pendingSynthesisID != nil, let current = model.modelName(role: "tts") {
            LabeledContent(String(appLocalized: "当前使用")) {
                Text(verbatim: current).foregroundStyle(.secondary)
            }
        }
        if model.sessionInProgress {
            StatusLabel(String(appLocalized: "当前操作结束后可切换"), .waiting,
                        help: String(appLocalized: "结束当前会话、录音或试听后选择合成模型"))
        } else if !model.installed, let problem = model.problem {
            StatusLabel(problem.text, problem.status, help: problem.help)
        }
        EngineOperationRows(model: model)
    }
}

/// The 模型 section's rows (§7.11): each pinned model with its size and revision, whether it is
/// installed, and delete or download.
struct EngineModelRows: View {
    @Bindable var model: EngineComponentsModel

    var body: some View {
        let installedKeys = Set(model.record?.models.map(\.id) ?? []).union(model.readyModelIDs)
        ForEach(EnginePins.models, id: \.key) { m in
            row(m, installed: installedKeys.contains(m.key))
        }
    }

    private func row(_ m: EnginePins.Model, installed: Bool) -> some View {
        let role = m.role == "asr" ? String(appLocalized: "语音识别") : String(appLocalized: "语音合成")
        let active = model.isModelActive(m.key)
        let ready = model.readyModelIDs.contains(m.key)
        return LabeledContent {
            HStack(spacing: 8) {
                Text(verbatim: "\(EngineComponentsModel.gb(m.bytes)) · \(m.revision.prefix(7))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if installed {
                    let word = ready ? String(appLocalized: "已就绪") : String(appLocalized: "需修复")
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: Ladder.inline, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help(String(appLocalized: "当前使用"))
                            .accessibilityLabel(String(appLocalized: "当前使用"))
                            .accessibilityAddTraits(.isSelected)
                    }
                    if !active || !ready {
                        StatusGlyph(ready ? .ok : .warn)
                            .help(word)
                            .accessibilityLabel(word)
                    }
                    IconButton(Icon.delete, help: active && model.sessionInProgress
                        ? String(appLocalized: "会话结束后可删除当前使用的模型")
                        : String(appLocalized: "删除模型 \(m.key)"),
                               accessibilityLabel: String(appLocalized: "删除模型 \(m.key)"), isDestructive: true) {
                        model.confirmRemoveModel(m.key)
                    }
                    .disabled(active && model.sessionInProgress)
                } else {
                    IconButton(Icon.download, help: String(appLocalized: "下载 \(m.key)")) { model.confirmAndRun(.addModel(m.key)) }
                        .disabled(!model.installed)
                }
            }
            .disabled(model.maintenanceBlocked)
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
        ContentUnavailableView(String(appLocalized: "此构建不可用"), systemImage: Icon.unavailable)
            .help(String(appLocalized: "这个构建里没有安装器（直接运行的二进制）：用 TalkTalk.app / TalkTalk-Dev.app。"))
    }
}

/// 安装与维护 › 语音资源's graphic (§7.11): the install lifecycle in one lane, every node leading to
/// the 引擎 section (`link`). The installation's state sits on its step (`statusStage`); the
/// running step shows a spinner badge and 取消, 下载 its file's progress, 就绪 the 档位 chip.
@MainActor
extension FlowGrid {
    /// These are two independent requirements of the selected preset, not pipeline stages.
    static func engineRequirements(_ model: EngineComponentsModel) -> some View {
        let choice = EngineProfile(rawValue: model.profile)
        let roles = choice?.expectedRoles ?? model.record?.roles.mapValues(\.id) ?? [:]
        let nodes = ["asr", "tts"].compactMap { role -> FlowNode? in
            let title = role == "asr" ? String(appLocalized: "语音识别") : String(appLocalized: "语音合成")
            if role == "asr", roles["asr"] == nil && roles["tts"] != nil {
                return FlowNode(title, glyph: .symbol(Icon.thisMac), badgeReason: String(appLocalized: "系统识别"),
                                accessory: .display {
                                    Text(String(appLocalized: "Apple Speech · 系统提供"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }, help: String(appLocalized: "当前配置仅包含语音合成模型；识别使用系统 Apple Speech。"))
            }
            guard let id = roles[role], let pin = EnginePins.models.first(where: { $0.key == id }) else { return nil }
            let ready = model.readyModelIDs.contains(id)
            let availability = ready ? String(appLocalized: "已就绪") : String(appLocalized: "需下载")
            let name = pin.repo.split(separator: "/").last.map(String.init) ?? pin.key
            let parameters = name.split(separator: "-").first { $0.hasSuffix("B") && Double($0.dropLast()) != nil }.map(String.init) ?? ""
            let nameAndSize = role == "asr" ? "Qwen3-ASR \(parameters)" : EngineSynthesisSelection.title(for: pin)
            let detail = "\(nameAndSize) · \(EngineComponentsModel.gb(pin.bytes))"
            return FlowNode(title, glyph: .symbol(ready ? (role == "asr" ? Icon.recognition : Icon.speech) : Icon.download),
                            badge: ready ? .ok : nil, badgeReason: availability,
                            accessory: .display {
                                Text(verbatim: detail).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).minimumScaleFactor(0.85)
                            }, help: "\(name) · \(availability)")
        }
        return FlowGrid.cards(String(appLocalized: "所选档位的模型"), nodes: nodes)
    }

    static func engine(_ model: EngineComponentsModel, link: NodeLink) -> FlowGrid {
        let active = model.activeStage
        let status = model.pendingProfileChange ?? model.status
        func node(_ stage: EngineComponentsModel.Stage, _ title: String, _ symbol: String) -> FlowNode {
            let running = stage == active
            let badge: SettingsProblem? = running ? SettingsProblem(.busy, String(appLocalized: "进行中"))
                : model.statusStage == stage ? status : nil
            let accessory: NodeAccessory? = running ? .controls { EngineStageProgress(model: model, stage: stage) }
                : stage == .ready ? .controls { EngineProfileChip(model: model) } : nil
            return FlowNode(title, glyph: .symbol(symbol),
                            state: badge.map { $0.status == .warn || $0.status == .failed } == true ? .needsAction : .ready,
                            badge: badge?.status, badgeReason: badge?.text,
                            // The running step keeps its width for progress and 取消: no chevron.
                            link: running ? nil : link, accessory: accessory, help: badge?.help)
        }
        return FlowGrid(String(appLocalized: "引擎安装步骤"), lanes: [
            FlowLane(String(appLocalized: "引擎"), cells: [
                .node(node(.download, String(appLocalized: "下载"), Icon.download)),
                .node(node(.install, String(appLocalized: "安装"), Icon.install)),
                .node(node(.verify, String(appLocalized: "校验"), Icon.verify)),
                .node(node(.ready, String(appLocalized: "就绪"), Icon.engine))
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
            .accessibilityLabel(String(appLocalized: "下载进度"))
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
        IconButton(Icon.cancel, help: String(appLocalized: "取消")) { model.cancel() }
    }
}

/// 就绪's 档位 chip (§3.4), the same choice as the 档位 row's picker.
private struct EngineProfileChip: View {
    @Bindable var model: EngineComponentsModel

    var body: some View {
        NodeChip(EngineComponentsModel.profileTitle(model.profile), accessibilityLabel: String(appLocalized: "档位"),
                 help: "\(EngineComponentsModel.profileMenuTitle(model.profile)) · \(EngineComponentsModel.profileSummary(model.profile))",
                 items: items)
            .disabled(model.maintenanceBlocked)
    }

    private var items: [NodeChipItem] {
        var choices = EngineComponentsModel.profiles.map { p in
            NodeChipItem(EngineComponentsModel.profileMenuTitle(p), isOn: p == model.profile) { model.profile = p }
        }
        if let legacy = model.legacyProfile {
            choices.insert(NodeChipItem(EngineComponentsModel.profileMenuTitle(legacy.rawValue),
                                        isOn: model.profile == legacy.rawValue, isEnabled: false) {}, at: 0)
        } else if model.record != nil && model.installedProfile == nil {
            choices.insert(NodeChipItem(EngineComponentsModel.profileTitle(EngineProfile.customID),
                                        isOn: model.profile == EngineProfile.customID, isEnabled: false) {}, at: 0)
        }
        return choices
    }
}

/// The installer's stopEngine, set after the model is built (the installer is a `let`).
@MainActor
final class EngineStopHook {
    var stop: (@MainActor () async -> Void)?
    var beginMaintenance: (@MainActor () async -> Void)?
    var maintenanceFinished: (@MainActor () -> Void)?

    func begin() async {
        if let beginMaintenance { await beginMaintenance() }
        else { await stop?() }
    }

    func finished() { maintenanceFinished?() }
}
