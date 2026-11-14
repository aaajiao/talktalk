import Foundation

/// Apple speech/translation resources the user wants to prepare. This does not narrow the
/// languages supported by Qwen or the scene language menus, and never deletes installed assets.
public struct SpeechResourceSelection: Equatable, Sendable {
    public static let required: Set<Lang> = [.zh, .en]
    public static let preferenceKey = "speech.resourceLanguages"
    public let languages: Set<Lang>

    public init(languages: Set<Lang> = required) {
        self.languages = languages.union(Self.required)
    }

    public var orderedLanguages: [Lang] { Lang.allCases.filter(languages.contains) }

    public func selecting(_ language: Lang, enabled: Bool) -> Self {
        var selected = languages
        if enabled { selected.insert(language) } else { selected.remove(language) }
        return Self(languages: selected)
    }

    public func missingLanguages(installed: Set<Lang>) -> [Lang] {
        orderedLanguages.filter { !installed.contains($0) }
    }

    public func isReady(installed: Set<Lang>) -> Bool { languages.isSubset(of: installed) }

    /// Existing installations have no selection key: Chinese and English are the base,
    /// while German and French become requirements only after an explicit selection.
    public static func load(defaults: UserDefaults = .standard) -> Self {
        let saved = defaults.stringArray(forKey: preferenceKey) ?? []
        return Self(languages: Set(saved.compactMap(Lang.init(rawValue:))))
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(orderedLanguages.map(\.rawValue), forKey: Self.preferenceKey)
    }
}
