import Foundation
import TalkTalkCore
import TalkTalkAudio

/// The audio-worker side of LISTEN (§1.2): 16 kHz mono chunks from MeetingTap go to the ASR
/// stream as Int16 and through libfvad mode 2 on 20 ms frames,
/// and into a 60 s ring for the second-pass clip (ringL16). Called on the
/// tap's worker queue; never waits on the pipeline actor.
public final class AudioIngest: @unchecked Sendable {
    public let voiceThresholdDbfs: Double
    public let ringSeconds: Double

    private let lock = NSLock()
    private var stream: (any ASRStream)?
    private var restartBuffer: [(host: HostTime, samples: [Float])]?
    private var lastVoiceEnd: HostTime?
    private var ring: [(host: HostTime, samples: [Float])] = []
    private var ringFrames = 0
    private var _chunks = 0
    private var voiceIntervals: [Range<HostTime>] = []
    private var vadIntervals: [Range<HostTime>] = []
    private let vad = try? SpeakVAD()
    private var lastChunkEnd: HostTime?
    private var latestFrame: (end: HostTime, voiced: Bool, energy: Double)?

    public init(voiceThresholdDbfs: Double = -50, ringSeconds: Double = 60) {
        self.voiceThresholdDbfs = voiceThresholdDbfs
        self.ringSeconds = ringSeconds
    }

    public func attach(_ s: any ASRStream) {
        lock.withLock {
            // feed is nonblocking; keep ordering with chunks arriving during the open await.
            for c in restartBuffer ?? [] { Self.feed(c.samples, host: c.host, to: s) }
            restartBuffer = nil; stream = s
        }
    }
    /// Preserve up to two seconds of newly captured audio while a language/ASR replacement opens.
    public func prepareForRecognizerReplacement() { lock.withLock { stream = nil; restartBuffer = [] } }

    public func prepareAnalyzerRestart(ifGapBefore host: HostTime) -> Int? {
        lock.withLock {
            guard restartBuffer == nil, let end = lastChunkEnd, host > end, host - end > 2_000_000_000 else { return nil }
            stream = nil; restartBuffer = []
            return Int((host - end) / 1_000_000)
        }
    }
    private static func feed(_ samples: [Float], host: HostTime, to target: any ASRStream) {
        let pcm = samples.map { Int16(clamping: Int((max(-1, min(1, $0)) * 32767).rounded())) }
        pcm.withUnsafeBufferPointer { target.feed($0, at: host) }
    }
    public func detach() { lock.withLock { stream = nil } }

    public var chunks: Int { lock.withLock { _chunks } }

    /// One chunk of 16 kHz mono Float32 whose first sample was at `host` (ns).
    public func push(_ samples: [Float], host: HostTime) {
        guard !samples.isEmpty else { return }
        let end = host &+ HostTime(Double(samples.count) / 16_000 * 1e9)
        let target: (any ASRStream)? = lock.withLock {
            _chunks += 1
            if let previous = lastChunkEnd, abs(HostClock.ms(previous, to: host)) > 20 { vad?.reset() }
            lastChunkEnd = end
            for frame in vad?.push(samples, at: host).frames ?? [] {
                latestFrame = (frame.end, frame.voiced && frame.rmsDb > voiceThresholdDbfs, frame.rmsDb)
                if let last = vadIntervals.last, frame.start <= last.upperBound {
                    vadIntervals[vadIntervals.count - 1] = last.lowerBound..<max(last.upperBound, frame.end)
                } else { vadIntervals.append(frame.start..<frame.end) }
                guard frame.voiced && frame.rmsDb > voiceThresholdDbfs else { continue }
                lastVoiceEnd = max(lastVoiceEnd ?? 0, frame.end)
                if let last = voiceIntervals.last, frame.start <= last.upperBound {
                    voiceIntervals[voiceIntervals.count - 1] = last.lowerBound..<max(last.upperBound, frame.end)
                } else {
                    voiceIntervals.append(frame.start..<frame.end)
                }
            }
            let window = HostTime(max(0, ringSeconds) * 1e9)
            let floor = end > window ? end - window : 0
            voiceIntervals.removeAll { $0.upperBound <= floor }
            vadIntervals.removeAll { $0.upperBound <= floor }
            if let first = voiceIntervals.first, first.lowerBound < floor {
                voiceIntervals[0] = floor..<first.upperBound
            }
            ring.append((host, samples))
            ringFrames += samples.count
            let cap = Int(ringSeconds * 16_000)
            while ringFrames > cap, let first = ring.first {
                ringFrames -= first.samples.count
                ring.removeFirst()
            }
            if restartBuffer != nil {
                restartBuffer!.append((host, samples))
                let floor = end > 2_000_000_000 ? end - 2_000_000_000 : 0
                restartBuffer!.removeAll { $0.host < floor }
            }
            return stream
        }
        guard let target else { return }
        Self.feed(samples, host: host, to: target)
    }

    /// Milliseconds since the last voiced chunk ended (0 while voiced; `Int.max / 2` before any voice).
    public func silenceMs(now: HostTime) -> Int {
        lock.withLock {
            guard let v = lastVoiceEnd else { return Int.max / 2 }
            return now > v ? Int((now - v) / 1_000_000) : 0
        }
    }

    /// Fresh classified audio only; a missing/stalled capture must not look like silence.
    public func activity(at now: HostTime) -> (vadSpeech: Bool?, energyDb: Double?) {
        lock.withLock {
            guard let f = latestFrame, now >= f.end, now - f.end <= 200_000_000 else { return (nil, nil) }
            return (f.voiced, f.energy.isFinite ? f.energy : -120)
        }
    }

    /// Fraction of this host-time interval covered by remote voice, for the M2 speaker-mode gate.
    public func remoteVADOverlap(from start: HostTime, to end: HostTime) -> Double? {
        guard end > start, vad != nil else { return nil }
        return lock.withLock {
            var coveredThrough = start
            for chunk in ring {
                let chunkEnd = chunk.host &+ HostTime(Double(chunk.samples.count) / 16_000 * 1e9)
                if chunkEnd <= coveredThrough { continue }
                guard chunk.host <= coveredThrough else { return nil }
                coveredThrough = chunkEnd
                if coveredThrough >= end { break }
            }
            guard coveredThrough >= end else { return nil }
            // Audio in a partial 20 ms frame has not been classified yet: it is unknown.
            guard vadIntervals.contains(where: { $0.lowerBound <= start && $0.upperBound >= end }) else { return nil }
            let overlap = voiceIntervals.reduce(UInt64(0)) { total, span in
                let lo = max(start, span.lowerBound), hi = min(end, span.upperBound)
                return total + (hi > lo ? hi - lo : 0)
            }
            return min(1, Double(overlap) / Double(end - start))
        }
    }

    /// The ring's audio between two host times (second-pass ASR, §4.2), or nil if it fell out.
    public func clip(from start: HostTime, to end: HostTime) -> PCMClip16k? {
        lock.withLock {
            guard end > start, let oldest = ring.first, oldest.host <= start else { return nil }
            var out: [Float] = []
            var clipStart: HostTime?
            for c in ring {
                let cEnd = c.host &+ HostTime(Double(c.samples.count) / 16_000 * 1e9)
                guard cEnd > start, c.host < end else { continue }
                let from = c.host >= start ? 0 : Int(Double(start - c.host) / 1e9 * 16_000)
                let to = cEnd <= end ? c.samples.count : min(c.samples.count, Int(Double(end - c.host) / 1e9 * 16_000))
                guard to > from else { continue }
                if clipStart == nil { clipStart = c.host &+ HostTime(Double(from) / 16_000 * 1e9) }
                out.append(contentsOf: c.samples[from..<to])
            }
            guard let clipStart, !out.isEmpty else { return nil }
            return PCMClip16k(samples: out, start: clipStart, end: clipStart &+ HostTime(Double(out.count) / 16_000 * 1e9))
        }
    }

    public func reset() {
        lock.withLock { lastVoiceEnd = nil; restartBuffer = nil; ring.removeAll(); ringFrames = 0; voiceIntervals.removeAll(); vadIntervals.removeAll(); lastChunkEnd = nil; latestFrame = nil; vad?.reset() }
    }
}
