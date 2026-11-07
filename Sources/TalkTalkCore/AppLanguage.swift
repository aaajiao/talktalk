// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Interface language only. Speech, translation and caption languages have their own preferences.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    public static let preferenceKey = "ui.appLanguage"
    public var id: String { rawValue }
    /// Autonyms remain recognizable in either interface language.
    public var nativeName: String {
        switch self {
        case .system: String(appLocalized: "跟随系统")
        case .english: "English"
        case .chinese: "中文" // l10n-ignore
        }
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    /// The first system language decides: all Chinese variants use Simplified Chinese;
    /// every other language uses English, even if Chinese appears later in the list.
    public func resolved(preferredLanguages: [String]) -> Self {
        guard self == .system else { return self }
        let first = preferredLanguages.first?.lowercased().replacingOccurrences(of: "_", with: "-") ?? ""
        return first == "zh" || first.hasPrefix("zh-") ? .chinese : .english
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }

    /// Set before NSApplication, Bundle localization or any UI model is initialized. The
    /// process-only override leaves macOS and other apps untouched. App-owned text uses
    /// AppLocalization for subsequent live changes; this sets native launch-time defaults.
    public func applyAtLaunch(defaults: UserDefaults = .standard) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = [resolved(preferredLanguages: Locale.preferredLanguages).rawValue]
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
