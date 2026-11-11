@preconcurrency import AVFoundation
import CAudioCore
import CoreAudio
import Foundation
import TalkTalkCore

/// The LISTEN capture (ARCHITECTURE.md, "实时音频与生命周期约束", from cicada `SystemAudioTap`): an include tap of the
/// meeting's process objects by default. Explicit global fallback supplies an exclusion list.
///
///  1. `CATapDescription(stereoMixdownOfProcesses:)`, private, `.unmuted` (`.muted` for the TCC probe).
///  2. When the process set changes, `kAudioTapPropertyDescription` is updated in place (`update`).
///  3. A private aggregate with the tap in its creation dictionary, `TapAutoStart`, drift
///     compensation on, UID prefix `com.aaajiao.talktalk.tap.`, and no sub-device: the tap clocks
///     itself, so no Bluetooth headset (and its HFP mic) is pulled in (C11).
///  4. The C IOProc `tt_tap_ioproc` copies L/R into two rings (2 s) and records host times. A
///     worker drains every 10 ms: TimeMap (gaps ≤2 s filled with zeros, longer → `.restartNeeded`),
///     downmix, resample to 16 kHz Float32, then `onChunk`.
///  5. `start` can block for the first-run TCC prompt (~90 s): call it off the main thread.
///
/// Requires the "屏幕与系统录音" (system audio recording) grant for the responsible app; when it is
/// denied the tap delivers exact zeros. Only TCCProbe decides about the grant (§3.1).
public final class MeetingTap: @unchecked Sendable {
    public static let uidPrefix = DriverPins.tapUIDPrefix
    public static let outputRate = 16_000.0

    public struct Chunk: Sendable {
        /// Mono 16 kHz Float32.
        public let samples: [Float]
        /// Index of `samples[0]` on this tap's 16 kHz timeline.
        public let startFrame: Int64
        /// Host time (ns) of `samples[0]`.
        public let hostTime: HostTime
    }

    public enum Event: Sendable, Equatable {
        case gapFilled(ms: Int)
        /// Gap > 2 s: the consumer restarts its analyzer (new time origin).
        case restartNeeded(gapMs: Int)
        case droppedStamps(Int)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public let what: String
        public var description: String { "\(what): OSStatus \(status)" }
    }

    public private(set) var processes: [AudioObjectID]
    public let excludesProcesses: Bool
    public let muteBehavior: CATapMuteBehavior
    /// The tap side of EchoScorer: 10 ms points at the resampled audio's capture time.
    /// FeedOutput owns the other envelope. Only this tap worker writes this instance.
    public let envelope: EnvelopeHistory?
    public private(set) var tapSampleRate: Double = 0
    public private(set) var tapChannels: UInt32 = 0
    public private(set) var aggregateUID = ""

    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.tap-worker", qos: .userInteractive)
    private let ringSeconds: Double
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var ringL: OpaquePointer?
    private var ringR: OpaquePointer?
    private var ctx: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var timeMap: TimeMap?
    private var description: CATapDescription?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var outFormat: AVAudioFormat?
    private var scratchL: [Float] = []
    private var scratchR: [Float] = []
    private var stamps = [tt_tap_stamp](repeating: tt_tap_stamp(), count: 256)
    private var out16kFrames: Int64 = 0
    private var onChunk: (@Sendable (Chunk) -> Void)?
    private var onEvent: (@Sendable (Event) -> Void)?
    private var ioPeriod = 512

    public init(processes: [AudioObjectID], muteBehavior: CATapMuteBehavior = .unmuted, ringSeconds: Double = 2, excludingProcesses: Bool = false) {
        self.processes = processes
        self.excludesProcesses = excludingProcesses
        self.muteBehavior = muteBehavior
        self.ringSeconds = ringSeconds
        envelope = EnvelopeHistory(windowFrames: 160,
            hostTicksPerFrame: Double(HostClock.machTicks(fromNanos: 1_000_000_000)) / Self.outputRate)
    }

    deinit { teardown() }

    // MARK: - lifecycle

    /// Creates tap, aggregate and IOProc and starts IO. Blocks on the first-run TCC prompt.
    public func start(onChunk: @escaping @Sendable (Chunk) -> Void, onEvent: @escaping @Sendable (Event) -> Void = { _ in }) throws {
        let desc = excludesProcesses ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
            : CATapDescription(stereoMixdownOfProcesses: processes)
        desc.name = "TalkTalk meeting tap"
        desc.isPrivate = true
        desc.muteBehavior = muteBehavior
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw Failure(status: status, what: "AudioHardwareCreateProcessTap") }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(status: status, what: "kAudioTapPropertyFormat")
        }

        let uid = Self.uidPrefix + UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TalkTalk Tap",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard status == noErr, agg != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(status: status, what: "AudioHardwareCreateAggregateDevice")
        }

        try queue.sync {
          do {
            tapID = tap
            aggregateID = agg
            aggregateUID = uid
            description = desc
            tapSampleRate = asbd.mSampleRate
            tapChannels = max(1, asbd.mChannelsPerFrame)
            let cap = UInt32(asbd.mSampleRate * ringSeconds)
            guard let l = tt_ring_create(cap), let r = tt_ring_create(cap), let c = tt_tap_ctx_create(l, r) else {
                throw Failure(status: 0, what: "ring allocation")
            }
            ringL = l; ringR = r; ctx = c
            scratchL = [Float](repeating: 0, count: Int(tt_ring_capacity(l)))
            scratchR = scratchL
            timeMap = TimeMap(sampleRate: asbd.mSampleRate)
            out16kFrames = 0
            setUpConverter(rate: asbd.mSampleRate)
            self.onChunk = onChunk
            self.onEvent = onEvent
            let buf: UInt32 = InputDeviceCatalog.scalar(agg, kAudioDevicePropertyBufferFrameSize) ?? 512
            ioPeriod = Int(max(64, buf))

            var proc: AudioDeviceIOProcID?
            var st = AudioDeviceCreateIOProcID(agg, tt_tap_ioproc, UnsafeMutableRawPointer(c), &proc)
            guard st == noErr, let proc else { throw Failure(status: st, what: "AudioDeviceCreateIOProcID") }
            procID = proc
            st = AudioDeviceStart(agg, proc)
            guard st == noErr else { throw Failure(status: st, what: "AudioDeviceStart") }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.drain() }
            t.resume()
            timer = t
          } catch {
            teardownOnQueue()
            throw error
          }
        }
    }

    /// The meeting's process set changed: update the tap in place (§3.1 step 2).
    public func update(processes new: [AudioObjectID]) throws {
        try queue.sync {
            guard new != processes, let desc = description, tapID != kAudioObjectUnknown else { return }
            desc.processes = new
            var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var ref: Unmanaged<CATapDescription> = Unmanaged.passUnretained(desc)
            let status = AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &ref)
            guard status == noErr else { throw Failure(status: status, what: "set kAudioTapPropertyDescription") }
            processes = new
        }
    }

    public func stop() {
        queue.sync { teardownOnQueue() }
    }

    /// Host time (ns) of the latest IO callback that carried a non-zero sample.
    public var lastNonZeroHostTime: HostTime? {
        queue.sync {
            guard let ctx else { return nil }
            let t = tt_tap_last_nonzero_host_time(ctx)
            return t == 0 ? nil : HostClock.nanos(fromMachTicks: t)
        }
    }

    public var callbacks: UInt64 { queue.sync { ctx.map { tt_tap_callbacks($0) } ?? 0 } }

    /// Host time of a frame on the 16 kHz timeline.
    public func hostTime(at16kFrame f: Int64) -> HostTime? {
        queue.sync {
            guard let m = timeMap else { return nil }
            return m.hostTime(atFrame: Int64((Double(f) * tapSampleRate / Self.outputRate).rounded()))
        }
    }

    /// 16 kHz frame playing at host time `h`.
    public func frame16k(atHost h: HostTime) -> Int64? {
        queue.sync {
            guard let m = timeMap, let f = m.frame(atHost: h) else { return nil }
            return Int64((Double(f) * Self.outputRate / tapSampleRate).rounded())
        }
    }

    // MARK: - worker

    private func setUpConverter(rate: Double) {
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false)
        if rate != Self.outputRate, let i = inFormat, let o = outFormat {
            converter = AVAudioConverter(from: i, to: o)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        } else {
            converter = nil
        }
    }

    private func drain() {
        guard let ctx, let ringL, let ringR, var map = timeMap else { return }
        var mono: [Float] = []
        while true {
            let n = stamps.withUnsafeMutableBufferPointer { tt_tap_read_stamps(ctx, $0.baseAddress!, UInt32($0.count)) }
            if n == 0 { break }
            for i in 0..<Int(n) {
                let s = stamps[i]
                let frames = Int(s.frames)
                timeMap = map
                if s.host_time != 0 {
                    switch map.observe(host: HostClock.nanos(fromMachTicks: s.host_time), frames: frames, ioPeriodFrames: ioPeriod) {
                    case .contiguous: break
                    case let .fillZeros(z):
                        mono.append(contentsOf: repeatElement(0, count: z))
                        onEvent?(.gapFilled(ms: Int(Double(z) * 1000 / tapSampleRate)))
                    case let .restart(gapMs):
                        flush(&mono)
                        converter?.reset()
                        // The new sample range starts after the gap, without old SRC tails.
                        out16kFrames = Int64((Double(map.framesSoFar - Int64(frames)) * Self.outputRate / tapSampleRate).rounded())
                        timeMap = map
                        onEvent?(.restartNeeded(gapMs: gapMs))
                    }
                }
                let want = UInt32(min(frames, scratchL.count))
                let gotL = scratchL.withUnsafeMutableBufferPointer { tt_ring_read(ringL, $0.baseAddress!, want) }
                let gotR = scratchR.withUnsafeMutableBufferPointer { tt_ring_read(ringR, $0.baseAddress!, gotL) }
                let k = Int(min(gotL, gotR))
                for j in 0..<k { mono.append((scratchL[j] + scratchR[j]) * 0.5) }
            }
            if n < UInt32(stamps.count) { break }
        }
        timeMap = map
        let dropped = tt_tap_dropped_stamps(ctx)
        if dropped > 0, dropped % 100 == 1 { onEvent?(.droppedStamps(Int(dropped))) }
        flush(&mono)
    }

    /// Resamples `mono` (tap rate) to 16 kHz and delivers it.
    private func flush(_ mono: inout [Float]) {
        guard !mono.isEmpty else { return }
        defer { mono.removeAll(keepingCapacity: true) }
        let out: [Float]
        if let converter, let inFormat, let outFormat {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(mono.count)) else { return }
            inBuf.frameLength = AVAudioFrameCount(mono.count)
            mono.withUnsafeBufferPointer { src in inBuf.floatChannelData![0].update(from: src.baseAddress!, count: mono.count) }
            let cap = AVAudioFrameCount(Double(mono.count) * Self.outputRate / inFormat.sampleRate) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: outBuf, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            out = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
        } else {
            out = mono
        }
        guard !out.isEmpty else { return }
        let start = out16kFrames
        out16kFrames += Int64(out.count)
        let tapFrame = Int64((Double(start) * tapSampleRate / Self.outputRate).rounded())
        let host = timeMap?.hostTime(atFrame: tapFrame) ?? HostClock.now()
        if let envelope {
            out.withUnsafeBufferPointer {
                tt_envelope_push(envelope.raw, $0.baseAddress, UInt32($0.count), 1, HostClock.machTicks(fromNanos: host))
            }
        }
        onChunk?(Chunk(samples: out, startFrame: start, hostTime: host))
    }

    private func teardownOnQueue() {
        timer?.cancel()
        timer = nil
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        if let ctx { tt_tap_ctx_destroy(ctx) }
        if let ringL { tt_ring_destroy(ringL) }
        if let ringR { tt_ring_destroy(ringR) }
        ctx = nil; ringL = nil; ringR = nil
        onChunk = nil
        onEvent = nil
        converter = nil
    }

    private func teardown() {
        // deinit: no other reference exists, the queue is idle.
        teardownOnQueue()
    }
}
