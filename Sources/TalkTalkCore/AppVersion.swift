import Foundation

/// Version metadata from the running app bundle. Bare development binaries use the version
/// and build compiled from the same pins that the packaging script reserves.
public struct AppVersion: Sendable, Equatable {
    public let name: String
    public let version: String
    public let build: String?

    public static var current: AppVersion { AppVersion() }

    public init(bundle: Bundle = .main) {
        func text(_ key: String) -> String? {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        name = text("CFBundleDisplayName") ?? text("CFBundleName") ?? "TalkTalk"
        version = text("CFBundleShortVersionString") ?? EnginePins.appVersion
        build = text("CFBundleVersion") ?? EnginePins.appBuild
    }

    public var displayString: String {
        build.map { "\(version) (\($0))" } ?? version
    }
}
