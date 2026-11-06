import Foundation

/// Each listening scenario owns its selection. Phone is fixed; the legacy meeting preference
/// remains a meeting preference and is never inherited by video captions.
public enum ListeningSourcePreferences {
    public static func source(for mode: MeetingMode, defaults: UserDefaults = .standard) -> String? {
        guard let key = key(for: mode) else { return MeetingMode.phoneAppID }
        return selectableSource(defaults.string(forKey: key))
    }

    public static func setSource(_ id: String?, for mode: MeetingMode, defaults: UserDefaults = .standard) {
        guard let key = key(for: mode) else { return }
        if let source = selectableSource(id) {
            defaults.set(source, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func key(for mode: MeetingMode) -> String? {
        switch mode {
        case .meeting: "meeting.lastSource"
        case .captions: "captions.lastSource"
        case .phone: nil
        }
    }

    private static func selectableSource(_ id: String?) -> String? {
        guard let source = id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty, source != MeetingMode.phoneAppID else { return nil }
        return source
    }
}
