// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Foundation
import TalkTalkCore
import TalkTalkSession

/// Per-meeting diagnostic recording (ARCHITECTURE.md §12.1, §12.4).
///
/// - Off unless chosen for this meeting. The choice is made per meeting (before it starts, for
///   the next one, or while it runs) and is cleared when the meeting ends.
/// - Default tracks: microphone and TTS (SPEAK, M2 feeds them). The remote side (meeting tap)
///   is recorded only after the user confirms *during this meeting* that all participants
///   agreed (German StGB §201). That confirmation is a `RemoteRecordingConsent`, which only
///   `confirmRemoteConsent` in this file can create, and it is bound to the running meeting.
/// - Files: `Application Support/TalkTalk/diagnostics/<session>/` (0700, excluded from backup),
///   `<track>.f32` (raw little-endian Float32, mono) + `<track>.json` (rate, first host time,
///   frames), and `marks.jsonl`: subtitle and lifecycle marks with host times, sentence ids and
///   lengths, never text (a transcript is §16 decision 7, not a diagnostic). Every file 0600.
///   Deleted after 24 h by `RetentionPolicy.diagnostics` (at launch and on the timer).
///
/// Wiring (MeetingController, listen's file): forward `MeetingEvents` lifecycle events to
/// `meetingStarted/Suspended/Resumed/Ended`, `SubtitleUpdate`s to `subtitle(_:)`, and remote
/// 16 kHz chunks to `appendRemote`. Audio calls are safe from any thread.
@MainActor
@Observable
final class DiagnosticRecorder {
    enum Track: String, CaseIterable, Sendable { case mic, tts, remote }

    /// Recording of mic + TTS chosen for the next meeting (or the running one).
    private(set) var micAndTTSArmed = false
    private(set) var meetingRunning = false
    private(set) var sessionDirectory: URL?
    private(set) var recordingTracks: Set<Track> = []
    private(set) var lastError: String?
    private(set) var meetingCounter = 0

    let root: URL
    private let writers = WriterSet()
    private let clock: @Sendable () -> HostTime

    init(root: URL, clock: @escaping @Sendable () -> HostTime = HostClock.now) {
        self.root = root
        self.clock = clock
    }

    // MARK: - choices

    /// Mic + TTS for this meeting (or the next one when none runs).
    func setMicAndTTS(_ on: Bool) {
        micAndTTSArmed = on
        guard meetingRunning else { return }
        if on { open([.mic, .tts]) } else { close([.mic, .tts]) }
    }

    /// Asks “所有参与者都已同意录音？” now. Nil unless a meeting runs and the user ticks the box
    /// and confirms; the token is valid for this meeting only.
    func confirmRemoteConsent() -> RemoteRecordingConsent? {
        guard meetingRunning else { return nil }
        let alert = NSAlert()
        alert.messageText = String(appLocalized: "录下对方的声音？")
        alert.informativeText = String(appLocalized: "只在会议里所有参与者都已同意录音时才可以录（德国《刑法典》§201 把未经同意录下非公开谈话列为犯罪）。录音只存在这台 Mac 上，24 小时后自动删除，不进诊断包。")
        let box = NSButton(checkboxWithTitle: String(appLocalized: "所有参与者都已同意录音"), target: nil, action: nil)
        box.state = .off
        alert.accessoryView = box
        alert.addButton(withTitle: String(appLocalized: "开始录音"))
        alert.addButton(withTitle: String(appLocalized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn, box.state == .on else { return nil }
        return RemoteRecordingConsent(meeting: meetingCounter, at: Date())
    }

    /// Starts the remote track. Refused without a consent from this very meeting.
    @discardableResult
    func startRemote(_ consent: RemoteRecordingConsent) -> Bool {
        guard meetingRunning, consent.meeting == meetingCounter else { return false }
        open([.remote])
        mark("remote_consent", [:])
        return recordingTracks.contains(.remote)
    }

    func stopRemote() { close([.remote]) }

    /// Stops recording and deletes this meeting's directory.
    func discardCurrent() {
        close(Set(Track.allCases))
        if let d = sessionDirectory { try? FileManager.default.removeItem(at: d) }
        sessionDirectory = nil
    }

    // MARK: - lifecycle (MeetingEvents)

    func meetingStarted(lang: Lang? = nil) {
        meetingCounter += 1
        meetingRunning = true
        sessionDirectory = nil
        if micAndTTSArmed { open([.mic, .tts]) }
        if let lang { mark("meeting.start", ["lang": lang.rawValue]) }
    }

    func meetingSuspended(_ reason: String) { mark("meeting.suspend", ["why": reason]) }
    func meetingResumed() { mark("meeting.resume", [:]) }

    /// Closes every track; the choices (and any consent) end with the meeting.
    func meetingEnded(_ reason: String) {
        mark("meeting.end", ["reason": reason])
        close(Set(Track.allCases))
        meetingRunning = false
        micAndTTSArmed = false
    }

    /// Subtitle marks: kind, sentence, lengths. The text itself is not written.
    func subtitle(_ u: SubtitleUpdate) {
        guard !recordingTracks.isEmpty else { return }
        switch u {
        case .source: return   // every ASR update; the events log has the timing that matters
        case let .draft(sentence, text, _):
            mark("draft", ["sentence": Int(sentence), "chars": text.count])
        case let .final(sentence, text, source, approx, numberWarning):
            mark("final", ["sentence": Int(sentence), "chars": text.count, "source_chars": source.count,
                           "approx": approx, "number_warning": numberWarning])
        case let .dropped(sentence):
            mark("dropped", ["sentence": Int(sentence)])
        }
    }

    // MARK: - audio (any thread)

    nonisolated func appendRemote(_ samples: [Float], host: HostTime, rate: Double = 16_000) {
        writers.append(.remote, samples, host: host, rate: rate)
    }

    nonisolated func appendMic(_ samples: [Float], host: HostTime, rate: Double) {
        writers.append(.mic, samples, host: host, rate: rate)
    }

    nonisolated func appendTTS(_ samples: [Float], host: HostTime, rate: Double) {
        writers.append(.tts, samples, host: host, rate: rate)
    }

    // MARK: - internals

    private func ensureSessionDirectory() throws -> URL {
        if let d = sessionDirectory { return d }
        try FileSystem.ensurePrivateDirectory(root)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        let d = root.appendingPathComponent("\(f.string(from: Date()))-\(UUID().uuidString.prefix(6).lowercased())", isDirectory: true)
        try FileSystem.ensurePrivateDirectory(d)
        sessionDirectory = d
        return d
    }

    private func open(_ tracks: Set<Track>) {
        do {
            let dir = try ensureSessionDirectory()
            for t in tracks.sorted(by: { $0.rawValue < $1.rawValue }) where !recordingTracks.contains(t) {
                try writers.open(t, in: dir)
                recordingTracks.insert(t)
            }
            lastError = nil
        } catch {
            lastError = String(appLocalized: "诊断录音无法开始：\(String(describing: error))")
        }
    }

    private func close(_ tracks: Set<Track>) {
        for t in tracks where recordingTracks.contains(t) {
            writers.close(t)
            recordingTracks.remove(t)
        }
        if recordingTracks.isEmpty { writers.closeMarks() }
    }

    private func mark(_ kind: String, _ fields: [String: Any]) {
        guard !recordingTracks.isEmpty, let dir = sessionDirectory else { return }
        var obj = fields
        obj["t"] = clock()
        obj["kind"] = kind
        writers.mark(obj, in: dir)
    }
}

/// Proof that the user confirmed, during meeting `meeting`, that every participant agreed to
/// be recorded. Only `DiagnosticRecorder.confirmRemoteConsent()` creates one.
struct RemoteRecordingConsent: Sendable, Equatable {
    let meeting: Int
    let at: Date
    fileprivate init(meeting: Int, at: Date) { self.meeting = meeting; self.at = at }
}

/// The open track files, behind one lock (audio arrives on worker threads).
private final class WriterSet: @unchecked Sendable {
    /// Per-track cap; past it the track stops (≈ 2.3 h of 16 kHz mono, 45 min of 48 kHz).
    static let maxBytes = 512 * 1024 * 1024

    private struct Writer {
        var handle: FileHandle
        var meta: URL
        var rate: Double?
        var firstHost: HostTime?
        var frames = 0
        var bytes = 0
        var capped = false
    }

    private let lock = NSLock()
    private var open: [DiagnosticRecorder.Track: Writer] = [:]
    private var marks: FileHandle?

    func open(_ t: DiagnosticRecorder.Track, in dir: URL) throws {
        let h = try FileSystem.openForAppending(dir.appendingPathComponent("\(t.rawValue).f32"))
        lock.withLock { open[t] = Writer(handle: h, meta: dir.appendingPathComponent("\(t.rawValue).json")) }
    }

    func append(_ t: DiagnosticRecorder.Track, _ samples: [Float], host: HostTime, rate: Double) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            guard var w = open[t], !w.capped else { return }
            if w.rate == nil { w.rate = rate; w.firstHost = host }
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }   // native = little-endian on arm64
            if w.bytes + data.count > Self.maxBytes { w.capped = true; open[t] = w; return }
            w.handle.write(data)
            w.frames += samples.count
            w.bytes += data.count
            open[t] = w
        }
    }

    func close(_ t: DiagnosticRecorder.Track) {
        let w: Writer? = lock.withLock { open.removeValue(forKey: t) }
        guard let w else { return }
        try? w.handle.close()
        let meta: [String: Any] = ["format": "f32le", "channels": 1, "rate": w.rate ?? 0,
                                   "first_host_ns": w.firstHost ?? 0, "frames": w.frames, "capped": w.capped]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
            try? FileSystem.writeAtomically(d, to: w.meta)
        }
    }

    func mark(_ obj: [String: Any], in dir: URL) {
        guard let line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        lock.withLock {
            if marks == nil { marks = try? FileSystem.openForAppending(dir.appendingPathComponent("marks.jsonl")) }
            marks?.write(line + Data("\n".utf8))
        }
    }

    func closeMarks() {
        lock.withLock {
            try? marks?.close()
            marks = nil
        }
    }
}
