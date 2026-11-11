import Foundation

/// How long local data is kept (ARCHITECTURE.md, "数据与隐私"):
///
/// | what | where | rule |
/// |---|---|---|
/// | diagnostic recordings | `Application Support/TalkTalk/diagnostics/<session>/` | 24 h |
/// | transcripts (§16 decision 7) | `Application Support/TalkTalk/transcripts/<id>.jsonl` | 30 days |
/// | latency events | `Logs/TalkTalk/sessions/*.jsonl` | newest 20, ≤ 14 days, ≤ 200 MB in all |
///
/// Pure rule (`expired(_:now:)`) plus a sweep over one directory and a scheduler that sweeps at
/// launch and then on a timer. Time always comes from the caller, so tests run on a fake clock.
/// Age is measured from the newest modification inside an entry, so a diagnostics session that
/// is still being written is never "24 h old".
public struct RetentionPolicy: Sendable, Equatable {
    public var maxAge: TimeInterval?
    public var maxCount: Int?
    public var maxTotalBytes: Int?
    /// Which directory entries the rule owns; anything else in the directory is left alone.
    public var selects: Selection

    public enum Selection: Sendable, Equatable {
        /// Every file and directory (diagnostics/ belongs to the rule as a whole).
        case all
        /// Regular files with this extension (e.g. "jsonl").
        case files(extension: String)
    }

    public init(maxAge: TimeInterval? = nil, maxCount: Int? = nil, maxTotalBytes: Int? = nil, selects: Selection = .all) {
        self.maxAge = maxAge; self.maxCount = maxCount; self.maxTotalBytes = maxTotalBytes; self.selects = selects
    }

    public static let diagnostics = RetentionPolicy(maxAge: 24 * 3600, selects: .all)
    public static let transcripts = RetentionPolicy(maxAge: 30 * 86400, selects: .files(extension: "jsonl"))
    /// Same limits as `EventLog` (which also prunes when a session opens).
    public static let events = RetentionPolicy(maxAge: EventLog.maxAgeDays * 86400, maxCount: EventLog.maxSessions,
                                               maxTotalBytes: EventLog.maxTotalBytes, selects: .files(extension: "jsonl"))

    public struct Entry: Sendable, Equatable {
        public var url: URL
        public var modified: Date
        public var bytes: Int
        public init(url: URL, modified: Date, bytes: Int) { self.url = url; self.modified = modified; self.bytes = bytes }
    }

    /// The entries to delete. Newest first: an entry is kept while it is younger than `maxAge`,
    /// among the newest `maxCount` kept, and the kept total including it stays ≤ `maxTotalBytes`
    /// (an entry too large to fit goes; a smaller older one may still fit).
    /// Entries dated in the future (clock changes) count as age 0.
    public func expired(_ entries: [Entry], now: Date) -> [Entry] {
        let sorted = entries.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.url.path < $1.url.path }
        var total = 0, kept = 0
        var out: [Entry] = []
        for e in sorted {
            let age = max(0, now.timeIntervalSince(e.modified))
            if let a = maxAge, age > a { out.append(e); continue }
            if let c = maxCount, kept >= c { out.append(e); continue }
            if let b = maxTotalBytes, total + e.bytes > b { out.append(e); continue }
            total += e.bytes
            kept += 1
        }
        return out
    }

    /// Lists the entries of `directory` this rule owns (no symlink is followed: a link is an entry
    /// of its own, dated and sized as the link).
    public func entries(in directory: URL) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [Entry] = []
        for name in names.sorted() {
            let url = directory.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            let kind = st.st_mode & S_IFMT
            switch selects {
            case .all: break
            case let .files(ext):
                guard kind == S_IFREG, url.pathExtension == ext else { continue }
            }
            let (date, bytes) = kind == S_IFDIR ? Self.treeStats(url) : (Self.mtime(st), Int(st.st_size))
            out.append(Entry(url: url, modified: date, bytes: bytes))
        }
        return out
    }

    /// Deletes what `expired` selects in `directory`; returns the removed entries. A missing
    /// directory is not an error.
    @discardableResult
    public func sweep(_ directory: URL, now: Date) -> [Entry] {
        let gone = expired(entries(in: directory), now: now)
        var removed: [Entry] = []
        for e in gone where (try? FileManager.default.removeItem(at: e.url)) != nil { removed.append(e) }
        return removed
    }

    static func mtime(_ st: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Newest modification and total size of a directory tree (symlinks not followed).
    static func treeStats(_ dir: URL) -> (Date, Int) {
        var st = stat()
        var newest = lstat(dir.path, &st) == 0 ? mtime(st) : .distantPast
        var bytes = 0
        if let en = FileManager.default.enumerator(atPath: dir.path) {
            while let rel = en.nextObject() as? String {
                guard lstat(dir.appendingPathComponent(rel).path, &st) == 0 else { continue }
                newest = max(newest, mtime(st))
                if (st.st_mode & S_IFMT) == S_IFREG { bytes += Int(st.st_size) }
            }
        }
        return (newest, bytes)
    }
}

/// Runs a set of retention rules at launch and then every `interval` (default 1 h).
/// The timer and the clock are injected; `RetentionScheduler.dispatchTimer` is the real timer.
public final class RetentionScheduler: @unchecked Sendable {
    public struct Target: Sendable, Equatable {
        public var directory: URL
        public var policy: RetentionPolicy
        public init(_ directory: URL, _ policy: RetentionPolicy) { self.directory = directory; self.policy = policy }
    }

    /// `schedule(interval, fire)` starts a repeating timer and returns a cancel function.
    public typealias Timer = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> (@Sendable () -> Void)

    public let targets: [Target]
    public let interval: TimeInterval
    private let clock: @Sendable () -> Date
    private let timer: Timer
    private let onSweep: (@Sendable ([RetentionPolicy.Entry]) -> Void)?
    private let lock = NSLock()
    private var cancel: (@Sendable () -> Void)?

    public init(targets: [Target], interval: TimeInterval = 3600, clock: @escaping @Sendable () -> Date = { Date() },
                timer: @escaping Timer = RetentionScheduler.dispatchTimer,
                onSweep: (@Sendable ([RetentionPolicy.Entry]) -> Void)? = nil) {
        self.targets = targets; self.interval = interval; self.clock = clock; self.timer = timer; self.onSweep = onSweep
    }

    /// The standard targets under `home` (Application Support/TalkTalk) and `logs` (Logs/TalkTalk).
    public static func standardTargets(home: URL, logs: URL) -> [Target] {
        [Target(home.appendingPathComponent("diagnostics", isDirectory: true), .diagnostics),
         Target(home.appendingPathComponent("transcripts", isDirectory: true), .transcripts),
         Target(logs.appendingPathComponent("sessions", isDirectory: true), .events)]
    }

    deinit { stop() }

    /// Sweeps once now (launch), then on every timer tick. Calling it again restarts the timer.
    @discardableResult
    public func start() -> [RetentionPolicy.Entry] {
        stop()
        let removed = sweepNow()
        let c = timer(interval) { [weak self] in _ = self?.sweepNow() }
        lock.lock(); cancel = c; lock.unlock()
        return removed
    }

    public func stop() {
        lock.lock(); let c = cancel; cancel = nil; lock.unlock()
        c?()
    }

    @discardableResult
    public func sweepNow() -> [RetentionPolicy.Entry] {
        let now = clock()
        let removed = targets.flatMap { $0.policy.sweep($0.directory, now: now) }
        onSweep?(removed)
        return removed
    }

    public static let dispatchTimer: Timer = { interval, fire in
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(60))
        t.setEventHandler(handler: fire)
        t.resume()
        let box = TimerBox(t)
        return { box.cancel() }
    }

    private final class TimerBox: @unchecked Sendable {
        let t: DispatchSourceTimer
        init(_ t: DispatchSourceTimer) { self.t = t }
        func cancel() { t.cancel() }
    }
}
