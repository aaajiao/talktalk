import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600, day: TimeInterval = 86400
private let mb = 1024 * 1024

private func entry(_ name: String, age: TimeInterval, bytes: Int = 1) -> RetentionPolicy.Entry {
    .init(url: URL(fileURLWithPath: "/x/\(name)"), modified: t0.addingTimeInterval(-age), bytes: bytes)
}

private func names(_ es: [RetentionPolicy.Entry]) -> [String] { es.map(\.url.lastPathComponent).sorted() }

/// Sets the modification time of a path (no symlink following for links).
private func setMTime(_ url: URL, _ date: Date) throws {
    var tv = [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0),
              timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
    struct UTimesFailed: Error {}
    guard lutimes(url.path, &tv) == 0 else { throw UTimesFailed() }
}

@Suite struct RetentionRuleTests {
    @Test func diagnosticsLastExactly24Hours() {
        let p = RetentionPolicy.diagnostics
        let es = [entry("fresh", age: 1), entry("edge", age: 24 * hour), entry("old", age: 24 * hour + 1)]
        #expect(names(p.expired(es, now: t0)) == ["old"])
    }

    @Test func transcriptsLast30Days() {
        let p = RetentionPolicy.transcripts
        let es = [entry("a", age: 29 * day), entry("b", age: 30 * day), entry("c", age: 30 * day + 60)]
        #expect(names(p.expired(es, now: t0)) == ["c"])
    }

    @Test func eventsKeepTheNewest20() {
        let p = RetentionPolicy.events
        #expect(p.maxCount == 20 && p.maxCount == EventLog.maxSessions)
        let es = (0..<25).map { entry(String(format: "s%02d", $0), age: TimeInterval($0) * 60) }
        #expect(names(p.expired(es, now: t0)) == ["s20", "s21", "s22", "s23", "s24"])
    }

    @Test func eventsExpireAfter14Days() {
        let p = RetentionPolicy.events
        let es = [entry("new", age: hour), entry("edge", age: 14 * day), entry("old", age: 14 * day + 1)]
        #expect(names(p.expired(es, now: t0)) == ["old"])
    }

    @Test func eventsStayUnder200MB() {
        let p = RetentionPolicy.events
        #expect(p.maxTotalBytes == 200 * mb)
        // newest first: 150 kept, 100 would make 250 → goes, 40 fits (190), 20 would make 210 → goes
        let es = [entry("a", age: 1, bytes: 150 * mb), entry("b", age: 2, bytes: 100 * mb),
                  entry("c", age: 3, bytes: 40 * mb), entry("d", age: 4, bytes: 20 * mb)]
        #expect(names(p.expired(es, now: t0)) == ["b", "d"])
    }

    @Test func countAndAgeAndSizeTogether() {
        let p = RetentionPolicy(maxAge: 10 * day, maxCount: 2, maxTotalBytes: 100)
        let es = [entry("a", age: 1, bytes: 60), entry("b", age: 2, bytes: 60), entry("c", age: 3, bytes: 30),
                  entry("d", age: 11 * day, bytes: 1)]
        // a kept; b too big; c kept (count 2); d too old
        #expect(names(p.expired(es, now: t0)) == ["b", "d"])
    }

    @Test func futureDatesCountAsNew() {
        #expect(RetentionPolicy.diagnostics.expired([entry("future", age: -5 * day)], now: t0).isEmpty)
    }
}

@Suite(.temporaryFiles) struct RetentionSweepTests {
    @Test func sweepsDiagnosticsSessionsByNewestInnerFile() throws {
        let dir = try makeScratchDir("ret")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let old = dir.appendingPathComponent("s-old"), live = dir.appendingPathComponent("s-live")
        for d in [old, live] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(count: 10).write(to: old.appendingPathComponent("mic.caf"))
        try Data(count: 20).write(to: live.appendingPathComponent("mic.caf"))
        try Data(count: 5).write(to: live.appendingPathComponent("tts.caf"))
        try setMTime(old.appendingPathComponent("mic.caf"), t0.addingTimeInterval(-25 * hour))
        try setMTime(old, t0.addingTimeInterval(-25 * hour))
        try setMTime(live.appendingPathComponent("mic.caf"), t0.addingTimeInterval(-30 * hour))
        try setMTime(live.appendingPathComponent("tts.caf"), t0.addingTimeInterval(-hour))   // still being written
        try setMTime(live, t0.addingTimeInterval(-30 * hour))
        let es = RetentionPolicy.diagnostics.entries(in: dir)
        #expect(es.first { $0.url.lastPathComponent == "s-live" }?.bytes == 25)
        let removed = RetentionPolicy.diagnostics.sweep(dir, now: t0)
        #expect(names(removed) == ["s-old"])
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: live.appendingPathComponent("mic.caf").path))
    }

    @Test func fileRulesTouchOnlyTheirExtension() throws {
        let dir = try makeScratchDir("ret")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jsonl"), keep = dir.appendingPathComponent("notes.txt")
        let sub = dir.appendingPathComponent("sub.jsonl")
        try Data("x".utf8).write(to: a)
        try Data("y".utf8).write(to: keep)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        for u in [a, keep, sub] { try setMTime(u, t0.addingTimeInterval(-31 * day)) }
        #expect(names(RetentionPolicy.transcripts.sweep(dir, now: t0)) == ["a.jsonl"])
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(FileManager.default.fileExists(atPath: sub.path))
    }

    @Test func aSymlinkEntryIsRemovedWithoutTouchingItsTarget() throws {
        let dir = try makeScratchDir("ret")
        let outside = try makeScratchDir("ret-outside")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("precious.wav")
        try Data(count: 3).write(to: target)
        let link = dir.appendingPathComponent("s1")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try setMTime(link, t0.addingTimeInterval(-2 * day))
        #expect(names(RetentionPolicy.diagnostics.sweep(dir, now: t0)) == ["s1"])
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func missingDirectoryIsFine() {
        let gone = URL(fileURLWithPath: "/nonexistent/tt-\(UUID().uuidString)")
        #expect(RetentionPolicy.events.sweep(gone, now: t0).isEmpty)
    }
}

@Suite(.temporaryFiles) struct RetentionSchedulerTests {
    final class FakeTimer: @unchecked Sendable {
        var interval: TimeInterval?
        var fire: (@Sendable () -> Void)?
        var cancelled = 0
        var timer: RetentionScheduler.Timer {
            { [self] i, f in interval = i; fire = f; return { [self] in cancelled += 1 } }
        }
    }

    final class FakeClock: @unchecked Sendable {
        var now: Date
        init(_ d: Date) { now = d }
    }

    @Test func sweepsAtLaunchAndOnEveryTick() throws {
        let home = try makeScratchDir("sched-home"), logs = try makeScratchDir("sched-logs")
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: logs) }
        let targets = RetentionScheduler.standardTargets(home: home, logs: logs)
        #expect(targets.map { $0.directory.lastPathComponent } == ["diagnostics", "transcripts", "sessions"])
        for t in targets { try FileManager.default.createDirectory(at: t.directory, withIntermediateDirectories: true) }
        let diag = targets[0].directory
        let s1 = diag.appendingPathComponent("s1")
        try FileManager.default.createDirectory(at: s1, withIntermediateDirectories: false)
        try setMTime(s1, t0.addingTimeInterval(-25 * hour))
        let s2 = diag.appendingPathComponent("s2")
        try FileManager.default.createDirectory(at: s2, withIntermediateDirectories: false)
        try setMTime(s2, t0.addingTimeInterval(-hour))

        let clock = FakeClock(t0), timer = FakeTimer()
        let sched = RetentionScheduler(targets: targets, interval: 1800, clock: { clock.now }, timer: timer.timer)
        #expect(names(sched.start()) == ["s1"])                // launch sweep
        #expect(timer.interval == 1800)
        #expect(FileManager.default.fileExists(atPath: s2.path))
        clock.now = t0.addingTimeInterval(22 * hour)            // s2 is 23 h old: kept
        timer.fire?()
        #expect(FileManager.default.fileExists(atPath: s2.path))
        clock.now = t0.addingTimeInterval(24 * hour)            // 25 h: the tick removes it
        timer.fire?()
        #expect(!FileManager.default.fileExists(atPath: s2.path))
        sched.stop()
        #expect(timer.cancelled == 1)
        sched.stop()
        #expect(timer.cancelled == 1)
    }

    @Test func restartCancelsThePreviousTimer() {
        let timer = FakeTimer()
        let sched = RetentionScheduler(targets: [], clock: { t0 }, timer: timer.timer)
        sched.start()
        sched.start()
        #expect(timer.cancelled == 1)
        #expect(timer.interval == 3600)
    }
}
