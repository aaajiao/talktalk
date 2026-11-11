import CryptoKit
import Foundation
import TalkTalkCore

/// Fixed facts about TalkTalkAudio.driver (ARCHITECTURE.md, "平台与模块"). The pins come from
/// `DriverPins` (generated from scripts/lib/versions.sh by scripts/gen-pins.sh). The version is
/// not here on purpose: the expected version is the one of the driver bundled with this app
/// (`DriverResources.manifest.version`), so a rebuilt app never disagrees with its own driver.
public enum DriverIdentity {
    public static let bundleIdentifier = DriverPins.bundleID
    public static let bundleName = DriverPins.bundleName
    public static let executableName = "TalkTalkAudio"   // TT_DRIVER_EXECUTABLE (gen-pins does not emit it)
    public static let feedUID = DriverPins.feedUID
    public static let micUID = DriverPins.micUID
    public static let testMicUID = DriverPins.testMicUID
    /// The two bundle ids the Feed's gate lets through (§8.3).
    public static let allowedClients: Set<String> = ["com.aaajiao.talktalk", "com.aaajiao.talktalk.dev"]
    public static let halDirectory = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)
    public static var installedBundle: URL { halDirectory.appendingPathComponent(bundleName) }

    /// Loopback lag of the driver: Mic / Test Mic read sample time T − 480 (§8.3, M0-T8).
    public static let loopbackLagFrames = 480
    public static let sampleRate = 48_000.0
    /// Feed custom properties (docs/decisions/m0-t8-driver.md "驱动的自定义属性").
    public static let diagnosticsSelector: UInt32 = DriverPins.diagnosticsSelector   // 'ttdg'
    public static let meetingModeSelector: UInt32 = DriverPins.meetingModeSelector   // 'ttmm'
}

/// `driver-manifest.json`, written by scripts/build-driver.sh next to the bundle: every file's
/// path, size and sha256. install-driver.sh checks it again as root.
public struct DriverManifest: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public let path: String
        public let bytes: Int64
        public let sha256: String
    }
    public let bundleName: String
    public let bundleIdentifier: String
    public let version: String
    public let micMode: String?
    public let micInUse: String?
    public let sign: String?
    public let libASPL: String?
    public let files: [File]

    public static let maxBytes = 1 << 20

    public static func read(_ url: URL) throws -> DriverManifest {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw DriverError.manifest("driver-manifest.json is \(size) bytes") }
        return try JSONDecoder().decode(DriverManifest.self, from: Data(contentsOf: url))
    }

    /// Checks `bundle` against the manifest: the identifier, no symlinks, exactly the listed
    /// files, each with its size and sha256. Returns the problems (empty = it matches).
    public func verify(bundle: URL) -> [String] {
        var problems: [String] = []
        if bundleIdentifier != DriverIdentity.bundleIdentifier {
            problems.append("manifest names \(bundleIdentifier), expected \(DriverIdentity.bundleIdentifier)")
        }
        let fm = FileManager.default
        var seen: Set<String> = []
        let base = bundle.standardizedFileURL.path
        if let e = fm.enumerator(at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                                 options: []) {
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                let full = url.standardizedFileURL.path
                let rel = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : full
                if v?.isSymbolicLink == true {
                    problems.append("symlink \(rel)")
                } else if v?.isRegularFile == true {
                    seen.insert(rel)
                }
            }
        } else {
            problems.append("cannot read \(bundle.path)")
        }
        let listed = Set(files.map(\.path))
        for extra in seen.subtracting(listed).sorted() { problems.append("not in manifest: \(extra)") }
        for f in files {
            let url = bundle.appendingPathComponent(f.path)
            guard seen.contains(f.path) else {
                problems.append("missing \(f.path)")
                continue
            }
            let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
            if size != f.bytes {
                problems.append("\(f.path): \(size) bytes, manifest \(f.bytes)")
                continue
            }
            guard let sum = try? Self.sha256(of: url) else {
                problems.append("\(f.path): unreadable")
                continue
            }
            if sum != f.sha256 { problems.append("\(f.path): sha256 differs") }
        }
        return problems
    }

    /// Streaming sha256 (the driver binary is a few hundred KB; no need to map it).
    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 16), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What the app bundle carries for the driver (§8.4 step 2): `Contents/Resources/driver/` with
/// `TalkTalkAudio.driver`, `driver-manifest.json`, `install-driver.sh`, `versions.sh` and the
/// gate probe `feedprobe`. scripts/build-app.sh assembles it.
public struct DriverResources: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var bundle: URL { directory.appendingPathComponent(DriverIdentity.bundleName) }
    public var manifestURL: URL { directory.appendingPathComponent("driver-manifest.json") }
    public var installScript: URL { directory.appendingPathComponent("install-driver.sh") }
    public var feedProbe: URL { directory.appendingPathComponent("feedprobe") }

    public func manifest() throws -> DriverManifest { try DriverManifest.read(manifestURL) }

    /// nil when this build carries no driver (e.g. a bare `swift run`).
    public static func inBundle(_ bundle: Bundle = .main) -> DriverResources? {
        guard let dir = bundle.resourceURL?.appendingPathComponent("driver", isDirectory: true) else { return nil }
        let r = DriverResources(directory: dir)
        let fm = FileManager.default
        guard fm.fileExists(atPath: r.bundle.path), fm.fileExists(atPath: r.manifestURL.path),
              fm.fileExists(atPath: r.installScript.path) else { return nil }
        return r
    }
}

/// Paths of the driver's own files outside the bundle (§7.1): `driver.json` in Application
/// Support, `driver-install.log` in Logs, staging under `Caches/TalkTalk/installer-tmp/`.
public struct DriverPaths: Sendable, Equatable {
    public let home: URL
    public let logs: URL
    public let caches: URL

    public init(home: URL, logs: URL, caches: URL) {
        self.home = home
        self.logs = logs
        self.caches = caches
    }

    public var record: URL { home.appendingPathComponent("driver.json") }
    public var installLog: URL { logs.appendingPathComponent("driver-install.log") }
    public var installerTmp: URL { caches.appendingPathComponent("installer-tmp") }

    public static func standard() -> DriverPaths {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return DriverPaths(home: library.appendingPathComponent("Application Support/TalkTalk"),
                           logs: library.appendingPathComponent("Logs/TalkTalk"),
                           caches: library.appendingPathComponent("Caches/TalkTalk"))
    }
}

public enum DriverError: Error, Equatable, CustomStringConvertible {
    case manifest(String)
    case staging(String)
    case record(String)

    public var description: String {
        switch self {
        case .manifest(let m): "driver manifest: \(m)"
        case .staging(let m): "staging: \(m)"
        case .record(let m): "driver.json: \(m)"
        }
    }
}
