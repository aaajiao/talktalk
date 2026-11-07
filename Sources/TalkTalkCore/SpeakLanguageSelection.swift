import Foundation

/// The explicit language spoken into the microphone. German remains a translation target.
public enum SpeakSourceLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case zh, en
    public var id: String { rawValue }
    public var lang: Lang { self == .zh ? .zh : .en }
    public var targets: [SpeakTargetLanguage] { self == .zh ? [.en, .de] : [.zh, .de] }
}

public enum SpeakTargetLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case zh, en, de
    public var id: String { rawValue }
    public var lang: Lang {
        switch self { case .zh: .zh; case .en: .en; case .de: .de }
    }
}

/// Source and target change atomically, so the UI and a rebuilt pipeline see the same pair.
public struct SpeakLanguageSelection: Equatable, Sendable {
    public let source: SpeakSourceLanguage
    public let target: SpeakTargetLanguage

    public init(source: SpeakSourceLanguage = .zh, target: SpeakTargetLanguage = .en) {
        self.source = source
        self.target = source.targets.contains(target) ? target : source.targets[0]
    }

    public func selectingSource(_ source: SpeakSourceLanguage) -> Self {
        Self(source: source, target: target)
    }

    public func selectingTarget(_ target: SpeakTargetLanguage) -> Self {
        Self(source: source, target: target)
    }
}

public enum SpeakLanguagePreferences {
    public enum Scope: Sendable { case meeting, phone }

    private static func keys(_ scope: Scope) -> (source: String, target: String) {
        switch scope {
        case .meeting: ("speak.sourceLanguage", "speak.targetLanguage")
        case .phone: ("phone.speak.sourceLanguage", "phone.speak.targetLanguage")
        }
    }

    public static func load(_ scope: Scope, defaults: UserDefaults = .standard) -> SpeakLanguageSelection {
        let key = keys(scope)
        let source = SpeakSourceLanguage(rawValue: defaults.string(forKey: key.source) ?? "") ?? .zh
        let target = SpeakTargetLanguage(rawValue: defaults.string(forKey: key.target) ?? "") ?? .en
        return SpeakLanguageSelection(source: source, target: target)
    }

    public static func save(_ selection: SpeakLanguageSelection, for scope: Scope,
                            defaults: UserDefaults = .standard) {
        let key = keys(scope)
        defaults.set(selection.source.rawValue, forKey: key.source)
        defaults.set(selection.target.rawValue, forKey: key.target)
    }
}
