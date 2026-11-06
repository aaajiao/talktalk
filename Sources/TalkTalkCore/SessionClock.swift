import Foundation

/// Elapsed session time for the menu header and the running scenario card: "12:03", "1:02:03".
/// In Core so the settings cards (TalkTalkSettingsUI, no session state) count the same way.
public enum SessionClock {
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
