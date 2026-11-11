/// Audio time ↔ host time for one capture stream (ARCHITECTURE.md, "实时音频与生命周期约束").
///
/// The stream's audio timeline counts frames delivered to consumers (including zeros we insert).
/// Each IO callback reports the host time of its first frame. The map is piecewise: a new segment
/// starts whenever the host clock and the frame count disagree by more than one IO period, so
/// conversions stay within one IO period even across tap rebuilds (≤300 ms), dropped buffers on a
/// sample-rate switch, coreaudiod restarts, and slow clock drift.
///
/// Gaps: ≤ `maxFillSeconds` (2 s) are filled with zeros so the audio timeline stays continuous;
/// longer ones ask the caller to restart the analyzer with a new origin. Everything downstream
/// (`finalize(through:)`, ring clips, EchoFilter windows, FloorManager) converts through here.
public struct TimeMap: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var startFrame: Int64
        public var startHost: HostTime
    }

    public enum Observation: Sendable, Equatable {
        /// The callback follows the previous one; append its frames.
        case contiguous
        /// Insert this many zero frames before the callback's frames.
        case fillZeros(Int)
        /// Gap longer than `maxFillSeconds` (or the first callback after `reset`): start a new
        /// analyzer; the timeline continues without filler.
        case restart(gapMs: Int)
    }

    public let sampleRate: Double
    public let maxFillSeconds: Double
    public let maxSegments: Int
    public private(set) var segments: [Segment] = []
    /// Frames on the audio timeline so far (the index the next callback's first frame gets).
    public private(set) var framesSoFar: Int64 = 0
    private var anchored = false

    public init(sampleRate: Double, maxFillSeconds: Double = 2, maxSegments: Int = 512) {
        precondition(sampleRate > 0)
        self.sampleRate = sampleRate
        self.maxFillSeconds = maxFillSeconds
        self.maxSegments = maxSegments
    }

    private func nanos(frames: Int64) -> Int64 { Int64((Double(frames) * 1e9 / sampleRate).rounded()) }
    private func frames(nanos: Int64) -> Int64 { Int64((Double(nanos) * sampleRate / 1e9).rounded()) }

    /// One IO callback: `frames` frames whose first one played at `host` (ns). `ioPeriodFrames`
    /// is the tolerance (one IO buffer). Returns what to do before appending the frames.
    public mutating func observe(host: HostTime, frames n: Int, ioPeriodFrames: Int) -> Observation {
        let tolerance = nanos(frames: Int64(max(1, ioPeriodFrames)))
        defer { framesSoFar += Int64(n) }
        // Expected from the segment anchor, not from the previous callback, so slow drift
        // accumulates and is caught.
        guard anchored, let expected = hostTime(atFrame: framesSoFar) else {
            anchored = true
            anchor(at: host)
            return .contiguous
        }
        let gap = Int64(bitPattern: host &- expected)   // signed difference in ns
        if abs(gap) <= tolerance {
            // Re-anchor quietly once drift exceeds half a period, so error stays below one period.
            if abs(gap) > tolerance / 2 { anchor(at: host) }
            return .contiguous
        }
        if gap < 0 {
            // The host clock went backwards relative to the frames (overlap): re-anchor, no fill.
            anchor(at: host)
            return .contiguous
        }
        if Double(gap) <= maxFillSeconds * 1e9 {
            let fill = frames(nanos: gap)
            framesSoFar += fill
            anchor(at: host)
            return .fillZeros(Int(fill))
        }
        anchor(at: host)
        return .restart(gapMs: Int(gap / 1_000_000))
    }

    /// Forget the stream position (a new tap). The next callback anchors a new segment.
    public mutating func reset() {
        anchored = false
    }

    private mutating func anchor(at host: HostTime) {
        if let last = segments.last, last.startFrame == framesSoFar {
            segments[segments.count - 1].startHost = host
        } else {
            segments.append(Segment(startFrame: framesSoFar, startHost: host))
        }
        if segments.count > maxSegments { segments.removeFirst(segments.count - maxSegments) }
    }

    /// Host time of audio frame `f` (extrapolated within its segment).
    public func hostTime(atFrame f: Int64) -> HostTime? {
        guard let seg = segment(containingFrame: f) else { return nil }
        let d = nanos(frames: f - seg.startFrame)
        return d >= 0 ? seg.startHost &+ HostTime(d) : seg.startHost &- HostTime(-d)
    }

    /// Audio frame playing at host time `h`.
    public func frame(atHost h: HostTime) -> Int64? {
        guard !segments.isEmpty else { return nil }
        var seg = segments[0]
        for s in segments where s.startHost <= h { seg = s }
        let d = Int64(bitPattern: h &- seg.startHost)
        return seg.startFrame + frames(nanos: d)
    }

    /// Seconds on the audio timeline of frame `f` (what SpeechAnalyzer's CMTime sees).
    public func seconds(atFrame f: Int64) -> Double { Double(f) / sampleRate }

    private func segment(containingFrame f: Int64) -> Segment? {
        guard !segments.isEmpty else { return nil }
        var seg = segments[0]
        for s in segments where s.startFrame <= f { seg = s }
        return seg
    }
}
