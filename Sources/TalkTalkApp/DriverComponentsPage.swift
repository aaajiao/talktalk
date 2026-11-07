// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import Observation
import TalkTalkDriverSupport

/// Settings › 组件 › 虚拟麦克风 and 通用 › 完全卸载… (ARCHITECTURE.md §8.4, §11): m0-t8's
/// DriverComponentModel wired to this app's SystemInputSwitcher. It is built the first time the
/// page appears, not at launch, because its refresh reads the HAL and the installed bundle.
///
/// Two cases get no model, and the page says why:
///  - the smoke run: it has no SystemInputController, because it must not read or write the
///    real default input (§8.6);
///  - a binary run without a bundle id: there is no Keychain item, defaults domain or TCC entry
///    of its own to remove.
@MainActor
@Observable
final class DriverComponentsPage {
    private(set) var model: DriverComponentModel?
    private(set) var problem: String?
    /// Set by AppDelegate right after it creates the controller (the settings window comes first).
    @ObservationIgnored var systemInput: SystemInputController?
    @ObservationIgnored var isChannel1Busy: @Sendable () -> Bool = { false }
    @ObservationIgnored var externalBusy: @MainActor () -> Bool = { false }
    @ObservationIgnored private let engine: EngineComponentsModel
    @ObservationIgnored private let bundle: Bundle

    init(engine: EngineComponentsModel, bundle: Bundle = .main) {
        self.engine = engine
        self.bundle = bundle
    }

    func load() {
        guard model == nil else { return }
        guard bundle.bundleIdentifier != nil else {
            problem = String(localized: "这个构建没有 bundle id（直接运行的二进制）：虚拟麦克风和完全卸载只在 TalkTalk.app / TalkTalk-Dev.app 里可用。")
            return
        }
        guard let switcher = systemInput?.switcher else {
            problem = String(localized: "这次运行没有接系统默认输入（冒烟运行），虚拟麦克风和完全卸载不可用。")
            return
        }
        let model = DriverComponentModel.forCurrentApp(
            // The driver's install / uninstall and 完全卸载 read the switcher's own meeting mode,
            // not a flag of their own (m2-driver wiring (a), §8.4).
            isMeetingModeOn: { [weak self] in switcher.isMeetingModeOn || self?.externalBusy() == true },
            isChannel1Busy: isChannel1Busy,
            engine: engine.installer,
            beforeBegin: { [weak engine] in await engine?.stopEngine?() },
            // Step 1 of 完全卸载 with this app's own record; another TalkTalk's or a stale record
            // goes to SysInputRestore.restoreStale (§8.4, §8.6).
            restoreWithSwitcher: SysInputRestore.withSwitcher(switcher),
            bundle: bundle)
        self.model = model
        problem = nil
        // Both use the same EngineInstaller: the engine rows wait while 完全卸载 runs, and
        // 完全卸载 waits while the engine installer runs (FullUninstaller's engineBusy).
        engine.blockedBy = { [weak model, weak self] in model?.fullUninstallRunning == true || self?.externalBusy() == true }
        if let full = model.fullUninstaller { follow(full) }
    }

    /// 完全卸载 runs the engine installer itself, so the components model does not re-read the
    /// installation on its own. Re-read it when a run ends: the engine rows and EngineHost
    /// (AppDelegate.followInstallation: stop and drop the instance) then see the engine gone.
    private func follow(_ full: FullUninstaller) {
        withObservationTracking { _ = full.phase } onChange: { [weak self, weak full] in
            Task { @MainActor in
                guard let self, let full else { return }
                if !full.phase.isRunning { self.engine.reload() }
                self.follow(full)
            }
        }
    }
}
