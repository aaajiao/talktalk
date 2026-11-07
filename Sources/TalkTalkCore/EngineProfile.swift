// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Named installation presets. Classification follows active roles, not the historical
/// profile label or other model files kept on disk; it never changes an installation.
public enum EngineProfile: String, CaseIterable, Sendable, Identifiable {
    case max, standard, compact24, compact16

    /// The resource picker offers local TTS + ASR combinations. compact16 remains
    /// readable for older installations and CLI compatibility, not as an ASR choice.
    public static let selectablePresets: [Self] = [.max, .standard, .compact24]
    public static let customID = "custom"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .max: String(localized: "Max")
        case .standard: String(localized: "标准")
        case .compact24: String(localized: "轻量")
        case .compact16: String(localized: "仅语音合成")
        }
    }

    public static func title(for id: String) -> String {
        Self(rawValue: id)?.title ?? String(localized: "自定义组合")
    }

    public var modelIDs: [String] { EnginePins.profiles[rawValue] ?? [] }
    public var expectedRoles: [String: String] {
        Self.roles(modelIDs: modelIDs, pins: EnginePins.models) ?? [:]
    }
    public var usesAppleRecognition: Bool { self == .compact16 }
    /// Downloaded model files only; excludes the runtime and working memory.
    public var modelBytes: Int64 {
        EnginePins.models.filter { modelIDs.contains($0.key) }.reduce(0) { $0 + $1.bytes }
    }

    public static func matching(activeRoles: [String: String]) -> Self? {
        allCases.first { $0.expectedRoles == activeRoles }
    }

    public static func matching(record: EngineInstallation.Record) -> Self? {
        matching(activeRoles: record.roles.mapValues(\.id))
    }

    /// Also used by installation checks with isolated fixture pins/catalogs.
    static func matchingID(activeRoles: [String: String], declaredID: String,
                           profiles: [String: [String]], pins: [EnginePins.Model]) -> String? {
        let matches = profiles.keys.sorted().filter {
            guard let ids = profiles[$0], let expected = roles(modelIDs: ids, pins: pins) else { return false }
            return expected == activeRoles
        }
        return matches.contains(declaredID) ? declaredID : matches.first
    }

    private static func roles(modelIDs: [String], pins: [EnginePins.Model]) -> [String: String]? {
        guard !modelIDs.isEmpty else { return nil }
        var roles: [String: String] = [:]
        for id in modelIDs {
            guard let model = pins.first(where: { $0.key == id }), roles[model.role] == nil else { return nil }
            roles[model.role] = id
        }
        return roles
    }
}
