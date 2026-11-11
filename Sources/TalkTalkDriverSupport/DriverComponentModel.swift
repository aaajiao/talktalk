// l10n: zh-Hans (scripts/check-strings.sh)
import TalkTalkCore
import AppKit
import Foundation
import Observation
import TalkTalkAudio
import TalkTalkEngineHost
import TalkTalkSettingsUI

/// State behind settings › 组件 › 虚拟麦克风 (ARCHITECTURE.md, "三种使用场景": 状态、安装、自检、卸载、谁在用)
/// and the 完全卸载 button. The app's components page (TalkTalkApp's DriverComponentsPage) builds
/// one with `forCurrentApp` and shows it:
///
///     let driver = DriverComponentModel.forCurrentApp(isMeetingModeOn: { switcher.isMeetingModeOn },
///                                                     engine: engineInstaller,
///                                                     restoreWithSwitcher: SysInputRestore.withSwitcher(switcher))
///     Section { DriverComponentRows(model: driver) }   // 组件 › 虚拟麦克风
///         .driverComponentLifecycle(driver)            // once, on the Form
///     Section { FullUninstallSection(model: driver) }   // 通用, last
@Observable @MainActor
public final class DriverComponentModel {
    public enum Confirmation: Sendable, Equatable, Identifiable {
        case install(warnings: [DriverPreflight.Warning], update: Bool)
        case uninstall(warnings: [DriverPreflight.Warning])
        case restartAudio(warnings: [DriverPreflight.Warning])
        case fullUninstall

        public var id: String {
            switch self {
            case .install: "install"
            case .uninstall: "uninstall"
            case .restartAudio: "restart"
            case .fullUninstall: "full"
            }
        }
    }

    public private(set) var state: DriverInstallation.State = .notInstalled
    public private(set) var record: DriverInstallation.Record?
    /// "谁在用": apps with IO running on TalkTalk Mic right now.
    public private(set) var users: [DriverUser] = []
    public private(set) var selfTest: DriverSelfTestReport?
    public private(set) var selfTestRunning = false
    /// The last action's outcome as a sentence (the result row's help).
    public private(set) var notice: String?
    /// The same outcome in the settings vocabulary, shortest words first (§7.12): the result row.
    public private(set) var result: SettingsProblem?
    public var confirmation: Confirmation?
    /// Which `driverComponentLifecycle` asked for `confirmation`. Settings › 安装与维护 and
    /// onboarding step 3 share this model, so only the asking window shows the alert.
    public enum Host: Sendable { case settings, onboarding }
    public private(set) var confirmationAskedBy: Host?
    /// FullUninstallSection's own confirmation (kept apart from `confirmation`, which the driver
    /// section's alert presents).
    public var confirmingFullUninstall = false

    public let installer: DriverInstaller
    public let fullUninstaller: FullUninstaller?
    @ObservationIgnored let selfTestOptions: @MainActor () -> DriverSelfTest.Options
    @ObservationIgnored let isMeetingModeOn: @MainActor () -> Bool
    /// sysinput's restore record exists. The self-test asks again right before the meeting path
    /// (§8.4). The default reads the real record, so a meeting-path run can never use a made-up
    /// `false`.
    @ObservationIgnored let restoreRecordExists: @Sendable () -> Bool

    public init(installer: DriverInstaller, fullUninstaller: FullUninstaller?,
                isMeetingModeOn: @escaping @MainActor () -> Bool,
                restoreRecordExists: @escaping @Sendable () -> Bool = { SysInputRecordStore(paths: .standard()).exists },
                selfTestOptions: @escaping @MainActor () -> DriverSelfTest.Options) {
        self.installer = installer
        self.fullUninstaller = fullUninstaller
        self.isMeetingModeOn = isMeetingModeOn
        self.restoreRecordExists = restoreRecordExists
        self.selfTestOptions = selfTestOptions
        refresh()
    }

    /// The real wiring for the running app. `isChannel1Busy`: FeedOutput is playing (skip isolation).
    public static func forCurrentApp(isMeetingModeOn: @escaping @MainActor () -> Bool,
                                     isChannel1Busy: @escaping @MainActor () -> Bool = { false },
                                     engine: EngineInstaller?,
                                     beforeBegin: (@MainActor @Sendable () async -> Void)? = nil,
                                     restoreWithSwitcher: (@MainActor @Sendable () -> FullUninstaller.RestoreOutcome?)? = nil,
                                     bundle: Bundle = .main) -> DriverComponentModel {
        let resources = DriverResources.inBundle(bundle)
        let installer = DriverInstaller(resources: resources, preflightInputs: {
            DriverPreflight.Inputs.current(meetingModeOn: isMeetingModeOn())
        })
        let bundleID = bundle.bundleIdentifier ?? "com.aaajiao.talktalk.dev"
        let full = FullUninstaller(.live(bundleID: bundleID, driver: installer, engine: engine,
                                         restoreWithSwitcher: restoreWithSwitcher))
        full.beforeBegin = beforeBegin
        return DriverComponentModel(installer: installer, fullUninstaller: full, isMeetingModeOn: isMeetingModeOn,
                                    selfTestOptions: {
                                        DriverSelfTest.Options(feedProbe: resources?.feedProbe,
                                                               channel1Busy: isChannel1Busy())
                                    })
    }

    public var bundledVersion: String? { try? installer.resources?.manifest().version }
    public var carriesDriver: Bool { installer.resources != nil }

    /// An install, uninstall, restart, self-test or 完全卸载 is running: every other action waits.
    public var isBusy: Bool {
        installer.phase.isBusy || selfTestRunning || (fullUninstaller?.phase.isRunning ?? false)
    }

    /// 完全卸载 cannot start: something above is running, or the engine installer is (the engine
    /// rows' install / check / models; review of 639f957 #2). Driver actions do not wait for the
    /// engine.
    /// A session, recording or audition runs (the app supplies it, as for the engine rows):
    /// 完全卸载 waits for it instead of being refused after its confirmation.
    @ObservationIgnored public var sessionActive: @MainActor () -> Bool = { false }

    public var fullUninstallBlocked: Bool {
        guard let fullUninstaller else { return true }
        // After a complete run there is nothing left to remove: quit and move the app to the Trash.
        return isBusy || fullUninstaller.isEngineBusy || sessionActive()
            || fullUninstallSummary?.outcome == .complete
    }

    /// 完全卸载 is running: the engine rows wait for it (DriverComponentsPage hands this to
    /// EngineComponentsModel.blockedBy).
    public var fullUninstallRunning: Bool { fullUninstaller?.phase.isRunning ?? false }

    /// The last 完全卸载 run's result (nil before the first run and while one runs).
    public var fullUninstallSummary: FullUninstallSummary? {
        guard let fullUninstaller else { return nil }
        return FullUninstallSummary(phase: fullUninstaller.phase, report: fullUninstaller.lastReport)
    }

    public func refresh() {
        let (s, r) = installer.installation.check()
        state = s
        record = r
        let diag = installer.hal.diagnostics()
        users = (diag?.micUsers ?? []).filter { $0.pid != getpid() }.map(Self.user).uniqued()
    }

    static func user(_ c: DriverDiagnostics.Client) -> DriverUser {
        let app = NSRunningApplication(processIdentifier: c.pid)
        let name = app?.localizedName ?? c.bundleID ?? "pid \(c.pid)"
        return DriverUser(name: name, bundleID: c.bundleID ?? app?.bundleIdentifier)
    }

    // MARK: actions

    public func requestInstall(from host: Host = .settings) {
        let pre = installer.preflight()
        guard pre.canProceed else { return blocked(pre) }
        ask(.install(warnings: pre.warnings, update: state != .notInstalled), host)
    }

    public func requestUninstall(from host: Host = .settings) {
        let pre = installer.preflight()
        guard pre.canProceed else { return blocked(pre) }
        ask(.uninstall(warnings: pre.warnings), host)
    }

    public func requestRestartAudio(from host: Host = .settings) {
        let pre = installer.preflight()
        guard pre.canProceed else { return blocked(pre) }
        ask(.restartAudio(warnings: pre.warnings), host)
    }

    private func ask(_ c: Confirmation, _ host: Host) {
        confirmationAskedBy = host
        confirmation = c
    }

    /// `confirmation` as the given window's alert item: nil in the other window.
    public func confirmation(for host: Host) -> Confirmation? {
        confirmationAskedBy == host ? confirmation : nil
    }

    public func dismissConfirmation() {
        confirmation = nil
        confirmationAskedBy = nil
    }

    public func requestFullUninstall() {
        guard !fullUninstallBlocked else { return }
        confirmingFullUninstall = true
    }

    /// A blocker stops the action before its confirmation: the reasons are the notice.
    private func blocked(_ pre: DriverPreflight) {
        let text = pre.blockers.map(\.text).joined(separator: "\n")
        notice = text
        result = SettingsProblem(.warn, sentence: text)
    }

    private func finished(_ p: DriverInstaller.Phase) {
        notice = Self.text(p)
        result = Self.result(p)
    }

    public func confirm(_ c: Confirmation) async {
        dismissConfirmation()
        notice = nil
        result = nil
        switch c {
        case .install:
            let p = await installer.install()
            refresh()
            finished(p)
            if case .finished(.installed) = p { await runSelfTest() }
        case .uninstall:
            finished(await installer.uninstall())
            refresh()
        case .restartAudio:
            finished(await installer.restartAudio())
            refresh()
        case .fullUninstall:
            // The result is FullUninstallSection's (`fullUninstallSummary`), not a notice.
            guard let fullUninstaller else { return }
            await fullUninstaller.run()
            refresh()
        }
    }

    /// `includeMeetingPath`: only the install path in onboarding step 3 sends the sweep through
    /// channel 1 into TalkTalk Mic. Settings' 自检 button and the self-test after its 安装 never
    /// do (§8.4, M2 复查).
    public func runSelfTest(includeMeetingPath: Bool = false) async {
        guard !isBusy, state.isUsable || state.isLoadedButOutdated else { return }
        selfTestRunning = true
        defer { selfTestRunning = false }
        // The last pass belongs to that run: a new one must not keep saying 自检通过.
        if result == Self.selfTestPassed { result = nil }
        var options = selfTestOptions()
        options.requestPermission = true
        options.includeMeetingPath = includeMeetingPath
        let report = await makeSelfTest().run(options)
        selfTest = report
        if !report.isConclusive {
            // nothing is written: an earlier result (or none) stays in driver.json
            let line = String(appLocalized: "自检没有跑完，上次的结果保留。\(report.incompleteText)")
            notice = [notice, line].compactMap { $0 }.joined(separator: "\n")
            result = SettingsProblem.mostSevere([result, SettingsProblem(.warn, sentence: line)]) ?? result
        } else {
            _ = try? installer.installation.record(report)
            // A pass changes nothing else on the page: say so, unless the install's own result
            // (已安装 v) is still showing. A failure is the status row's 自检未通过.
            if report.passed, result == nil { result = Self.selfTestPassed }
        }
        refresh()
    }

    private static var selfTestPassed: SettingsProblem { SettingsProblem(.ok, String(appLocalized: "自检通过")) }

    /// The self-test with this model's HAL, version and restore-record check.
    func makeSelfTest() -> DriverSelfTest {
        DriverSelfTest(hal: installer.hal, expectedVersion: bundledVersion, restoreRecordExists: restoreRecordExists)
    }

    public func dismissNotice() {
        notice = nil
        result = nil
    }

    // MARK: texts

    public var statusText: String {
        switch state {
        case .notInstalled: carriesDriver ? String(appLocalized: "未安装") : String(appLocalized: "这个版本没有带虚拟麦克风")
        case .onDiskNotLoaded: String(appLocalized: "已安装，需要重启音频服务才生效")
        case .loaded(let v): String(appLocalized: "已安装 \(v)")
        case .outdated(let i, let b): String(appLocalized: "已安装 \(i)，App 带的是 \(b)：请更新")
        case .damaged(let why): String(appLocalized: "有问题：\(why)")
        case .selfTestFailed(let v, let f):
            String(appLocalized: "已安装 \(v)，上次自检没通过（\(DriverSelfTestReport.Check.Name.shortTitles(f))）")
        }
    }

    static func text(_ p: DriverInstaller.Phase) -> String? {
        switch p {
        case .finished(.installed(let v)): String(appLocalized: "虚拟麦克风 \(v) 已安装。")
        case .finished(.uninstalled): String(appLocalized: "虚拟麦克风已卸载。会议 App 会切回实体麦克风。")
        case .finished(.restarted): String(appLocalized: "音频服务已重启。")
        case .finished(.needsLogout): String(appLocalized: "文件已更新，但音频服务没能重启：注销或重启 Mac 后生效。")
        case .blocked(let pre): pre.blockers.map(\.text).joined(separator: "\n")
        case .failed(let m): String(appLocalized: "没有成功：\(m)")
        case .cancelled: String(appLocalized: "已取消。")
        default: nil
        }
    }
}

/// An app reading TalkTalk Mic now: its name for help and VoiceOver, its bundle id for the icon.
public struct DriverUser: Sendable, Hashable {
    public var name: String
    public var bundleID: String?

    public init(name: String, bundleID: String?) {
        self.name = name
        self.bundleID = bundleID
    }
}

extension DriverInstallation.State {
    /// Loaded but older/newer than the bundled one: the self-test may still run.
    var isLoadedButOutdated: Bool { if case .outdated = self { true } else { false } }
}
