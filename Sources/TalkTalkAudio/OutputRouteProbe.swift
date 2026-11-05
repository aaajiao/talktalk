import CoreAudio
import Foundation
import TalkTalkCore

/// What OutputRouteProbe reads (§3.7): the output devices the meeting processes play on, the
/// default output, a device by UID (the self-monitor device), plus change notifications. Behind a
/// protocol so tests feed snapshots. Device and process properties only (no audio, no TCC).
public protocol OutputRouteSource: AnyObject, Sendable {
    /// `kAudioProcessPropertyDevices` (output scope) of the meeting processes in `scope` (empty:
    /// every known meeting app) that are running output. nil: could not be read.
    func meetingOutputs(scope: Set<String>) -> [OutputRouteClassifier.Device]?
    func defaultOutput() -> OutputRouteClassifier.Device?
    func device(uid: String) -> OutputRouteClassifier.Device?
    /// Start delivering changes (any thread).
    func startWatching(scope: Set<String>, monitorUID: String?, _ onChange: @escaping @Sendable () -> Void)
    func stopWatching()
}

/// Core Audio: listens to the default output, the device list, the process list, `ServiceRestarted`,
/// each meeting process object's Devices and IsRunningOutput, and the DataSource (output scope:
/// the built-in jack's headphones / speaker) and IsAlive of every device in play.
public final class CoreAudioOutputRouteSource: OutputRouteSource, @unchecked Sendable {
    private let resolver: MeetingSourceResolver
    private let lock = NSLock()
    private var onChange: (@Sendable () -> Void)?
    private var listeners: HALListenerSet?
    private var watched: (scope: Set<String>, monitorUID: String?) = ([], nil)

    public init(resolver: MeetingSourceResolver = MeetingSourceResolver()) {
        self.resolver = resolver
    }

    deinit { listeners?.stop() }

    private func meetingOutputIDs(scope: Set<String>) -> [AudioObjectID]? {
        guard let list = try? AudioProcessList.current() else { return nil }
        var out: [AudioObjectID] = []
        for c in resolver.candidates(list) where scope.isEmpty || scope.contains(c.app.id) {
            for p in c.processes where p.isRunningOutput {
                guard let ids = HALReads.processDevices(AudioObjectID(p.objectID), scope: kAudioObjectPropertyScopeOutput)
                else { return nil }
                for id in ids where !out.contains(id) { out.append(id) }
            }
        }
        return out
    }

    public func meetingOutputs(scope: Set<String>) -> [OutputRouteClassifier.Device]? {
        guard let ids = meetingOutputIDs(scope: scope) else { return nil }
        let devs = ids.compactMap(HALReads.outputDevice)
        return devs.count == ids.count ? devs : nil
    }

    public func defaultOutput() -> OutputRouteClassifier.Device? {
        HALReads.defaultOutput().flatMap(HALReads.outputDevice)
    }

    public func device(uid: String) -> OutputRouteClassifier.Device? {
        HALReads.device(uid: uid).flatMap(HALReads.outputDevice)
    }

    public func startWatching(scope: Set<String>, monitorUID: String?, _ onChange: @escaping @Sendable () -> Void) {
        let existing = lock.withLock { () -> HALListenerSet? in
            self.onChange = onChange
            watched = (scope, monitorUID)
            return listeners
        }
        let set = existing ?? HALListenerSet(label: "com.aaajiao.talktalk.output-route") { [weak self] key in
            self?.changed(restarted: key.selector == kAudioHardwarePropertyServiceRestarted)
        }
        if existing == nil { lock.withLock { listeners = set } }
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

    private func changed(restarted: Bool) {
        let (cb, set) = lock.withLock { (onChange, listeners) }
        guard let set else { return }
        let k = keys()
        if restarted { set.restart(k) } else { set.set(k) }
        cb?()
    }

    private func keys() -> Set<HALListenerSet.Key> {
        let (scope, monitorUID) = lock.withLock { watched }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var k: Set<HALListenerSet.Key> = [
            .init(system, kAudioHardwarePropertyDefaultOutputDevice),
            .init(system, kAudioHardwarePropertyDevices),
            .init(system, kAudioHardwarePropertyProcessObjectList),
            .init(system, kAudioHardwarePropertyServiceRestarted),
        ]
        var devices: [AudioObjectID] = []
        if let list = try? AudioProcessList.current() {
            for c in resolver.candidates(list) where scope.isEmpty || scope.contains(c.app.id) {
                for p in c.processes {
                    let id = AudioObjectID(p.objectID)
                    k.insert(.init(id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput))
                    k.insert(.init(id, kAudioProcessPropertyIsRunningOutput))
                    devices += HALReads.processDevices(id, scope: kAudioObjectPropertyScopeOutput) ?? []
                }
            }
        }
        if let d = HALReads.defaultOutput() { devices.append(d) }
        if let uid = monitorUID, let d = HALReads.device(uid: uid) { devices.append(d) }
        for d in devices {
            k.insert(.init(d, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput))
            k.insert(.init(d, kAudioDevicePropertyDeviceIsAlive))
        }
        return k
    }
}

/// OutputRouteProbe (§3.7): speaker mode from the devices the meeting app really plays on plus the
/// self-monitor device, and whether a cue may play (default output is headphones). Re-judged on
/// every device, DataSource or process-device change; OutputRouteClassifier decides.
@MainActor
public final class OutputRouteProbe {
    public struct State: Sendable, Equatable {
        /// PassthroughPolicy.Facts.speakerMode. nil: the meeting's outputs are unknown (none yet,
        /// unreadable): unavailable, not "headphones".
        public var speakerMode: Bool?
        /// Passthrough and MeetingMicGuard cues may play (OutputRouteClassifier.cueAllowed).
        public var cueAllowed: Bool
        public var meetingOutputs: [OutputRouteClassifier.Device]?
        public var defaultOutput: OutputRouteClassifier.Device?

        public init(speakerMode: Bool? = nil, cueAllowed: Bool = false,
                    meetingOutputs: [OutputRouteClassifier.Device]? = nil, defaultOutput: OutputRouteClassifier.Device? = nil) {
            self.speakerMode = speakerMode; self.cueAllowed = cueAllowed
            self.meetingOutputs = meetingOutputs; self.defaultOutput = defaultOutput
        }
    }

    public private(set) var state = State() { didSet { if state != oldValue { onState?(state) } } }
    public var onState: (@MainActor (State) -> Void)?
    public private(set) var isRunning = false

    private let source: OutputRouteSource
    /// UIDs the user confirmed as headphones (settings › 音频, HeadphoneAnswers).
    private let confirmedHeadphones: @MainActor () -> Set<String>
    /// The self-monitor device's UID while self-monitoring is on (nil: off).
    private let monitorUID: @MainActor () -> String?
    private let pollInterval: Double?
    private var scope: Set<String> = []
    private var watchedMonitor: String?
    private var pollTask: Task<Void, Never>?

    /// `pollInterval`: a poll behind the listeners (nil: listeners only, tests).
    public init(source: OutputRouteSource = CoreAudioOutputRouteSource(),
                confirmedHeadphones: @escaping @MainActor () -> Set<String>,
                monitorUID: @escaping @MainActor () -> String? = { nil }, pollInterval: Double? = 2) {
        self.source = source
        self.confirmedHeadphones = confirmedHeadphones
        self.monitorUID = monitorUID
        self.pollInterval = pollInterval
    }

    public func start(scope: Set<String>) {
        self.scope = scope
        watch()
        if !isRunning {
            isRunning = true
            if let interval = pollInterval {
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

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        source.stopWatching()
        pollTask?.cancel(); pollTask = nil
        state = State()
    }

    private func watch() {
        watchedMonitor = monitorUID()
        source.startWatching(scope: scope, monitorUID: watchedMonitor) { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.refresh()
            }
        }
    }

    /// Re-judge now (listener, poll, the user answered "这是耳机吗？", self-monitoring toggled).
    public func refresh() {
        guard isRunning else { return }
        let monitorNow = monitorUID()
        if monitorNow != watchedMonitor { watch() }   // its DataSource / IsAlive are listened to as well
        let confirmed = confirmedHeadphones()
        let outs = source.meetingOutputs(scope: scope)
        let monitor = monitorNow.flatMap { source.device(uid: $0) }
        let def = source.defaultOutput()
        state = State(speakerMode: OutputRouteClassifier.isSpeakerMode(meetingOutputs: outs, monitor: monitor,
                                                                       confirmedHeadphones: confirmed),
                      cueAllowed: OutputRouteClassifier.cueAllowed(defaultOutput: def, confirmedHeadphones: confirmed),
                      meetingOutputs: outs, defaultOutput: def)
    }
}
