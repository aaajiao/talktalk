// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Settings › 通用 › 登录启动 (ARCHITECTURE.md §11), the logic behind `LaunchAtLogin`
/// (SMAppService.mainApp). Registration needs a signed bundle; the unit tests cover only this.
public enum LaunchAtLoginPolicy {
    /// SMAppService.Status, mirrored so Core does not import ServiceManagement.
    public enum Status: String, Sendable, Equatable {
        case notRegistered, enabled, requiresApproval, notFound
    }

    public enum Action: Sendable, Equatable { case register, unregister, none }

    public struct Presentation: Sendable, Equatable {
        public var isOn: Bool
        public var canToggle: Bool
        /// Gray note under the toggle; nil: none.
        public var note: String?
        /// Show "打开登录项设置" (System Settings › 通用 › 登录项与扩展).
        public var offerSystemSettings: Bool
        /// The §8.6 recommendation is shown in red-ish emphasis (driver layer does not count).
        public var stronglyRecommended: Bool
    }

    /// `stronglyRecommended`: `SystemInputPlan.Config.loginStartStronglyRecommended` while the
    /// default-input switch is on (§8.6: layer 4, "下次启动", is what cleans up after a crash).
    public static func present(_ status: Status, bundleSigned: Bool, stronglyRecommended: Bool) -> Presentation {
        guard bundleSigned else {
            return Presentation(isOn: false, canToggle: false,
                                note: String(localized: "这个构建没有签名，不能注册登录启动。"),
                                offerSystemSettings: false, stronglyRecommended: stronglyRecommended)
        }
        let recommend = stronglyRecommended && status != .enabled
        switch status {
        case .enabled:
            return Presentation(isOn: true, canToggle: true, note: nil, offerSystemSettings: false,
                                stronglyRecommended: false)
        case .requiresApproval:
            return Presentation(isOn: true, canToggle: true,
                                note: String(localized: "等你在“系统设置 › 通用 › 登录项与扩展”里允许 TalkTalk。"),
                                offerSystemSettings: true, stronglyRecommended: recommend)
        case .notRegistered:
            return Presentation(isOn: false, canToggle: true, note: recommend ? recommendation : nil,
                                offerSystemSettings: false, stronglyRecommended: recommend)
        case .notFound:
            return Presentation(isOn: false, canToggle: true,
                                note: String(localized: "系统没找到这个 App 的登录项；把 TalkTalk 放进“应用程序”文件夹后再试。"),
                                offerSystemSettings: false, stronglyRecommended: recommend)
        }
    }

    public static let recommendation = String(localized: "强烈建议开启：TalkTalk 异常退出后，系统默认输入可能还停在 TalkTalk Mic，下次启动时才会还原。")

    public static func action(wantOn: Bool, current: Status) -> Action {
        switch (wantOn, current) {
        case (true, .enabled), (true, .requiresApproval): .none
        case (true, _): .register
        case (false, .notRegistered), (false, .notFound): .none
        case (false, _): .unregister
        }
    }
}
