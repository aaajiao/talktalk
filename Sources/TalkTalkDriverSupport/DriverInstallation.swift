// l10n: zh-Hans (scripts/check-strings.sh)
import TalkTalkCore
import Darwin
import Foundation

/// Decides the driver's install state (ARCHITECTURE.md, "平台与模块") from the bundle on disk, the
/// HAL and `driver.json`. Cheap enough for every launch: `lstat`, one Info.plist read and HAL
/// property reads; no hashing (sha256 runs only when installing), no process, no IO.
public struct DriverInstallation: Sendable {
    /// `driver.json` (§7.1): what the app installed last, plus the last self-test result.
    public struct Record: Codable, Sendable, Equatable {
        public struct SelfTest: Codable, Sendable, Equatable {
            public var at: Date
            public var version: String
            public var passed: Bool
            /// Names of the failed checks (empty when passed).
            public var failed: [String]

            public init(at: Date = Date(), version: String, passed: Bool, failed: [String] = []) {
                self.at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down))
                self.version = version
                self.passed = passed
                self.failed = failed
            }
        }
        public var version: String
        /// sha256 of the driver-manifest.json the installed bundle was checked against.
        public var sha256: String
        public var installedAt: Date
        public var selfTest: SelfTest?

        public init(version: String, sha256: String, installedAt: Date = Date(), selfTest: SelfTest? = nil) {
            self.version = version
            self.sha256 = sha256
            self.installedAt = Date(timeIntervalSince1970: installedAt.timeIntervalSince1970.rounded(.down))
            self.selfTest = selfTest
        }

        enum CodingKeys: String, CodingKey {
            case version, sha256
            case installedAt = "installed_at"
            case selfTest = "self_test"
        }
    }

    /// §8.4 状态.
    public enum State: Sendable, Equatable {
        case notInstalled
        /// Files are in place but the HAL has not loaded them (or still runs an older copy):
        /// the audio service must restart ("重启音频服务"; if that fails, log out or restart).
        case onDiskNotLoaded(version: String?)
        case loaded(version: String)
        /// Loaded, but not the driver this app carries: reinstall from the app.
        case outdated(installed: String, bundled: String)
        case damaged(reason: String)
        /// Loaded and current, but the last self-test of this version failed.
        case selfTestFailed(version: String, failed: [String])

        /// The Feed is there and is the bundled version (a failed self-test still lets the user try).
        public var isUsable: Bool {
            switch self {
            case .loaded, .selfTestFailed: true
            default: false
            }
        }

        public var needsAudioRestart: Bool { if case .onDiskNotLoaded = self { true } else { false } }
    }

    /// What is on disk at `/Library/Audio/Plug-Ins/HAL/TalkTalkAudio.driver`.
    public enum DiskState: Sendable, Equatable {
        case absent
        case present(version: String)
        case foreign(String)
        case damaged(String)
    }

    public static let maxRecordBytes = 64 * 1024

    public let paths: DriverPaths
    public let installedBundle: URL
    /// Version of the driver bundled with this app (nil: this build carries none).
    public let bundledVersion: String?
    public let hal: any DriverHAL

    public init(paths: DriverPaths, bundledVersion: String?, hal: any DriverHAL = CoreAudioDriverHAL(),
                installedBundle: URL = DriverIdentity.installedBundle) {
        self.paths = paths
        self.bundledVersion = bundledVersion
        self.hal = hal
        self.installedBundle = installedBundle
    }

    // MARK: driver.json

    public func readRecord() throws -> Record? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.record.path) else { return nil }
        let size = ((try fm.attributesOfItem(atPath: paths.record.path))[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxRecordBytes else { throw DriverError.record("\(size) bytes") }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Record.self, from: Data(contentsOf: paths.record))
    }

    /// Atomic replace, 0600; the directory is created 0700 if needed.
    public func writeRecord(_ record: Record) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.home.path) {
            try fm.createDirectory(at: paths.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(record).write(to: paths.record, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.record.path)
    }

    public func deleteRecord() {
        unlink(paths.record.path)
    }

    /// Stores a self-test result in driver.json (creates a minimal record when the driver was
    /// installed outside the app, e.g. by the M0 scripts).
    public func recordSelfTest(_ result: Record.SelfTest) throws {
        var r = (try? readRecord()) ?? Record(version: result.version, sha256: "", installedAt: Date())
        r.selfTest = result
        try writeRecord(r)
    }

    /// Stores a self-test run only when it is conclusive (`DriverSelfTestReport.isConclusive`): a
    /// run whose required checks were skipped keeps the earlier record, so it can neither mark an
    /// untested driver as passed nor clear a real `selfTestFailed`. true = written.
    @discardableResult
    public func record(_ report: DriverSelfTestReport) throws -> Bool {
        guard report.isConclusive, let v = report.version else { return false }
        try recordSelfTest(.init(version: v, passed: report.passed, failed: report.failed.map(\.rawValue)))
        return true
    }

    // MARK: state

    /// What an interrupted install leaves next to the bundle: `.TalkTalkAudio.driver.old` and
    /// `.TalkTalkAudio.driver.tmp-*` (root-owned; install-driver.sh removes them, ours only, at the
    /// start of every install and in uninstall). Every entry with such a name, ours or not.
    public func leftovers() -> [URL] {
        let dir = installedBundle.deletingLastPathComponent()
        let name = installedBundle.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0 == ".\(name).old" || $0.hasPrefix(".\(name).tmp-") }.sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// The leftovers install-driver.sh removes: ours by its `is_ours` rule. Anything else with a
    /// leftover name (another bundle, a half-copied tmp without Info.plist) the script leaves alone,
    /// so it must not make 完全卸载 ask for authorization again and again.
    public func removableLeftovers() -> [URL] { leftovers().filter(Self.isOurBundle) }

    /// install-driver.sh `is_ours`: a real directory (not a symlink) whose Contents/Info.plist names
    /// our bundle identifier.
    public static func isOurBundle(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return bundleIdentifier(of: url) == DriverIdentity.bundleIdentifier
    }

    static func bundleIdentifier(of bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    public func diskState() -> DiskState {
        var st = stat()
        guard lstat(installedBundle.path, &st) == 0 else { return .absent }
        if (st.st_mode & S_IFMT) == S_IFLNK { return .damaged("\(installedBundle.path) is a symlink") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return .damaged("\(installedBundle.path) is not a directory") }
        let plist = installedBundle.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .damaged("Info.plist unreadable") }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        guard id == DriverIdentity.bundleIdentifier else { return .foreign(id) }
        let exe = installedBundle.appendingPathComponent("Contents/MacOS/\(DriverIdentity.executableName)")
        guard access(exe.path, R_OK) == 0 else { return .damaged("Contents/MacOS/\(DriverIdentity.executableName) missing") }
        let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? ""
        return .present(version: version)
    }

    /// Problems with the loaded devices' fixed properties (§8.2), empty when they match.
    public static func deviceProblems(feed: DriverDeviceInfo, testMic: DriverDeviceInfo?) -> [String] {
        var p: [String] = []
        if !feed.isHidden { p.append("Feed is not hidden") }
        if feed.outputChannels != 2 { p.append("Feed has \(feed.outputChannels) output channels, expected 2") }
        if feed.inputChannels != 0 { p.append("Feed has \(feed.inputChannels) input channels") }
        if feed.sampleRate != DriverIdentity.sampleRate { p.append("Feed runs at \(feed.sampleRate) Hz") }
        if let t = testMic {
            if !t.isHidden { p.append("Test Mic is not hidden") }
            if t.inputChannels != 1 || t.outputChannels != 0 {
                p.append("Test Mic has \(t.inputChannels) in / \(t.outputChannels) out")
            }
        } else {
            p.append("Test Mic not found")
        }
        return p
    }

    public func check() -> (state: State, record: Record?) {
        let record = try? readRecord()
        let disk = diskState()
        let feed = hal.device(uid: DriverIdentity.feedUID)
        let loadedVersion = feed == nil ? nil : (hal.loadedVersion() ?? "")

        switch disk {
        case .foreign(let id):
            let name = installedBundle.lastPathComponent
            return (.damaged(reason: id.isEmpty ? String(appLocalized: "\(name) 属于其他软件")
                                                : String(appLocalized: "\(name) 属于 \(id)")), record)
        case .damaged(let why):
            return (.damaged(reason: why), record)
        case .absent:
            if loadedVersion != nil {
                return (.damaged(reason: String(appLocalized: "已从磁盘删除但仍在加载：请重启音频服务")), record)
            }
            return (.notInstalled, record)
        case .present(let diskVersion):
            guard let feed, let loaded = loadedVersion else { return (.onDiskNotLoaded(version: diskVersion), record) }
            if loaded != diskVersion { return (.onDiskNotLoaded(version: diskVersion), record) }
            let problems = Self.deviceProblems(feed: feed, testMic: hal.device(uid: DriverIdentity.testMicUID))
            if !problems.isEmpty { return (.damaged(reason: problems.joined(separator: "; ")), record) }
            if let bundled = bundledVersion, bundled != loaded {
                return (.outdated(installed: loaded, bundled: bundled), record)
            }
            if let t = record?.selfTest, t.version == loaded, !t.passed {
                return (.selfTestFailed(version: loaded, failed: t.failed), record)
            }
            return (.loaded(version: loaded), record)
        }
    }
}
