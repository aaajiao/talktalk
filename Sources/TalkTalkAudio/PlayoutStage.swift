@preconcurrency import AVFoundation
import Foundation
import TalkTalkCore

/// Post-processing applied when ClauseQueue moves a clause into ringO (§3.3, §9.2 step 6):
///
///     24 kHz TTS PCM → LeadTrim → TailTrim (streaming) → TempoStage → 24k→48k → fixed gain
///       → −1 dBTP true-peak limiter (5 ms lookahead) → 48 kHz mono for ringO / ringO2
///
/// Runs only as audio is moved into ringO, so a tempo set by the backlog controller takes effect
/// at the next clause (and `setTempo` mid-clause, for slow renders, at the next block).
/// One clause at a time: `begin` → `process`… → `finish` (isLast). Not thread-safe; the audio
/// worker (ClauseQueue under its lock) owns it.
public final class PlayoutStage {
    public struct Config: Sendable, Equatable {
        public var leadTrim: LeadTrim.Config
        public var tailTrim: TailTrim.Config
        /// Fixed gain in dB. Calibrated once at enrollment from the audition loudness (target
        /// ≈ −20 LUFS, §3.3); 0 dB until calibrated.
        public var gainDb: Double
        public var limiterDbtp: Double
        public var limiterLookaheadMs: Double

        public init(leadTrim: LeadTrim.Config = .init(), tailTrim: TailTrim.Config = .init(), gainDb: Double = 0,
                    limiterDbtp: Double = -1, limiterLookaheadMs: Double = 5) {
            self.leadTrim = leadTrim; self.tailTrim = tailTrim; self.gainDb = gainDb
            self.limiterDbtp = limiterDbtp; self.limiterLookaheadMs = limiterLookaheadMs
        }

        public init(_ p: PolicyProfile, gainDb: Double? = nil) {
            let t = p.speak.tts
            self.init(leadTrim: .init(thresholdDbfs: t.leadTrim.thresholdDbfs, maxMs: t.leadTrim.maxMs),
                      tailTrim: .init(thresholdDbfs: t.tailTrim.thresholdDbfs, holdMaxMs: t.tailTrim.holdMaxMs,
                                      keepMs: t.tailTrim.keepMs),
                      gainDb: gainDb ?? 0, limiterDbtp: p.speak.passthrough.limiterDbtp)
        }
    }

    public static let inputRate = 24_000.0
    public static let outputRate = 48_000.0

    public var config: Config
    public private(set) var tempo: Double = 1
    public private(set) var leadTrimmedMs = 0

    private var lead: LeadTrim
    private var tail: TailTrim
    private var tempoStage: TempoStage?
    private let src: Resampler2x
    private var limiter: TruePeakLimiter
    private var linearGain: Float

    public init(config: Config = Config()) throws {
        self.config = config
        lead = LeadTrim(config.leadTrim, rate: Self.inputRate)
        tail = TailTrim(config.tailTrim, rate: Self.inputRate)
        src = try Resampler2x()
        limiter = TruePeakLimiter(sampleRate: Self.outputRate, ceilingDbtp: config.limiterDbtp,
                                  lookaheadMs: config.limiterLookaheadMs)
        linearGain = Float(pow(10, config.gainDb / 20))
    }

    /// Updates the calibrated gain; applies from the next clause (gain never changes inside one).
    public func setGainDb(_ db: Double) { config.gainDb = db }

    /// Starts a clause at `tempo` (1.0 = bypass).
    public func begin(tempo: Double) throws {
        lead = LeadTrim(config.leadTrim, rate: Self.inputRate)
        tail = TailTrim(config.tailTrim, rate: Self.inputRate)
        linearGain = Float(pow(10, config.gainDb / 20))
        leadTrimmedMs = 0
        src.reset()
        try retarget(tempo)
    }

    /// Changes tempo inside a clause (slow render → 1.25 for the part not yet in ringO): the
    /// current TimePitch segment is flushed first, so no audio is lost.
    public func setTempo(_ t: Double) throws -> [Float] {
        guard abs(t - tempo) > 1e-6 else { return [] }
        var out48: [Float] = []
        if let ts = tempoStage {
            let tailOut = try ts.finish()
            out48 = post(src.convert(tailOut, last: false))
        }
        try retarget(t)
        return out48
    }

    private func retarget(_ t: Double) throws {
        tempo = t
        if abs(t - 1) < 1e-6 { tempoStage = nil; return }
        if let ts = tempoStage { try ts.begin(rate: t) } else { tempoStage = try TempoStage(rate: t) }
    }

    /// One block of raw 24 kHz TTS audio → 48 kHz output ready for ringO (may be empty while
    /// trims hold audio back).
    public func process(_ raw: [Float]) throws -> [Float] {
        let a = lead.process(raw)
        let b = tail.process(a)
        return try stage(b, last: false)
    }

    /// isLast: TailTrim keeps `keepMs`, TimePitch and the converter are flushed, the limiter's
    /// lookahead is pushed out. Returns the clause's remaining output.
    public func finish() throws -> [Float] {
        let a = lead.finish()
        let b = tail.process(a) + tail.finish()
        leadTrimmedMs = lead.trimmedMs
        var out = try stage(b, last: true)
        var flushed: [Float] = []
        limiter.flush(into: &flushed)
        out += flushed
        return out
    }

    /// Drops the clause in progress (cut, interrupt) without producing its tail.
    public func abandon() {
        src.reset()
        tempoStage?.abandon()
        limiter.reset()
    }

    private func stage(_ x: [Float], last: Bool) throws -> [Float] {
        var t = x
        if let ts = tempoStage {
            t = try ts.process(x)
            if last { t += try ts.finish() }
        }
        return post(src.convert(t, last: last))
    }

    private func post(_ x48: [Float]) -> [Float] {
        guard !x48.isEmpty else { return [] }
        var y = x48
        if linearGain != 1 { for i in y.indices { y[i] *= linearGain } }
        var out: [Float] = []
        limiter.process(y, into: &out)
        return out
    }
}

// MARK: - trims

/// Drops leading 20 ms windows whose RMS is below −45 dBFS, at most 400 ms (§3.3).
public struct LeadTrim: Sendable {
    public struct Config: Sendable, Equatable {
        public var thresholdDbfs: Double = -45
        public var maxMs: Int = 400
        public var windowMs: Int = 20
        public init(thresholdDbfs: Double = -45, maxMs: Int = 400, windowMs: Int = 20) {
            self.thresholdDbfs = thresholdDbfs; self.maxMs = maxMs; self.windowMs = windowMs
        }
    }
    let window: Int
    let maxFrames: Int
    let threshold: Float
    let rate: Double
    private var pending: [Float] = []
    private var trimmed = 0
    private var done = false

    public init(_ c: Config, rate: Double) {
        self.rate = rate
        window = max(1, Int(rate * Double(c.windowMs) / 1000))
        maxFrames = Int(rate * Double(c.maxMs) / 1000)
        threshold = Float(pow(10, c.thresholdDbfs / 20))
    }

    public var trimmedMs: Int { Int(Double(trimmed) * 1000 / rate) }

    public mutating func process(_ x: [Float]) -> [Float] {
        if done { return x }
        pending += x
        while !done, pending.count >= window {
            if trimmed + window > maxFrames { done = true; break }
            if blockRMS(pending[0..<window]) >= threshold { done = true; break }
            pending.removeFirst(window)
            trimmed += window
        }
        if done { defer { pending = [] }; return pending }
        return []
    }

    /// End of clause: a partial window still pending is kept (too short to judge).
    public mutating func finish() -> [Float] {
        done = true
        defer { pending = [] }
        return pending
    }
}

/// Streaming tail trim (§3.3): a quiet run (< −45 dBFS per 20 ms window, ≤ 400 ms) is held back;
/// audible audio after it releases it unchanged; at isLast only `keepMs` (60 ms) of it is kept.
public struct TailTrim: Sendable {
    public struct Config: Sendable, Equatable {
        public var thresholdDbfs: Double = -45
        public var holdMaxMs: Int = 400
        public var keepMs: Int = 60
        public var windowMs: Int = 20
        public init(thresholdDbfs: Double = -45, holdMaxMs: Int = 400, keepMs: Int = 60, windowMs: Int = 20) {
            self.thresholdDbfs = thresholdDbfs; self.holdMaxMs = holdMaxMs; self.keepMs = keepMs; self.windowMs = windowMs
        }
    }
    let window: Int
    let holdMax: Int
    let keep: Int
    let threshold: Float
    private var partial: [Float] = []     // < 1 window, not judged yet
    private var held: [Float] = []        // quiet run being held

    public init(_ c: Config, rate: Double) {
        window = max(1, Int(rate * Double(c.windowMs) / 1000))
        holdMax = Int(rate * Double(c.holdMaxMs) / 1000)
        keep = Int(rate * Double(c.keepMs) / 1000)
        threshold = Float(pow(10, c.thresholdDbfs / 20))
    }

    public mutating func process(_ x: [Float]) -> [Float] {
        partial += x
        var out: [Float] = []
        var i = 0
        while partial.count - i >= window {
            let w = partial[i..<(i + window)]
            i += window
            if blockRMS(w) < threshold {
                held += w
                if held.count > holdMax {                         // only the last ≤ 400 ms is held
                    let n = held.count - holdMax
                    out += held[0..<n]
                    held.removeFirst(n)
                }
            } else {
                out += held
                held.removeAll(keepingCapacity: true)
                out += w
            }
        }
        partial.removeFirst(i)
        return out
    }

    /// isLast: a trailing partial window joins the quiet run if quiet, else releases it.
    public mutating func finish() -> [Float] {
        var out: [Float] = []
        if !partial.isEmpty {
            if blockRMS(partial[...]) < threshold { held += partial } else { out += held; held = []; out += partial }
            partial = []
        }
        out += held.prefix(keep)
        held = []
        return out
    }
}

@inline(__always)
func blockRMS(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    var s: Float = 0
    for v in x { s += v * v }
    return (s / Float(x.count)).squareRoot()
}

// MARK: - TempoStage

/// tempo ≠ 1: offline AVAudioEngine manual rendering, AVAudioSourceNode → AVAudioUnitTimePitch
/// (§3.3). The source node pulls from our own FIFO, so a dry pull is visible (`dryFrames`) and
/// never happens before `finish`; an AVAudioPlayerNode inserted ≈ 60 ms gaps mid-clause in
/// manual rendering without ever reporting a starved timeline. Each clause (segment) is separate:
/// the first `latency` output frames are dropped, `finish` feeds zeros to push the tail out, and
/// the output length is exactly round(input / rate). The latency is measured once per rate
/// (envelope correlation on a noise probe; ≈ 0 on this machine), the reported value (0) being
/// the fallback.
final class TempoStage {
    static let rate24k = PlayoutStage.inputRate
    static let maxFrames: AVAudioFrameCount = 4096
    /// Output frames per render call while streaming: small steps so the input reserve check
    /// below stays tight.
    static let step = 512
    /// Input frames kept in reserve while streaming (TimePitch pulls ahead of its output by its
    /// analysis window; measured ≈ 2 000 frames at 1.25). Never let it run dry before `finish`:
    /// a dry pull would put silence into the middle of the clause.
    static let inputReserve = 6_144
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate24k, channels: 1, interleaved: false)!
    nonisolated(unsafe) private static var measuredLatency: [Int: Int] = [:]   // rate×1000 → output frames
    private static let latencyLock = NSLock()

    /// Input FIFO the source node pulls from. Offline rendering calls the render block
    /// synchronously inside `renderOffline`, on the caller's thread.
    final class Fifo: @unchecked Sendable {
        var buf: [Float] = []
        var head = 0
        var pulled = 0          // frames handed to the unit (incl. zeros after a dry pull)
        var dry = 0             // frames the unit asked for that were not there
        var available: Int { buf.count - head }
        func push(_ x: [Float]) {
            if head > 65_536 { buf.removeFirst(head); head = 0 }
            buf += x
        }
        func clear() { buf = []; head = 0; pulled = 0; dry = 0 }
    }

    private let engine = AVAudioEngine()
    private let fifo = Fifo()
    private let source: AVAudioSourceNode
    private let pitch = AVAudioUnitTimePitch()
    private let out: AVAudioPCMBuffer
    private(set) var rate: Double = 1
    private var latencyOut = 0
    private var inFrames = 0           // real input in this segment
    private var outRendered = 0        // frames rendered by the engine (incl. dropped latency)

    var dryFrames: Int { fifo.dry }
    var latency: Int { latencyOut }

    init(rate: Double) throws {
        let f = fifo
        source = AVAudioSourceNode(format: Self.format) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            guard let dst = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let have = min(n, f.available)
            if have > 0 {
                f.buf.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress! + f.head, count: have) }
                f.head += have
            }
            if have < n { (dst + have).update(repeating: 0, count: n - have); f.dry += n - have }
            f.pulled += n
            return noErr
        }
        engine.attach(source)
        engine.attach(pitch)
        engine.connect(source, to: pitch, format: Self.format)
        engine.connect(pitch, to: engine.mainMixerNode, format: Self.format)
        try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: Self.maxFrames)
        out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.maxFrames)!
        try engine.start()
        try begin(rate: rate)
    }

    deinit { engine.stop() }

    /// Fresh segment at `rate`: clears the unit's state and any queued input.
    func begin(rate r: Double) throws {
        pitch.rate = Float(r)
        pitch.pitch = 0
        rate = r
        latencyOut = try latencyFrames(for: r)
        resetSegment()
    }

    private func resetSegment() {
        engine.reset()
        fifo.clear()
        inFrames = 0
        outRendered = 0
    }

    func abandon() { resetSegment() }

    func process(_ x: [Float]) throws -> [Float] {
        guard !x.isEmpty else { return [] }
        fifo.push(x)
        inFrames += x.count
        var y: [Float] = []
        // Render while the unit can be fed without running dry.
        while true {
            let need = Int((Double(Self.step) * rate).rounded(.up)) + Self.inputReserve
            guard fifo.available >= need else { break }
            y += try render(Self.step)
        }
        return y
    }

    /// Flushes the segment: zeros push the tail out, then exactly round(in / rate) frames
    /// after the latency are returned.
    func finish() throws -> [Float] {
        let total = Int((Double(inFrames) / rate).rounded()) + latencyOut
        let tailS = pitch.auAudioUnit.tailTime + pitch.auAudioUnit.latency
        let pad = Int((tailS * Self.rate24k).rounded(.up)) + Int((Double(latencyOut) * rate).rounded(.up))
            + Self.inputReserve + Int(Self.maxFrames)
        fifo.push([Float](repeating: 0, count: pad))
        var y: [Float] = []
        while outRendered < total { y += try render(min(Int(Self.maxFrames), total - outRendered)) }
        resetSegment()
        return y
    }

    /// Renders `n` frames, dropping the first `latencyOut` frames of the segment.
    private func render(_ n: Int) throws -> [Float] {
        let st = try engine.renderOffline(AVAudioFrameCount(n), to: out)
        guard st == .success else { throw PlayoutError.tempoRender(st.rawValue) }
        let got = Int(out.frameLength)
        let p = out.floatChannelData![0]
        let skip = max(0, min(got, latencyOut - outRendered))
        outRendered += got
        guard got > skip else { return [] }
        return Array(UnsafeBufferPointer(start: p + skip, count: got - skip))
    }

    /// Output latency at `r`, measured once per rate on a speech-like probe: a harmonic carrier
    /// (150 Hz, 6 partials) under a random smooth envelope. The latency is the lag that best aligns
    /// the 10 ms RMS envelope of the output with that of the input mapped by 1/r (1 ms hops).
    /// A transient after silence is not representative: TimePitch places an isolated burst
    /// ≈ 1 600 frames earlier than sustained sound, and the unit reports latency 0 / tailTime 0.
    private func latencyFrames(for r: Double) throws -> Int {
        let key = Int((r * 1000).rounded())
        Self.latencyLock.lock()
        if let v = Self.measuredLatency[key] { Self.latencyLock.unlock(); return v }
        Self.latencyLock.unlock()
        resetSegment()
        let n = 48_000
        var s: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> Double { s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Double(s >> 11) / Double(1 << 53) }
        // envelope: random targets every 40 ms, smoothed by a one-pole (≈ 15 ms)
        var x = [Float](repeating: 0, count: n)
        var target = 0.5, env = 0.5
        let a = exp(-1 / (0.015 * Self.rate24k))
        for i in 0..<n {
            if i % 960 == 0 { target = 0.05 + 0.95 * rnd() }
            env = a * env + (1 - a) * target
            x[i] = Float(0.3 * env * (2 * rnd() - 1))
        }
        fifo.push(x + [Float](repeating: 0, count: 12_000))
        let outCount = Int(Double(n) / r) + 6_000
        var y: [Float] = []
        while y.count < outCount {
            let st = try engine.renderOffline(AVAudioFrameCount(min(Int(Self.maxFrames), outCount - y.count)), to: out)
            guard st == .success else { throw PlayoutError.tempoRender(st.rawValue) }
            y.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        resetSegment()
        let hop = 24.0, win = 480
        func envelope(_ z: [Float], hop h: Double, count: Int) -> [Double] {
            (0..<count).map { k in
                let j = Int((Double(k) * h).rounded())
                guard j + win <= z.count else { return 0 }
                var e = 0.0
                for v in z[j..<(j + win)] { e += Double(v) * Double(v) }
                return (e / Double(win)).squareRoot()
            }
        }
        let hops = (n - win) / Int(hop)
        let ex = envelope(x, hop: hop, count: hops)
        let maxLag = 250                                   // hops: 250 ms of input
        let ey = envelope(y, hop: hop / r, count: hops + maxLag)
        let mx = ex.reduce(0, +) / Double(ex.count)
        var best = (lag: 0, score: -Double.infinity)
        for L in 0...maxLag {
            let seg = ey[L..<(L + hops)]
            let my = seg.reduce(0, +) / Double(hops)
            var num = 0.0, dy = 0.0, dx = 0.0
            for (i, v) in seg.enumerated() { let p = ex[i] - mx, q = v - my; num += p * q; dx += p * p; dy += q * q }
            let score = num / max((dx * dy).squareRoot(), 1e-12)
            if score > best.score { best = (L, score) }
        }
        var lat = Int((pitch.auAudioUnit.latency * Self.rate24k).rounded())
        if best.score > 0.8 { lat = Int((Double(best.lag) * hop / r).rounded()) }
        Self.latencyLock.lock()
        Self.measuredLatency[key] = lat
        Self.latencyLock.unlock()
        return lat
    }
}

// MARK: - 24k → 48k

/// AVAudioConverter 24 kHz → 48 kHz mono, flushed once per clause (§3.3).
final class Resampler2x {
    static let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    static let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private let conv: AVAudioConverter
    private var ended = false

    init() throws {
        guard let c = AVAudioConverter(from: Self.inFormat, to: Self.outFormat) else { throw PlayoutError.converter }
        c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        conv = c
    }

    func reset() {
        conv.reset()
        ended = false
    }

    func convert(_ x: [Float], last: Bool) -> [Float] {
        if ended { reset() }
        var input: AVAudioPCMBuffer?
        if !x.isEmpty {
            let b = AVAudioPCMBuffer(pcmFormat: Self.inFormat, frameCapacity: AVAudioFrameCount(x.count))!
            b.frameLength = AVAudioFrameCount(x.count)
            x.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
            input = b
        }
        var y: [Float] = []
        let cap = AVAudioFrameCount(max(1024, x.count * 2 + 1024))
        let ob = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: cap)!
        // The input block may be @Sendable: hand it a box instead of capturing mutable locals.
        let feed = Feed(input: input, last: last)
        while true {
            ob.frameLength = 0
            var err: NSError?
            let st = conv.convert(to: ob, error: &err) { _, status in
                if !feed.fed, let b = feed.input { feed.fed = true; status.pointee = .haveData; return b }
                status.pointee = feed.last ? .endOfStream : .noDataNow
                return nil
            }
            if ob.frameLength > 0 {
                y.append(contentsOf: UnsafeBufferPointer(start: ob.floatChannelData![0], count: Int(ob.frameLength)))
            }
            switch st {
            case .haveData: continue
            case .endOfStream: ended = true; return y
            default: return y
            }
        }
    }
}

private final class Feed: @unchecked Sendable {
    let input: AVAudioPCMBuffer?
    let last: Bool
    var fed = false
    init(input: AVAudioPCMBuffer?, last: Bool) { self.input = input; self.last = last }
}

public enum PlayoutError: Error, Sendable, Equatable {
    case converter
    case tempoRender(Int)
}
