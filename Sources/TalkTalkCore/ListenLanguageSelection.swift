import Foundation

/// A complete caption direction. Equal languages are replaced by a useful default.
public struct ListenLanguageSelection: Equatable, Sendable {
    public let source: Lang
    public let target: Lang

    public init(source: Lang = .en, target: Lang = .zh) {
        self.source = source
        self.target = source == target ? (source == .zh ? .en : .zh) : target
    }

    public func selectingSource(_ source: Lang) -> Self { Self(source: source, target: target) }
    public func selectingTarget(_ target: Lang) -> Self { Self(source: source, target: target) }
    public var swapped: Self { Self(source: target, target: source) }
    public var targets: [Lang] { Lang.allCases.filter { $0 != source } }
}

/// Each scene owns its saved direction. Migration snapshots the old shared source once;
/// subsequent edits in one scene cannot overwrite another scene's choice.
public enum ListenLanguagePreferences {
    public enum Scope: String, Sendable, CaseIterable { case meeting, phone, video }
    public static let legacySourceKey = "listen.remoteLanguage"

    /// All three scenes support the same six caption directions; scope only owns persistence.
    public static func normalized(_ selection: ListenLanguageSelection, for _: Scope) -> ListenLanguageSelection {
        selection
    }

    public static func load(_ scope: Scope, defaults: UserDefaults = .standard) -> ListenLanguageSelection {
        let prefix = "\(scope.rawValue).listen."
        let savedSource = defaults.string(forKey: prefix + "sourceLanguage")
        let legacy = defaults.string(forKey: legacySourceKey)
        let source = Lang(rawValue: savedSource ?? legacy ?? "") ?? .en
        let target = Lang(rawValue: defaults.string(forKey: prefix + "targetLanguage") ?? "") ?? .zh
        let selection = normalized(.init(source: source, target: target), for: scope)
        save(selection, for: scope, defaults: defaults)
        return selection
    }

    public static func save(_ selection: ListenLanguageSelection, for scope: Scope,
                            defaults: UserDefaults = .standard) {
        let prefix = "\(scope.rawValue).listen."
        let selection = normalized(selection, for: scope)
        defaults.set(selection.source.rawValue, forKey: prefix + "sourceLanguage")
        defaults.set(selection.target.rawValue, forKey: prefix + "targetLanguage")
    }
}
