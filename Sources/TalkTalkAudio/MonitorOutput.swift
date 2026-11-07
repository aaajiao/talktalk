// l10n: zh-Hans (scripts/check-strings.sh)
import AVFoundation
import CAudioCore
import CoreAudio
import Foundation
import Synchronization
import TalkTalkCore

/// The monitor output (ARCHITECTURE.md §3.4): monitorIOProc (C, `tt_monitor_ioproc`) on the
/// current default output device. It follows the default output (rebuilt when it changes) and
/// never changes it: no rate, buffer size, volume or default-device writes.
///
/// What it plays, all of it only here and never on the Feed / TalkTalk Mic:
///  - self-listen: `ringO2`, ClauseQueue's mirror of ringO (48 kHz), at −10 dB (adjustable). It is
///    audible only when `selfListen == .audible`: the `.selfListen` use is on, this device is
///    headphones, the meeting is known not to be in speaker mode, and the device runs at 48 kHz
///    (no rate conversion on the IO thread). Otherwise the gain is 0 and ringO2 is still read,
///    so its pauses and jumps behave as ClauseQueue expects.
///  - cues (passthrough, MeetingMicGuard): `playCue`, only with the `.cues` use on and the device
///    classified as headphones (`cuesAudible`), rendered at the device rate into this
///    attachment's cue ring.
///  - the voice audition (§9.2 step 7): `playAudition`, any device class outside meeting mode
///    (`setMeetingMode`: unavailable there), resampled to the device rate off the IO thread,
///    streamed through the same cue ring. A cue interrupts it.
/// The cue ring has its own gain: 1 while cues are audible or an audition holds the ring (outside
/// meeting mode), else 0, ramped over one cycle. The ring is read every cycle either way, so a
/// cue queued on headphones is dropped within one cycle when the same device turns into its
/// speaker (Intel built-in 'hdpn' → 'ispk').
///
/// It attaches only while a use is on or an audition plays (or fades out): an IOProc keeps the
/// device running. Every attachment turns all of the device's input streams off for this IOProc
/// (`kAudioDevicePropertyIOProcStreamUsage`, read back; `Stats.inputStreamsDisabled` is what the
/// read-back confirmed) so a Bluetooth headset is not pulled into HFP (C11); a device whose inputs
/// cannot be turned off is refused. TalkTalk's own devices and outputs that are not Float32 are
/// refused too. On a device with more than two output channels only the preferred stereo pair
/// (`kAudioDevicePropertyPreferredChannelsForStereo` through the output stream layout) is written.
/// A failed attach to the current default output is retried (0.5 s doubling to 5 s, at most 8
/// times) unless the refusal is permanent; any new trigger starts the retries again.
///
/// HAL listeners follow the §8.6 rule: registered and removed through `HALListenerSet` (its own
/// control queue), never on the queue that delivers them; a callback hops to this object's queue
/// with the epoch of its registration, so one queued before a rebuild cannot touch the new one.
///
/// The setters and `playCue` never wait (an attach can take hundreds of ms on Bluetooth): they
/// queue the change; the published state (`selfListen`, `cuesAudible`, `stats`, …) follows, and a
/// `.route` change says when to read it. `suspend()` is the one call that waits: the restart
/// sequence needs the IOProc stopped when it returns.
///
/// Wiring (§3.4 "MonitorOutput"): on every `.route` change the app re-reads `isSelfListenAudible`
/// (→ `ClauseQueue.setMonitorEnabled`) and `cuesAudible` (→ the gate's `setCueAudible`, with the
/// cue setting). `setMeetingSpeakerMode` takes `OutputRouteClassifier.isSpeakerMode`; nil (not
/// known) keeps self-listen off. SpeakOutput owns restart recovery: close gate, detach Feed,
/// suspend Monitor, reset the current session queue, resume Monitor, then attach Feed if wanted.
/// The generation-tagged restart callback lets it ignore notifications from an old attachment.
public final class MonitorOutput: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let status: OSStatus
        public let what: String
        /// False for a refusal a retry cannot fix (TalkTalk's own device, input streams that cannot
        /// be turned off, a format monitorIOProc cannot write) or one a listener reports the end of
        /// (no default output): no retry for it.
        public let transient: Bool
        public init(status: OSStatus, what: String, transient: Bool = true) {
            self.status = status; self.what = what; self.transient = transient
        }
        public var description: String { status == 0 ? what : "\(what): OSStatus \(status)" }
    }

    /// Why the output should be attached. The audition holds it by itself while it plays.
    public enum Use: Sendable, Hashable {
        /// Self-listen is on in settings and TTS may play (audible only per `selfListen`).
        case selfListen
        /// Cues are enabled and meeting mode is on: keeps the device open, so a cue plays at once
        /// (attaching can take hundreds of ms, more on Bluetooth).
        case cues
    }

    /// Whether ringO2 is audible now, or why not.
    public enum SelfListen: Sendable, Equatable {
        case audible
        /// The `.selfListen` use is off.
        case off
        /// Not attached: no usable default output, refused, or suspended.
        case noOutput
        /// This device is not classified as headphones (§3.7: forced off in speaker mode).
        case notHeadphones
        /// The meeting's outputs are a speaker, or not known yet (nil).
        case meetingSpeaker
        /// The device does not run at 48 kHz, ringO2's rate.
        case sampleRate(Double)
    }

    public enum Change: Sendable, Equatable {
        /// The device, its route or what is audible changed: re-read the properties.
        case route
        /// coreaudiod restarted: detached and suspended until `resume()`.
        case serviceRestarted
    }

    public enum AuditionError: Error, Equatable, CustomStringConvertible {
        case unavailable(String)
        case interrupted(String)
        public var description: String {
            switch self {
            case .unavailable(let why): String(appLocalized: "自听输出不可用：\(why)")
            case .interrupted(let why): String(appLocalized: "试听中断：\(why)")
            }
        }
    }

    public struct Stats: Sendable, Equatable {
        public var attached = false
        public var deviceUID: String?
        public var sampleRate: Double = 0
        public var bufferFrames: UInt32 = 0
        /// Device + stream latency + safety offset of the output scope, in frames (the cue reaches
        /// the ear this much plus one IO buffer after it is written).
        public var latencyFrames: UInt32 = 0
        /// Input streams the read-back confirmed off for this IOProc (0: the device has none).
        public var inputStreamsDisabled = 0
        /// The output slots written, [left buffer, left channel, right buffer, right channel];
        /// empty: every channel (two output channels or fewer).
        public var channelSlots: [UInt32] = []
        /// Of the current attachment, or of the last one after it ended.
        public var callbacks: UInt64 = 0
        public var frames: UInt64 = 0
        public var audioFrames: UInt64 = 0
        public var cueFrames: UInt64 = 0
        public var underruns: UInt64 = 0
        /// The ringO2 gain monitorIOProc is heading to (linear; 0 unless self-listen is audible).
        public var gain: Float = 0
        /// The cue ring gain it is heading to (1 or 0).
        public var cueGain: Float = 0
        public var cueFill: UInt32 = 0
        public var attachments: UInt64 = 0
        public var lastFailure: String?
        public init() {}
    }

    /// ringO2's rate: ClauseQueue writes it with PlayoutStage's 48 kHz output.
    public static let ringO2Rate = 48_000.0
    public static let defaultGainDb: Float = -10
    /// Retries of a failed attach: 0.5 s doubling to 5 s, this many times.
    static let maxRetries = 8
    static var meetingModeReason: String { String(appLocalized: "会议模式中不能试听") }

    /// ClauseQueue's `monitor` ring, made by the app like ringO (§3.3 "RingO 的生命周期").
    public let ringO2: RingO
    /// Shared with FeedOutput; the worker drains it (TT_EV_MON_UNDERRUN).
    public let events: EventRing

    /// The two output slots monitorIOProc writes on a device with more than two output channels:
    /// (buffer index, channel within that buffer) for left and right.
    struct StereoSlots: Sendable, Equatable {
        var leftBuffer: UInt32, leftChannel: UInt32, rightBuffer: UInt32, rightChannel: UInt32
        var array: [UInt32] { [leftBuffer, leftChannel, rightBuffer, rightChannel] }
    }

    /// An output device as attach sees it. Internal: tests build their own.
    struct Target: Sendable, Equatable {
        var id: AudioObjectID
        var device: OutputRouteClassifier.Device
        var sampleRate: Double
        var inputStreams: Int
        var latencyFrames: UInt32 = 0
        /// nil: two output channels or fewer, every channel is written.
        var stereo: StereoSlots? = nil
        /// Its output streams (their VirtualFormat is listened to).
        var outputStreams: [AudioStreamID] = []

        /// The same attachment: what an attachment is built from. Everything else (name,
        /// transport, data source, latency) is followed in place.
        func sameAttachment(as o: Target) -> Bool {
            id == o.id && device.uid == o.device.uid && sampleRate == o.sampleRate && inputStreams == o.inputStreams
                && stereo == o.stereo && outputStreams == o.outputStreams
        }
    }

    /// What MonitorOutput asks of Core Audio. Tests pass their own (`realIO` false: no IOProc, no
    /// listeners, no retry timers; cycles run through `processOffline`).
    struct HAL: Sendable {
        var realIO: Bool
        var defaultOutput: @Sendable () -> AudioObjectID?
        /// `MonitorOutput.describe`: throws a `Failure` for a device it cannot attach to.
        var describe: @Sendable (AudioObjectID) throws -> Target
        var isAlive: @Sendable (AudioObjectID) -> Bool
        /// Every input stream off for the IOProc (nil without real IO), read back: how many the
        /// read-back lists as off. Throws a `Failure` when the HAL refuses.
        var turnOffInputStreams: @Sendable (AudioObjectID, AudioDeviceIOProcID?, Int) throws -> Int
        var bufferFrames: @Sendable (AudioObjectID) -> UInt32

        static let live = HAL(
            realIO: true,
            defaultOutput: { HALReads.defaultOutput() },
            describe: { try MonitorOutput.describe($0) },
            isAlive: { (InputDeviceCatalog.scalar($0, kAudioDevicePropertyDeviceIsAlive) as UInt32? ?? 0) != 0 },
            turnOffInputStreams: { id, proc, n in
                guard let proc else { throw Failure(status: 0, what: String(appLocalized: "没有 IOProc"), transient: false) }
                return try MonitorOutput.turnOffInputStreams(id, proc: proc, streams: n)
            },
            bufferFrames: { InputDeviceCatalog.scalar($0, kAudioDevicePropertyBufferFrameSize) ?? 0 })
    }

    /// The tt_monitor_ctx and cue ring of an attachment, shared with the IOProc by its rules and
    /// used here only under `state`'s lock.
    private struct Context: @unchecked Sendable {
        let ctx: OpaquePointer
        let cues: OpaquePointer
    }

    /// What a `.route` change reports.
    private struct Route: Equatable {
        var device: OutputRouteClassifier.Device?
        var sampleRate: Double?
        var selfListen: SelfListen = .off
        var cuesAudible = false
    }

    private struct Published {
        var reported = Route()
        var context: Context?
        var target: Target?
        var bufferFrames: UInt32 = 0
        var inputStreamsDisabled = 0
        var selfListen: SelfListen = .off
        var cuesAudible = false
        var attachments: UInt64 = 0
        var lastFailure: String?
        var last = Stats()
    }

    /// Queue-confined.
    private final class Attachment {
        var target: Target
        let ctx: OpaquePointer
        let cues: OpaquePointer
        var procID: AudioDeviceIOProcID?
        var bufferFrames: UInt32
        var lead: Int
        var inputStreamsDisabled = 0
        var cueWasQueued = false
        var emptySince: (callbacks: UInt64, at: HostTime)?
        var listeners: HALListenerSet?
        init(target: Target, ctx: OpaquePointer, cues: OpaquePointer, bufferFrames: UInt32) {
            self.target = target; self.ctx = ctx; self.cues = cues; self.bufferFrames = bufferFrames
            lead = MonitorOutput.leadFrames(rate: target.sampleRate, bufferFrames: bufferFrames,
                                            capacity: Int(tt_ring_capacity(cues)))
        }
    }

    /// Queue-confined.
    private final class Audition {
        let id: UInt64
        let samples: [Float]
        var pos = 0
        let cont: CheckedContinuation<Void, any Error>
        init(id: UInt64, samples: [Float], cont: CheckedContinuation<Void, any Error>) {
            self.id = id; self.samples = samples; self.cont = cont
        }
    }

    private let state = Mutex(Published())
    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.monitor-output", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private let hal: HAL
    private let onChange: @Sendable (Change) -> Void
    private var onServiceRestarted: (@Sendable (UInt64) -> Void)?
    private var ownerGeneration: UInt64 = 0
    private let auditionIDs = Atomic<UInt64>(0)

    // Queue-confined from here.
    private var uses: Set<Use> = []
    private var suspended = false
    private var meetingMode = false
    private var gainDb = MonitorOutput.defaultGainDb
    private var meetingSpeakerMode: Bool?
    private var confirmedHeadphones: Set<String> = []
    private var attachment: Attachment?
    private var audition: Audition?
    private var auditionPending = false
    /// An audition ended early: its fade-out is still in the cue ring.
    private var draining = false
    private var drainingCue = false
    /// Every 10 ms while an audition plays or drains.
    private var feedTimer: DispatchSourceTimer?
    private var cancelledAuditions: Set<UInt64> = []
    /// Bumped by every attachment / system-listener registration. A callback queued before its
    /// registration ended carries the old value and is ignored.
    private var epoch: UInt64 = 0
    private var systemEpoch: UInt64 = 0
    private var systemRegistered = false
    private var systemListeners: HALListenerSet?
    private var retryAttempt = 0
    private var retryToken: UInt64 = 0
    private var retryDelay: Double?

    /// The contexts keep raw pointers to `ringO2` and `events`; this object holds both, so they
    /// outlive every context. `onChange` runs on a global queue (it may call back in).
    public convenience init(ringO2: RingO, events: EventRing, onChange: @escaping @Sendable (Change) -> Void = { _ in }) {
        self.init(ringO2: ringO2, events: events, hal: .live, onChange: onChange)
    }

    init(ringO2: RingO, events: EventRing, hal: HAL, onChange: @escaping @Sendable (Change) -> Void = { _ in }) {
        self.ringO2 = ringO2
        self.events = events
        self.hal = hal
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        onQueue {
            uses.removeAll()
            suspended = true
            reconcile()
        }
    }

    // MARK: - app (never waits, except `suspend`)

    public func setUse(_ use: Use, _ on: Bool) {
        queue.async { [self] in
            if on { uses.insert(use) } else {
                uses.remove(use)
                if use == .cues, audition == nil, let att = attachment, att.cueWasQueued, !hasDrained(att) {
                    draining = true; drainingCue = true; updateFeedTimer()
                }
            }
            reconcile()
        }
    }

    /// `OutputRouteClassifier.isSpeakerMode(meetingOutputs:monitor:confirmedHeadphones:)`; nil
    /// (unknown) keeps self-listen off.
    public func setMeetingSpeakerMode(_ speaker: Bool?) {
        queue.async { [self] in meetingSpeakerMode = speaker; applyPolicy() }
    }

    /// UIDs the user confirmed as headphones (§3.7).
    public func setConfirmedHeadphones(_ uids: Set<String>) {
        queue.async { [self] in confirmedHeadphones = uids; applyPolicy() }
    }

    /// The self-listen gain (default −10 dB; ≤ −60 mutes, clamped to +12). Ramps over one cycle.
    public func setSelfListenGainDb(_ db: Float) {
        queue.async { [self] in gainDb = db; applyPolicy() }
    }

    /// Meeting mode on: no audition (§3.4: in a meeting the default output may be the speaker or a
    /// share-sound device, and passthrough may be open); a playing one is interrupted.
    public func setMeetingMode(_ on: Bool) {
        queue.async { [self] in
            meetingMode = on
            if on, let a = audition { endAudition(a, error: AuditionError.interrupted(String(appLocalized: "会议模式")), early: true) }
            applyPolicy()
        }
    }

    /// Detaches and stays detached until `resume()` (coreaudiod restart sequence). Waits until the
    /// IOProc is stopped: call it off the main actor.
    public func suspend() { onQueue { suspended = true; reconcile() } }
    func setServiceRestartHandler(_ handler: (@Sendable (UInt64) -> Void)?) {
        queue.async { [self] in onServiceRestarted = handler }
    }
    public func resume(generation: UInt64? = nil) {
        queue.async { [self] in
            if let generation { ownerGeneration = generation }
            suspended = false; reconcile()
        }
    }

    public var selfListen: SelfListen { state.withLock { $0.selfListen } }
    public var isSelfListenAudible: Bool { selfListen == .audible }
    public var cuesAudible: Bool { state.withLock { $0.cuesAudible } }
    /// The device it is attached to (the default output), as the classifier sees it.
    public var device: OutputRouteClassifier.Device? { state.withLock { $0.target?.device } }
    public var isAttached: Bool { state.withLock { $0.context != nil } }

    public var stats: Stats {
        state.withLock { p in
            guard let c = p.context, let t = p.target else { var s = p.last; s.attached = false; s.attachments = p.attachments; s.lastFailure = p.lastFailure; return s }
            var s = Self.snapshot(c, target: t, bufferFrames: p.bufferFrames, inputStreamsDisabled: p.inputStreamsDisabled)
            s.attachments = p.attachments
            s.lastFailure = p.lastFailure
            return s
        }
    }

    // MARK: - cues

    /// Renders a cue at the device rate (`render(sampleRate)`, on this object's queue) and queues
    /// it if cues are audible then; `completion` (on a global queue) says whether it was queued.
    /// Returns at once. A playing audition fades out first (`AuditionError.interrupted`); what of
    /// it is already queued (≤ 100 ms) plays before the cue.
    public func playCue(_ render: @escaping @Sendable (Double) -> [Float], completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let played = queueCue(render)
            DispatchQueue.global(qos: .userInitiated).async { completion(played) }
        }
    }

    /// `playCue(_:completion:)`, awaited.
    public func playCue(_ render: @escaping @Sendable (Double) -> [Float]) async -> Bool {
        await withCheckedContinuation { c in playCue(render) { c.resume(returning: $0) } }
    }

    // MARK: - audition

    /// A default output it could play on now (attached, or one that would attach), outside
    /// meeting mode and the restart suspension.
    public var isAuditionAvailable: Bool {
        get async { await withCheckedContinuation { c in queue.async { [self] in c.resume(returning: auditionAvailableNow()) } } }
    }

    /// Plays mono `samples` at `sampleRate` to the end on the default output (attaching for it if
    /// needed). `stopAudition()` or a new audition ends it normally, a cue or meeting mode with
    /// `AuditionError.interrupted` (all of these fade it out over 5 ms), a device change or
    /// `suspend()` with `.interrupted` too; task cancellation with CancellationError (faded).
    public func playAudition(_ samples: [Float], sampleRate: Double) async throws {
        let id = auditionIDs.add(1, ordering: .relaxed).newValue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                queue.async { self.startAudition(id: id, samples: samples, rate: sampleRate, cont: cont) }
            }
        } onCancel: {
            queue.async { self.cancelAudition(id: id) }
        }
    }

    /// Fades the audition out; the output stays attached until the fade has played.
    public func stopAudition() {
        queue.async { [self] in
            guard let a = audition else { return }
            endAudition(a, error: nil, early: true)
            reconcile()
        }
    }

    // MARK: - tests

    /// Waits for everything queued so far.
    func flush() { onQueue {} }

    /// One IO cycle through the current context, as monitorIOProc runs it. False when not attached.
    @discardableResult
    func processOffline(_ list: UnsafeMutablePointer<AudioBufferList>, frames: UInt32, outHostTicks: UInt64 = 0) -> Bool {
        state.withLock { p in
            guard let c = p.context else { return false }
            tt_monitor_process(c.ctx, list, frames, outHostTicks)
            return true
        }
    }

    var listenerEpoch: UInt64 { onQueue { epoch } }
    var systemListenerEpoch: UInt64 { onQueue { systemEpoch } }
    /// A device listener callback (IsAlive, NominalSampleRate, Streams, …) of a registration.
    func deliverPropertyChange(_ selector: AudioObjectPropertySelector, epoch e: UInt64) {
        onQueue { deviceChanged(selector, epoch: e) }
    }
    /// A system listener callback (DefaultOutputDevice, ServiceRestarted) of a registration.
    func deliverSystemChange(_ selector: AudioObjectPropertySelector, epoch e: UInt64) {
        onQueue { systemChanged(selector, epoch: e) }
    }
    func deliverServiceRestart() { onQueue { systemChanged(kAudioHardwarePropertyServiceRestarted, epoch: systemEpoch) } }
    var cueLeadFrames: Int? { onQueue { attachment?.lead } }
    var isDraining: Bool { onQueue { draining } }
    /// The delay of the retry waiting now (nil: none).
    var pendingRetry: Double? { onQueue { retryDelay } }
    /// Runs the waiting retry now (without real IO no timer runs it).
    func fireRetry() {
        onQueue {
            guard retryDelay != nil else { return }
            retryToken &+= 1
            retryDelay = nil
            reconcile(retrying: true)
        }
    }

    // MARK: - policy (pure)

    static func selfListenState(wanted: Bool, target: Target?, meetingSpeakerMode: Bool?,
                                confirmedHeadphones: Set<String>) -> SelfListen {
        guard wanted else { return .off }
        guard let t = target else { return .noOutput }
        guard OutputRouteClassifier.classify(t.device, confirmedHeadphones: confirmedHeadphones) == .headphones else { return .notHeadphones }
        guard meetingSpeakerMode == false else { return .meetingSpeaker }
        guard t.sampleRate == ringO2Rate else { return .sampleRate(t.sampleRate) }
        return .audible
    }

    /// How far the audition runs ahead of the IOProc in the cue ring: ≥ 100 ms and ≥ two IO
    /// buffers plus the 10 ms feed tick with margin, within half the ring.
    static func leadFrames(rate: Double, bufferFrames: UInt32, capacity: Int) -> Int {
        let want = max(Int(0.1 * rate), 2 * Int(max(bufferFrames, 512)) + Int(0.02 * rate))
        return min(want, capacity / 2)
    }

    /// The delay before retry `attempt` (0-based): 0.5 s doubling to 5 s; nil after the last.
    static func retryDelay(attempt: Int) -> Double? {
        attempt < maxRetries ? min(0.5 * Double(1 << min(attempt, 8)), 5) : nil
    }

    /// Never TalkTalk's own devices (the Feed above all: nothing here may reach TalkTalk Mic).
    static func refusal(_ d: OutputRouteClassifier.Device) -> String? {
        d.uid.hasPrefix(DriverPins.ownUIDPrefix) ? String(appLocalized: "默认输出是 TalkTalk 自己的设备") : nil
    }

    /// Float32 linear PCM, native endian: what monitorIOProc writes.
    static func isPlayableFormat(_ f: AudioStreamBasicDescription) -> Bool {
        f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && f.mBitsPerChannel == 32 && f.mChannelsPerFrame > 0
    }

    /// The preferred stereo pair (1-based device channels; nil or out of range: the HAL default
    /// 1, 2) as slots of the IOProc's buffer list, one buffer per output stream with these
    /// channel counts. nil when the device has two output channels or fewer: every channel is
    /// written then.
    static func stereoSlots(channelsPerBuffer: [Int], preferred: (UInt32, UInt32)?) -> StereoSlots? {
        let total = channelsPerBuffer.reduce(0) { $0 + max($1, 0) }
        guard total > 2 else { return nil }
        func slot(_ c: UInt32) -> (UInt32, UInt32)? {
            guard c >= 1, Int(c) <= total else { return nil }
            var rest = Int(c) - 1
            for (b, n) in channelsPerBuffer.enumerated() where n > 0 {
                if rest < n { return (UInt32(b), UInt32(rest)) }
                rest -= n
            }
            return nil
        }
        func pair(_ l: UInt32, _ r: UInt32) -> StereoSlots? {
            guard let a = slot(l), let b = slot(r) else { return nil }
            return StereoSlots(leftBuffer: a.0, leftChannel: a.1, rightBuffer: b.0, rightChannel: b.1)
        }
        let p = preferred ?? (1, 2)
        return pair(p.0, p.1) ?? pair(1, 2)
    }

    /// An `AudioHardwareIOProcStreamUsage` for `streams` streams, every one set to `on`
    /// (0 = not used). The HAL wants every stream of the direction listed.
    static func streamUsageBytes(proc: UnsafeRawPointer?, streams: Int, on: UInt32 = 0) -> [UInt8] {
        let flagsAt = streamUsageFlagsOffset
        let size = max(flagsAt + 4 * streams, MemoryLayout<AudioHardwareIOProcStreamUsage>.size)
        var bytes = [UInt8](repeating: 0, count: size)
        bytes.withUnsafeMutableBytes { b in
            b.storeBytes(of: proc, toByteOffset: 0, as: UnsafeRawPointer?.self)
            b.storeBytes(of: UInt32(streams), toByteOffset: MemoryLayout<UnsafeRawPointer?>.size, as: UInt32.self)
            for i in 0..<streams { b.storeBytes(of: on, toByteOffset: flagsAt + 4 * i, as: UInt32.self) }
        }
        return bytes
    }

    /// How many streams a read-back usage lists as off; 0 unless it lists exactly `n` streams.
    static func streamsOff(_ bytes: [UInt8], expected n: Int) -> Int {
        let flagsAt = streamUsageFlagsOffset
        return bytes.withUnsafeBytes { b -> Int in
            guard b.count >= flagsAt + 4 * n else { return 0 }
            let count = Int(b.load(fromByteOffset: MemoryLayout<UnsafeRawPointer?>.size, as: UInt32.self))
            guard count == n else { return 0 }
            return (0..<n).filter { b.load(fromByteOffset: flagsAt + 4 * $0, as: UInt32.self) == 0 }.count
        }
    }

    private static var streamUsageFlagsOffset: Int {
        MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn) ?? 12
    }

    /// Frames of the fade an early-ended audition gets (5 ms).
    static func fadeFrames(rate: Double) -> Int { max(1, Int((0.005 * rate).rounded())) }

    /// `x` times a raised-cosine fade from 1 towards 0 (the sample after the last would be 0).
    static func fadeOut(_ x: [Float]) -> [Float] {
        let n = Double(x.count + 1)
        return x.enumerated().map { i, v in v * Float(0.5 * (1 + cos(Double.pi * Double(i + 1) / n))) }
    }

    /// Mono `x` from `from` Hz to `to` Hz (AVAudioConverter, high quality), clamped to ±1.
    static func resample(_ x: [Float], from: Double, to: Double) throws -> [Float] {
        let y: [Float]
        if from == to || x.isEmpty {
            y = x
        } else {
            guard let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
                  let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: inF, to: outF),
                  let input = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(x.count))
            else { throw Failure(status: 0, what: "AVAudioConverter \(from) → \(to) Hz") }
            conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            input.frameLength = AVAudioFrameCount(x.count)
            x.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
            let cap = AVAudioFrameCount(Double(x.count) * to / from) + 4096
            guard let out = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { throw Failure(status: 0, what: "AVAudioPCMBuffer") }
            let feed = OneShot(input)
            var acc: [Float] = []
            while true {
                out.frameLength = 0
                var err: NSError?
                let st = conv.convert(to: out, error: &err) { _, status in
                    if let b = feed.take() { status.pointee = .haveData; return b }
                    status.pointee = .endOfStream
                    return nil
                }
                if out.frameLength > 0 {
                    acc.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
                }
                if st == .haveData { continue }
                if st == .error { throw Failure(status: OSStatus(truncatingIfNeeded: err?.code ?? 0), what: "AVAudioConverter.convert") }
                break
            }
            y = acc
        }
        return y.map { min(max($0, -1), 1) }
    }

    // MARK: - Core Audio reads

    /// The checks a device must pass before anything is attached to it, and what attach needs.
    /// Every read that fails is a (transient) refusal, never a default: an input-stream count read
    /// as 0 would leave a headset's microphone on.
    static func describe(_ id: AudioObjectID) throws -> Target {
        guard let device = HALReads.outputDevice(id) else { throw Failure(status: 0, what: String(appLocalized: "默认输出没有 UID")) }
        let rate: Double = InputDeviceCatalog.scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 0
        guard rate > 0, rate.isFinite else { throw Failure(status: 0, what: String(appLocalized: "默认输出没有采样率")) }
        let hog: pid_t = InputDeviceCatalog.scalar(id, kAudioDevicePropertyHogMode) ?? -1
        guard hog == -1 || hog == getpid() else { throw Failure(status: 0, what: String(appLocalized: "默认输出被别的程序独占（hog mode）")) }
        guard let outs = streams(id, kAudioObjectPropertyScopeOutput) else { throw Failure(status: 0, what: String(appLocalized: "默认输出的输出流读不出来")) }
        guard !outs.isEmpty else { throw Failure(status: 0, what: String(appLocalized: "默认输出没有输出流")) }
        for s in outs {
            guard let f: AudioStreamBasicDescription = InputDeviceCatalog.scalar(s, kAudioStreamPropertyVirtualFormat) else {
                throw Failure(status: 0, what: String(appLocalized: "默认输出的格式读不出来"))
            }
            guard isPlayableFormat(f) else { throw Failure(status: 0, what: String(appLocalized: "默认输出的格式不是 Float32"), transient: false) }
        }
        guard let ins = streams(id, kAudioObjectPropertyScopeInput) else {
            throw Failure(status: 0, what: String(appLocalized: "默认输出的输入流读不出来（不知道要关几条）"))
        }
        guard let layout = channelsPerBuffer(id, kAudioObjectPropertyScopeOutput) else {
            throw Failure(status: 0, what: String(appLocalized: "默认输出的声道布局读不出来"))
        }
        let out = kAudioObjectPropertyScopeOutput
        let devLatency: UInt32 = InputDeviceCatalog.scalar(id, kAudioDevicePropertyLatency, scope: out) ?? 0
        let safety: UInt32 = InputDeviceCatalog.scalar(id, kAudioDevicePropertySafetyOffset, scope: out) ?? 0
        let streamLatency: UInt32 = InputDeviceCatalog.scalar(outs[0], kAudioStreamPropertyLatency) ?? 0
        return Target(id: id, device: device, sampleRate: rate, inputStreams: ins.count,
                      latencyFrames: devLatency &+ safety &+ streamLatency,
                      stereo: stereoSlots(channelsPerBuffer: layout, preferred: preferredStereo(id)), outputStreams: outs)
    }

    /// The device's streams in `scope`; nil when the HAL does not answer ([] when it has none).
    static func streams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioStreamID]? {
        HALReads.objectList(id, kAudioDevicePropertyStreams, scope: scope)
    }

    /// Channels per buffer of the IOProc's buffer list in `scope` (kAudioDevicePropertyStreamConfiguration).
    static func channelsPerBuffer(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        if size == 0 { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// kAudioDevicePropertyPreferredChannelsForStereo (output); nil when it does not read.
    static func preferredStereo(_ id: AudioObjectID) -> (UInt32, UInt32)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var pair: (UInt32, UInt32) = (0, 0)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pair) == noErr, size == 8 else { return nil }
        return pair
    }

    /// Every input stream off for `proc`, then read back (the HAL fills only the streams it
    /// knows): how many the read-back lists as off. A write or read the HAL refuses is permanent.
    static func turnOffInputStreams(_ id: AudioObjectID, proc: AudioDeviceIOProcID, streams n: Int) throws -> Int {
        let p = unsafeBitCast(proc, to: UnsafeRawPointer.self)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var off = streamUsageBytes(proc: p, streams: n, on: 0)
        var st = off.withUnsafeMutableBytes { AudioObjectSetPropertyData(id, &address, 0, nil, UInt32($0.count), $0.baseAddress!) }
        guard st == noErr else { throw Failure(status: st, what: String(appLocalized: "IOProcStreamUsage 写不进去（关不掉输入流，不接这台设备）"), transient: false) }
        var back = streamUsageBytes(proc: p, streams: n, on: 1)
        var size = UInt32(back.count)
        st = back.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
        guard st == noErr else { throw Failure(status: st, what: String(appLocalized: "IOProcStreamUsage 读不回来（不接这台设备）"), transient: false) }
        return streamsOff(back, expected: n)
    }

    // MARK: - queue-confined

    private var wanted: Bool { (!uses.isEmpty || audition != nil || auditionPending || draining) && !suspended }

    private func cuesAllowed(_ t: Target?) -> Bool {
        t != nil && uses.contains(.cues) && OutputRouteClassifier.cueAllowed(defaultOutput: t?.device, confirmedHeadphones: confirmedHeadphones)
    }

    /// 1 while cues are audible, or an audition holds the ring outside meeting mode; else 0.
    private func cueGain(_ t: Target?) -> Float {
        let auditioning = (audition != nil || auditionPending || draining) && !meetingMode
        let cueTail = drainingCue && OutputRouteClassifier.cueAllowed(defaultOutput: t?.device, confirmedHeadphones: confirmedHeadphones)
        return cuesAllowed(t) || cueTail || (t != nil && auditioning) ? 1 : 0
    }

    /// The default output as the HAL describes it, with this object's own refusal (nil: none).
    private func currentDefault() throws -> Target? {
        guard let id = hal.defaultOutput() else { return nil }
        let t = try hal.describe(id)
        if let why = Self.refusal(t.device) { throw Failure(status: 0, what: why, transient: false) }
        return t
    }

    /// Attaches to, follows or leaves the default output as the uses, the suspension and the
    /// default output say. `retrying`: run by the retry timer (keeps the attempt count).
    private func reconcile(retrying: Bool = false) {
        cancelRetry()
        if !retrying { retryAttempt = 0 }
        guard wanted else {
            detach(reason: suspended ? String(appLocalized: "音频系统重启") : String(appLocalized: "不再需要"))
            syncSystemListeners(false)
            applyPolicy()
            return
        }
        syncSystemListeners(true)
        let next: Target
        do {
            guard let t = try currentDefault() else {
                // Not retried: the DefaultOutputDevice listener says when there is one.
                failed(Failure(status: 0, what: String(appLocalized: "没有默认输出"), transient: false), detaching: String(appLocalized: "没有默认输出"))
                return
            }
            next = t
        } catch {
            failed(error, detaching: String(appLocalized: "输出设备不可用"))
            return
        }
        if let att = attachment {
            if att.target.sameAttachment(as: next) {
                att.target = next                     // name, transport, data source or latency changed
                applyPolicy()
                return
            }
            detach(reason: String(appLocalized: "输出设备变了"))
            guard wanted else { syncSystemListeners(false); applyPolicy(); return }
        }
        do {
            try attach(next)
            setFailure(nil)
        } catch {
            failed(error, detaching: String(appLocalized: "输出设备不可用"))
            return
        }
        applyPolicy()
    }

    private func failed(_ error: any Error, detaching reason: String) {
        setFailure("\(error)")
        detach(reason: reason)
        applyPolicy()
        guard (error as? Failure)?.transient ?? true, wanted, attachment == nil,
              let delay = Self.retryDelay(attempt: retryAttempt) else { return }
        retryAttempt += 1
        retryDelay = delay
        guard hal.realIO else { return }
        let token = retryToken
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.retryToken == token, self.retryDelay != nil else { return }
            self.retryDelay = nil
            self.reconcile(retrying: true)
        }
    }

    private func cancelRetry() {
        retryToken &+= 1
        retryDelay = nil
    }

    private func attach(_ t: Target) throws {
        guard let cues = tt_ring_create(UInt32(t.sampleRate) + 8192) else { throw Failure(status: 0, what: "tt_ring_create") }
        guard let ctx = tt_monitor_ctx_create(ringO2.raw, cues, events.raw, 0) else {
            tt_ring_destroy(cues)
            throw Failure(status: 0, what: "tt_monitor_ctx_create")
        }
        var proc: AudioDeviceIOProcID?
        func undo() {
            if let proc { AudioDeviceDestroyIOProcID(t.id, proc) }
            tt_monitor_ctx_destroy(ctx)
            tt_ring_destroy(cues)
        }
        if hal.realIO {
            let st = AudioDeviceCreateIOProcID(t.id, tt_monitor_ioproc, UnsafeMutableRawPointer(ctx), &proc)
            guard st == noErr, proc != nil else {
                proc = nil
                undo()
                throw Failure(status: st, what: "AudioDeviceCreateIOProcID")
            }
        }
        var disabled = 0
        if t.inputStreams > 0 {
            do { disabled = try hal.turnOffInputStreams(t.id, proc, t.inputStreams) } catch { undo(); throw error }
            guard disabled == t.inputStreams else {
                undo()
                throw Failure(status: 0, what: String(appLocalized: "IOProcStreamUsage：\(t.inputStreams) 条输入流只确认关掉 \(disabled) 条（不接这台设备）"),
                              transient: false)
            }
        }
        if let s = t.stereo { tt_monitor_set_channels(ctx, s.leftBuffer, s.leftChannel, s.rightBuffer, s.rightChannel) }
        let att = Attachment(target: t, ctx: ctx, cues: cues, bufferFrames: hal.bufferFrames(t.id))
        att.procID = proc
        att.inputStreamsDisabled = disabled
        install(att)
        listen(to: att)
        guard let proc else { return }
        let st = AudioDeviceStart(t.id, proc)
        guard st == noErr else {
            detach(reason: "AudioDeviceStart")
            throw Failure(status: st, what: "AudioDeviceStart")
        }
        // A change between describe and the listeners' registration: look once more.
        let e = epoch
        queue.async { [weak self] in
            guard let self, self.epoch == e, self.attachment != nil else { return }
            self.reconcile()
        }
    }

    /// Makes `att` current: both gains are set before any cycle runs (no ramp from the defaults),
    /// then the context is published.
    private func install(_ att: Attachment) {
        attachment = att
        let audible = Self.selfListenState(wanted: uses.contains(.selfListen), target: att.target, meetingSpeakerMode: meetingSpeakerMode,
                                           confirmedHeadphones: confirmedHeadphones) == .audible
        if audible { tt_monitor_set_gain_db(att.ctx, gainDb) } else { tt_monitor_set_gain(att.ctx, 0) }
        tt_monitor_set_gain_initial(att.ctx, tt_monitor_gain(att.ctx))
        let cg = cueGain(att.target)
        tt_monitor_set_cue_gain(att.ctx, cg)
        tt_monitor_set_cue_gain_initial(att.ctx, cg)
        state.withLock {
            $0.context = Context(ctx: att.ctx, cues: att.cues)
            $0.target = att.target
            $0.bufferFrames = att.bufferFrames
            $0.inputStreamsDisabled = att.inputStreamsDisabled
            $0.attachments &+= 1
        }
    }

    private func detach(reason: String) {
        cancelRetry()
        guard let att = attachment else { return }
        if let a = audition { endAudition(a, error: AuditionError.interrupted(reason), early: false) }
        draining = false; drainingCue = false
        updateFeedTimer()
        if let proc = att.procID {
            // Same known assumption as FeedOutput (§3.3): when AudioDeviceStop returns, the
            // IOProc's last call has finished.
            AudioDeviceStop(att.target.id, proc)
            AudioDeviceDestroyIOProcID(att.target.id, proc)
        }
        att.listeners?.stop()
        att.listeners = nil
        attachment = nil
        state.withLock { p in
            if let c = p.context, let t = p.target {
                p.last = Self.snapshot(c, target: t, bufferFrames: p.bufferFrames, inputStreamsDisabled: p.inputStreamsDisabled)
            }
            p.context = nil
            p.target = nil
        }
        tt_monitor_ctx_destroy(att.ctx)
        tt_ring_destroy(att.cues)
    }

    /// Recomputes what is audible, sets both gains, publishes, and reports a change.
    private func applyPolicy() {
        let t = attachment?.target
        let sl = Self.selfListenState(wanted: uses.contains(.selfListen), target: t, meetingSpeakerMode: meetingSpeakerMode,
                                      confirmedHeadphones: confirmedHeadphones)
        let cues = cuesAllowed(t)
        if let att = attachment {
            if sl == .audible { tt_monitor_set_gain_db(att.ctx, gainDb) } else { tt_monitor_set_gain(att.ctx, 0) }
            tt_monitor_set_cue_gain(att.ctx, cueGain(t))
        }
        let now = Route(device: t?.device, sampleRate: t?.sampleRate, selfListen: sl, cuesAudible: cues)
        let changed = state.withLock { p -> Bool in
            p.target = t
            p.selfListen = sl
            p.cuesAudible = cues
            defer { p.reported = now }
            return p.reported != now
        }
        if changed { notify(.route) }
    }

    private func setFailure(_ why: String?) { state.withLock { $0.lastFailure = why } }

    private func notify(_ c: Change) {
        let handler = onChange
        DispatchQueue.global(qos: .userInitiated).async { handler(c) }
    }

    private func serviceRestarted() {
        suspended = true
        detach(reason: String(appLocalized: "音频系统重启"))
        syncSystemListeners(false)
        applyPolicy()
        notify(.serviceRestarted)
        let generation = ownerGeneration, handler = onServiceRestarted
        DispatchQueue.global(qos: .userInitiated).async { handler?(generation) }
    }

    private static func snapshot(_ c: Context, target: Target, bufferFrames: UInt32, inputStreamsDisabled: Int) -> Stats {
        var s = Stats()
        s.attached = true
        s.deviceUID = target.device.uid
        s.sampleRate = target.sampleRate
        s.bufferFrames = bufferFrames
        s.latencyFrames = target.latencyFrames
        s.inputStreamsDisabled = inputStreamsDisabled
        s.channelSlots = target.stereo?.array ?? []
        s.callbacks = tt_monitor_callbacks(c.ctx)
        s.frames = tt_monitor_frames(c.ctx)
        s.audioFrames = tt_monitor_audio_frames(c.ctx)
        s.cueFrames = tt_monitor_cue_frames(c.ctx)
        s.underruns = tt_monitor_underruns(c.ctx)
        s.gain = tt_monitor_gain(c.ctx)
        s.cueGain = tt_monitor_cue_gain(c.ctx)
        s.cueFill = tt_ring_available(c.cues)
        return s
    }

    // Cues and audition, on the queue.

    private func queueCue(_ render: (Double) -> [Float]) -> Bool {
        guard let att = attachment, cuesAllowed(att.target) else { return false }
        let x = render(att.target.sampleRate)
        guard !x.isEmpty else { return false }
        if let a = audition { endAudition(a, error: AuditionError.interrupted(String(appLocalized: "提示音")), early: true) }
        let room = Int(tt_ring_capacity(att.cues)) - Int(tt_ring_available(att.cues))
        guard x.count <= room else { return false }
        let n = x.withUnsafeBufferPointer { tt_ring_write_strided(att.cues, $0.baseAddress!, UInt32(x.count), 1) }
        if n > 0 { att.cueWasQueued = true; att.emptySince = nil }
        return Int(n) == x.count
    }

    public var auditionUnavailableReason: String? {
        get async { await withCheckedContinuation { c in queue.async { [self] in c.resume(returning: auditionUnavailableNow()) } } }
    }

    private func auditionAvailableNow() -> Bool { auditionUnavailableNow() == nil }

    private func auditionUnavailableNow() -> String? {
        if meetingMode { return Self.meetingModeReason }
        if suspended { return String(appLocalized: "音频输出恢复中") }
        if attachment != nil { return nil }
        do { return try currentDefault() == nil ? String(appLocalized: "没有默认输出") : nil }
        catch { return String(describing: error) }
    }

    private func startAudition(id: UInt64, samples: [Float], rate: Double, cont: CheckedContinuation<Void, any Error>) {
        if cancelledAuditions.remove(id) != nil { cont.resume(throwing: CancellationError()); return }
        if let a = audition { endAudition(a, error: nil, early: true) }    // replaced: faded, then this one
        guard !meetingMode else { cont.resume(throwing: AuditionError.unavailable(Self.meetingModeReason)); return }
        guard rate > 0, rate.isFinite else { cont.resume(throwing: AuditionError.unavailable(String(appLocalized: "采样率不对"))); return }
        auditionPending = true
        reconcile()
        auditionPending = false
        guard let att = attachment else {
            let why = state.withLock { $0.lastFailure } ?? String(appLocalized: "没有默认输出")
            reconcile()
            cont.resume(throwing: AuditionError.unavailable(why))
            return
        }
        let y: [Float]
        do { y = try Self.resample(samples, from: rate, to: att.target.sampleRate) } catch {
            reconcile()
            cont.resume(throwing: AuditionError.unavailable("\(error)"))
            return
        }
        audition = Audition(id: id, samples: y, cont: cont)
        applyPolicy()
        updateFeedTimer()
        feedAudition()
    }

    private func updateFeedTimer() {
        let need = audition != nil || draining
        if need, feedTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.feedTick() }
            feedTimer = timer
            timer.resume()
        } else if !need, let timer = feedTimer {
            timer.cancel()
            feedTimer = nil
        }
    }

    private func feedTick() {
        if audition != nil {
            feedAudition()
        } else if draining {
            guard let att = attachment else { draining = false; updateFeedTimer(); return }
            if hasDrained(att) {
                draining = false; drainingCue = false
                updateFeedTimer()
                reconcile()
            }
        }
    }

    /// Reading the ring empty only submits its final samples to the device. Wait for two
    /// further callbacks AND device latency plus one buffer before stopping the IOProc.
    private func hasDrained(_ att: Attachment) -> Bool {
        guard tt_ring_available(att.cues) == 0 else { att.emptySince = nil; return false }
        let callbacks = tt_monitor_callbacks(att.ctx), now = HostClock.now()
        guard let empty = att.emptySince else { att.emptySince = (callbacks, now); return false }
        let frames = Double(att.target.latencyFrames) + Double(att.bufferFrames)
        let delay = HostTime(frames * 1e9 / att.target.sampleRate)
        guard callbacks >= empty.callbacks + 2, now >= empty.at, now - empty.at >= delay else { return false }
        att.cueWasQueued = false
        return true
    }

    /// Keeps the cue ring `lead` ahead of the IOProc; ends after the device drains.
    private func feedAudition() {
        guard let a = audition, let att = attachment else { return }
        let available = Int(tt_ring_available(att.cues))
        if a.pos < a.samples.count {
            let n = min(att.lead - available, a.samples.count - a.pos)
            if n > 0 {
                let stored = a.samples.withUnsafeBufferPointer { tt_ring_write_strided(att.cues, $0.baseAddress! + a.pos, UInt32(n), 1) }
                a.pos += Int(stored)
                if stored > 0 { att.cueWasQueued = true; att.emptySince = nil }
            }
        } else if available == 0 && hasDrained(att) {
            endAudition(a, error: nil, early: false)
            reconcile()
        }
    }

    /// `early`: it did not play to its end, so the next 5 ms of it go into the cue ring faded out
    /// before anything else, and the output stays attached until they have played (`draining`).
    /// The caller reconciles.
    private func endAudition(_ a: Audition, error: (any Error)?, early: Bool) {
        guard audition === a else { return }
        audition = nil
        if early, let att = attachment {
            drainingCue = false
            let n = min(Self.fadeFrames(rate: att.target.sampleRate), a.samples.count - a.pos)
            if n > 0 {
                let faded = Self.fadeOut(Array(a.samples[a.pos ..< a.pos + n]))
                let stored = faded.withUnsafeBufferPointer { tt_ring_write_strided(att.cues, $0.baseAddress!, UInt32(n), 1) }
                a.pos += Int(stored)
                if stored > 0 { att.cueWasQueued = true; att.emptySince = nil }
            }
            if att.cueWasQueued { draining = true }
        }
        updateFeedTimer()
        if let error { a.cont.resume(throwing: error) } else { a.cont.resume() }
    }

    private func cancelAudition(id: UInt64) {
        if let a = audition, a.id == id {
            endAudition(a, error: CancellationError(), early: true)
            reconcile()
        } else {
            // Cancelled before its start reached the queue (or in the moment it ended): the start
            // finds it here. Ids are never reused; keep the set small.
            cancelledAuditions.insert(id)
            if cancelledAuditions.count > 64, let oldest = cancelledAuditions.min() { cancelledAuditions.remove(oldest) }
        }
    }

    // Listeners (§8.6 rule: HALListenerSet adds and removes them on its own control queue).

    private func syncSystemListeners(_ on: Bool) {
        guard on != systemRegistered else { return }
        systemRegistered = on
        guard on else {
            systemListeners?.stop()
            systemListeners = nil
            return
        }
        systemEpoch &+= 1
        guard hal.realIO else { return }
        let e = systemEpoch
        let q = queue
        let owner = AudioWeakReference(self)
        let set = HALListenerSet(label: "com.aaajiao.talktalk.monitor-output.system") { key in
            // No strong reference on the HAL's delivery queue: a last release there would run deinit,
            // which removes listeners, on the queue that delivers them (§8.6).
            q.async { owner.value?.systemChanged(key.selector, epoch: e) }
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        set.set([.init(system, kAudioHardwarePropertyDefaultOutputDevice), .init(system, kAudioHardwarePropertyServiceRestarted)])
        _ = set.current                               // registered before the default output is read
        systemListeners = set
    }

    private func listen(to att: Attachment) {
        epoch &+= 1
        guard hal.realIO else { return }
        let e = epoch, id = att.target.id
        let q = queue
        let owner = AudioWeakReference(self)
        let set = HALListenerSet(label: "com.aaajiao.talktalk.monitor-output.device") { key in
            // No strong reference on the HAL's delivery queue: a last release there would run deinit,
            // which removes listeners, on the queue that delivers them (§8.6).
            q.async { owner.value?.deviceChanged(key.selector, epoch: e) }
        }
        let g = kAudioObjectPropertyScopeGlobal, i = kAudioObjectPropertyScopeInput, o = kAudioObjectPropertyScopeOutput
        var keys: Set<HALListenerSet.Key> = [
            .init(id, kAudioDevicePropertyDeviceIsAlive, g), .init(id, kAudioDevicePropertyNominalSampleRate, g),
            .init(id, kAudioDevicePropertyStreams, i), .init(id, kAudioDevicePropertyStreams, o),
            .init(id, kAudioDevicePropertyDataSource, o), .init(id, kAudioDevicePropertyHogMode, g),
            .init(id, kAudioDevicePropertyStreamConfiguration, o), .init(id, kAudioDevicePropertyPreferredChannelsForStereo, o),
        ]
        for s in att.target.outputStreams { keys.insert(.init(s, kAudioStreamPropertyVirtualFormat, g)) }
        set.set(keys)
        _ = set.current                               // registered before AudioDeviceStart
        att.listeners = set
    }

    /// On `queue`. `e`: the epoch of the registration that delivered it.
    private func systemChanged(_ selector: AudioObjectPropertySelector, epoch e: UInt64) {
        guard e == systemEpoch, systemRegistered else { return }
        if selector == kAudioHardwarePropertyServiceRestarted { serviceRestarted() } else { reconcile() }
    }

    /// On `queue`. `e`: the epoch of the attachment that registered it.
    private func deviceChanged(_ selector: AudioObjectPropertySelector, epoch e: UInt64) {
        guard e == epoch, let att = attachment else { return }
        if selector == kAudioDevicePropertyDeviceIsAlive, !hal.isAlive(att.target.id) { detach(reason: String(appLocalized: "输出设备断开")) }
        // Rate, streams, data source, hog mode, layout, stereo pair, format: re-describe and follow.
        reconcile()
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? try body() : try queue.sync(execute: body)
    }
}

/// Hands AVAudioConverter's input block one buffer, once (the block may be @Sendable).
private final class OneShot: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ b: AVAudioPCMBuffer) { buffer = b }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}
