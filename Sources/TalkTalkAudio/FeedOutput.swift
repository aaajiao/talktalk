import CAudioCore
import CoreAudio
import Foundation
import Synchronization
import TalkTalkCore

/// The output to the meeting (ARCHITECTURE.md, "实时音频与生命周期约束"): feedIOProc (C,
/// `tt_feed_ioproc`) attached with `AudioDeviceCreateIOProcID` on the hidden "TalkTalk Feed",
/// found by `DriverPins.feedUID`. 48 kHz Float32, 2 output channels, no SRC. Channel 1 goes to
/// TalkTalk Mic (the meeting), channel 2 to Test Mic (self-test only).
///
/// Audio reaches it on exactly two paths, both rings it owns, never an API that takes samples:
///  - TTS: `ClauseQueue` (after PlayoutStage) writes `ringO` through the `PlayoutRing` contract;
///  - passthrough: `PassthroughStage` (this module) writes ringP from the gate's PassthroughFrames.
/// ringP is internal, so nothing outside TalkTalkAudio can reach it (check-audio-paths AP4/AP5/AP10).
/// Every IO cycle plays one source, never a mix (tt_ioproc_feed.h).
///
/// `ringO` (made by the app with `maxLeadFrames` from PolicyProfile, held by ClauseQueue too) and
/// `events` (shared with MonitorOutput) come from outside; ringP, `passthroughState` and
/// `envelope` are made here. All of them live as long as the FeedOutput; an
/// attachment (IOProc + tt_feed_ctx) is made by `attach` and undone by `detach` or an
/// interruption, so the Feed can be re-attached after a coreaudiod restart without new rings.
/// Each attachment starts with a new context (mode ringO, resume threshold at its floor), which
/// takes the passthrough generation current at that moment as finished: after any detach or
/// interruption, passthrough plays again only after a new open (a new, clean press, §3.6).
///
/// Who calls what (the wiring rules in §3.3 "FeedOutput"):
///  - the app: `attach` once the driver is there (off the main thread: AudioDeviceStart can take a
///    while), `detach` at quit; `isChannel1Busy` to `DriverComponentModel.forCurrentApp`. The
///    meeting-mode switch 'ttmm' is not FeedOutput's: sysinput uses `CoreAudioMeetingModeSwitch` (§8.6).
///  - coreaudiod restart: SpeakOutput serializes all four notification sources. It closes the
///    gate, detaches Feed, suspends Monitor, resets the session queue, resumes Monitor, then
///    reattaches Feed if wanted. Old attachment callbacks are ignored by the owner's generation.
///  - the audio worker: drains `events` every 10 ms, `ClauseQueue.setFeedResumeFrames(resumeFrames)`,
///    `setChunkIntervalP95(ms:)` from `ClauseQueue.chunkIntervalP95Ms`, reads `envelope` for echoScore.
///  - `passthroughState` is the gate's `PassthroughStateSink`.
public final class FeedOutput: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        /// kAudioHardwareUnspecifiedError ('what') from AudioDeviceStart can be the driver's client
        /// gate (the HAL replaces its kAudioHardwareIllegalOperationError, §8.3): the driver's
        /// diagnostics tell (`DriverDiagnostics.feedAddClientDenied` / `feedStartIODenied`).
        public let status: OSStatus
        public let what: String
        public init(status: OSStatus, what: String) { self.status = status; self.what = what }
        public var description: String { "\(what): OSStatus \(status)" }
    }

    /// Why an attachment ended by itself. The IOProc is stopped and its context destroyed before
    /// the handler runs (on a global queue, so it may call `attach`).
    public enum Interruption: Sendable, Equatable {
        case deviceDied
        case sampleRateChanged(to: Double)
        case serviceRestarted
    }

    public enum Mode: Sendable, Equatable {
        case ringO, ringOToPassthrough, passthrough, passthroughClosing
    }

    public struct Stats: Sendable, Equatable {
        public var attached = false
        /// Of the current attachment, or of the last one after it ended.
        public var callbacks: UInt64 = 0
        public var frames: UInt64 = 0
        public var ringOAudioFrames: UInt64 = 0
        public var ringPAudioFrames: UInt64 = 0
        public var outUnderruns: UInt64 = 0
        public var ptUnderruns: UInt64 = 0
        public var ptOpens: UInt64 = 0
        public var ptLeaseExpiries: UInt64 = 0
        public var ptOutOfIntervalFrames: UInt64 = 0
        /// Cycles with both rings audible: always 0 (privacy invariant 1 is checked on it).
        public var mixedCycles: UInt64 = 0
        public var missingBuffers: UInt64 = 0
        public var mode: Mode = .ringO
        public var resumeFrames: UInt32 = 0
        /// The Feed's IO buffer at attach, read back after asking for TT_FEED_IO_BUFFER_FRAMES (480).
        public var bufferFrames: UInt32 = 0
        public var eventsDropped: UInt64 = 0
        public var ringPFill: UInt32 = 0
        public var ringPOverrunFrames: UInt64 = 0
        public init() {}
    }

    public static let sampleRate = Double(TT_FEED_RATE)
    /// mach ticks per Feed frame (exactly 500 on Apple silicon).
    public static let hostTicksPerFrame = Double(HostClock.machTicks(fromNanos: 1_000_000_000)) / Double(TT_FEED_RATE)

    /// TTS playout ring (48 kHz mono, 2 s, lead 0.5 s), ClauseQueue's `PlayoutRing`.
    public let ringO: RingO
    /// The gate's sink; feedIOProc reads it every cycle.
    public let passthroughState: CPassthroughState
    /// Shared with MonitorOutput; the worker drains it.
    public let events: EventRing
    /// What feedIOProc actually wrote to channel 1, 10 ms RMS at its TalkTalk Mic arrival time.
    public let envelope: EnvelopeHistory
    /// For PassthroughStage only.
    let ringP: PassthroughRing

    /// The tt_feed_ctx of an attachment. Sendable: it is shared only with the IOProc (by its own
    /// rules) and used here only under `state`'s lock.
    private struct Context: @unchecked Sendable { let raw: OpaquePointer }

    private struct Attachment {
        var ctx: Context?
        var p95Frames: UInt32 = 0
        var attachedAt: HostTime?
        var bufferFrames: UInt32 = 0
        var last: Stats = { var s = Stats(); s.resumeFrames = TT_FEED_RESUME_MIN_FRAMES; return s }()
    }

    // `state` is read by the worker and the app (under its lock, never by the IOProc); the device
    // fields below are touched on `queue` only.
    private let state = Mutex(Attachment())
    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.feed-output", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private var device: AudioObjectID?
    private var procID: AudioDeviceIOProcID?
    private var onInterruption: (@Sendable (Interruption) -> Void)?
    /// Bumped by every attach. A listener callback queued before its attachment ended carries the
    /// old value and is ignored, so it cannot tear down a newer attachment.
    private var epoch: UInt64 = 0
    /// The attachment's HAL listeners. §8.6 rule: added and removed on HALListenerSet's own control
    /// queue, never on the queue that delivers them; a callback hops to `queue` with its epoch.
    private var listeners: HALListenerSet?

    /// The context keeps raw pointers to `ringO` and `events`; FeedOutput holds both, so they
    /// outlive every context (tt_ioproc_feed.h).
    public init(ringO: RingO, events: EventRing) throws {
        guard let ringP = PassthroughRing(hostTicksPerFrame: Self.hostTicksPerFrame) else { throw Failure(status: 0, what: "ringP") }
        guard let pt = CPassthroughState() else { throw Failure(status: 0, what: "tt_pt_state_create") }
        guard let env = EnvelopeHistory(windowFrames: TT_ENVELOPE_WINDOW_48K, hostTicksPerFrame: Self.hostTicksPerFrame) else {
            throw Failure(status: 0, what: "tt_envelope_create")
        }
        self.ringO = ringO
        self.ringP = ringP
        self.passthroughState = pt
        self.events = events
        self.envelope = env
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { onQueue { detachOnQueue(interruption: nil) } }

    // MARK: - attach / detach

    /// Resolves the Feed by UID, checks 48 kHz and 2 output channels, and starts feedIOProc on it.
    /// No-op when already attached. Throws when the Feed is missing or wrong, or Core Audio refuses.
    public func attach(onInterruption: @escaping @Sendable (Interruption) -> Void) throws {
        try onQueue {
            guard state.withLock({ $0.ctx == nil }) else { return }
            guard let id = CoreAudioMeetingModeSwitch.translate(uid: DriverPins.feedUID) else {
                throw Failure(status: OSStatus(kAudioHardwareBadDeviceError), what: "TalkTalk Feed not found")
            }
            let rate: Double = InputDeviceCatalog.scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 0
            guard rate == Self.sampleRate else { throw Failure(status: 0, what: "Feed runs at \(rate) Hz, not 48 kHz") }
            let channels = AudioDeviceCatalog.channels(id, kAudioObjectPropertyScopeOutput)
            guard channels == Int(TT_FEED_CHANNELS) else { throw Failure(status: 0, what: "Feed has \(channels) output channels, not 2") }

            // 480 frames, as the driver was measured with (m0-t8) and DriverSelfTest sets; without
            // it the HAL gives this process 512 (m2 --bench feed). feedIOProc copes with any size,
            // so a refusal is not fatal: `stats.bufferFrames` reads back what the HAL took.
            var want = TT_FEED_IO_BUFFER_FRAMES
            var bufAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectSetPropertyData(id, &bufAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &want)

            let ctx = try makeContext()
            var proc: AudioDeviceIOProcID?
            var st = AudioDeviceCreateIOProcID(id, tt_feed_ioproc, UnsafeMutableRawPointer(ctx), &proc)
            guard st == noErr, let proc else {
                tt_feed_ctx_destroy(ctx)
                throw Failure(status: st, what: "AudioDeviceCreateIOProcID")
            }
            device = id
            procID = proc
            self.onInterruption = onInterruption
            epoch &+= 1
            publish(ctx, bufferFrames: InputDeviceCatalog.scalar(id, kAudioDevicePropertyBufferFrameSize) ?? 0)
            listen(to: id)
            st = AudioDeviceStart(id, proc)
            guard st == noErr else {
                detachOnQueue(interruption: nil)
                throw Failure(status: st, what: "AudioDeviceStart")
            }
        }
    }

    /// Stops feedIOProc and destroys its context; the rings and states stay. Safe to call twice.
    public func detach() { onQueue { detachOnQueue(interruption: nil) } }

    public var isAttached: Bool { state.withLock { $0.ctx != nil } }
    /// When the current attachment started.
    public var attachedAt: HostTime? { state.withLock { $0.attachedAt } }

    // MARK: - worker / app

    /// `ClauseQueue.chunkIntervalP95Ms` → the ringO rebuffer threshold max(80 ms, 2 × p95)
    /// (tt_ioproc_feed.h). Kept for the next attachment.
    public func setChunkIntervalP95(ms: Double) {
        let frames = ms.isFinite && ms > 0 ? UInt32(clamping: Int((ms * Self.sampleRate / 1000).rounded())) : 0
        state.withLock {
            $0.p95Frames = frames
            if let ctx = $0.ctx { tt_feed_set_chunk_interval_p95_frames(ctx.raw, frames) }
        }
    }

    /// The ringO rebuffer threshold feedIOProc uses now (of the last attachment when detached).
    public var resumeFrames: UInt32 {
        state.withLock { a in a.ctx.map { tt_feed_resume_frames($0.raw) } ?? a.last.resumeFrames }
    }

    public var stats: Stats {
        state.withLock { a in
            guard let ctx = a.ctx else { var s = a.last; s.attached = false; return s }
            return snapshot(ctx.raw, bufferFrames: a.bufferFrames)
        }
    }

    /// Something is or is about to be on channel 1 (DriverSelfTest skips its isolation check):
    /// attached and passthrough holds the Feed, or ringO has unread audio or a clause in progress.
    public var isChannel1Busy: Bool {
        state.withLock { a in
            guard let ctx = a.ctx else { return false }
            if tt_feed_mode(ctx.raw) != TT_FEED_MODE_RING_O { return true }
            if ringO.availableFrames > 0 { return true }
            let s = ringO.playoutState
            return s == .playing || s == .underrun
        }
    }

    // MARK: - tests

    /// The attachment's context without a device: what `attach` does minus Core Audio.
    func attachOffline(onInterruption: (@Sendable (Interruption) -> Void)? = nil) throws {
        try onQueue {
            guard state.withLock({ $0.ctx == nil }) else { return }
            let ctx = try makeContext()
            self.onInterruption = onInterruption
            epoch &+= 1
            publish(ctx, bufferFrames: 0)
        }
    }

    /// The current attachment's listener epoch, and a listener block delivered with a given one.
    var listenerEpoch: UInt64 { onQueue { epoch } }
    func deliverPropertyChange(_ selector: AudioObjectPropertySelector, epoch e: UInt64) {
        onQueue { propertyChanged(selector, epoch: e) }
    }

    /// One IO cycle through the current context, as feedIOProc runs it. False when not attached.
    @discardableResult
    func processOffline(_ list: UnsafeMutablePointer<AudioBufferList>, frames: UInt32, outHostTicks: UInt64) -> Bool {
        state.withLock { a in
            guard let ctx = a.ctx else { return false }
            tt_feed_process(ctx.raw, list, frames, outHostTicks)
            return true
        }
    }

    // MARK: - queue-confined

    private func makeContext() throws -> OpaquePointer {
        var config = tt_feed_config(host_ticks_per_frame: Self.hostTicksPerFrame,
                                    mic_latency_frames: TT_FEED_MIC_LATENCY_FRAMES,
                                    max_cycle_frames: TT_FEED_DEFAULT_MAX_CYCLE_FRAMES)
        guard let ctx = tt_feed_ctx_create(ringO.raw, ringP.raw, passthroughState.raw, events.raw, envelope.raw, &config) else {
            throw Failure(status: 0, what: "tt_feed_ctx_create")
        }
        return ctx
    }

    private func publish(_ raw: OpaquePointer, bufferFrames: UInt32) {
        let ctx = Context(raw: raw)
        state.withLock {
            tt_feed_set_chunk_interval_p95_frames(ctx.raw, $0.p95Frames)
            $0.ctx = ctx
            $0.attachedAt = HostClock.now()
            $0.bufferFrames = bufferFrames
        }
    }

    private func detachOnQueue(interruption: Interruption?) {
        if let id = device, let proc = procID {
            // Known assumption (§3.3 FeedOutput): when AudioDeviceStop returns, the IOProc's last
            // call has finished. Neither the header nor Apple's docs say so; MicCapture and
            // MeetingTap rely on the same.
            AudioDeviceStop(id, proc)
            AudioDeviceDestroyIOProcID(id, proc)
        }
        listeners?.stop()
        listeners = nil
        device = nil
        procID = nil
        let handler = onInterruption
        onInterruption = nil
        let ctx: Context? = state.withLock { a in
            guard let ctx = a.ctx else { return nil }
            a.last = snapshot(ctx.raw, bufferFrames: a.bufferFrames)
            a.ctx = nil
            a.attachedAt = nil
            return ctx
        }
        tt_feed_ctx_destroy(ctx?.raw)
        if let interruption, let handler, ctx != nil {
            DispatchQueue.global(qos: .userInitiated).async { handler(interruption) }
        }
    }

    private func snapshot(_ ctx: OpaquePointer, bufferFrames: UInt32) -> Stats {
        var s = Stats()
        s.attached = true
        s.callbacks = tt_feed_callbacks(ctx)
        s.frames = tt_feed_frames(ctx)
        s.ringOAudioFrames = tt_feed_ring_o_audio_frames(ctx)
        s.ringPAudioFrames = tt_feed_ring_p_audio_frames(ctx)
        s.outUnderruns = tt_feed_out_underruns(ctx)
        s.ptUnderruns = tt_feed_pt_underruns(ctx)
        s.ptOpens = tt_feed_pt_opens(ctx)
        s.ptLeaseExpiries = tt_feed_pt_lease_expiries(ctx)
        s.ptOutOfIntervalFrames = tt_feed_pt_out_of_interval_frames(ctx)
        s.mixedCycles = tt_feed_mixed_cycles(ctx)
        s.missingBuffers = tt_feed_missing_buffers(ctx)
        s.mode = switch tt_feed_mode(ctx) {
        case TT_FEED_MODE_O_TO_P: .ringOToPassthrough
        case TT_FEED_MODE_PT: .passthrough
        case TT_FEED_MODE_PT_CLOSING: .passthroughClosing
        default: .ringO
        }
        s.resumeFrames = tt_feed_resume_frames(ctx)
        s.bufferFrames = bufferFrames
        s.eventsDropped = events.dropped
        s.ringPFill = ringP.fill
        s.ringPOverrunFrames = ringP.overrunFrames
        return s
    }

    /// IsAlive and NominalSampleRate of the Feed, ServiceRestarted of the system; registered before
    /// AudioDeviceStart (`current` waits for the control queue).
    private func listen(to id: AudioObjectID) {
        let e = epoch
        let q = queue
        let owner = AudioWeakReference(self)
        let set = HALListenerSet(label: "com.aaajiao.talktalk.feed-output.listeners") { key in
            // No strong reference on the HAL's delivery queue: a last release there would run deinit,
            // which removes listeners, on the queue that delivers them (§8.6).
            q.async { owner.value?.propertyChanged(key.selector, epoch: e) }
        }
        set.set([.init(id, kAudioDevicePropertyDeviceIsAlive), .init(id, kAudioDevicePropertyNominalSampleRate),
                 .init(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted)])
        _ = set.current
        listeners = set
    }

    /// Runs on `queue`. `e`: the epoch of the attachment that registered it.
    private func propertyChanged(_ selector: AudioObjectPropertySelector, epoch e: UInt64) {
        guard e == epoch, state.withLock({ $0.ctx != nil }) else { return }
        var interruption: Interruption?
        switch selector {
        case kAudioHardwarePropertyServiceRestarted:
            interruption = .serviceRestarted
        case kAudioDevicePropertyDeviceIsAlive:
            guard let id = device else { return }
            let alive: UInt32 = InputDeviceCatalog.scalar(id, kAudioDevicePropertyDeviceIsAlive) ?? 0
            if alive == 0 { interruption = .deviceDied }
        case kAudioDevicePropertyNominalSampleRate:
            guard let id = device else { return }
            let rate: Double = InputDeviceCatalog.scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 0
            if rate != Self.sampleRate { interruption = .sampleRateChanged(to: rate) }
        default:
            break
        }
        if let interruption { detachOnQueue(interruption: interruption) }
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? try body() : try queue.sync(execute: body)
    }
}

/// ringP (tt_ringp.h, §3.8): passthrough's own ring, 48 kHz mono, 200 ms, blocks stamped with
/// capture host time and generation. FeedOutput owns it; PassthroughStage (this module) is the
/// only writer, feedIOProc the only reader (check-audio-paths AP4, AP5, AP10). Internal on purpose.
final class PassthroughRing: @unchecked Sendable {
    let raw: OpaquePointer

    init?(hostTicksPerFrame: Double) {
        guard let r = tt_ringp_create(hostTicksPerFrame) else { return nil }
        raw = r
    }

    deinit { tt_ringp_destroy(raw) }

    var fill: UInt32 { tt_ringp_fill(raw) }
    var writtenFrames: UInt64 { tt_ringp_written_frames(raw) }
    var overrunFrames: UInt64 { tt_ringp_overrun_frames(raw) }
}
