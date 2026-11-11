import Darwin
import Foundation

/// Private files and directories (ARCHITECTURE.md, "数据与隐私"): directories 0700, files 0600,
/// excluded from backup, written atomically, never through a symlink.
///
/// Permissions are set at creation (mkdir/open with the mode; the umask can only remove bits, and
/// an exact chmod/fchmod follows), so there is no window in which a file is readable by others.
/// The process umask is never changed (it is process-wide). Existing directories are tightened.
public enum FileSystem {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case posix(String, Int32)
        /// The path (or a directory we were asked to create) is a symlink: refused.
        case symlink(String)
        case notADirectory(String)

        public var description: String {
            switch self {
            case let .posix(op, e): "\(op): \(String(cString: strerror(e)))"
            case let .symlink(p): "refusing symlink: \(p)"
            case let .notADirectory(p): "not a directory: \(p)"
            }
        }
    }

    public static let directoryMode: mode_t = 0o700
    public static let fileMode: mode_t = 0o600

    /// Creates `url` and any missing parents with mode 0700, tightens an existing directory to
    /// 0700, and (by default) marks it excluded from backup. Parents that already exist are left
    /// as they are (`~/Library/...` belongs to the system).
    public static func ensurePrivateDirectory(_ url: URL, excludeFromBackup: Bool = true) throws {
        let path = url.standardizedFileURL.path
        var st = stat()
        if lstat(path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK { throw Failure.symlink(path) }
            if (st.st_mode & S_IFMT) != S_IFDIR { throw Failure.notADirectory(path) }
            if st.st_mode & 0o777 != directoryMode, chmod(path, directoryMode) != 0 { throw Failure.posix("chmod", errno) }
        } else {
            let parent = url.standardizedFileURL.deletingLastPathComponent()
            if parent.path != path, lstat(parent.path, &st) != 0 {
                try ensurePrivateDirectory(parent, excludeFromBackup: false)
            }
            if mkdir(path, directoryMode) != 0 {
                let e = errno
                if e != EEXIST { throw Failure.posix("mkdir", e) }
                return try ensurePrivateDirectory(url, excludeFromBackup: excludeFromBackup)
            }
            if chmod(path, directoryMode) != 0 { throw Failure.posix("chmod", errno) }
        }
        if excludeFromBackup { try setExcludedFromBackup(url) }
    }

    /// Writes `data` to `url` atomically: a 0600 temporary file in the same directory (O_EXCL,
    /// O_NOFOLLOW), fsync, then rename(2) over the target. Readers see the old or the new file,
    /// never a partial one. A symlink at `url` is refused rather than followed or replaced.
    public static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = fileMode) throws {
        let path = url.standardizedFileURL.path
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK { throw Failure.symlink(path) }
        let dir = url.standardizedFileURL.deletingLastPathComponent().path
        let tmp = dir + "/.\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        let fd = openPrivate(tmp, flags: O_WRONLY | O_CREAT | O_EXCL, mode: mode)
        guard fd >= 0 else { throw Failure.posix("open", errno) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(tmp) }
        }
        guard fchmod(fd, mode) == 0 else { throw Failure.posix("fchmod", errno) }
        try writeAll(fd, data)
        guard fsync(fd) == 0 else { throw Failure.posix("fsync", errno) }
        guard rename(tmp, path) == 0 else { throw Failure.posix("rename", errno) }
        ok = true
    }

    /// Opens (creating with 0600 if needed) a private file for appending. Refuses symlinks.
    public static func openForAppending(_ url: URL, mode: mode_t = fileMode) throws -> FileHandle {
        let path = url.standardizedFileURL.path
        let fd = openPrivate(path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: mode)
        guard fd >= 0 else {
            let e = errno
            throw e == ELOOP ? Failure.symlink(path) : Failure.posix("open", e)
        }
        if fchmod(fd, mode) != 0 { let e = errno; close(fd); throw Failure.posix("fchmod", e) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Sets (or clears) the backup exclusion of a file or directory.
    public static func setExcludedFromBackup(_ url: URL, _ excluded: Bool = true) throws {
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = excluded
        try u.setResourceValues(v)
    }

    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        var u = url
        u.removeAllCachedResourceValues()
        return (try? u.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }

    /// Permission bits (`st_mode & 0o777`) without following symlinks; nil when missing.
    public static func permissions(_ url: URL) -> mode_t? {
        var st = stat()
        guard lstat(url.standardizedFileURL.path, &st) == 0 else { return nil }
        return st.st_mode & 0o777
    }

    public static func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.standardizedFileURL.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - internals

    private static func openPrivate(_ path: String, flags: Int32, mode: mode_t) -> Int32 {
        open(path, flags | O_NOFOLLOW | O_CLOEXEC, mode)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.posix("write", errno)
                }
                off += n
            }
        }
    }
}
