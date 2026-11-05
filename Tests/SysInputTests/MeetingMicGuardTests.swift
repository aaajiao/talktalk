import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import TalkTalkAudio
import TalkTalkCore

/// A recorded MeetingMicSource: tests set the processes and fire changes by hand.
final class FakeMeetingMicSource: MeetingMicSource, @unchecked Sendable {
    private let lock = NSLock()
    private var procs: [MeetingMicGuardPlan.Process]? = []
    private var onChange: (@Sendable (Bool) -> Void)?
    private(set) var watching = false
    private(set) var reads = 0

    func set(_ p: [MeetingMicGuardPlan.Process]?) { lock.withLock { procs = p } }
    func meetingProcesses() -> [MeetingMicGuardPlan.Process]? { lock.withLock { reads += 1; return procs } }
    func startWatching(_ onChange: @escaping @Sendable (Bool) -> Void) { lock.withLock { self.onChange = onChange; watching = true } }
    func stopWatching() { lock.withLock { onChange = nil; watching = false } }
    func fire(restarted: Bool = false) { lock.withLock { onChange }?(restarted) }
}

final class FakeOutputRouteSource: OutputRouteSource, @unchecked Sendable {
    private let lock = NSLock()
    var outputs: [OutputRouteClassifier.Device]? = []
    var defaultOut: OutputRouteClassifier.Device?
    var byUID: [String: OutputRouteClassifier.Device] = [:]
    private(set) var watchedMonitors: [String?] = []
    private(set) var watching = false
    private var onChange: (@Sendable () -> Void)?

    func meetingOutputs(scope: Set<String>) -> [OutputRouteClassifier.Device]? { lock.withLock { outputs } }
    func defaultOutput() -> OutputRouteClassifier.Device? { lock.withLock { defaultOut } }
    func device(uid: String) -> OutputRouteClassifier.Device? { lock.withLock { byUID[uid] } }
    func startWatching(scope: Set<String>, monitorUID: String?, _ onChange: @escaping @Sendable () -> Void) {
        lock.withLock { watchedMonitors.append(monitorUID); self.onChange = onChange; watching = true }
    }
    func stopWatching() { lock.withLock { onChange = nil; watching = false } }
    func fire() { lock.withLock { onChange }?() }
}

/// Lets the main actor run the Task a fake change notification starts.
@MainActor func settle() async { for _ in 0..<5 { await Task.yield() } }

@MainActor @Suite(.serialized) struct MeetingMicGuardTests {
    typealias P = MeetingMicGuardPlan
    static let mic = P.InputDevice(uid: MicPolicy.talkTalkMicUID, name: "TalkTalk Mic")
    static let builtIn = P.InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    static func zoom(_ d: [P.InputDevice]?) -> P.Process {
        P.Process(appID: "us.zoom.xos", appName: "Zoom", pid: 100, isRunningInput: true, inputDevices: d)
    }

    final class Clock: @unchecked Sendable {
        var t: Double = 1000
    }

    func rig() -> (MeetingMicGuard, FakeMeetingMicSource, Clock, EventTrail) {
        let src = FakeMeetingMicSource()
        let clock = Clock()
        let g = MeetingMicGuard(source: src, config: .init(confirmSettle: 0.5), now: { clock.t }, autoPoll: false)
        let trail = EventTrail()
        g.onEvent = { trail.add("\($0)") }
        return (g, src, clock, trail)
    }

    @Test func startObservesAndListens() {
        let (g, src, _, _) = rig()
        src.set([Self.zoom([Self.mic])])
        g.start(scope: ["us.zoom.xos"])
        #expect(src.watching)
        #expect(g.state.micGuard == .green)
        #expect(g.state.verified)
    }

    /// A listener notification re-reads: the app moved to the built-in mic, red once.
    @Test func changeNotificationTurnsRed() async {
        let (g, src, _, trail) = rig()
        src.set([Self.zoom([Self.mic])])
        g.start(scope: [])
        src.set([Self.zoom([Self.builtIn])])
        src.fire()
        await settle()
        #expect(g.state.micGuard == .meetingUsesPhysicalMic)
        #expect(!g.state.allowsPushToTalk)
        #expect(trail.all.count == 1)
    }

    /// The source's own ServiceRestarted: wait for green again, confirmed after the settle time.
    @Test func restartFromTheListenerWaitsForConfirmation() async {
        let (g, src, clock, trail) = rig()
        src.set([Self.zoom([Self.mic])])
        g.start(scope: [])
        src.set(nil)
        src.fire(restarted: true)
        await settle()
        #expect(g.state.awaitingConfirmation)
        #expect(!g.state.allowsPushToTalk)
        src.set([Self.zoom([Self.mic])])
        clock.t += 1
        g.refresh()
        #expect(g.state.awaitingConfirmation)
        clock.t += 0.5
        g.refresh()
        #expect(!g.state.awaitingConfirmation)
        #expect(trail.all.contains("confirmed"))
    }

    /// Wake goes through audioRestarted() from the app.
    @Test func wakeWaitsToo() {
        let (g, src, _, _) = rig()
        src.set([Self.zoom([Self.mic])])
        g.start(scope: [])
        g.audioRestarted()
        #expect(g.state.awaitingConfirmation)
    }

    /// Stopping while red clears the red line once; nothing is observed afterwards.
    @Test func stopClearsRed() async {
        let (g, src, _, trail) = rig()
        src.set([Self.zoom([Self.builtIn])])
        g.start(scope: [])
        g.stop()
        #expect(!src.watching)
        #expect(g.state == P.State())
        #expect(trail.all.last == "clearedRed")
        let before = src.reads
        src.fire()
        await settle()
        g.refresh()
        #expect(src.reads == before)
    }

    /// The scope can change while running (another meeting app joined the session).
    @Test func scopeChange() {
        let (g, src, _, _) = rig()
        let teams = P.Process(appID: "com.microsoft.teams2", appName: "Teams", pid: 200, isRunningInput: true,
                              inputDevices: [Self.builtIn])
        src.set([Self.zoom([Self.mic]), teams])
        g.start(scope: ["us.zoom.xos"])
        #expect(g.state.micGuard == .green)
        g.start(scope: ["us.zoom.xos", "com.microsoft.teams2"])
        #expect(g.state.micGuard == .meetingUsesPhysicalMic)
    }
}

@MainActor @Suite(.serialized) struct OutputRouteProbeTests {
    typealias D = OutputRouteClassifier.Device
    static let speakers = D(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn,
                            dataSource: OutputRouteClassifier.dataSourceInternalSpeaker)
    static let jack = D(uid: "BuiltInHeadphoneOutputDevice", name: "External Headphones", transport: .builtIn,
                        dataSource: OutputRouteClassifier.dataSourceHeadphones)
    static let airpods = D(uid: "bt:airpods", name: "AirPods", transport: .bluetooth)

    @Test func headphonesVersusSpeakers() async {
        let src = FakeOutputRouteSource()
        var confirmed: Set<String> = []
        let probe = OutputRouteProbe(source: src, confirmedHeadphones: { confirmed }, pollInterval: nil)
        src.outputs = [Self.jack]
        src.defaultOut = Self.speakers
        probe.start(scope: ["us.zoom.xos"])
        #expect(probe.state.speakerMode == false)
        #expect(probe.state.cueAllowed == false)   // the default output is still the speakers (C11)
        // AirPods connect and Zoom moves to them: speaker until confirmed.
        src.outputs = [Self.airpods]
        src.defaultOut = Self.airpods
        src.fire()
        await settle()
        #expect(probe.state.speakerMode == true)
        confirmed = ["bt:airpods"]
        probe.refresh()
        #expect(probe.state.speakerMode == false)
        #expect(probe.state.cueAllowed)
        // AirPods disconnect, Zoom falls back to the speakers: at once.
        src.outputs = [Self.speakers]
        src.fire()
        await settle()
        #expect(probe.state.speakerMode == true)
    }

    @Test func unknownOutputsAreUnknown() {
        let src = FakeOutputRouteSource()
        let probe = OutputRouteProbe(source: src, confirmedHeadphones: { [] }, pollInterval: nil)
        src.outputs = nil
        probe.start(scope: [])
        #expect(probe.state.speakerMode == nil)
        src.outputs = []
        probe.refresh()
        #expect(probe.state.speakerMode == nil)   // not playing yet: not "headphones"
    }

    /// The self-monitor device counts, and turning self-monitoring on re-registers its listeners.
    @Test func monitorDevice() {
        let src = FakeOutputRouteSource()
        var monitor: String?
        src.outputs = [Self.jack]
        src.byUID = [Self.speakers.uid: Self.speakers]
        let probe = OutputRouteProbe(source: src, confirmedHeadphones: { [] }, monitorUID: { monitor }, pollInterval: nil)
        probe.start(scope: [])
        #expect(probe.state.speakerMode == false)
        monitor = Self.speakers.uid
        probe.refresh()
        #expect(probe.state.speakerMode == true)
        #expect(src.watchedMonitors == [nil, Self.speakers.uid])
        probe.stop()
        #expect(!src.watching)
        #expect(probe.state == OutputRouteProbe.State())
    }
}

/// The Core Audio listener bookkeeping against the real HAL's system object (no device, no IO,
/// no TCC): adds, swaps, stops.
@Suite(.serialized) struct HALListenerSetTests {
    @Test func bookkeeping() {
        let hits = Mutex(0)
        let set = HALListenerSet(label: "test.hal-listener-set") { _ in hits.withLock { $0 += 1 } }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let a = HALListenerSet.Key(sys, kAudioHardwarePropertyDevices)
        let b = HALListenerSet.Key(sys, kAudioHardwarePropertyProcessObjectList)
        set.set([a])
        #expect(set.current == [a])
        set.set([b])
        #expect(set.current == [b])
        set.restart([a, b])
        #expect(set.current == [a, b])
        set.stop()
        #expect(set.current.isEmpty)
        set.set([a])
        #expect(set.current.isEmpty)   // stopped stays stopped
    }
}

/// Review of a5b2b6b #1: an aggregate's sub-device that fails to read never leaves "TalkTalk Mic only".
@Suite struct AggregateSubDeviceReadTests {
    @Test func unreadableSubDeviceEmptiesTheList() {
        let mic = MicPolicy.talkTalkMicUID
        #expect(HALReads.inputSubDeviceUIDs([(1, mic), (2, "usb:mv7")]) == [mic, "usb:mv7"])
        #expect(HALReads.inputSubDeviceUIDs([(1, mic), (0, "BuiltInSpeakerDevice")]) == [mic])   // output only
        #expect(HALReads.inputSubDeviceUIDs([(1, mic), (nil, "usb:mv7")]).isEmpty)   // channels unreadable
        #expect(HALReads.inputSubDeviceUIDs([(1, mic), (2, nil)]).isEmpty)           // UID unreadable
        #expect(HALReads.inputSubDeviceUIDs([(0, nil), (1, mic)]) == [mic])          // 0 channels: not needed
        // …and an aggregate with an empty list is red.
        let agg = MeetingMicGuardPlan.InputDevice(uid: "agg", name: "Agg", isAggregate: true,
                                                  inputSubDeviceUIDs: HALReads.inputSubDeviceUIDs([(1, mic), (nil, "usb:mv7")]))
        let p = MeetingMicGuardPlan.Process(appID: "us.zoom.xos", appName: "Zoom", pid: 1, isRunningInput: true, inputDevices: [agg])
        #expect(MeetingMicGuardPlan.verdict([p], scope: [])?.micGuard == .meetingUsesPhysicalMic)
    }
}

/// Review of a5b2b6b #4, through the guard: the start window is set by `start(justSwitchedDefaultInput:)`.
@MainActor @Suite(.serialized) struct MeetingMicGuardStartTests {
    @Test func startWindow() {
        let src = FakeMeetingMicSource()
        let clock = MeetingMicGuardTests.Clock()
        let g = MeetingMicGuard(source: src, config: .init(startSettle: 1.5), now: { clock.t }, autoPoll: false)
        var events: [MeetingMicGuardPlan.Event] = []
        g.onEvent = { events.append($0) }
        src.set([MeetingMicGuardTests.zoom([MeetingMicGuardTests.builtIn])])
        g.start(scope: [], justSwitchedDefaultInput: true)
        #expect(g.state.micGuard == .meetingUsesPhysicalMic)
        #expect(events.isEmpty)
        clock.t += 1.5
        g.refresh()
        #expect(events.count == 1)
        // Without the flag (meeting mode did not switch): at once.
        let g2 = MeetingMicGuard(source: src, now: { clock.t }, autoPoll: false)
        var e2: [MeetingMicGuardPlan.Event] = []
        g2.onEvent = { e2.append($0) }
        g2.start(scope: [])
        #expect(e2.count == 1)
    }
}
