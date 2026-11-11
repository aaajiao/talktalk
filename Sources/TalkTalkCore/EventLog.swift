import Foundation

/// Per-session latency events (ARCHITECTURE.md, "数据与隐私").
///
///     ~/Library/Logs/TalkTalk/sessions/<ISO>-<id>.jsonl     one JSON object per line
///     {"t": <host ns>, "ev": "listen.final", "sentence": 3, "chars": 41, ...}
///
/// Fields are numbers, booleans and short code-defined tags only: there is no string field for
/// free text, so transcripts, translations, keys, paths and device names cannot end up here
/// (text is logged by length, §12.1). Retention: the newest 20 sessions, none older than 14 days,
/// at most 200 MB in all (pruned when a session opens).
public final class EventLog: @unchecked Sendable {
    public enum Value: Sendable, Equatable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
        case int(Int)
        case double(Double)
        case bool(Bool)
        /// A code-defined identifier (trigger kind, backend name, reason). Never user content:
        /// limited to 64 ASCII characters `[A-Za-z0-9._:-]`, anything else is replaced by "?".
        case tag(String)

        public init(integerLiteral v: Int) { self = .int(v) }
        public init(floatLiteral v: Double) { self = .double(v) }
        public init(booleanLiteral v: Bool) { self = .bool(v) }

        var json: Any {
            switch self {
            case let .int(v): v
            case let .double(v): v.isFinite ? (v * 1000).rounded() / 1000 : 0
            case let .bool(v): v
            case let .tag(s): Self.sanitize(s)
            }
        }

        static func sanitize(_ s: String) -> String {
            let ok = s.count <= 64 && s.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0))
            }
            return ok ? s : "?"
        }
    }

    public static let maxSessions = 20
    public static let maxAgeDays = 14.0
    public static let maxTotalBytes = 200 * 1024 * 1024

    public let url: URL?
    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.eventlog", qos: .utility)
    private var handle: FileHandle?
    private var memory: [[String: Any]]?
    private let clock: @Sendable () -> HostTime

    /// A session log in `directory` (default `~/Library/Logs/TalkTalk/sessions`).
    public init(sessionID: String, directory: URL? = nil, clock: @escaping @Sendable () -> HostTime = HostClock.now) throws {
        let dir = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/TalkTalk/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Self.prune(dir)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = iso.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let file = dir.appendingPathComponent("\(stamp)-\(Value.sanitize(sessionID)).jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        url = file
        handle = try FileHandle(forWritingTo: file)
        self.clock = clock
    }

    /// In-memory log for tests.
    public init(inMemory clock: @escaping @Sendable () -> HostTime = HostClock.now) {
        url = nil
        memory = []
        self.clock = clock
    }

    deinit { try? handle?.close() }

    public func event(_ name: String, _ fields: [String: Value] = [:], at t: HostTime? = nil) {
        let time = t ?? clock()
        queue.async { [self] in
            var obj: [String: Any] = ["t": time, "ev": Value.sanitize(name)]
            for (k, v) in fields { obj[Value.sanitize(k)] = v.json }
            if memory != nil {
                memory!.append(obj)
                return
            }
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
            handle?.write(data + Data("\n".utf8))
        }
    }

    /// Waits for queued writes (tests, session end).
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    public func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    /// Events written to an in-memory log, in order.
    public var recorded: [[String: Any]] {
        queue.sync { memory ?? [] }
    }

    static func prune(_ dir: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let logs = files.filter { $0.pathExtension == "jsonl" }.map { url -> (URL, Date, Int) in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var total = 0
        for (i, (url, date, size)) in logs.enumerated() {
            total += size
            // Room for the session being opened: keep at most maxSessions - 1 old ones.
            if i >= maxSessions - 1 || now.timeIntervalSince(date) > maxAgeDays * 86400 || total > maxTotalBytes {
                try? fm.removeItem(at: url)
            }
        }
    }
}
