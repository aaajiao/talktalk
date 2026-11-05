import CoreAudio
import Foundation
import TalkTalkCore

/// System-audio-recording grant check (ARCHITECTURE.md §3.1 "TCC 探针"). Meeting clients output
/// exact digital silence in a lobby, muted, with DTX or alone, so silence never means "denied".
/// Instead the app plays a short, quiet tone with `/usr/bin/afplay` (a PID we know), taps only that
/// process with `.muted` (the user hears nothing once the tap is up), and decides:
///   - non-zero samples while afplay plays → granted;
///   - only zeros while afplay is a running Core Audio client → denied (guide the user to
///     System Settings › Privacy & Security › Screen & System Audio Recording);
///   - afplay never became a client, or the tap only came up after it finished (e.g. the first-run
///     prompt blocked) → inconclusive; run again.
/// Tapping another process is gated by TCC; tapping ourselves is not, hence afplay.
/// Run it from LaunchServices-started TalkTalk(-Dev).app, off the main thread.
public enum TCCProbe {
    public enum Verdict: String, Sendable, Codable { case granted, denied, inconclusive }

    public struct Result: Sendable, Codable {
        public var verdict: Verdict
        public var reason: String
        public var tapStartMs: Int?
        public var processObjectMs: Int?
        public var chunks: Int
        public var nonZero: Bool
    }

    /// - Parameters: toneSeconds 0.3 and −40 dBFS per §3.1.
    public static func run(toneSeconds: Double = 0.3, dbfs: Double = -40, frequency: Double = 880) -> Result {
        var result = Result(verdict: .inconclusive, reason: "", tapStartMs: nil, processObjectMs: nil, chunks: 0, nonZero: false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("talktalk-tcc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("probe.wav")
        // A little silence first, so the tap can come up before the tone starts.
        guard (try? toneWAV(seconds: toneSeconds, leadSilence: 0.25, dbfs: dbfs, frequency: frequency).write(to: wav)) != nil else {
            result.reason = "could not write tone"
            return result
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [wav.path]
        let t0 = HostClock.now()
        do { try p.run() } catch {
            result.reason = "afplay: \(error)"
            return result
        }
        defer { if p.isRunning { p.terminate() } }

        var object: AudioObjectID?
        while object == nil, p.isRunning, HostClock.ms(t0, to: HostClock.now()) < 1500 {
            object = AudioDeviceCatalog.processObject(pid: p.processIdentifier)
            if object == nil { usleep(10_000) }
        }
        guard let object else {
            result.reason = p.isRunning ? "afplay has no process object" : "afplay ended before it became a client"
            return result
        }
        result.processObjectMs = HostClock.ms(t0, to: HostClock.now())

        let tap = MeetingTap(processes: [object], muteBehavior: .muted, ringSeconds: 1)
        let counter = ChunkCounter()
        do {
            try tap.start(onChunk: { c in counter.add(c.samples) })
        } catch {
            result.reason = "tap: \(error)"
            return result
        }
        result.tapStartMs = HostClock.ms(t0, to: HostClock.now())
        let tapUpWhilePlaying = p.isRunning
        p.waitUntilExit()
        usleep(60_000)   // let the worker drain the last callbacks
        tap.stop()
        result.chunks = counter.chunks
        result.nonZero = counter.nonZero
        if counter.nonZero {
            result.verdict = .granted
            result.reason = "non-zero audio from afplay"
        } else if tapUpWhilePlaying && counter.chunks > 0 {
            result.verdict = .denied
            result.reason = "only zeros while afplay played"
        } else {
            result.reason = tapUpWhilePlaying ? "tap delivered no callbacks" : "tap came up after afplay finished"
        }
        return result
    }

    /// 16-bit mono 48 kHz WAV: `leadSilence` s of zeros, then a sine at `dbfs` with 10 ms fades.
    static func toneWAV(seconds: Double, leadSilence: Double, dbfs: Double, frequency: Double) -> Data {
        let rate = 48_000
        let lead = Int(leadSilence * Double(rate)), n = Int(seconds * Double(rate))
        let amp = pow(10, dbfs / 20) * 32767
        let fade = rate / 100
        var pcm = Data(capacity: (lead + n) * 2)
        for _ in 0..<lead { pcm.append(contentsOf: [0, 0]) }
        for i in 0..<n {
            let g = min(1, Double(min(i, n - 1 - i)) / Double(fade))
            let v = Int16(clamping: Int((amp * g * sin(2 * .pi * frequency * Double(i) / Double(rate))).rounded()))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var h = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        h.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        return h + pcm
    }

    final class ChunkCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _chunks = 0, _nonZero = false
        func add(_ s: [Float]) {
            let nz = s.contains { $0 != 0 }
            lock.withLock { _chunks += 1; if nz { _nonZero = true } }
        }
        var chunks: Int { lock.withLock { _chunks } }
        var nonZero: Bool { lock.withLock { _nonZero } }
    }
}
