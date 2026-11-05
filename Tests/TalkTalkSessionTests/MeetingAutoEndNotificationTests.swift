import Foundation
import Testing
import TalkTalkSession

@Suite struct MeetingAutoEndNotificationTests {
    @Test func savedPreferenceCanTurnOffAndOnWithoutChangingPermission() throws {
        let suite = "TalkTalk.NotificationPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MeetingAutoEndNotification.isEnabled(defaults: defaults))
        MeetingAutoEndNotification.setEnabled(false, defaults: defaults)
        #expect(!MeetingAutoEndNotification.isEnabled(defaults: defaults))
        let disabled = MeetingAutoEndNotification.Setting(
            enabled: MeetingAutoEndNotification.isEnabled(defaults: defaults), authorization: .allowed)
        #expect(!disabled.isEffective)
        #expect(disabled.action(enabling: true) == .enable)
        MeetingAutoEndNotification.setEnabled(true, defaults: defaults)
        #expect(MeetingAutoEndNotification.isEnabled(defaults: defaults))
        #expect(MeetingAutoEndNotification.Setting(enabled: true, authorization: .allowed).isEffective)
    }

    @Test func systemPermissionIsNotConfusedWithTheAppPreference() {
        let allowed = MeetingAutoEndNotification.Setting(enabled: true, authorization: .allowed)
        #expect(allowed.isEffective)
        #expect(allowed.action(enabling: false) == .disable)
        #expect(allowed.action(enabling: true) == .enable) // no repeated authorization request

        let undecided = MeetingAutoEndNotification.Setting(enabled: true, authorization: .notDetermined)
        #expect(!undecided.isEffective)
        #expect(undecided.action(enabling: true) == .requestAuthorization)

        let denied = MeetingAutoEndNotification.Setting(enabled: true, authorization: .denied)
        #expect(!denied.isEffective)
        #expect(denied.action(enabling: true) == .openSystemSettings)
        #expect(denied.action(enabling: false) == .disable) // can revoke app intent even while denied
        #expect(MeetingAutoEndNotification.Setting(enabled: true, authorization: .unavailable)
            .action(enabling: true) == .none)
    }
}
