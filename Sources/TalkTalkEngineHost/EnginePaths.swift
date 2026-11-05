import Foundation
import TalkTalkCore

/// Every path the engine host uses (ARCHITECTURE.md §7.1, §10). Only `~/Library/{Application
/// Support,Logs,Caches}/TalkTalk`; never a dot directory in HOME, never anything of readread.
public struct EnginePaths: Sendable, Equatable {
    /// `~/Library/Application Support/TalkTalk` (`$TALKTALK_HOME` overrides it in dev builds only).
    public let home: URL
    public let logs: URL
    public let caches: URL
    /// The engine's Python source (`talktalk_engine.py` + package): `Contents/Resources/engine`.
    public let engineSource: URL?
    /// The installer script (`Contents/Resources/installer/scripts/install-engine.sh`).
    public let installerScript: URL?

    public init(home: URL, logs: URL, caches: URL, engineSource: URL?, installerScript: URL?) {
        self.home = home
        self.logs = logs
        self.caches = caches
        self.engineSource = engineSource
        self.installerScript = installerScript
    }

    /// Engine home of a runtime flavour (§7.6: one `EngineProcess` per flavour). v1 ships only
    /// "main" (`engine/`); a second flavour gets its own directory, venv and lock.
    public func engineHome(flavour: String = "main") -> URL {
        home.appendingPathComponent(flavour == "main" ? "engine" : "engine-\(flavour)")
    }

    public var voiceDir: URL { home.appendingPathComponent("voice") }
    public var engineLog: URL { logs.appendingPathComponent("engine.log") }
    public var installLog: URL { logs.appendingPathComponent("engine-install.log") }
    public var engineTmp: URL { caches.appendingPathComponent("engine-tmp") }
    public var installerTmp: URL { caches.appendingPathComponent("installer-tmp") }
    public var hfHome: URL { caches.appendingPathComponent("hf") }
    public var buildCache: URL { caches.appendingPathComponent("engine-build") }
    /// `TALKTALK_CACHE_DIR` for the engine (voice-conditioning work files, never audio of the user).
    public var engineCache: URL { caches.appendingPathComponent("engine-cache") }

    /// The standard layout for this process. `TALKTALK_HOME` and `TALKTALK_ENGINE_SRC_DIR` are honoured
    /// only outside the release build (§7.1 "仅开发用").
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment,
                                bundle: Bundle = .main, flavor: BuildFlavor = .current) -> EnginePaths {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var home = library.appendingPathComponent("Application Support/TalkTalk")
        if flavor != .release, let h = environment["TALKTALK_HOME"], h.hasPrefix("/") {
            home = URL(fileURLWithPath: h, isDirectory: true)
        }
        var source: URL? = bundle.resourceURL?.appendingPathComponent("engine")
        if flavor != .release, let s = environment["TALKTALK_ENGINE_SRC_DIR"], s.hasPrefix("/") {
            source = URL(fileURLWithPath: s, isDirectory: true)
        }
        if let s = source, !fm.fileExists(atPath: s.appendingPathComponent("talktalk_engine.py").path) { source = nil }
        var installer = bundle.resourceURL?.appendingPathComponent("installer/scripts/install-engine.sh")
        if let i = installer, !fm.fileExists(atPath: i.path) { installer = nil }
        return EnginePaths(home: home, logs: library.appendingPathComponent("Logs/TalkTalk"),
                           caches: library.appendingPathComponent("Caches/TalkTalk"),
                           engineSource: source, installerScript: installer)
    }

    /// Creates a private directory (0700) if it is missing.
    public static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
