import CoreAudio
import Foundation
import TalkTalkCore

/// What MeetingMicGuard reads: the meeting processes and the input devices each one reads, plus
/// change notifications. Behind a protocol so tests feed snapshots. Device and process properties
/// only (no audio, no TCC).
public protocol MeetingMicSource: AnyObject, Sendable {
    /// Meeting processes (MeetingSourceResolver's attribution) with their input devices, by UID.
    /// nil: the process list could not be read.
    func meetingProcesses() -> [MeetingMicGuardPlan.Process]?
    /// Start delivering changes (any thread). `restarted`: a coreaudiod restart.
    func startWatching(_ onChange: @escaping @Sendable (_ restarted: Bool) -> Void)
    func stopWatching()
}

/// Core Audio: `kAudioHardwarePropertyProcessObjectList` through MeetingSourceResolver (the same
/// rules as LISTEN and the call-end check), each meeting process object's
/// `kAudioProcessPropertyDevices` (input scope) and `IsRunningInput`; device UIDs, names,
/// aggregates' active sub-devices. Listens to the process list, the device list,
/// `ServiceRestarted`, and each meeting process object's Devices and IsRunningInput (§8.6).
public final class CoreAudioMeetingMicSource: MeetingMicSource, @unchecked Sendable {
    private let resolver: MeetingSourceResolver
    private let lock = NSLock()
    private var onChange: (@Sendable (Bool) -> Void)?
    private var listeners: HALListenerSet?

    public init(resolver: MeetingSourceResolver = MeetingSourceResolver()) {
        self.resolver = resolver
    }

    deinit { listeners?.stop() }

    public func meetingProcesses() -> [MeetingMicGuardPlan.Process]? {
        guard let list = try? AudioProcessList.current() else { return nil }
        let candidates = resolver.candidates(list)
        return candidates.flatMap { c in
            c.processes.map { p in
                // A device whose UID cannot be read makes this process unknown, not "reads nothing".
                let devs = HALReads.processDevices(AudioObjectID(p.objectID), scope: kAudioObjectPropertyScopeInput)
                    .flatMap { ids -> [MeetingMicGuardPlan.InputDevice]? in
                        let out = ids.compactMap(HALReads.inputDevice)
                        return out.count == ids.count ? out : nil
                    }
                return MeetingMicGuardPlan.Process(appID: c.app.id, appName: c.app.name, pid: p.pid,
                                                   isRunningInput: p.isRunningInput, inputDevices: devs)
            }
        }
    }

    public func startWatching(_ onChange: @escaping @Sendable (Bool) -> Void) {
        let set = HALListenerSet(label: "com.aaajiao.talktalk.meeting-mic-guard") { [weak self] key in
            self?.changed(restarted: key.selector == kAudioHardwarePropertyServiceRestarted)
        }
        lock.withLock {
            self.onChange = onChange
            listeners = set
        }
        set.set(keys())
    }

    public func stopWatching() {
        let set = lock.withLock { () -> HALListenerSet? in
            onChange = nil
            defer { listeners = nil }
            return listeners
        }
        set?.stop()
    }

    /// On the listeners' delivery queue: re-register for the current process objects (async on
    /// their control queue), then tell.
    private func changed(restarted: Bool) {
        let (cb, set) = lock.withLock { (onChange, listeners) }
        guard let set else { return }
        let k = keys()
        if restarted { set.restart(k) } else { set.set(k) }
        cb?(restarted)
    }

    private func keys() -> Set<HALListenerSet.Key> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var k: Set<HALListenerSet.Key> = [
            .init(system, kAudioHardwarePropertyProcessObjectList),
            .init(system, kAudioHardwarePropertyDevices),
            .init(system, kAudioHardwarePropertyServiceRestarted),
        ]
        if let list = try? AudioProcessList.current() {
            for c in resolver.candidates(list) {
                for p in c.processes {
                    let id = AudioObjectID(p.objectID)
                    k.insert(.init(id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput))
                    k.insert(.init(id, kAudioProcessPropertyIsRunningInput))
                }
            }
        }
        return k
    }
}

/// MeetingMicGuard (§8.6): green while every active meeting process of the current meeting source
/// reads TalkTalk Mic, red ("对方会听到你的原声") when one reads anything else. Event-driven
/// (process and device listeners) with a 2 s poll behind it. After a coreaudiod restart (seen by
/// its own listener) or `audioRestarted()` (wake, §3.6) push to talk and passthrough wait until it
/// confirms green again. It only watches: macOS does not let one app choose another app's mic.
@MainActor
public final class MeetingMicGuard {
    public typealias Plan = MeetingMicGuardPlan

    public private(set) var state = Plan.State() { didSet { if state != oldValue { onState?(state) } } }
    /// Every state change (PassthroughGate facts, settings page, onboarding, PTT).
    public var onState: (@MainActor (Plan.State) -> Void)?
    /// Turned red / cleared / confirmed (HUD red line, the headphone cue).
    public var onEvent: (@MainActor (Plan.Event) -> Void)?
    public private(set) var isRunning = false

    private let source: MeetingMicSource
    private let config: Plan.Config
    private let now: @Sendable () -> Double
    private let autoPoll: Bool
    private var monitor: Plan.Monitor
    private var scope: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?

    public init(source: MeetingMicSource = CoreAudioMeetingMicSource(), config: Plan.Config = .default,
                now: @escaping @Sendable () -> Double = { Double(HostClock.now()) / 1e9 }, autoPoll: Bool = true) {
        self.source = source
        self.config = config
        self.now = now
        self.autoPoll = autoPoll
        monitor = Plan.Monitor(config: config)
    }

    /// Start watching `scope` (the session's meeting apps; empty: every known meeting app).
    /// Called again with another scope just changes it. `justSwitchedDefaultInput`: meeting mode
    /// has just made TalkTalk Mic the default input; apps following the default still read the
    /// physical mic for a moment, so the red line and cue wait `startSettle` (the verdict does not).
    public func start(scope: Set<String>, justSwitchedDefaultInput: Bool = false) {
        self.scope = scope
        if justSwitchedDefaultInput { monitor.holdRedEvents(from: now()) }
        if !isRunning {
            isRunning = true
            source.startWatching { [weak self] restarted in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    if restarted { self.audioRestarted() } else { self.refresh() }
                }
            }
            if autoPoll {
                let interval = config.pollInterval
                pollTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                        guard let self, self.isRunning else { return }
                        self.refresh()
                    }
                }
            }
        }
        refresh()
    }

    /// Meeting mode ended (or the page that wanted it closed): stop, forget, state unknown.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        source.stopWatching()
        pollTask?.cancel(); pollTask = nil
        recheckTask?.cancel(); recheckTask = nil
        let wasRed: Bool = { if case .physicalMic = state.verdict { true } else { false } }()
        monitor.reset()
        state = monitor.state
        if wasRed { onEvent?(.clearedRed) }
    }

    /// A coreaudiod restart or wake (§3.6): wait for green again. Object IDs are not kept: every
    /// observation reads the process list and device UIDs afresh.
    public func audioRestarted() {
        monitor.audioRestarted()
        state = monitor.state
        refresh()
    }

    /// Observe now (listener, poll, tests).
    public func refresh() {
        guard isRunning else { return }
        let procs = source.meetingProcesses()
        let out = monitor.observe(procs, scope: scope, now: now())
        state = monitor.state
        for e in out.events { onEvent?(e) }
        scheduleRecheck(out.recheckAt)
    }

    private func scheduleRecheck(_ at: Double?) {
        recheckTask?.cancel()
        recheckTask = nil
        guard autoPoll, let at else { return }
        let delay = max(0, at - now())
        recheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refresh()
        }
    }
}
