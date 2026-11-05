import Foundation

/// The app's launch check (ARCHITECTURE.md §7.5). Every item runs without starting a process,
/// without the network and without a permission prompt; it only stats, reads small files and asks
/// status APIs. Items live next to what they check:
///   1–2 engine install   `EngineStartupCheck` (here, over EngineInstallation)
///   3   driver           TalkTalkAudio (M2)
///   4   voice            `VoiceStartupCheck` (TalkTalkVoice)
///   5   permissions      `PermissionsStartupCheck` (here; the status probes are injected by the app)
///   6   Apple assets     TalkTalkApple
///   7   OpenAI key       TalkTalkCloud (existence only, never the data)
public protocol StartupCheckItem: Sendable {
    var id: String { get }
    func run() async -> StartupCheckResult
}

public struct StartupCheckResult: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable, Comparable {
        /// Nothing to show.
        case ok
        /// Works; the UI may show a badge (an outdated model, no voice recorded yet).
        case notice
        /// A feature is unavailable until the user acts (install, repair, grant).
        case action

        var rank: Int { switch self { case .ok: 0; case .notice: 1; case .action: 2 } }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    public let id: String
    public let level: Level
    /// A short status for the diagnostics page: never a path, never text of the user, never a key.
    public let summary: String
    public let details: [String: String]

    public init(id: String, level: Level, summary: String, details: [String: String] = [:]) {
        self.id = id
        self.level = level
        self.summary = summary
        self.details = details
    }
}

/// Runs the items concurrently and returns the results in item order.
public struct StartupChecker: Sendable {
    public let items: [any StartupCheckItem]

    public init(items: [any StartupCheckItem]) {
        self.items = items
    }

    public func run() async -> [StartupCheckResult] {
        await withTaskGroup(of: (Int, StartupCheckResult).self) { group in
            for (i, item) in items.enumerated() {
                group.addTask { (i, await item.run()) }
            }
            var out = [StartupCheckResult?](repeating: nil, count: items.count)
            for await (i, r) in group { out[i] = r }
            return out.compactMap { $0 }
        }
    }

    public static func worst(_ results: [StartupCheckResult]) -> StartupCheckResult.Level {
        results.map(\.level).max() ?? .ok
    }
}

/// §7.5 items 1–2: install.json, stamps, the compatibility lists and every pinned file's size.
/// sha256 is computed only by the user's "校验" (`--check`).
public struct EngineStartupCheck: StartupCheckItem {
    public let id = "engine"
    public let installation: EngineInstallation

    public init(installation: EngineInstallation) {
        self.installation = installation
    }

    public func run() async -> StartupCheckResult {
        let (state, record) = installation.check()
        var d: [String: String] = [:]
        if let record { d["profile"] = record.profile; d["runtime"] = record.runtime }
        switch state {
        case .installed(let profile, let models):
            d["models"] = models.joined(separator: " ")
            return StartupCheckResult(id: id, level: .ok, summary: "installed (\(profile))", details: d)
        case .outdated(let profile, let models):
            d["outdated"] = models.joined(separator: " ")
            return StartupCheckResult(id: id, level: .notice, summary: "installed (\(profile)), update available", details: d)
        case .notInstalled:
            return StartupCheckResult(id: id, level: .action, summary: "not installed", details: d)
        case .incompatible(let reason):
            d["reason"] = reason
            return StartupCheckResult(id: id, level: .action, summary: "runtime update required", details: d)
        case .incomplete(let missing, let bytes):
            d["missing"] = missing.joined(separator: " "); d["bytes"] = String(bytes)
            return StartupCheckResult(id: id, level: .action, summary: "incomplete", details: d)
        case .unfinished:
            return StartupCheckResult(id: id, level: .action, summary: "unfinished install (re-run to resume)", details: d)
        case .damaged(let reason):
            d["reason"] = reason
            return StartupCheckResult(id: id, level: .action, summary: "damaged (repair in 设置 › 组件)", details: d)
        }
    }
}

/// §7.5 item 5. The probes are injected so this stays free of AVFoundation / Speech / CoreGraphics:
/// the app passes `AVCaptureDevice.authorizationStatus(for: .audio)`, `CGPreflightListenEventAccess()`
/// and `SFSpeechRecognizer.authorizationStatus()`, all of which only read status. System audio
/// recording has no status API: the afplay probe (§3.1) covers it at meeting start.
public struct PermissionsStartupCheck: StartupCheckItem {
    public enum Status: String, Sendable { case granted, denied, notDetermined = "not_determined", restricted }

    public let id = "permissions"
    let microphone: @Sendable () -> Status
    let inputMonitoring: @Sendable () -> Bool
    let speechRecognition: @Sendable () -> Status

    public init(microphone: @escaping @Sendable () -> Status, inputMonitoring: @escaping @Sendable () -> Bool,
                speechRecognition: @escaping @Sendable () -> Status) {
        self.microphone = microphone
        self.inputMonitoring = inputMonitoring
        self.speechRecognition = speechRecognition
    }

    public func run() async -> StartupCheckResult {
        let mic = microphone(), im = inputMonitoring(), sr = speechRecognition()
        let d = ["microphone": mic.rawValue, "input_monitoring": im ? "granted" : "not_granted",
                 "speech_recognition": sr.rawValue]
        let missing = [mic != .granted ? "microphone" : nil, !im ? "input_monitoring" : nil,
                       sr != .granted ? "speech_recognition" : nil].compactMap { $0 }
        if missing.isEmpty { return StartupCheckResult(id: id, level: .ok, summary: "granted", details: d) }
        // Not yet asked is the onboarding's job; denied needs System Settings.
        return StartupCheckResult(id: id, level: .action, summary: "missing: " + missing.joined(separator: ", "), details: d)
    }
}
