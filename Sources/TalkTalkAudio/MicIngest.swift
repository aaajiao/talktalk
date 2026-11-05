import AVFoundation
import CoreAudio
import Foundation
import TalkTalkCore

/// Small capture boundary used by the worker and fake-device tests. No other SPEAK owner opens a mic.
public protocol SpeakCapture: AnyObject, Sendable {
    var device: InputDeviceInfo { get }
    var sampleRate: Double { get }
    func start(onChunk: @escaping @Sendable (MicCapture.Chunk) -> Void,
               onInterruption: @escaping @Sendable (MicCapture.Interruption) -> Void) throws
    func stop()
    func setDrainCadence(milliseconds: Int)
}
extension MicCapture: SpeakCapture {}

/// Physical microphone owner for SPEAK and passthrough. HAL and SRC work never runs on the key thread.
public final class MicIngest: SpeakMicSource, @unchecked Sendable {
    public struct Stats: Sendable {
        public var blocks = 0, frames16k = 0, onsets = 0, rateRestarts = 0, droppedBlocks = 0
        public var deviceRate = 0.0, audioSeconds = 0.0
        public var firstHost: HostTime = 0, lastHost: HostTime = 0
    }
    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.speak-mic", qos: .userInteractive)
    private let lock = NSLock()
    private var reported = SpeakMicState(capture: .closed, physicalMicPassesRule2: false)
    private var numbers = Stats()
    private var reservation: UInt64?
    private var releasedReservation: UInt64?
    /// A newly accepted press can shorten only an already-released press's remaining tail.
    /// Read by the worker before consuming queued VAD frames, so they cannot cross the new floor.
    private var handoffEnds: [UInt64: HostTime] = [:]
    private var stopped = false
    private let profile: PolicyProfile.Speak
    private let devices: @Sendable () -> [InputDeviceInfo]
    private let userUID: @Sendable () -> String?
    private let factory: @Sendable (InputDeviceInfo) throws -> any SpeakCapture
    private let onBlock: @Sendable (MicBlock) -> Void
    private let onVAD: @Sendable (SpeakVAD.Event) -> Void
    private let onState: @Sendable (SpeakMicState) -> Void
    private let onSystemEvent: @Sendable (PassthroughSystemEvent, HostTime) -> Void
    private let watchHAL: Bool
    private var listeners: HALListenerSet?
    private var capture: (any SpeakCapture)?
    private var generation: UInt64 = 0
    private var hot = false, passthrough = false
    private let ring = SpeakMicRing()
    private let vad: SpeakVAD
    private var converter: AVAudioConverter?
    private var outputFrames: UInt64 = 0
    private var inputFrames: UInt64 = 0
    private var expectedRawFrame: UInt64?
    private var rawEnd: HostTime?
    private var previousClipEnd: HostTime?
    private var history: [SpeakVAD.Frame] = []
    private var current: Press?
    private var segmenter: SpeakSegmenter?
    private let target: Lang
    private let charactersPerSecond: @Sendable () -> Double?
    private var index = 0
    private var idleTimer: DispatchSourceTimer?

    public init(profile: PolicyProfile.Speak, target: Lang = .en,
                charactersPerSecond: @escaping @Sendable () -> Double? = { nil }, userUID: @escaping @Sendable () -> String? = { nil },
                onBlock: @escaping @Sendable (MicBlock) -> Void = { _ in },
                onVAD: @escaping @Sendable (SpeakVAD.Event) -> Void = { _ in },
                onState: @escaping @Sendable (SpeakMicState) -> Void = { _ in },
                onSystemEvent: @escaping @Sendable (PassthroughSystemEvent, HostTime) -> Void = { _, _ in },
                devices: @escaping @Sendable () -> [InputDeviceInfo] = InputDeviceCatalog.inputDevices,
                makeCapture: @escaping @Sendable (InputDeviceInfo) throws -> any SpeakCapture = { try MicCapture(device: $0) },
                watchHAL: Bool = true, vad: SpeakVAD? = nil) throws {
        self.profile = profile; self.target = target; self.charactersPerSecond = charactersPerSecond; self.userUID = userUID; self.devices = devices; factory = makeCapture
        self.onBlock = onBlock; self.onVAD = onVAD; self.onState = onState; self.onSystemEvent = onSystemEvent
        self.watchHAL = watchHAL; self.vad = try vad ?? SpeakVAD()
    }
    deinit { current?.finish(); idleTimer?.cancel(); capture?.stop(); listeners?.stop() }
    public var state: SpeakMicState { lock.withLock { reported } }
    public var stats: Stats { lock.withLock { numbers } }

    /// HotMicPolicy's result. This alone never grants permission to send samples anywhere.
    public func setHot(_ on: Bool) { queue.async { [weak self] in self?.hot = on; self?.reconcile() } }
    /// Cold passthrough opens only after its hold/preparation requested capture; also uses 5 ms drains.
    public func setPassthroughCadence(_ preparingOrOpen: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            passthrough = preparingOrOpen
            capture?.setDrainCadence(milliseconds: preparingOrOpen ? 5 : 10)
            reconcile()
        }
    }
    public func refreshDevices() { queue.async { [weak self] in self?.reconcile(checkDevice: true) } }
    public func stop() {
        lock.withLock { stopped = true; reservation = nil; releasedReservation = nil; handoffEnds.removeAll() }
        // A stopped owner may be released immediately; retain it until both streams are closed.
        queue.async { [self] in
            finishPress(cancelled: true); hot = false; passthrough = false
            closeCapture(); ring.reset(); listeners?.stop(); listeners = nil
            idleTimer?.cancel(); idleTimer = nil
        }
    }

    public func beginPress(id: UInt64, keyDownAt: HostTime, passthroughClosedAt: HostTime?) -> (any SpeakPressAudio)? {
        let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            if let old = reservation {
                guard releasedReservation == old else { return false }
                handoffEnds[old] = keyDownAt
            }
            reservation = id; releasedReservation = nil
            return true
        }
        guard accepted else { return nil }
        let press = Press(id: id, preview: { [weak self] text, through, at, final in
            self?.queue.async { [weak self] in
                guard let self, current?.id == id else { return }
                emit(segmenter?.preview(stableText: text, through: through, at: at, isFinal: final) ?? [])
            }
        }, release: { [weak self] time, _ in
            self?.requestRelease(id: id, at: time)
        }, cancel: { [weak self] in
            self?.queue.async { [weak self] in
                guard self?.current?.id == id else { return }
                self?.finishPress(cancelled: true); self?.reconcile()
            }
        })
        queue.async { [weak self] in
            guard let self, !lock.withLock({ stopped }) else { press.finish(); return }
            if current != nil { finishForHandoff(at: keyDownAt) }
            current = press; index = 0
            let floor = PrerollFloor.compute(keyDown: keyDownAt, prerollMs: profile.ptt.prerollMs,
                                            previousClipEnd: previousClipEnd, passthroughClosedAt: passthroughClosedAt)
            ring.beginPress(floor: floor)
            segmenter = SpeakSegmenter(profile: profile, target: target, start: floor,
                                        charactersPerSecond: charactersPerSecond())
            if let end = ring.endHostTime, let clip = ring.read(from: floor, to: end) { preview(clip) }
            for frame in history where frame.end > floor { consume(frame) }
            reconcile()
        }
        return press
    }

    private func requestRelease(id: UInt64, at host: HostTime) {
        lock.withLock {
            guard reservation == id else { return }
            releasedReservation = id
            // Enqueue before another begin can accept the handoff.
            queue.async { [weak self] in self?.release(id: id, at: host) }
        }
    }

    private func finishForHandoff(at host: HostTime) {
        emit(segmenter?.finish(at: host) ?? [])
        previousClipEnd = max(previousClipEnd ?? 0, host)
        finishPress(cancelled: false)
    }

    private func release(id: UInt64, at host: HostTime) {
        guard current?.id == id else { return }
        emit(segmenter?.release(at: host) ?? [])
        if segmenter?.finished == true { finishPress(cancelled: false); reconcile() }
    }
    private func setState(_ state: SpeakMicState) {
        let changed = lock.withLock { () -> Bool in
            guard reported != state else { return false }; reported = state; return true
        }
        if changed { onState(state) }
    }
    private func chosenDevice() -> InputDeviceInfo? {
        let list = devices()
        let values = list.map { MicPolicy.Device(uid: $0.uid, name: $0.name, transport: $0.transport, isAggregate: $0.isAggregate, isAlive: $0.isAlive) }
        guard let uid = MicPolicy.select(values, userUID: userUID()).device?.uid else { return nil }
        return list.first { $0.uid == uid }
    }
    private func reconcile(checkDevice: Bool = false) {
        guard !lock.withLock({ stopped }) else { return }
        ensureWatching()
        guard hot || passthrough || current != nil else { closeCapture(); return }
        guard let device = chosenDevice() else {
            if capture != nil { changed(.micUnplugged) }
            closeCapture(); finishPress(cancelled: true)
            setState(.init(capture: .noDevice, physicalMicPassesRule2: false)); return
        }
        if let capture {
            if checkDevice && capture.device != device { changed(capture.device.uid == device.uid ? .micFormatChanged : .micUnplugged) }
            else { return }
        }
        do {
            let new = try factory(device)
            capture = new; generation += 1
            let epoch = generation, rate = new.sampleRate
            resetAnalysis()
            try new.start(onChunk: { [weak self] chunk in
                self?.queue.async { [weak self] in
                    guard let self, generation == epoch, capture != nil else { return }
                    receive(chunk, rate: rate)
                }
            }, onInterruption: { [weak self] reason in
                self?.queue.async { [weak self] in
                    guard let self, generation == epoch else { return }
                    if case .sampleRateChanged = reason { lock.withLock { numbers.rateRestarts += 1 } }
                    changed(reason == .deviceDied ? .micUnplugged : .micFormatChanged)
                    reconcile()
                }
            })
            new.setDrainCadence(milliseconds: passthrough ? 5 : 10)
            lock.withLock { numbers.deviceRate = new.sampleRate }
            setState(.init(capture: .open, physicalMicPassesRule2: true))
        } catch {
            closeCapture(); finishPress(cancelled: true)
            setState(.init(capture: .noDevice, physicalMicPassesRule2: false))
        }
    }
    private func closeCapture() {
        generation += 1
        let old = capture; capture = nil; old?.stop()
        setState(.init(capture: .closed, physicalMicPassesRule2: chosenDevice() != nil))
    }
    private func changed(_ event: PassthroughSystemEvent) {
        onSystemEvent(event, HostClock.now()) // MUST precede reselecting/opening another physical microphone.
        if let end = ring.endHostTime { emit(segmenter?.finish(at: end) ?? []) }
        finishPress(cancelled: false)
        closeCapture(); resetAnalysis()
    }
    private func resetAnalysis() {
        ring.reset(); vad.reset(); converter = nil; outputFrames = 0; inputFrames = 0
        expectedRawFrame = nil; rawEnd = nil; history.removeAll()
    }
    private func receive(_ chunk: MicCapture.Chunk, rate: Double) {
        guard chunk.hostTime != 0 else {
            lock.withLock { numbers.droppedBlocks += 1 }
            onSystemEvent(.micFormatChanged, HostClock.now())
            finishPress(cancelled: true); resetAnalysis(); reconcile(); return
        }
        let discontinuous = expectedRawFrame.map { $0 != chunk.startFrame } ?? false
        let cycleNs = UInt64(Double(max(1, chunk.samples.count)) * 1e9 / rate)
        let gap = rawEnd.map { end in
            (end > chunk.hostTime ? end - chunk.hostTime : chunk.hostTime - end) > cycleNs
        } ?? false
        if discontinuous || gap {
            onSystemEvent(.micFormatChanged, chunk.hostTime)
            if let end = ring.endHostTime { emit(segmenter?.finish(at: end) ?? []) }
            finishPress(cancelled: false); resetAnalysis()
        }
        expectedRawFrame = chunk.startFrame + UInt64(chunk.samples.count)
        let priorInputFrames = inputFrames
        inputFrames += UInt64(chunk.samples.count)
        let end = chunk.hostTime + UInt64(Double(chunk.samples.count) * 1e9 / rate)
        rawEnd = end
        lock.withLock {
            numbers.blocks += 1; numbers.audioSeconds += Double(chunk.samples.count) / rate
            if numbers.firstHost == 0 { numbers.firstHost = chunk.hostTime }; numbers.lastHost = end
        }
        onBlock(MicBlock(origin: .mic, hostTime: chunk.hostTime, sampleRate: rate, samples: chunk.samples))
        do {
            let samples = try convert(chunk.samples, rate: rate)
            // SRC can retain a fractional frame from the previous input block. Map its next
            // output back from THIS hardware timestamp, not from a growing nominal timeline.
            let pendingNs = (Double(priorInputFrames) / rate - Double(outputFrames) / 16_000) * 1e9
            let host: HostTime
            if pendingNs >= 0 { host = chunk.hostTime > UInt64(pendingNs) ? chunk.hostTime - UInt64(pendingNs) : 0 }
            else { host = chunk.hostTime + UInt64(-pendingNs) }
            outputFrames += UInt64(samples.count)
            ring.append(samples, at: host)
            lock.withLock { numbers.frames16k += samples.count }
            if current != nil, !samples.isEmpty, let clip = ring.readLatestBlock() { preview(clip) }
            let result = vad.push(samples, at: host)
            for event in result.events {
                if case .began = event { lock.withLock { numbers.onsets += 1 } }
                onVAD(event)
            }
            history.append(contentsOf: result.frames)
            let floor = end > 1_000_000_000 ? end - 1_000_000_000 : 0
            history.removeAll { $0.end <= floor }
            for frame in result.frames { consume(frame) }
            if current == nil { ring.clearIdle(before: floor) }
            if segmenter?.finished == true { finishPress(cancelled: false); reconcile() }
            else if discontinuous || gap { reconcile() }
        } catch {
            changed(.micFormatChanged)
            reconcile()
        }
    }
    private func consume(_ frame: SpeakVAD.Frame) {
        guard let current else { return }
        if let boundary = lock.withLock({ handoffEnds[current.id] }), frame.end >= boundary {
            if frame.start < boundary {
                emit(segmenter?.audio(.init(start: frame.start, end: boundary, speech: frame.voiced,
                                           energy: pow(10, frame.rmsDb / 10))) ?? [])
            }
            finishForHandoff(at: boundary)
            return
        }
        emit(segmenter?.audio(.init(start: frame.start, end: frame.end, speech: frame.voiced,
                                   energy: pow(10, frame.rmsDb / 10))) ?? [])
    }
    private func preview(_ clip: PCMClip16k) {
        let int16 = clip.samples.map { Int16(clamping: Int((max(-1, min(1, $0)) * 32767).rounded())) }
        let power = clip.samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, clip.samples.count))
        current?.previewContinuation.yield(.init(samples: int16, at: clip.start, level: power.squareRoot()))
    }
    private func emit(_ cuts: [SpeakSegmenter.Commit]) {
        guard let current else { return }
        for cut in cuts {
            guard let pcm = ring.read(from: cut.start, to: cut.end) else { continue }
            current.clipContinuation.yield(.init(pcm: pcm, index: index, isFinal: cut.isFinalChunk, speechMs: cut.speechMs, cutReason: Self.reason(cut.reason)))
            index += 1; previousClipEnd = max(previousClipEnd ?? 0, pcm.end)
        }
    }
    private static func reason(_ reason: SpeakSegmenter.Reason) -> SpeakClip.CutReason {
        switch reason {
        case .release: .release
        case .silence, .forcedDip: .vadDip
        case .hardCap: .energyMinimum
        case .punctuation, .asrFinal, .stall: .limit
        }
    }
    private func finishPress(cancelled: Bool) {
        guard let current else { return }
        if cancelled { previousClipEnd = max(previousClipEnd ?? 0, ring.endHostTime ?? 0, HostClock.now()) }
        current.finish(); self.current = nil; segmenter = nil
        lock.withLock {
            handoffEnds[current.id] = nil
            if reservation == current.id { reservation = nil; releasedReservation = nil }
        }
    }
    private func convert(_ samples: [Float], rate: Double) throws -> [Float] {
        if rate == 16_000 { return samples }
        guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16_000 / rate) + 512)) else { throw Conversion.failed }
        if converter == nil { converter = AVAudioConverter(from: from, to: to); converter?.primeMethod = .none }
        guard let converter else { throw Conversion.failed }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var fed = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, flag in
            if fed { flag.pointee = .noDataNow; return nil }
            fed = true; flag.pointee = .haveData; return input
        }
        if error != nil || status == .error { throw Conversion.failed }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
    private enum Conversion: Error { case failed }

    private final class WeakBox: @unchecked Sendable { weak var value: MicIngest?; init(_ value: MicIngest) { self.value = value } }
    private func ensureWatching() {
        if idleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self, current == nil else { return }
                let now = HostClock.now(); ring.clearIdle(before: now > 1_000_000_000 ? now - 1_000_000_000 : 0)
            }
            timer.resume(); idleTimer = timer
        }
        guard watchHAL, listeners == nil else { return }
        let queue = self.queue, box = WeakBox(self)
        let keys: Set<HALListenerSet.Key> = [.init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices),
                                             .init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted)]
        let set = HALListenerSet(label: "com.aaajiao.talktalk.speak-mic-devices") { key in
            queue.async { [box] in
                guard let owner = box.value, !owner.lock.withLock({ owner.stopped }) else { return }
                if key.selector == kAudioHardwarePropertyServiceRestarted {
                    owner.listeners?.restart(keys); owner.changed(.coreaudiodRestarted)
                }
                owner.reconcile(checkDevice: true)
            }
        }
        listeners = set; set.set(keys)
    }
}

private final class Press: SpeakPressAudio, @unchecked Sendable {
    let id: UInt64
    let clips: AsyncStream<SpeakClip>
    let preview: AsyncStream<SpeakPreviewFrame>
    let clipContinuation: AsyncStream<SpeakClip>.Continuation
    let previewContinuation: AsyncStream<SpeakPreviewFrame>.Continuation
    private let onPreview: @Sendable (String, HostTime, HostTime, Bool) -> Void
    private let onRelease: @Sendable (HostTime, PushToTalkMachine.ReleaseReason) -> Void
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var ended = false, released = false
    init(id: UInt64, preview: @escaping @Sendable (String, HostTime, HostTime, Bool) -> Void, release: @escaping @Sendable (HostTime, PushToTalkMachine.ReleaseReason) -> Void, cancel: @escaping @Sendable () -> Void) {
        self.id = id; onPreview = preview; onRelease = release; onCancel = cancel
        (clips, clipContinuation) = AsyncStream.makeStream()
        (self.preview, previewContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(100))
    }
    func updatePreview(stableText: String, through: HostTime, at: HostTime, isFinal: Bool) {
        if !lock.withLock({ ended }) { onPreview(stableText, through, at, isFinal) }
    }
    func release(at: HostTime, reason: PushToTalkMachine.ReleaseReason) {
        let send = lock.withLock { () -> Bool in guard !ended, !released else { return false }; released = true; return true }
        if send { onRelease(at, reason) }
    }
    func cancel() {
        let send = lock.withLock { () -> Bool in guard !ended else { return false }; ended = true; return true }
        if send { onCancel() }
        clipContinuation.finish(); previewContinuation.finish()
    }
    func finish() { lock.withLock { ended = true }; clipContinuation.finish(); previewContinuation.finish() }
}
