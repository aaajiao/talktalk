import Foundation
import Observation
import Synchronization

/// The user's interface language, independent of recognition and translation directions.
/// A launch snapshot lets “Follow system” keep its meaning after the process-only
/// AppleLanguages override has been installed for native system controls.
@MainActor
@Observable
public final class AppLanguageStore {
    public static let shared = AppLanguageStore()
    public nonisolated static let didChangeNotification = Notification.Name("TalkTalkAppLanguageDidChange")

    private let defaults: UserDefaults
    private let preferredLanguages: [String]
    private let runtime: AppLocalizationRuntime

    public var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            selection.save(defaults: defaults)
            let previous = oldValue.resolved(preferredLanguages: preferredLanguages)
            runtime.setLanguage(language)
            if previous != language {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
    }

    public var language: AppLanguage { selection.resolved(preferredLanguages: preferredLanguages) }
    public var locale: Locale { Locale(identifier: language.rawValue) }

    init(defaults: UserDefaults = .standard,
         preferredLanguages: [String] = AppLocalization.systemPreferredLanguages,
         runtime: AppLocalizationRuntime = .shared) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        self.runtime = runtime
        selection = AppLanguage.load(defaults: defaults)
        runtime.setLanguage(language)
    }

    /// Call before creating NSApplication or any UI models. Subsequent changes update
    /// the in-process resolver and observable views immediately, without restarting audio.
    public static func bootstrap() {
        let store = shared
        store.language.applyAtLaunch(defaults: store.defaults)
    }
}

/// Synchronous localization for both UI and background error presentation.
public enum AppLocalization {
    static let systemPreferredLanguages = Locale.preferredLanguages

    /// A nonpersistent override for explicit command-line localization checks. Normal
    /// interface changes go through AppLanguageStore.selection to update observers.
    public static func setLanguage(_ language: AppLanguage) {
        AppLocalizationRuntime.shared.setLanguage(language.resolved(preferredLanguages: systemPreferredLanguages))
    }
}

/// ObservationRegistrar is thread-safe, as is the Mutex containing the selected snapshot.
/// Registering reads here allows SwiftUI bodies that build ordinary Strings to refresh
/// without replacing their view identity or triggering recording-related onDisappear work.
final class AppLocalizationRuntime: Observable, Sendable {
    struct Snapshot: Sendable {
        let language: AppLanguage
        let bundle: Bundle
        let locale: Locale
    }

    static let shared = AppLocalizationRuntime()
    private let registrar = ObservationRegistrar()
    private let snapshots: [AppLanguage: Snapshot]
    private let storage: Mutex<Snapshot>

    init(bundle: Bundle = .main, language: AppLanguage = .system,
         preferredLanguages: [String] = AppLocalization.systemPreferredLanguages) {
        let snapshots = Dictionary(uniqueKeysWithValues: [AppLanguage.english, .chinese].map { language in
            let localizedBundle = bundle.url(forResource: language.rawValue, withExtension: "lproj")
                .flatMap(Bundle.init(url:)) ?? bundle
            return (language, Snapshot(language: language, bundle: localizedBundle,
                                       locale: Locale(identifier: language.rawValue)))
        })
        self.snapshots = snapshots
        storage = Mutex(snapshots[language.resolved(preferredLanguages: preferredLanguages)]!)
    }

    var language: AppLanguage {
        registrar.access(self, keyPath: \.language)
        return storage.withLock { $0.language }
    }

    func snapshot() -> Snapshot {
        registrar.access(self, keyPath: \.language)
        return storage.withLock { $0 }
    }

    func setLanguage(_ language: AppLanguage) {
        guard let next = snapshots[language], storage.withLock({ $0.language }) != language else { return }
        registrar.withMutation(of: self, keyPath: \.language) {
            storage.withLock { $0 = next }
        }
    }

    func localized(_ key: String.LocalizationValue) -> String {
        let selected = snapshot()
        return String(localized: key, bundle: selected.bundle, locale: selected.locale)
    }
}

extension String {
    public init(appLocalized key: String.LocalizationValue) {
        self = AppLocalizationRuntime.shared.localized(key)
    }
}
