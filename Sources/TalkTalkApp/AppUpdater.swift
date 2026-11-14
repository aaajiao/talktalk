// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Observation
import Sparkle
import TalkTalkCore

/// App-lifetime adapter for Sparkle's standard UI. Sparkle owns discovery, download,
/// verification and installation; this adapter only enforces explicit checks and safe restart.
@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    let isEnabled: Bool
    private var configured = false
    private var sparkleCanCheck = false
    private var activity = AppUpdateActivity(maintenance: true)
    private var relaunchState = AppUpdateRelaunchState()
    private var refusedTermination = false
    @ObservationIgnored private var activityProvider: @MainActor () -> AppUpdateActivity = {
        AppUpdateActivity(maintenance: true)
    }
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var readinessObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    /// The host can reveal the General page, where the explicit resume action lives.
    @ObservationIgnored var onPendingRestart: (@MainActor () -> Void)?

    init(enabled: Bool, bundle: Bundle = .main) {
        isEnabled = AppUpdatePolicy.isEnabled(requested: enabled, bundleIdentifier: bundle.bundleIdentifier,
                                              isApplicationBundle: bundle.bundleURL.pathExtension == "app")
        super.init()
    }

    var canCheckForUpdates: Bool {
        isEnabled && configured && sparkleCanCheck && activity.blockingReason == nil
            && !hasPendingRestart && !relaunching
    }
    var hasPendingRestart: Bool { relaunchState.pending && pendingInstall != nil }
    var canResumePendingUpdate: Bool { hasPendingRestart && relaunchState.canResume(activity: activity) }
    var relaunching: Bool { relaunchState.relaunching }

    var busyReason: String? {
        activity.blockingReason.map(Self.message)
    }
    var statusMessage: String? {
        if !isEnabled { return String(appLocalized: "此构建不支持在线更新") }
        if hasPendingRestart || refusedTermination {
            return String(appLocalized: "结束当前操作后再重启更新")
        }
        if relaunching { return String(appLocalized: "正在重启更新…") }
        return nil
    }

    func configure(activity provider: @escaping @MainActor () -> AppUpdateActivity) {
        activityProvider = provider
        refreshActivity()
        guard isEnabled, !configured else { return }
        configured = true
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                      userDriverDelegate: nil)
        self.controller = controller
        // This product exposes manual updates only, including when older Sparkle defaults
        // exist. Info.plist also disables automatic-update options and the permission prompt.
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.sendsSystemProfile = false
        readinessObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshSparkleReadiness() }
        }
        controller.startUpdater()
        refreshSparkleReadiness()
    }

    /// Observation only: becoming idle never invokes the deferred installation handler.
    func refreshActivity() {
        activity = activityProvider()
    }

    func checkForUpdates() {
        refreshActivity()
        guard canCheckForUpdates, let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
        refreshSparkleReadiness()
    }

    /// Called only by the user's "Restart and Update" action. Consume before invoking because
    /// Sparkle may call back synchronously; neither reentrancy nor a second click can reuse it.
    func resumePendingUpdate() {
        refreshActivity()
        guard let install = pendingInstall, relaunchState.requestResume(activity: activity) else { return }
        pendingInstall = nil
        refusedTermination = false
        install()
    }

    /// The app delegate's final termination check can catch activity that started after the
    /// native installer requested restart. Keep the pending choice; never retry by observation.
    func refuseBusyTermination() {
        refreshActivity()
        refusedTermination = true
        onPendingRestart?()
    }

    private func refreshSparkleReadiness() {
        sparkleCanCheck = controller?.updater.canCheckForUpdates == true
    }

    private func clearUpdateSession() {
        pendingInstall = nil
        relaunchState.reset()
        refusedTermination = false
        refreshActivity()
        refreshSparkleReadiness()
    }

    // MARK: Sparkle main-thread delegate

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        refreshActivity()
        guard isEnabled, configured, updateCheck == .updates,
              activity.blockingReason == nil, !hasPendingRestart, !relaunching else {
            throw NSError(domain: "com.aaajiao.talktalk.update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: busyReason
                            ?? String(appLocalized: "请通过“检查更新…”手动检查更新。")])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        refreshActivity()
        guard relaunchState.shouldPostpone(activity: activity) else { return false }
        if pendingInstall == nil { pendingInstall = installHandler }
        onPendingRestart?()
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Also covers Sparkle resuming a previously prepared installation, which may skip the
        // postponement hook. AppDelegate rechecks actual work when termination is requested.
        pendingInstall = nil
        relaunchState.willRelaunch()
        refreshActivity()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        clearUpdateSession()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        clearUpdateSession()
    }

    private static func message(_ reason: AppUpdateActivity.Reason) -> String {
        switch reason {
        case .session: String(appLocalized: "请先结束当前同传或视频字幕。")
        case .voice: String(appLocalized: "请先完成录音、保存或试听声音。")
        case .maintenance: String(appLocalized: "请等待语音资源或 TalkTalk Mic 维护完成。")
        case .diagnostics: String(appLocalized: "请先结束诊断录音、字幕分析或自检。")
        case .onboarding: String(appLocalized: "请等待使用引导中的下载或示例结束。")
        case .exporting: String(appLocalized: "请等待诊断包导出完成。")
        case .calibration: String(appLocalized: "请先完成麦克风校准。")
        }
    }
}
