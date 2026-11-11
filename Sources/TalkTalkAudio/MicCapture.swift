import CAudioCore
import CoreAudio
import Foundation
import TalkTalkCore

/// Microphone capture on one physical input device (ARCHITECTURE.md, "实时音频与生命周期约束").
///
/// A C IOProc (`tt_mic_ioproc`, CAudioCore) is attached with `AudioDeviceCreateIOProcID` directly
/// on the device and copies one input channel into an SPSC ring (`tt_ring`). A worker queue drains
/// the ring every 10 ms and hands mono Float32 chunks at the device's sample rate to `onChunk`.
/// No AVAudioEngine: it stops itself when the device format changes (§3.2).
///
/// If the device's nominal sample rate changes or the device dies while running, capture stops
/// and `onInterruption` fires once; the caller decides what to do (the enrollment recorder
/// discards the take, §3.6 "物理麦的采样率、格式变化").
///
/// Must run inside TalkTalk.app / TalkTalk-Dev.app started through LaunchServices (§2.2): when
/// TCC denies the microphone, the HAL delivers exact zeros instead of failing.
public final class MicCapture: @unchecked Sendable {
    public struct Chunk: Sendable {
        /// Mono samples at `sampleRate`.
        public let samples: [Float]
        /// Index of `samples[0]` counted from the first frame this capture produced.
        public let startFrame: UInt64
        /// Capture time of the first sample, in HostClock nanoseconds; 0 means HAL supplied none.
        public let hostTime: HostTime
        public init(samples: [Float], startFrame: UInt64, hostTime: HostTime) {
            self.samples = samples; self.startFrame = startFrame; self.hostTime = hostTime
        }
    }

    public enum Interruption: Sendable, Equatable {
        case sampleRateChanged(to: Double)
        case deviceDied
        case formatChanged
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public let what: String
        public var description: String { "\(what): OSStatus \(status)" }
    }

    public struct Stats: Sendable {
        public let callbacks: UInt64
        public let framesFromHAL: UInt64
        public let framesDelivered: UInt64
        public let overrunFrames: UInt64
        public let missingBuffers: UInt64
        public let firstHostTime: UInt64
        public let lastValidHostTime: HostTime
        public let droppedStamps: UInt64
    }

    public let device: InputDeviceInfo
    public let sampleRate: Double
    public let channel: UInt32

    // All mutable state below is touched only on `queue` (or before start / after stop).
    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.mic-worker", qos: .userInteractive)
    private let ring: OpaquePointer
    private let ctx: OpaquePointer
    private var procID: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private var delivered: UInt64 = 0
    private var scratch: [Float]
    private var running = false
    private var inputFormat: InputFormat?
    private var onChunk: (@Sendable (Chunk) -> Void)?
    private var onInterruption: (@Sendable (Interruption) -> Void)?
    private var listeners: HALListenerSet?
    private var epoch: UInt64 = 0
    private var drainMilliseconds: Int
    private var lastValidHost: HostTime = 0
    private var stamps = [tt_mic_stamp](repeating: tt_mic_stamp(), count: Int(TT_MIC_STAMPS))
    private let onQueue = DispatchSpecificKey<Bool>()
    private final class WeakBox: @unchecked Sendable { weak var value: MicCapture?; init(_ value: MicCapture) { self.value = value } }

    /// - Parameter ringSeconds: ring capacity; the worker drains every 10 ms, so 2–4 s is ample.
    public init(device: InputDeviceInfo, channel: UInt32 = 0, ringSeconds: Double = 4, drainMilliseconds: Int = 10) throws {
        guard device.nominalSampleRate > 0 else { throw Failure(status: 0, what: "device has no sample rate") }
        guard Int(channel) < device.inputChannels else { throw Failure(status: 0, what: "channel out of range") }
        self.device = device
        self.sampleRate = device.nominalSampleRate
        self.channel = channel
        self.drainMilliseconds = drainMilliseconds <= 5 ? 5 : 10
        guard let ring = tt_ring_create(UInt32(device.nominalSampleRate * ringSeconds)) else {
            throw Failure(status: 0, what: "tt_ring_create")
        }
        guard let ctx = tt_mic_ctx_create(ring, channel) else {
            tt_ring_destroy(ring)
            throw Failure(status: 0, what: "tt_mic_ctx_create")
        }
        self.ring = ring
        self.ctx = ctx
        self.scratch = [Float](repeating: 0, count: Int(tt_ring_capacity(ring)))
        queue.setSpecific(key: onQueue, value: true)
    }

    deinit {
        stopOnQueue()
        tt_mic_ctx_destroy(ctx)
        tt_ring_destroy(ring)
    }

    public func start(onChunk: @escaping @Sendable (Chunk) -> Void,
                      onInterruption: @escaping @Sendable (Interruption) -> Void) throws {
        try queue.sync {
            guard !running else { return }
            self.onChunk = onChunk
            self.onInterruption = onInterruption
            let id = AudioObjectID(device.objectID)

            // The rate we sized for must still be the device's rate.
            let current: Double = InputDeviceCatalog.scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 0
            guard current == sampleRate else {
                throw Failure(status: 0, what: "sample rate changed before start (\(current) Hz)")
            }

            guard let format = Self.readInputFormat(id) else {
                throw Failure(status: 0, what: "input stream format could not be read before start")
            }
            inputFormat = format
            var proc: AudioDeviceIOProcID?
            var status = AudioDeviceCreateIOProcID(id, tt_mic_ioproc, UnsafeMutableRawPointer(ctx), &proc)
            guard status == noErr, let proc else { throw Failure(status: status, what: "AudioDeviceCreateIOProcID") }
            procID = proc
            registerListeners()
            status = AudioDeviceStart(id, proc)
            guard status == noErr else {
                removeListeners()
                AudioDeviceDestroyIOProcID(id, proc)
                procID = nil
                throw Failure(status: status, what: "AudioDeviceStart")
            }
            running = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(drainMilliseconds), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.drain() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Stops IO, delivers whatever is still in the ring, and returns. Safe to call twice.
    public func stop() {
        if DispatchQueue.getSpecific(key: onQueue) == true { stopOnQueue() } else { queue.sync { stopOnQueue() } }
    }

    public var stats: Stats {
        let read = { [self] in
            Stats(callbacks: tt_mic_callbacks(ctx), framesFromHAL: tt_mic_frames(ctx), framesDelivered: delivered,
                  overrunFrames: tt_mic_dropped_frames(ctx), missingBuffers: tt_mic_missing_buffers(ctx),
                  firstHostTime: tt_mic_first_host_time(ctx), lastValidHostTime: lastValidHost,
                  droppedStamps: tt_mic_dropped_stamps(ctx))
        }
        return DispatchQueue.getSpecific(key: onQueue) == true ? read() : queue.sync(execute: read)
    }

    // MARK: - queue-confined

    private func stopOnQueue(deliverRemaining: Bool = true) {
        guard running || procID != nil else { return }
        timer?.cancel()
        timer = nil
        if let procID {
            AudioDeviceStop(AudioObjectID(device.objectID), procID)
            AudioDeviceDestroyIOProcID(AudioObjectID(device.objectID), procID)
        }
        procID = nil
        removeListeners()
        if running && deliverRemaining { drain() }
        running = false
        inputFormat = nil
        onChunk = nil
        onInterruption = nil
    }

    /// Nonblocking cadence switch, used while passthrough is preparing/open.
    public func setDrainCadence(milliseconds: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            drainMilliseconds = milliseconds <= 5 ? 5 : 10
            timer?.schedule(deadline: .now(), repeating: .milliseconds(drainMilliseconds), leeway: .milliseconds(1))
        }
    }

    private func drain() {
        let count = stamps.withUnsafeMutableBufferPointer { tt_mic_read_stamps(ctx, $0.baseAddress!, UInt32($0.count)) }
        for stamp in stamps.prefix(Int(count)) {
            let n = scratch.withUnsafeMutableBufferPointer { tt_ring_read(ring, $0.baseAddress!, stamp.frames) }
            guard n > 0 else { continue }
            let host = stamp.host_time == 0 ? 0 : HostClock.nanos(fromMachTicks: stamp.host_time)
            if host != 0 { lastValidHost = host + HostTime(Double(n) * 1e9 / sampleRate) }
            delivered += UInt64(n)
            onChunk?(Chunk(samples: Array(scratch.prefix(Int(n))), startFrame: stamp.frame_index, hostTime: host))
        }
    }

    private func registerListeners() {
        epoch += 1
        let generation = epoch, queue = self.queue, box = WeakBox(self)
        let set = HALListenerSet(label: "com.aaajiao.talktalk.mic-listeners") { key in
            queue.async { [box] in
                guard let owner = box.value, owner.epoch == generation else { return }
                owner.propertyChanged(key.selector)
            }
        }
        let id = AudioObjectID(device.objectID)
        var keys: Set<HALListenerSet.Key> = [
            .init(id, kAudioDevicePropertyNominalSampleRate), .init(id, kAudioDevicePropertyDeviceIsAlive),
            .init(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
            .init(id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        for stream in inputFormat?.streamIDs ?? [] {
            keys.insert(.init(stream, kAudioStreamPropertyVirtualFormat))
        }
        listeners = set
        set.set(keys)
        _ = set.current
    }

    private func removeListeners() {
        epoch += 1
        listeners?.stop()
        listeners = nil
    }

    /// Values affecting the copied input channel. Buffer pointers/byte counts and ASBD's
    /// reserved padding are not a format change when HAL announces start/stop bookkeeping.
    struct InputFormat: Equatable {
        var streamIDs: [AudioObjectID]
        var channelsPerBuffer: [Int]
        var formats: [AudioStreamBasicDescription]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.streamIDs == rhs.streamIDs && lhs.channelsPerBuffer == rhs.channelsPerBuffer
                && lhs.formats.count == rhs.formats.count
                && zip(lhs.formats, rhs.formats).allSatisfy { a, b in
                    a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID
                        && a.mFormatFlags == b.mFormatFlags && a.mBytesPerPacket == b.mBytesPerPacket
                        && a.mFramesPerPacket == b.mFramesPerPacket && a.mBytesPerFrame == b.mBytesPerFrame
                        && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
                }
        }
    }

    static func formatInterruption(previous: InputFormat?, current: InputFormat?) -> Interruption? {
        guard let previous, let current, previous == current else { return .formatChanged }
        return nil
    }

    private static func readInputFormat(_ id: AudioObjectID) -> InputFormat? {
        guard let streams = HALReads.objectList(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
              !streams.isEmpty,
              let channels = MonitorOutput.channelsPerBuffer(id, kAudioObjectPropertyScopeInput),
              channels.contains(where: { $0 > 0 }) else { return nil }
        var formats: [AudioStreamBasicDescription] = []
        for stream in streams {
            guard let format: AudioStreamBasicDescription = InputDeviceCatalog.scalar(stream, kAudioStreamPropertyVirtualFormat),
                  format.mSampleRate.isFinite, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { return nil }
            formats.append(format)
        }
        return InputFormat(streamIDs: streams, channelsPerBuffer: channels, formats: formats)
    }

    private func propertyChanged(_ selector: AudioObjectPropertySelector) {
        guard running else { return }
        let id = AudioObjectID(device.objectID)
        var interruption: Interruption?
        switch selector {
        case kAudioDevicePropertyNominalSampleRate:
            let rate: Double = InputDeviceCatalog.scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 0
            if rate != sampleRate { interruption = .sampleRateChanged(to: rate) }
        case kAudioDevicePropertyDeviceIsAlive:
            let alive: UInt32 = InputDeviceCatalog.scalar(id, kAudioDevicePropertyDeviceIsAlive) ?? 0
            if alive == 0 { interruption = .deviceDied }
        case kAudioDevicePropertyStreams, kAudioDevicePropertyStreamConfiguration, kAudioStreamPropertyVirtualFormat:
            let current = Self.readInputFormat(id)
            interruption = Self.formatInterruption(previous: inputFormat, current: current)
            // HAL can announce the unchanged format while starting/waking the input device.
            // Keep metadata only so a real-device failure can be distinguished from a bad stamp.
            NSLog("mic.capture format_notification selector=%u result=%@", selector,
                  current == nil ? "read_failed" : (interruption == nil ? "unchanged" : "changed"))
        default:
            break
        }
        guard let interruption else { return }
        NSLog("mic.capture interruption selector=%u", selector)
        let handler = onInterruption
        stopOnQueue(deliverRemaining: false)
        handler?(interruption)
    }
}
