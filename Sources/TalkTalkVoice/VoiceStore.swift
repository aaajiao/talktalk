import Darwin
import Foundation

/// The one "my voice" profile on disk (ARCHITECTURE.md §9.2 steps 6 and 8, §9.3, §9.4, §9.5).
///
///     ~/Library/Application Support/TalkTalk/
///       voice/                       0700, excluded from backup, contains .metadata_never_index
///         reference.wav  script.txt  profile.json   0600
///         conditioning/<key>.safetensors            0600 (built by the engine at warm-up)
///       .voice-staging-<uuid>/       same attributes from the moment it is created
///
/// Dev and release builds share this directory (§7, §9.3), so a profile recorded with
/// `TalkTalk-Dev.app --bench enroll` is the one the finished app uses.
///
/// Only the app writes here; the engine gets bytes, never paths. Deletion removes only file
/// names this type creates. Nothing here logs content or paths.
public struct VoiceStore: Sendable {
    public static let referenceName = "reference.wav"
    public static let scriptName = "script.txt"
    public static let profileName = "profile.json"
    public static let neverIndexName = ".metadata_never_index"
    public static let conditioningName = "conditioning"
    static let stagingPrefix = ".voice-staging-"
    static let profileTempName = "profile.json.tmp"
    static let knownFiles = [referenceName, scriptName, profileName, neverIndexName, profileTempName,
                             "reference-en.wav", "script-en.txt"]

    /// `~/Library/Application Support/TalkTalk` (or a test directory).
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The shared product location used by both TalkTalk.app and TalkTalk-Dev.app.
    public static var product: VoiceStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VoiceStore(root: base.appendingPathComponent("TalkTalk", isDirectory: true))
    }

    public var voiceURL: URL { root.appendingPathComponent("voice", isDirectory: true) }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case posix(String, Int32)
        case notStaging
        case incomplete(String)
        /// The saved profile is not the one the caller started from (re-recorded or deleted).
        case profileChanged

        public var description: String {
            switch self {
            case .profileChanged: "the saved profile changed meanwhile"
            case let .posix(op, code): "\(op): \(String(cString: strerror(code)))"
            case .notStaging: "not a staging directory of this store"
            case let .incomplete(name): "staging is missing \(name)"
            }
        }
    }

    // MARK: - staging (§9.2 step 6)

    /// Creates `.voice-staging-<uuid>/` with 0700, the backup exclusion and the never-index marker.
    public func makeStaging() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        guard mkdir(url.path, 0o700) == 0 else { throw Failure.posix("mkdir", errno) }
        try PrivateFiles.protectDirectory(url)
        return url
    }

    public func writeReference(_ wav: Data, script: EnrollmentScript, profile: VoiceProfile, into staging: URL) throws {
        try checkStaging(staging)
        try PrivateFiles.write(wav, to: staging.appendingPathComponent(Self.referenceName))
        try PrivateFiles.write(Data(script.text.utf8), to: staging.appendingPathComponent(Self.scriptName))
        try PrivateFiles.write(profile.encoded(), to: staging.appendingPathComponent(Self.profileName))
    }

    /// Stores one conditioning blob returned by `/v1/voice/build` (§9.2 step 6). `key` is the
    /// cache key of §9.3; anything outside [A-Za-z0-9._@-] is replaced so it stays one file name.
    public func writeConditioning(_ blob: Data, key: String, into dir: URL) throws {
        let cond = dir.appendingPathComponent(Self.conditioningName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: cond.path) {
            guard mkdir(cond.path, 0o700) == 0 else { throw Failure.posix("mkdir", errno) }
        }
        try PrivateFiles.write(blob, to: cond.appendingPathComponent(Self.safeKey(key) + ".safetensors"))
    }

    static func safeKey(_ key: String) -> String {
        String(key.map { c in
            c.isASCII && (c.isLetter || c.isNumber || "._@-".contains(c)) ? c : "_"
        })
    }

    /// Leaving without saving (§9.2 step 8): the staging directory is removed.
    public func discard(_ staging: URL) {
        guard (try? checkStaging(staging)) != nil else { return }
        removeOwned(staging)
    }

    // MARK: - save (§9.2 step 8)

    /// Makes the staging directory the profile. With no profile yet: `rename`. With one:
    /// `renamex_np(RENAME_SWAP)`, then the swapped-out old profile (now at the staging path) is
    /// deleted. The old profile stays valid until the swap succeeds.
    public func commit(_ staging: URL) throws {
        try checkStaging(staging)
        for name in [Self.referenceName, Self.scriptName, Self.profileName, Self.neverIndexName]
        where !FileManager.default.fileExists(atPath: staging.appendingPathComponent(name).path) {
            throw Failure.incomplete(name)
        }
        let voice = voiceURL
        if FileManager.default.fileExists(atPath: voice.path) {
            guard renamex_np(staging.path, voice.path, UInt32(RENAME_SWAP)) == 0 else {
                throw Failure.posix("renamex_np(RENAME_SWAP)", errno)
            }
            removeOwned(staging)   // the old profile
        } else {
            guard rename(staging.path, voice.path) == 0 else { throw Failure.posix("rename", errno) }
        }
        try PrivateFiles.protectDirectory(voice)   // re-assert; rename keeps them, this is belt and braces
    }

    // MARK: - read / delete (§9.4)

    public var hasProfile: Bool {
        FileManager.default.fileExists(atPath: voiceURL.appendingPathComponent(Self.profileName).path)
    }

    public func loadProfile() throws -> VoiceProfile {
        try VoiceProfile.decode(Data(contentsOf: voiceURL.appendingPathComponent(Self.profileName)))
    }

    /// Saved reference text is authoritative, including edited excerpts of an enrollment script.
    public func loadScript(_ profile: VoiceProfile) throws -> String {
        let script = try String(contentsOf: voiceURL.appendingPathComponent(Self.scriptName), encoding: .utf8)
        guard sha256Hex(Data(script.utf8)) == profile.scriptSHA256 else {
            throw Failure.incomplete("script.txt hash mismatch")
        }
        return script
    }

    /// Rewrites profile.json of the saved profile (a re-check after the engine got ready, §9.2):
    /// written 0600 under a temporary name in `voice/`, then renamed over the old one.
    public func replaceProfile(_ profile: VoiceProfile) throws {
        let tmp = voiceURL.appendingPathComponent(Self.profileTempName)
        try PrivateFiles.write(profile.encoded(), to: tmp)
        guard rename(tmp.path, voiceURL.appendingPathComponent(Self.profileName).path) == 0 else {
            let e = errno
            unlink(tmp.path)
            throw Failure.posix("rename", e)
        }
    }

    /// `replaceProfile` only if the saved profile is still `expecting` (same id and wav hash);
    /// otherwise `profileChanged` and nothing is written.
    public func replaceProfile(_ profile: VoiceProfile, expecting: VoiceProfile.Identity) throws {
        try checkStill(expecting)
        try replaceProfile(profile)
    }

    /// Throws `profileChanged` unless the saved profile is `expecting`.
    public func checkStill(_ expecting: VoiceProfile.Identity) throws {
        guard let now = try? loadProfile(), now.identity == expecting else { throw Failure.profileChanged }
    }

    /// Writes rebuilt conditioning into `voice/conditioning/` for the saved profile `expecting`,
    /// then removes stale blobs except the explicitly retained caches of other TTS models.
    public func replaceSavedConditioning(_ blobs: [ConditioningBlob], expecting: VoiceProfile.Identity,
                                         retainingKeys: Set<String> = []) throws {
        try checkStill(expecting)
        for b in blobs { try writeConditioning(b.data, key: b.key, into: voiceURL) }
        let keep = Set((blobs.map(\.key) + Array(retainingKeys)).map { Self.safeKey($0) + ".safetensors" })
        let cond = voiceURL.appendingPathComponent(Self.conditioningName, isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: cond.path)) ?? []
        where name.hasSuffix(".safetensors") && !keep.contains(name) {
            unlink(cond.appendingPathComponent(name).path)
        }
    }

    /// The saved profile's conditioning blobs (bytes for `/v1/voice/load`), in profile order.
    /// Entries whose file is missing are skipped; the engine rebuilds them at warm-up (§9.3).
    public func loadConditioning(_ profile: VoiceProfile) -> [ConditioningBlob] {
        let cond = voiceURL.appendingPathComponent(Self.conditioningName, isDirectory: true)
        return ((profile.conditioningEntries ?? []) + (profile.archivedConditioningEntries ?? [])).compactMap { e in
            guard let d = try? Data(contentsOf: cond.appendingPathComponent(Self.safeKey(e.key) + ".safetensors")) else { return nil }
            return ConditioningBlob(key: e.key, data: d, model: e.model, mode: e.mode, samplingKey: profile.samplingKey)
        }
    }

    /// Deletes the profile's files (only names we create). The caller then tells the engine
    /// `/v1/voice/unload` and SPEAK falls back to the system voice (C8).
    public func deleteProfile() {
        removeOwned(voiceURL)
    }

    /// Removes staging directories left by a crash. Call at app start.
    public func removeStaleStaging() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(Self.stagingPrefix) {
            removeOwned(root.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: - helpers

    private func checkStaging(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              url.lastPathComponent.hasPrefix(Self.stagingPrefix) else { throw Failure.notStaging }
    }

    /// Deletes the file names this store creates, the conditioning blobs, then the directory
    /// if it is empty. Unknown files are left alone (and so is the directory).
    private func removeOwned(_ dir: URL) {
        let fm = FileManager.default
        for name in Self.knownFiles { unlink(dir.appendingPathComponent(name).path) }
        let cond = dir.appendingPathComponent(Self.conditioningName, isDirectory: true)
        if let blobs = try? fm.contentsOfDirectory(atPath: cond.path) {
            for b in blobs where b.hasSuffix(".safetensors") { unlink(cond.appendingPathComponent(b).path) }
            rmdir(cond.path)
        }
        rmdir(dir.path)
    }
}

/// Private on-disk storage for personal audio (§9.3, §12.1): directories 0700, excluded from
/// Time Machine, never indexed by Spotlight; files created 0600. Used by VoiceStore and by the
/// dev-only bench recorder.
public enum PrivateFiles {
    /// Creates `url` (and missing parents) and protects it. Existing parents are not changed.
    public static func makeDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw VoiceStore.Failure.posix("mkdir", errno) }
        }
        try protectDirectory(url)
    }

    /// 0700, excluded from backup, `.metadata_never_index` inside.
    public static func protectDirectory(_ url: URL) throws {
        guard chmod(url.path, 0o700) == 0 else { throw VoiceStore.Failure.posix("chmod", errno) }
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try u.setResourceValues(values)
        let marker = url.appendingPathComponent(VoiceStore.neverIndexName)
        if !FileManager.default.fileExists(atPath: marker.path) {
            try write(Data(), to: marker)
        }
    }

    /// Writes with O_CREAT|O_TRUNC and mode 0600 from the start (no window with wider permissions).
    public static func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VoiceStore.Failure.posix("open", errno) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw VoiceStore.Failure.posix("fchmod", errno) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw VoiceStore.Failure.posix("write", errno)
                }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw VoiceStore.Failure.posix("fsync", errno) }
    }
}
