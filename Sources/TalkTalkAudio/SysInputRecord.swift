// l10n: zh-Hans (scripts/check-strings.sh)
import Darwin
import Foundation
import TalkTalkCore

/// Where the restore record and its lock live (ARCHITECTURE.md, "实时音频与生命周期约束"). TalkTalk.app and
/// TalkTalk-Dev.app share one record on purpose: the guard, the other build and the uninstaller
/// all read it. So the path does not depend on the build flavor.
public struct SysInputPaths: Sendable, Equatable {
    public let directory: URL
    public var record: URL { directory.appendingPathComponent("sysinput-restore.json") }
    public var lock: URL { directory.appendingPathComponent("sysinput-restore.lock") }

    public init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/TalkTalk/`, the same for every flavor.
    public static func standard() -> SysInputPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SysInputPaths(directory: base.appendingPathComponent("TalkTalk", isDirectory: true))
    }

    func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
}

/// `sysinput-restore.json` (§8.6): the original device, when we switched, which build wrote it,
/// and the guard's PID. No UserDefaults: the guard, the other build and the uninstaller read it.
public struct SysInputRecord: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public var version: Int
    /// The device to restore (§8.6 entry step 2).
    public var original: SystemInputPlan.DeviceRef
    /// Wall-clock time of the switch (diagnostics only; decisions use the monotonic clock).
    public var switchedAt: Date
    /// Bundle id of the build that wrote it (`com.aaajiao.talktalk[.dev]`, or "bare").
    public var writerBundleID: String
    public var writerPID: Int32
    /// The writer's executable (resolved). Layer 4 only signals a PID whose executable is this path.
    public var executablePath: String
    public var guardPID: Int32?
    /// Bundle ids of the meeting apps of the session ("通话结束" scope; empty = all known).
    public var meetingApps: [String]
    /// TalkTalk Mic vanished and macOS picked this UID (so the guard / next launch may restore over it).
    public var replacementUID: String?
    /// Set by a launch that took the record over (§8.6 layer 4): the virtual device that was the
    /// default then. The guard it hands to applies the same rule. Absent in older records.
    public var layer4UID: String?
    /// The takeover saw no default input: until this time the first default that appears becomes
    /// `layer4UID`, in the guard too. Seconds of CLOCK_UPTIME_RAW (`HostClock`), the same in every
    /// process during one boot and unaffected by wall-clock changes; valid only with the same
    /// `bootSessionUUID` (review 2026-11-05 #1).
    public var layer4ArmedUntilUptime: Double?
    /// `kern.bootsessionuuid` when `layer4ArmedUntilUptime` was written.
    public var bootSessionUUID: String?
    /// You chose "现在还原" (menu, dialog, or when quitting) and the write failed: the app, the
    /// guard and a layer-4 takeover keep retrying the restore without waiting for the call, and
    /// never switch back to TalkTalk Mic (review of a7ef015 #5, review of 37c505d #2). Entering
    /// meeting mode or a new end decision clears it. Absent in older records.
    public var restoreNow: Bool?

    public init(original: SystemInputPlan.DeviceRef, switchedAt: Date = Date(), writerBundleID: String,
                writerPID: Int32 = getpid(), executablePath: String, guardPID: Int32? = nil,
                meetingApps: [String] = [], replacementUID: String? = nil, layer4UID: String? = nil) {
        self.version = Self.currentVersion
        self.original = original
        // Whole seconds: the file stores ISO 8601 without fractions, so a record read back
        // compares equal to the one written.
        self.switchedAt = Date(timeIntervalSince1970: switchedAt.timeIntervalSince1970.rounded(.down))
        self.writerBundleID = writerBundleID
        self.writerPID = writerPID
        self.executablePath = executablePath
        self.guardPID = guardPID
        self.meetingApps = meetingApps
        self.replacementUID = replacementUID
        self.layer4UID = layer4UID
    }

    /// Used when the file exists but cannot be decoded: nothing is known about the original, so
    /// the restore order (built-in first) applies.
    public static func unreadable(writerBundleID: String = "unknown") -> SysInputRecord {
        SysInputRecord(original: .init(uid: "", name: String(appLocalized: "（记录无法读取）"), transport: "????"),
                       switchedAt: Date(timeIntervalSince1970: 0), writerBundleID: writerBundleID,
                       writerPID: 0, executablePath: "")
    }
}

/// Reads and writes the record: mode 0600, written to a temp file in the same directory,
/// fsync'd, renamed over the record, then the directory fsync'd (so a crash right after the
/// switch never leaves a half record or none).
public struct SysInputRecordStore: Sendable {
    public enum StoreError: Error, Equatable {
        case io(String, Int32)
    }

    public let paths: SysInputPaths
    /// Test hook: called with the path of every file descriptor fsync'd (temp file, then directory).
    public var onFsync: (@Sendable (String) -> Void)?

    public init(paths: SysInputPaths, onFsync: (@Sendable (String) -> Void)? = nil) {
        self.paths = paths
        self.onFsync = onFsync
    }

    public var exists: Bool { access(paths.record.path, F_OK) == 0 }

    /// nil = no record. A file that does not decode is `SysInputRecord.unreadable()`.
    public func read() -> SysInputRecord? {
        guard let data = FileManager.default.contents(atPath: paths.record.path) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(SysInputRecord.self, from: data)) ?? .unreadable()
    }

    public func write(_ record: SysInputRecord) throws {
        try paths.ensureDirectory()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(record)
        let tmp = paths.directory.appendingPathComponent(".sysinput-restore.json.\(getpid()).tmp").path
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StoreError.io("open tmp", errno) }
        var ok = fchmod(fd, 0o600) == 0
        ok = ok && data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        if ok { ok = fsync(fd) == 0; if ok { onFsync?(tmp) } }
        let err = errno
        close(fd)
        guard ok else { unlink(tmp); throw StoreError.io("write tmp", err) }
        guard rename(tmp, paths.record.path) == 0 else {
            let e = errno
            unlink(tmp)
            throw StoreError.io("rename", e)
        }
        let dfd = open(paths.directory.path, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 {
            if fsync(dfd) == 0 { onFsync?(paths.directory.path) }
            close(dfd)
        }
    }

    public func delete() {
        unlink(paths.record.path)
        let dfd = open(paths.directory.path, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 { fsync(dfd); close(dfd) }
    }
}

/// `flock(LOCK_EX)` on `sysinput-restore.lock` (§8.6 "记录归谁"): whoever holds it owns the record.
/// The descriptor is `O_CLOEXEC` (the engine and every other child inherit nothing); only the
/// guard gets it, through `posix_spawn_file_actions_addinherit_np` (M0-T8 d6: `adddup2(fd, fd)`
/// does not clear `FD_CLOEXEC` on macOS). flock locks belong to the open file description, so
/// the guard keeps holding it after the app crashes or is `kill -9`'d; when both are gone the
/// kernel drops it.
public final class SysInputLock: @unchecked Sendable {
    public let path: String
    public private(set) var fd: Int32 = -1

    public init(path: String) { self.path = path }

    /// Adopts an inherited descriptor (the guard). Call `verifyInherited` first.
    public init(path: String, inheritedFD: Int32) {
        self.path = path
        self.fd = inheritedFD
    }

    deinit { if fd >= 0 { close(fd) } }

    public var isHeld: Bool { fd >= 0 }

    /// Non-blocking; retries for up to `timeout` seconds.
    @discardableResult
    public func tryAcquire(timeout: Double = 0) -> Bool {
        if fd >= 0 { return true }
        let dir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let f = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard f >= 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(f, LOCK_EX | LOCK_NB) == 0 {
                fd = f
                return true
            }
            if Date() >= deadline { break }
            usleep(20_000)
        }
        close(f)
        return false
    }

    /// Unlocks (for every holder of this open file description, the guard included) and closes.
    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// Closes our descriptor without unlocking: the guard, which shares the open file
    /// description, keeps the lock (hand-off on quit).
    public func detach() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    /// Whether nobody holds the lock right now (opens a separate description, tries, gives it back).
    public static func isAvailable(path: String) -> Bool {
        let f = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard f >= 0 else { return false }
        defer { close(f) }
        guard flock(f, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(f, LOCK_UN)
        return true
    }

    /// The guard's check of its inherited descriptor: open, a regular file, the same file as
    /// `path`, and we hold the lock on it (re-locking our own description succeeds; a
    /// description that someone else holds the lock on fails).
    public static func verifyInherited(fd: Int32, path: String) -> Bool {
        guard fd > 2 else { return false }
        var a = stat(), b = stat()
        guard fstat(fd, &a) == 0, (a.st_mode & S_IFMT) == S_IFREG else { return false }
        guard lstat(path, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino else { return false }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    public static func hasCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC) != 0
    }
}
