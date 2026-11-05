import CAudioCore
import CoreAudio
import Foundation
import Synchronization
import TalkTalkCore

/// App-lifetime output owner. All HAL calls, ring resets, passthrough writes and the 10 ms pump
/// are serialized here. ClauseQueue lasts one SPEAK session; suspend/resume retains that queue.
public final class SpeakOutput: SpeakPlayoutHost, @unchecked Sendable {
    public enum Failure: Error { case allocation, sessionAlreadyActive, stopped }
    public let ringO: RingO
    public let ringO2: RingO
    public let events: EventRing
    public let feed: FeedOutput
    public let monitor: MonitorOutput
    public var passthroughState: CPassthroughState { feed.passthroughState }
    public var envelope: EnvelopeHistory { feed.envelope }
    public var isFeedAttached: Bool { hooks.isAttached() }
    public var isChannel1Busy: Bool { feed.isChannel1Busy }
    public var passthroughRMS: Float { published.withLock { $0.level } }
    public var restartGeneration: UInt64 { published.withLock { $0.generation } }
    public var lastFailure: String? { published.withLock { $0.failure } }

    /// Small device boundary for deterministic lifecycle tests, with no HAL starts.
    struct FeedHooks: Sendable {
        var attach: @Sendable (@escaping @Sendable (FeedOutput.Interruption) -> Void) throws -> Void
        var detach: @Sendable () -> Void
        var isAttached: @Sendable () -> Bool
    }
    private struct Published { var generation: UInt64 = 0; var session: UInt64 = 0; var level: Float = 0; var failure: String? }
    private let published = Mutex(Published())
    private let worker = DispatchQueue(label: "com.aaajiao.talktalk.speak-output", qos: .userInteractive)
    private let workerKey = DispatchSpecificKey<Void>()
    private let profile: PolicyProfile
    private let hooks: FeedHooks
    private let liveIO: Bool
    private let passthrough: PassthroughStage
    private var log: EventLog?
    private var session: ClauseQueue?
    private var sessionID: UInt64 = 0
    private var wantFeed = false
    private var suspended = false
    private var shutdown = false
    private var restartPending = false
    private var generation: UInt64 = 0
    private var attachmentEpoch: UInt64 = 0
    private var recoveredAt: HostTime = 0
    private var listeners: HALListenerSet?
    private var timer: DispatchSourceTimer?
    private var eventSink: (@Sendable ([ClauseQueue.Event]) -> Void)?
    private var systemSink: (@Sendable (PassthroughSystemEvent, HostTime) -> Void)?
    private var routeSink: (@Sendable () -> Void)?

    public convenience init(profile: PolicyProfile, log: EventLog? = nil) throws {
        try self.init(profile: profile, log: log, liveIO: true, hooks: nil)
    }
    init(profile: PolicyProfile, log: EventLog? = nil, liveIO: Bool, hooks: FeedHooks?) throws {
        guard let out = RingO(maxLeadFrames: profile.speak.tts.ringOAheadMs * 48),
              let mirror = RingO(maxLeadFrames: profile.speak.tts.ringOAheadMs * 48),
              let events = EventRing() else { throw Failure.allocation }
        self.profile = profile; self.log = log; self.liveIO = liveIO
        ringO = out; ringO2 = mirror; self.events = events
        feed = try FeedOutput(ringO: out, events: events)
        let owner = AudioWeakReference<SpeakOutput>()
        monitor = MonitorOutput(ringO2: mirror, events: events, onChange: { change in if change == .route { owner.value?.routeChanged() } })
        let feed = self.feed
        self.hooks = hooks ?? FeedHooks(attach: { try feed.attach(onInterruption: $0) },
                                        detach: { feed.detach() }, isAttached: { feed.isAttached })
        passthrough = PassthroughStage(feed: feed, ceilingDbtp: profile.speak.passthrough.limiterDbtp)
        worker.setSpecific(key: workerKey, value: ())
        owner.value = self
        monitor.setServiceRestartHandler { generation in owner.value?.receiveRestart(generation: generation) }
        if liveIO {
            worker.async { [weak self] in
                guard let self else { return }
                registerListeners()
                let timer = DispatchSource.makeTimerSource(queue: worker)
                timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.pump() }
                self.timer = timer; timer.resume()
            }
        }
    }

    public func beginSession(config: ClauseQueue.Config) async throws -> ClauseQueue {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { [self] in
                do {
                    guard !shutdown else { throw Failure.stopped }
                    guard session == nil else { throw Failure.sessionAlreadyActive }
                    let stage = try PlayoutStage(config: .init(profile))
                    let queue = ClauseQueue(config: config, ring: ringO, monitor: ringO2, stage: stage)
                    session = queue; sessionID &+= 1
                    published.withLock { $0.session = sessionID }
                    queue.setMonitorEnabled(monitor.isSelfListenAudible)
                    suspended = false; wantFeed = true
                    tryAttach()
                    continuation.resume(returning: queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// Temporary Feed attachment for SystemInputController's launch takeover. Does not invent
    /// a SPEAK session or queue. Only call beginLaunchTakeover after this returns true.
    public func prepareLaunchTakeover() async -> Bool {
        await withCheckedContinuation { continuation in
            worker.async { [self] in
                guard !shutdown, !suspended else { continuation.resume(returning: false); return }
                wantFeed = true
                tryAttach()
                continuation.resume(returning: hooks.isAttached())
            }
        }
    }
    public func finishLaunchTakeover() async {
        await barrier { output in
            if output.session == nil { output.wantFeed = false; output.detachFeed() }
        }
    }

    public func endSession() async {
        await barrier { output in output.endOnWorker() }
    }
    public func suspend() async {
        await barrier { output in
            output.suspended = true
            output.systemSink?(.sleep, HostClock.now())
            output.detachFeed()
            output.monitor.suspend()
            output.passthrough.reset()
            output.published.withLock { $0.level = 0 }
        }
    }
    public func resume() async {
        await barrier { output in
            guard !output.shutdown else { return }
            output.suspended = false
            output.recover(at: HostClock.now())
        }
    }
    public func close() async {
        await barrier { output in output.shutdownOnWorker() }
    }

    public func setEventSink(_ sink: (@Sendable ([ClauseQueue.Event]) -> Void)?) {
        let id = published.withLock { $0.session }
        worker.async { [weak self] in
            guard let self, session != nil, sessionID == id else { return }
            eventSink = sink
        }
    }
    public func setSystemEventSink(_ sink: (@Sendable (PassthroughSystemEvent, HostTime) -> Void)?) {
        worker.async { [weak self] in self?.systemSink = sink }
    }
    public func setRouteSink(_ sink: (@Sendable () -> Void)?) {
        worker.async { [weak self] in self?.routeSink = sink; self?.updateRoute() }
    }
    public func setLog(_ log: EventLog?) { worker.async { [weak self] in self?.log = log } }
    /// Worker already runs every 10 ms, including ordinary playout and passthrough yielding.
    public func setFastPump(_ enabled: Bool) {}

    /// The observation timestamp lets a delayed MeetingEvents report identify an already
    /// handled restart. Feed/Monitor/HAL callbacks additionally carry attachment generations.
    public func audioServiceRestarted(observedAt: HostTime = HostClock.now()) {
        worker.async { [weak self] in
            guard let self, !shutdown, observedAt > recoveredAt else { return }
            restartPending = true
            if !suspended { recover(at: HostClock.now()) }
        }
    }
    public func devicesChanged() {
        worker.async { [weak self] in self?.tryAttach() }
    }
    public func offer(_ block: MicBlock, gate: PassthroughGate, gainDb: Double) {
        worker.async { [weak self] in
            guard let self, !shutdown, !suspended, wantFeed, hooks.isAttached() else { return }
            do {
                try passthrough.offer(block, gate: gate, now: HostClock.now(), gainDb: gainDb)
                published.withLock { $0.level = passthrough.rms }
            } catch { log?.event("pt.stage_failed") }
        }
    }

    private func barrier(_ action: @escaping @Sendable (SpeakOutput) -> Void) async {
        await withCheckedContinuation { continuation in
            worker.async { [self] in action(self); continuation.resume() }
        }
    }
    private func endOnWorker() {
        eventSink = nil
        systemSink?(.meetingModeEnded, HostClock.now())
        session?.teardown()
        wantFeed = false
        detachFeed()
        ringO.reset() // no producer and no Feed consumer remain
        session = nil; systemSink = nil
        passthrough.reset()
        published.withLock { $0.level = 0 }
        // Drop old-session events before a new queue can receive them.
        while !events.drain(max: 1024).isEmpty {}
    }
    private func shutdownOnWorker() {
        guard !shutdown else { return }
        shutdown = true
        timer?.cancel(); timer = nil
        endOnWorker()
        monitor.suspend()
        listeners?.stop(); listeners = nil
        routeSink = nil
    }
    deinit {
        if DispatchQueue.getSpecific(key: workerKey) != nil { shutdownOnWorker() }
        else { worker.sync { shutdownOnWorker() } }
    }

    private func detachFeed() { attachmentEpoch &+= 1; hooks.detach() }

    private func tryAttach() {
        guard !shutdown, wantFeed, !suspended, !hooks.isAttached() else { return }
        let epoch = generation, id = sessionID
        attachmentEpoch &+= 1
        let attachment = attachmentEpoch
        do {
            try hooks.attach { [weak self] event in
                self?.worker.async { [weak self] in
                    guard let self, epoch == generation, id == sessionID, attachment == attachmentEpoch, !shutdown else { return }
                    if event == .serviceRestarted {
                        restartPending = true
                        if !suspended { recover(at: HostClock.now()) }
                    } else if wantFeed && !suspended {
                        systemSink?(.feedGone, HostClock.now())
                        if case let .sampleRateChanged(rate) = event { log?.event("out.format_changed", ["rate": .double(rate)]) }
                        tryAttach()
                    }
                }
            }
            published.withLock { $0.failure = nil }
        } catch {
            published.withLock { $0.failure = String(describing: error) }
            log?.event("out.attach_failed")
        }
    }
    private func receiveRestart(generation old: UInt64) {
        worker.async { [weak self] in
            guard let self, old == generation, !shutdown else { return }
            restartPending = true
            if !suspended { recover(at: HostClock.now()) }
        }
    }
    private func recover(at time: HostTime) {
        generation &+= 1
        published.withLock { $0.generation = generation }
        recoveredAt = time
        systemSink?(.coreaudiodRestarted, time)
        detachFeed()
        monitor.suspend()
        precondition(!hooks.isAttached())
        session?.audioServiceRestarted(at: time)
        passthrough.reset()
        while !events.drain(max: 1024).isEmpty {}
        restartPending = false
        registerListeners()
        monitor.resume(generation: generation)
        tryAttach()
        recoveredAt = HostClock.now()
        updateRoute()
    }
    private func registerListeners() {
        guard liveIO, !shutdown else { return }
        listeners?.stop()
        let epoch = generation, queue = worker, owner = AudioWeakReference(self)
        let set = HALListenerSet(label: "com.aaajiao.talktalk.speak-output.hal") { key in
            queue.async {
                guard let output = owner.value, output.generation == epoch, !output.shutdown else { return }
                if key.selector == kAudioHardwarePropertyServiceRestarted {
                    output.restartPending = true
                    if !output.suspended { output.recover(at: HostClock.now()) }
                } else { output.tryAttach() }
            }
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        set.set([.init(system, kAudioHardwarePropertyServiceRestarted), .init(system, kAudioHardwarePropertyDevices)])
        _ = set.current
        listeners = set
    }
    private func routeChanged() { worker.async { [weak self] in self?.updateRoute() } }
    private func updateRoute() {
        session?.setMonitorEnabled(monitor.isSelfListenAudible)
        routeSink?()
    }
    private func pump() {
        guard !shutdown, !suspended else { return }
        let raw = events.drain()
        for event in raw { logPassthrough(event) }
        guard let session, hooks.isAttached() else { return }
        session.setFeedResumeFrames(Int(feed.resumeFrames))
        feed.setChunkIntervalP95(ms: session.chunkIntervalP95Ms)
        do {
            let result = try session.pump(at: HostClock.now(), ringEvents: raw.compactMap(PlayoutRingEvent.init))
            if !result.isEmpty { eventSink?(result) }
        } catch { log?.event("out.pump_failed") }
    }
    private func logPassthrough(_ event: tt_event) {
        guard event.source == TT_EV_SRC_FEED else { return }
        let time = HostClock.nanos(fromMachTicks: event.host_ticks)
        let fields: [String: EventLog.Value] = ["generation": .int(Int(event.a))]
        switch UInt32(event.type) {
        case TT_EV_PT_FIRST_SAMPLE:
            log?.event("pt.first_sample", ["generation": .int(Int(event.a)),
                "latMs": .int(HostClock.ms(HostClock.nanos(fromMachTicks: event.b), to: time))], at: time)
        case TT_EV_PT_UNDERRUN: log?.event("pt.underrun", fields, at: time)
        case TT_EV_PT_LEASE_EXPIRED: log?.event("pt.lease_expired", fields, at: time)
        case TT_EV_PT_ZERO: log?.event("pt.zero", fields, at: time)
        case TT_EV_PT_DISCARDED: log?.event("pt.discarded", ["frames": .int(Int(clamping: event.b))], at: time)
        default: break
        }
    }

    func flushForTesting() async { await barrier { _ in } }
    func pumpForTesting() async { await barrier { $0.pump() } }
}
