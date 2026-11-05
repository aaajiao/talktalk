import Darwin
import Foundation

/// The engine's stderr log (`engine.log`, §7.6, §7.1): appended, 0600, rotated to `.1` at 5 MB.
/// The engine itself logs request ids, lengths and timings only, never text.
public enum ServerLog {
    public static let rotateBytes: Int64 = 5 * 1024 * 1024

    /// Rotates if needed and opens the file for appending. The caller owns (and closes) the fd.
    public static func openForAppend(_ url: URL, rotateAt: Int64 = rotateBytes) throws -> Int32 {
        try EnginePaths.ensurePrivateDirectory(url.deletingLastPathComponent())
        rotateIfNeeded(url, rotateAt: rotateAt)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }

    public static func rotateIfNeeded(_ url: URL, rotateAt: Int64 = rotateBytes) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size >= rotateAt else { return }
        let old = url.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }

    /// One app-side line (lifecycle events: start, READY, crash, restart). Never text or secrets.
    public static func note(_ url: URL, _ message: String) {
        guard let fd = try? openForAppend(url) else { return }
        defer { close(fd) }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "app: \(stamp) \(message)\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }
}
