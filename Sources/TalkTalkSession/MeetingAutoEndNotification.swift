// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import UserNotifications
import TalkTalkCore

/// Permission is requested only by an explicit App UI action, never by the idle timer.
public enum MeetingAutoEndNotification {
    private static let identifier = "talktalk.meeting-auto-end"
    private static let preferenceKey = "meeting.autoEndNotifications.enabled"

    public enum Authorization: Sendable, Equatable {
        case checking, notDetermined, allowed, denied, unavailable
    }
    public enum SettingAction: Sendable, Equatable { case enable, disable, requestAuthorization, openSystemSettings, none }
    /// App intent and OS permission are separate; delivery requires both.
    public struct Setting: Sendable, Equatable {
        public var enabled: Bool
        public var authorization: Authorization
        public init(enabled: Bool, authorization: Authorization) {
            self.enabled = enabled; self.authorization = authorization
        }
        public var isEffective: Bool { enabled && authorization == .allowed }
        public func action(enabling: Bool) -> SettingAction {
            guard enabling else { return .disable }
            switch authorization {
            case .allowed: return .enable
            case .notDetermined: return .requestAuthorization
            case .denied: return .openSystemSettings
            case .checking, .unavailable: return .none
            }
        }
    }

    /// Preserve the old behavior for users who already granted OS permission.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }
    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: preferenceKey)
    }

    public static func authorization() async -> Authorization {
        guard BuildFlavor.current != .bare else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .allowed
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .unavailable
        }
    }

    public static func requestAuthorization() async -> Bool {
        switch await authorization() {
        case .allowed: return true // never request permission again for an ordinary preference toggle
        case .notDetermined: break
        case .checking, .denied, .unavailable: return false
        }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    public static func postIfAuthorized(mode: MeetingMode = .meeting) async {
        guard BuildFlavor.current != .bare, isEnabled() else { return }
        let center = UNUserNotificationCenter.current()
        guard await authorization() == .allowed, isEnabled(), !Task.isCancelled else { return }
        let content = UNMutableNotificationContent()
        content.title = switch mode {
        case .phone: String(localized: "电话同传即将结束")
        case .captions: String(localized: "视频字幕即将结束")
        case .meeting: String(localized: "会议似乎已结束")
        }
        content.body = mode == .phone
            ? String(localized: "Phone 已长时间没有音频。若还在等待电话，请在 TalkTalk 菜单中选择“继续收听”；60 秒后将结束同传并还原麦克风。")
            : String(localized: "若还要继续收听，请在 TalkTalk 菜单中选择“继续收听”；60 秒后将结束当前收听。")
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        // Closing the switch or ending the meeting can race the async add operation.
        if !isEnabled() || Task.isCancelled { clear() }
    }

    public static func clear() {
        guard BuildFlavor.current != .bare else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
