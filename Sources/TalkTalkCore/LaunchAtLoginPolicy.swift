// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Settings › 通用 › 登录时启动 (ARCHITECTURE.md §11), the logic behind `LaunchAtLogin`
/// (SMAppService.mainApp). Registration needs a signed bundle; the unit tests cover only this.
public enum LaunchAtLoginPolicy {
    /// SMAppService.Status, mirrored so Core does not import ServiceManagement.
    public enum Status: String, Sendable, Equatable {
        case notRegistered, enabled, requiresApproval, notFound
    }

    public enum Action: Sendable, Equatable { case register, unregister, none }

    /// What the row ends with besides its switch (settings visual system §7.5): only a fact that
    /// needs the user, in the shortest words; the reason is in help or ⓘ.
    public enum Notice: Sendable, Equatable {
        /// Off while §8.6 recommends it (the default-input switch is on and the driver layer does
        /// not count): 建议开启, with `recommendation` behind ⓘ.
        case recommended
        /// Registered, waiting for the user in 系统设置 › 通用 › 登录项与扩展: 待系统允许 and 登录项….
        case awaitingApproval
        /// The system finds no login item for this bundle: 请移到“应用程序”文件夹.
        case moveToApplications
        /// An unsigned build cannot register: the switch is disabled, the reason in help.
        case unsigned
    }

    public struct Presentation: Sendable, Equatable {
        public var isOn: Bool
        public var canToggle: Bool
        /// nil: nothing to say (on and allowed, or off without the recommendation).
        public var notice: Notice?
    }

    /// `stronglyRecommended`: `SystemInputPlan.Config.loginStartStronglyRecommended` while the
    /// default-input switch is on (§8.6: layer 4, "下次启动", is what cleans up after a crash).
    public static func present(_ status: Status, bundleSigned: Bool, stronglyRecommended: Bool) -> Presentation {
        guard bundleSigned else { return Presentation(isOn: false, canToggle: false, notice: .unsigned) }
        switch status {
        case .enabled:
            return Presentation(isOn: true, canToggle: true, notice: nil)
        case .requiresApproval:
            return Presentation(isOn: true, canToggle: true, notice: .awaitingApproval)
        case .notRegistered:
            return Presentation(isOn: false, canToggle: true, notice: stronglyRecommended ? .recommended : nil)
        case .notFound:
            return Presentation(isOn: false, canToggle: true, notice: .moveToApplications)
        }
    }

    /// The ⓘ behind 建议开启 (§7.5).
    public static let recommendation = String(localized: "异常退出后，默认输入可能停在 TalkTalk Mic，直到下次启动才还原。")

    public static func action(wantOn: Bool, current: Status) -> Action {
        switch (wantOn, current) {
        case (true, .enabled), (true, .requiresApproval): .none
        case (true, _): .register
        case (false, .notRegistered), (false, .notFound): .none
        case (false, _): .unregister
        }
    }
}
