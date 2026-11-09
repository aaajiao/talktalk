import Foundation

/// The opt-in subtitle text trace only. Inactive instances create no files. The app uses its
/// serial utility queue for these short writes; the lock also makes close/append safe at teardown.
public final class SubtitleAnalysisTrace: @unchecked Sendable {
    public static let maxBytes = 8 * 1_024 * 1_024
    public static let maxRecords = 10_000
    public static let directoryPrefix = "subtitle-analysis-"
    public enum AppendResult: Sendable, Equatable { case ignored, written, limitReached }

    private let lock = NSLock()
    private let root: URL
    private let byteLimit: Int
    private let recordLimit: Int
    private var handle: FileHandle?
    private var enabledAt: HostTime = 0
    private var bytes = 0
    private var records = 0

    public init(root: URL, maxBytes: Int = SubtitleAnalysisTrace.maxBytes,
                maxRecords: Int = SubtitleAnalysisTrace.maxRecords) {
        self.root = root; byteLimit = max(0, maxBytes); recordLimit = max(0, maxRecords)
    }

    deinit { try? handle?.close() }

    /// Starts a new, private run under diagnostics/, which already has a 24-hour retention rule.
    public func start(at now: HostTime) throws -> URL {
        try lock.withLock {
            try handle?.close(); handle = nil
            try FileSystem.ensurePrivateDirectory(root)
            let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let directory = root.appendingPathComponent("\(Self.directoryPrefix)\(date)-\(UUID().uuidString)", isDirectory: true)
            try FileSystem.ensurePrivateDirectory(directory)
            let url = directory.appendingPathComponent("trace.jsonl")
            handle = try FileSystem.openForAppending(url)
            enabledAt = now; bytes = 0; records = 0
            return url
        }
    }

    /// `line` is one encoded JSON object without a trailing newline. Events captured before the
    /// explicit start are rejected even if their main-actor delivery was delayed until afterward.
    @discardableResult public func append(_ line: Data, at time: HostTime) throws -> AppendResult {
        try lock.withLock {
            guard let handle, time >= enabledAt else { return .ignored }
            guard records < recordLimit, line.count < byteLimit - bytes else {
                try handle.close(); self.handle = nil
                return .limitReached
            }
            var row = line; row.append(0x0a)
            do { try handle.write(contentsOf: row) }
            catch { try? handle.close(); self.handle = nil; throw error }
            bytes += row.count; records += 1
            return .written
        }
    }

    public func stop() {
        lock.withLock { try? handle?.close(); handle = nil }
    }
}
