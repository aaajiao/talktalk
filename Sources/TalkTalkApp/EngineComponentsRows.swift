// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkSettingsUI

/// Settings › 组件 › 引擎与模型 (ARCHITECTURE.md §7.3–§7.5, §11), on top of M0's @Observable
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
    private(set) var lastMessage: String?

    static let profiles = ["max", "standard", "compact24", "compact16"]

    init(paths: EnginePaths = .standard()) {
        self.paths = paths
        let hook = EngineStopHook()
        stopHook = hook
        installer = paths.installerScript.map { EngineInstaller(script: $0, paths: paths, stopEngine: { await hook.run() }) }
        profile = "max"
        reload()
    }

    func reload() {
        let r = EngineInstallation(engineHome: paths.engineHome()).check()
        state = r.state
        record = r.record
        if let p = record?.profile, Self.profiles.contains(p) { profile = p }
    }

    var installed: Bool { state.canStartEngine }
    var running: Bool { installer?.state.isRunning ?? false }

    /// Pinned model bytes of a profile (the runtime comes on top).
    static func modelBytes(_ profile: String) -> Int64 {
        let keys = Set(EnginePins.profiles[profile] ?? [])
        return EnginePins.models.filter { keys.contains($0.key) }.reduce(0) { $0 + $1.bytes }
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

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
        lastMessage = nil
        Task {
            let s = await installer.run(op)
            switch s {
            case .finished: lastMessage = String(localized: "完成")
            case let .failed(why): lastMessage = String(localized: "没有完成：\(why)")
            case .cancelled: lastMessage = String(localized: "已取消")
            case .idle, .running: break
            }
            reload()
        }
    }

    private func confirmation(_ op: InstallerOp) -> (String, String, String)? {
        switch op {
        case let .install(p):
            let prof = p ?? profile
            return (String(localized: "安装引擎（\(prof)）？"),
                    String(localized: "要从 Hugging Face 和 python-build-standalone 下载运行时和模型，模型约 \(Self.gb(Self.modelBytes(prof)))，另加运行时。可以随时取消，下次接着下。"),
                    String(localized: "下载并安装"))
        case let .addModel(k):
            let b = EnginePins.models.first { $0.key == k }?.bytes ?? 0
            return (String(localized: "下载模型 \(k)？"), String(localized: "约 \(Self.gb(b))。"), String(localized: "下载"))
        case let .removeModel(k):
            return (String(localized: "删除模型 \(k)？"), String(localized: "以后要用时需要重新下载。"), String(localized: "删除"))
        case .uninstall:
            return (String(localized: "卸载引擎？"),
                    String(localized: "删除运行时和全部模型；“我的声音”、术语表和设置保留。"), String(localized: "卸载"))
        case .check:
            return nil
        }
    }

    func cancel() { installer?.cancel() }

    func doRestart() {
        guard let restart, !restarting, !running, !blocked else { return }
        restarting = true
        lastMessage = nil
        Task {
            let failure = await restart()
            restarting = false
            lastMessage = failure.map { String(localized: "引擎没能重启：\($0)") } ?? String(localized: "引擎已重启")
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

    var stateText: String {
        switch state {
        case .notInstalled: String(localized: "未安装")
        case let .installed(p, _): String(localized: "已安装（\(p)）")
        case let .outdated(p, _): String(localized: "已安装（\(p)），有新的推荐版本")
        case let .incompatible(r): String(localized: "运行时与这个版本的 App 不兼容，需要更新：\(r)")
        case let .incomplete(missing, bytes): String(localized: "缺 \(missing.count) 个模型文件，修复需下载约 \(Self.gb(bytes))")
        case .unfinished: String(localized: "上次安装没有完成")
        case let .damaged(r): String(localized: "安装记录损坏：\(r)")
        }
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
}

struct EngineComponentsRows: View {
    @Bindable var model: EngineComponentsModel
    var refreshOnAppear = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cpu").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("引擎与模型").font(.headline)
                    Text(model.stateText).font(.callout)
                        .foregroundStyle(model.needsRepair ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.installer == nil {
                SettingsNote("这个构建里没有安装器（直接运行的二进制）：用 TalkTalk.app / TalkTalk-Dev.app。")
            }
            progress
            actions
            roleSummary("asr", title: String(localized: "语音识别"), symbol: "waveform", purpose: String(localized: "Qwen3-ASR · 把听到的声音转成原文"))
            roleSummary("tts", title: String(localized: "语音合成"), symbol: SubtitleTokens.SettingsIcon.myVoice, purpose: String(localized: "Qwen3-TTS · 用你的声音朗读译文"))
            DisclosureGroup(String(localized: "模型、版本与单独下载")) { models.padding(.top, 8) }
            if let m = model.lastMessage {
                Text(m).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if refreshOnAppear { model.reload() } }
    }

    @ViewBuilder private var progress: some View {
        if case let .running(op, p)? = model.installer?.state {
            VStack(alignment: .leading, spacing: 4) {
                Text(stepText(op, p)).font(.callout)
                if p.fileTotal > 0 {
                    ProgressView(value: Double(p.fileHave), total: Double(p.fileTotal)).frame(maxWidth: 420)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("取消") { model.cancel() }
            }
        }
    }

    private func stepText(_ op: InstallerOp, _ p: InstallerProgress) -> String {
        var s = p.step ?? String(localized: "准备中")
        if let d = p.stepDone, let c = p.stepCount { s += " \(d)/\(c)" }
        if let m = p.model { s += " · \(m)" }
        if p.fileTotal > 0 { s += " · \(EngineComponentsModel.gb(p.fileHave))/\(EngineComponentsModel.gb(p.fileTotal))" }
        return s
    }

    private var actions: some View {
        let busy = model.running || model.restarting || model.installer == nil || model.blocked
        return VStack(alignment: .leading, spacing: 8) {
            if model.blocked, !model.running {
                SettingsNote("完全卸载正在进行：引擎的操作要等它结束。")
            }
            HStack {
                Picker("档位", selection: $model.profile) {
                    ForEach(EngineComponentsModel.profiles, id: \.self) { p in
                        Text(verbatim: "\(p) · \(EngineComponentsModel.gb(EngineComponentsModel.modelBytes(p)))").tag(p)
                    }
                }
                .frame(maxWidth: 260)
                Button(model.installed ? String(localized: "换档并安装") : String(localized: "下载并安装")) { model.confirmAndRun(.install(profile: model.profile)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
            HStack {
                if model.needsRepair {
                    Button { model.confirmAndRun(.install(profile: model.record?.profile ?? model.profile)) }
                    label: { Label("修复安装", systemImage: "wrench.and.screwdriver") }
                }
                Menu("维护引擎") {
                    Button("校验安装") { model.confirmAndRun(.check) }
                    Button("重启引擎") { model.doRestart() }
                        .disabled(model.restart == nil || model.restarting || model.running || !model.installed)
                    Button("查看日志") { model.revealLogs() }
                    Divider()
                    Button("卸载引擎…", role: .destructive) { model.confirmAndRun(.uninstall) }
                        .disabled(model.state == .notInstalled)
                }
                .fixedSize()
            }
            .disabled(busy)
        }
    }

    private func roleSummary(_ role: String, title: String, symbol: String,
                             purpose: String) -> some View {
        let installed = model.record?.roles[role] != nil && model.installed
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(purpose).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            StatusLabel(installed ? String(localized: "已安装") : (model.needsRepair ? String(localized: "待修复") : String(localized: "未安装")),
                        installed ? .ok : (model.needsRepair ? .warn : .pending))
        }
        .padding(.vertical, 6)
    }

    private var models: some View {
        let installedKeys = Set(model.record?.models.map(\.id) ?? [])
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(EnginePins.models, id: \.key) { m in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: m.key).font(.callout.monospaced())
                        Text(m.role == "asr" ? String(localized: "语音识别 · 声音转成原文") : String(localized: "语音合成 · 用我的声音读出译文"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: "\(EngineComponentsModel.gb(m.bytes)) · \(m.revision.prefix(7))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installedKeys.contains(m.key) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(model.installed ? String(localized: "已安装") : String(localized: "待校验"))
                                .font(.caption).foregroundStyle(model.installed ? Color.green : Color.orange)
                            Button("删除", role: .destructive) { model.confirmAndRun(.removeModel(m.key)) }
                        }
                    } else {
                        Button("下载") { model.confirmAndRun(.addModel(m.key)) }
                            .disabled(!model.installed)
                    }
                }
                .frame(maxWidth: 640)
                .padding(.vertical, 5)
            }
        }
        .disabled(model.running || model.restarting || model.installer == nil || model.blocked)
    }
}

/// The installer's stopEngine, set after the model is built (the installer is a `let`).
@MainActor
final class EngineStopHook {
    var stop: (@MainActor () async -> Void)?
    func run() async { await stop?() }
}
