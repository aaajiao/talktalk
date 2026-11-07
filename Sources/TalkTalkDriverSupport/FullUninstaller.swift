// l10n: zh-Hans (scripts/check-strings.sh)
import Darwin
import Foundation
import Observation
import ServiceManagement
import TalkTalkAudio
import TalkTalkCloud
import TalkTalkCore
import TalkTalkEngineHost

/// "完全卸载 TalkTalk" (ARCHITECTURE.md §8.4, settings › 组件). In this order:
///
/// 1. the default input: with a restore record, restore now if the call has ended, refuse while
///    it goes on ("先离开会议"), refuse if another TalkTalk owns the record;
/// 2. the driver: one administrator authorization (`install-driver.sh uninstall`);
/// 3. the engine: `install-engine.sh --uninstall`;
/// 4. files: `voice/`, `.voice-staging-*`, `glossary.json`, `sysinput-restore.json/.lock`,
///    `transcripts/`, `diagnostics/`, `driver.json`, `Logs/TalkTalk`, `Caches/TalkTalk`;
/// 5. this build's Keychain item (`<bundle id>.openai`, account `api-key`; never the user's own
///    `com.aaajiao.talktalk.openai` item with the macOS user name as account, §7.7);
/// 6. UserDefaults and the login item; 7. `tccutil reset All <bundle id>`.
///
/// Then the user drags the app to the Trash (the app cannot delete itself while running).
/// A cancelled or failed driver step stops the run before anything else is deleted.
@Observable @MainActor
public final class FullUninstaller {
    public enum Step: String, Sendable, CaseIterable {
        case defaultInput, driver, engine, files, keychain, preferences, loginItem, privacy

        /// What the settings row shows while the step runs and when it stops there.
        public var title: String {
            switch self {
            case .defaultInput: String(appLocalized: "还原系统默认输入")
            case .driver: String(appLocalized: "卸载虚拟麦克风")
            case .engine: String(appLocalized: "卸载引擎和模型")
            case .files: String(appLocalized: "删除数据文件")
            case .keychain: String(appLocalized: "删除钥匙串里的 OpenAI key")
            case .preferences: String(appLocalized: "删除设置")
            case .loginItem: String(appLocalized: "移除登录项")
            case .privacy: String(appLocalized: "重置隐私权限")
            }
        }
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case running(Step)
        case blocked(String)
        case cancelled
        case failed(Step, String)
        case finished(Report)

        public var isRunning: Bool { if case .running = self { true } else { false } }
    }

    public struct Report: Sendable, Equatable {
        public var removed: [String] = []
        /// Steps that did not fully succeed but did not stop the run (shown to the user).
        public var problems: [String] = []
    }

    /// What step 1 found and did.
    public enum RestoreOutcome: Sendable, Equatable {
        case noRecord
        case restored(String)
        /// The record exists and the current default input is not ours: the record was dropped.
        case recordDropped
        case callOngoing
        case ownedByAnotherTalkTalk
        case failed(String)
    }

    public struct Dependencies: Sendable {
        public var restoreDefaultInput: @MainActor @Sendable () -> RestoreOutcome
        /// Runs `install-driver.sh uninstall`. Returns nil when no driver is on disk at the time the
        /// step runs (no authorization, nothing reported); the closure itself is nil when this app
        /// has no driver installer at all.
        public var uninstallDriver: (@MainActor @Sendable () async -> DriverInstaller.Phase?)?
        /// Install leftovers still next to the driver bundle after the driver step
        /// (`DriverInstallation.leftovers()`): the script leaves those that are not ours.
        public var driverLeftovers: @Sendable () -> [URL]
        /// nil = done; otherwise the error (the run goes on, the problem is reported).
        public var uninstallEngine: @MainActor @Sendable () async -> String?
        /// What is still under the engine home after the engine step. `install-engine.sh
        /// --uninstall` exits 0 and only warns when it keeps something: foreign files in a model
        /// directory, old-revision or unpinned model directories, a `.python.tmp-<pid>` left by a
        /// cancelled install (review of 639f957 #1).
        public var engineLeftovers: @Sendable () -> [URL]
        /// The engine installer is running (install, check, models): 完全卸载 does not start
        /// (review of 639f957 #2).
        public var engineBusy: @MainActor @Sendable () -> Bool
        public var deleteKeychainItem: @Sendable () -> String?
        public var removePreferences: @Sendable () -> Void
        public var unregisterLoginItem: @Sendable () -> String?
        public var resetPrivacy: @Sendable () -> String?
        public var home: URL
        public var logs: URL
        public var caches: URL

        public init(restoreDefaultInput: @escaping @MainActor @Sendable () -> RestoreOutcome,
                    uninstallDriver: (@MainActor @Sendable () async -> DriverInstaller.Phase?)?,
                    driverLeftovers: @escaping @Sendable () -> [URL] = { [] },
                    uninstallEngine: @escaping @MainActor @Sendable () async -> String?,
                    engineLeftovers: @escaping @Sendable () -> [URL] = { [] },
                    engineBusy: @escaping @MainActor @Sendable () -> Bool = { false },
                    deleteKeychainItem: @escaping @Sendable () -> String?,
                    removePreferences: @escaping @Sendable () -> Void,
                    unregisterLoginItem: @escaping @Sendable () -> String?,
                    resetPrivacy: @escaping @Sendable () -> String?,
                    home: URL, logs: URL, caches: URL) {
            self.restoreDefaultInput = restoreDefaultInput
            self.uninstallDriver = uninstallDriver
            self.driverLeftovers = driverLeftovers
            self.uninstallEngine = uninstallEngine
            self.engineLeftovers = engineLeftovers
            self.engineBusy = engineBusy
            self.deleteKeychainItem = deleteKeychainItem
            self.removePreferences = removePreferences
            self.unregisterLoginItem = unregisterLoginItem
            self.resetPrivacy = resetPrivacy
            self.home = home
            self.logs = logs
            self.caches = caches
        }
    }

    public private(set) var phase: Phase = .idle
    /// What the last run did before it ended, also when it was blocked, cancelled or failed: step 1
    /// may already have restored the default input before the driver step stops (§8.4 wiring (d)),
    /// and the result must say so.
    public private(set) var lastReport = Report()
    @ObservationIgnored let deps: Dependencies

    /// Stop the owned engine before its files are removed. Called only after the restore/driver
    /// steps succeed; a refused or cancelled uninstall leaves the running engine alone.
    @ObservationIgnored public var beforeBegin: (@MainActor @Sendable () async -> Void)?

    public init(_ deps: Dependencies) { self.deps = deps }

    /// The engine installer is running: the 完全卸载 button waits (it would fail the engine step
    /// and delete the installer's TMPDIR and log under it).
    public var isEngineBusy: Bool { deps.engineBusy() }

    public static var engineBusyText: String { String(appLocalized: "引擎正在安装或校验：请在“安装与维护”页取消或等它结束，再完全卸载。") }

    /// The exact files and directories step 4 removes (only those that exist).
    public nonisolated static func fileTargets(home: URL, logs: URL, caches: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for name in ["voice", "glossary.json", "sysinput-restore.json", "sysinput-restore.lock", "transcripts",
                     "diagnostics", "driver.json"] {
            out.append(home.appendingPathComponent(name))
        }
        if let names = try? fm.contentsOfDirectory(atPath: home.path) {
            for n in names.sorted() where n.hasPrefix(".voice-staging-") { out.append(home.appendingPathComponent(n)) }
            // SingleInstance's 0-byte locks. Unlinking a held one does not release its flock: this
            // app keeps running until you quit it.
            for n in names.sorted() where n.hasPrefix(".instance-") && n.hasSuffix(".lock") {
                out.append(home.appendingPathComponent(n))
            }
        }
        out.append(logs)
        out.append(caches)
        return out.filter { fm.fileExists(atPath: $0.path) }
    }

    /// What is left under the engine home: each entry of `models/` on its own (the model
    /// directories, by revision), every other entry as it is (`.python.tmp-*`, `venv`, …), the
    /// home itself when it is empty. Hidden files count.
    public nonisolated static func engineLeftovers(engineHome: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: engineHome.path) else { return [] }
        if names.isEmpty { return [engineHome] }
        var out: [URL] = []
        for name in names.sorted() {
            let url = engineHome.appendingPathComponent(name)
            if name == "models", let inner = try? fm.contentsOfDirectory(atPath: url.path), !inner.isEmpty {
                out += inner.sorted().map { url.appendingPathComponent($0) }
            } else {
                out.append(url)
            }
        }
        return out
    }

    @discardableResult
    public func run() async -> Phase {
        guard !phase.isRunning else { return phase }
        var report = Report()
        lastReport = report
        // Before anything is done: the engine step would fail, and step 4 would delete the running
        // installer's TMPDIR and log.
        if deps.engineBusy() { return finish(.blocked(Self.engineBusyText), report) }

        phase = .running(.defaultInput)
        switch deps.restoreDefaultInput() {
        case .noRecord, .recordDropped: break
        case .restored(let name): report.removed.append(String(appLocalized: "默认输入已还原到 \(name)"))
        case .callOngoing: return finish(.blocked(String(appLocalized: "通话还在进行：先离开会议，再完全卸载。")), report)
        case .ownedByAnotherTalkTalk: return finish(.blocked(String(appLocalized: "另一个 TalkTalk 正在管系统默认输入：先在那边结束会议模式。")), report)
        case .failed(let why): return finish(.failed(.defaultInput, why), report)
        }

        if let uninstallDriver = deps.uninstallDriver {
            phase = .running(.driver)
            switch await uninstallDriver() {
            case nil:
                break   // nothing on disk
            case .finished(.needsLogout):
                report.removed.append(String(appLocalized: "虚拟麦克风（注销或重启后完全移除）"))
            case .finished:
                report.removed.append(String(appLocalized: "虚拟麦克风"))
            case .cancelled:
                return finish(.cancelled, report)
            case .blocked(let pre):
                return finish(.blocked(pre.blockers.map(\.text).joined(separator: " ")), report)
            case .failed(let why):
                return finish(.failed(.driver, why), report)
            default:
                return finish(.failed(.driver, "unexpected driver state"), report)
            }
            // Checked again after the script: what it left (not ours, e.g. a half-copied .tmp-*
            // without Info.plist) is named, so "虚拟麦克风" removed is not the whole story.
            let left = deps.driverLeftovers()
            if !left.isEmpty {
                let paths = left.map(\.path).joined(separator: String(appLocalized: "、"))
                report.problems.append(String(appLocalized: "虚拟麦克风：\(paths) 没有删除（认不出是 TalkTalk 的安装副本，卸载脚本不碰它；确定不要的话，在访达里删除，要管理员密码）"))
            }
        }

        phase = .running(.engine)
        await beforeBegin?()
        let engineError = await deps.uninstallEngine()
        if let engineError { report.problems.append(String(appLocalized: "引擎：\(engineError)")) }
        // Checked whatever the script said: it exits 0 when it keeps something.
        let engineLeft = deps.engineLeftovers()
        for url in engineLeft {
            report.problems.append(String(appLocalized: "引擎：\(url.path) 没有删除（卸载以后还在；确定不要的话，在访达里删除）"))
        }
        if engineError == nil, engineLeft.isEmpty { report.removed.append(String(appLocalized: "引擎和模型")) }

        phase = .running(.files)
        let fm = FileManager.default
        for url in Self.fileTargets(home: deps.home, logs: deps.logs, caches: deps.caches) {
            do {
                try fm.removeItem(at: url)
                report.removed.append(url.path)
            } catch {
                report.problems.append(String(appLocalized: "\(url.path)：\(error.localizedDescription)"))
            }
        }
        // Application Support/TalkTalk itself, once nothing is left in it; otherwise each entry
        // that is left is named (the engine's are already, above).
        if let rest = try? fm.contentsOfDirectory(atPath: deps.home.path) {
            if rest.isEmpty {
                try? fm.removeItem(at: deps.home)
            } else {
                for name in rest.sorted() {
                    let url = deps.home.appendingPathComponent(name)
                    if engineLeft.contains(where: { $0.path == url.path || $0.path.hasPrefix(url.path + "/") }) { continue }
                    report.problems.append(String(appLocalized: "\(url.path) 没有删除（不在完全卸载要删的清单里；确定不要的话，在访达里删除）"))
                }
            }
        }

        phase = .running(.keychain)
        if let err = deps.deleteKeychainItem() { report.problems.append(String(appLocalized: "钥匙串：\(err)")) }
        phase = .running(.preferences)
        deps.removePreferences()
        phase = .running(.loginItem)
        if let err = deps.unregisterLoginItem() { report.problems.append(String(appLocalized: "登录项：\(err)")) }
        phase = .running(.privacy)
        if let err = deps.resetPrivacy() { report.problems.append(String(appLocalized: "隐私权限：\(err)")) }
        return finish(.finished(report), report)
    }

    private func finish(_ p: Phase, _ r: Report) -> Phase {
        lastReport = r
        phase = p
        return p
    }
}

// MARK: live dependencies

extension FullUninstaller.Dependencies {
    /// The real steps for the running app. `restoreWithSwitcher` is the app's own
    /// `SystemInputSwitcher` path (`restoreForUninstall()`, via `SysInputRestore.withSwitcher`),
    /// used when this app owns the record; a stale
    /// record nobody owns is restored here (`SysInputRestore.restoreStale`, at `sysInputPaths`).
    @MainActor
    public static func live(bundleID: String, driver: DriverInstaller?, engine: EngineInstaller?,
                            restoreWithSwitcher: (@MainActor @Sendable () -> FullUninstaller.RestoreOutcome?)? = nil,
                            sysInputPaths: SysInputPaths = .standard(),
                            enginePaths: EnginePaths = .standard()) -> Self {
        let restore: @MainActor @Sendable () -> FullUninstaller.RestoreOutcome = {
            if let own = restoreWithSwitcher?() { return own }
            return SysInputRestore.restoreStale(paths: sysInputPaths)
        }
        var uninstallDriver: (@MainActor @Sendable () async -> DriverInstaller.Phase?)?
        let installation = driver?.installation
        if let driver, let installation {
            uninstallDriver = {
                // Decided when the step runs, not when the settings window built this: the driver
                // may have been installed (or removed) in the same window since. Our leftovers of
                // an interrupted install count too: only install-driver.sh (root) can remove them.
                guard installation.diskState() != .absent || !installation.removableLeftovers().isEmpty else { return nil }
                // Step 1 dealt with the restore record; a call or a Mic reader still blocks.
                return await driver.uninstall(ignoringRestoreRecord: true)
            }
        }
        let engineHome = engine?.engineHome ?? enginePaths.engineHome()
        let uninstallEngine: @MainActor @Sendable () async -> String? = {
            // A build without install-engine.sh cannot remove an installed engine: say so instead
            // of reporting it removed.
            guard let engine else {
                return FileManager.default.fileExists(atPath: engineHome.path) ? String(appLocalized: "这个构建没有带 install-engine.sh，引擎没有卸载") : nil
            }
            guard !engine.state.isRunning else { return String(appLocalized: "引擎安装器正在运行，引擎没有卸载") }
            let state: InstallerState = await engine.run(.uninstall)
            switch state {
            case .failed(let m): return m
            case .cancelled: return "cancelled"
            default: return nil
            }
        }
        let keychain: @Sendable () -> String? = {
            guard let item = KeychainSecret.openAI(bundleID: bundleID) else { return nil }
            do { try item.delete(); return nil } catch { return "\(error)" }
        }
        let prefs: @Sendable () -> Void = { UserDefaults.standard.removePersistentDomain(forName: bundleID) }
        let loginItem: @Sendable () -> String? = {
            let s = SMAppService.mainApp
            guard s.status == .enabled || s.status == .requiresApproval else { return nil }
            do { try s.unregister(); return nil } catch { return error.localizedDescription }
        }
        let privacy: @Sendable () -> String? = { Self.runTCCReset(bundleID: bundleID) }
        return Self(restoreDefaultInput: restore, uninstallDriver: uninstallDriver,
                    driverLeftovers: { installation?.leftovers() ?? [] }, uninstallEngine: uninstallEngine,
                    engineLeftovers: { FullUninstaller.engineLeftovers(engineHome: engineHome) },
                    engineBusy: { engine?.state.isRunning ?? false },
                    deleteKeychainItem: keychain, removePreferences: prefs, unregisterLoginItem: loginItem,
                    resetPrivacy: privacy,
                    home: enginePaths.home, logs: enginePaths.logs, caches: enginePaths.caches)
    }

    /// `tccutil reset All <bundle id>`: this build's microphone, audio-capture and speech grants.
    nonisolated static func runTCCReset(bundleID: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "All", bundleID]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "\(error)" }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? nil : "tccutil exited \(p.terminationStatus)"
    }
}

/// Restoring the default input from a restore record nobody owns any more (§8.6 "记录归谁": the
/// lock is free, so neither app nor guard is alive). Uses sysinput's own types; never touches the
/// default output.
public enum SysInputRestore {
    public static func restoreStale(paths: SysInputPaths, hal: any SysInputHAL = CoreAudioSysInputHAL(),
                                    processes: () -> [MeetingCandidate] = { (try? MeetingSourceResolver().currentCandidates()) ?? [] })
        -> FullUninstaller.RestoreOutcome {
        let store = SysInputRecordStore(paths: paths)
        guard let record = store.read() else { return .noRecord }
        let lock = SysInputLock(path: paths.lock.path)
        guard lock.tryAcquire() else { return .ownedByAnotherTalkTalk }
        defer { lock.release() }
        let scope = Set(record.meetingApps)
        let watched = processes().filter { scope.isEmpty || scope.contains($0.app.id) }
        if watched.contains(where: { $0.isRunningInput || $0.isRunningOutput }) { return .callOngoing }
        let snap = hal.snapshot()
        let current = snap.defaultInput?.uid
        let ours = current == MicPolicy.talkTalkMicUID || (record.replacementUID != nil && current == record.replacementUID)
        guard ours else {
            store.delete()
            return .recordDropped
        }
        guard let target = SystemInputPlan.restoreTarget(original: record.original, devices: snap.devices) else {
            return .failed(String(appLocalized: "没有可还原的实体输入设备：接上一个麦克风再试"))
        }
        guard hal.writeAndConfirm(uid: target.device.uid) else { return .failed(String(appLocalized: "写默认输入失败（\(target.device.name)）")) }
        store.delete()
        return .restored(target.device.name)
    }
}
