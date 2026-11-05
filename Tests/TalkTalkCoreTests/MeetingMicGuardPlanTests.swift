import Testing
@testable import TalkTalkCore

/// MeetingMicGuard's rules (§8.6, §3.6): multiple meeting apps, an app switching devices mid-call,
/// pinned to a physical mic, aggregates, processes exiting, and the wait after a coreaudiod restart.
@Suite struct MeetingMicGuardPlanTests {
    typealias P = MeetingMicGuardPlan
    static let mic = P.InputDevice(uid: MicPolicy.talkTalkMicUID, name: "TalkTalk Mic")
    static let builtIn = P.InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    static let krisp = P.InputDevice(uid: "krisp:mic", name: "Krisp Microphone")

    static func zoom(_ devs: [P.InputDevice]?, running: Bool = true, pid: Int32 = 100) -> P.Process {
        P.Process(appID: "us.zoom.xos", appName: "Zoom", pid: pid, isRunningInput: running, inputDevices: devs)
    }
    static func teams(_ devs: [P.InputDevice]?, running: Bool = true) -> P.Process {
        P.Process(appID: "com.microsoft.teams2", appName: "Microsoft Teams", pid: 200, isRunningInput: running, inputDevices: devs)
    }
    static func chrome(_ devs: [P.InputDevice]?, running: Bool = true, pid: Int32 = 300) -> P.Process {
        P.Process(appID: "com.google.Chrome", appName: "Google Chrome", pid: pid, isRunningInput: running, inputDevices: devs)
    }

    @Test func greenWhenTheMeetingReadsTalkTalkMic() {
        let v = P.verdict([Self.zoom([Self.mic])], scope: [])
        #expect(v == .green(appID: "us.zoom.xos", app: "Zoom"))
        #expect(v?.micGuard == .green)
    }

    @Test func pinnedToThePhysicalMicIsRed() {
        let v = P.verdict([Self.zoom([Self.builtIn])], scope: ["us.zoom.xos"])
        #expect(v == .physicalMic(appID: "us.zoom.xos", app: "Zoom", device: "MacBook Pro Microphone"))
        #expect(v?.micGuard == .meetingUsesPhysicalMic)
        #expect(v?.detail == "Zoom 正在用 MacBook Pro Microphone：在 Zoom › 设置 › 音频 › 麦克风 里选 TalkTalk Mic")
    }

    /// Krisp and the like pass the physical mic on: not TalkTalk Mic, red.
    @Test func anotherVirtualMicIsRed() {
        #expect(P.verdict([Self.zoom([Self.krisp])], scope: [])?.micGuard == .meetingUsesPhysicalMic)
    }

    @Test func nobodyReadingIsNoReader() {
        #expect(P.verdict([Self.zoom([], running: false)], scope: []) == .noReader)
        #expect(P.verdict([], scope: []) == .noReader)
        #expect(P.verdict([], scope: [])?.micGuard == .noReaderOfTalkTalkMic)
    }

    @Test func unreadableIsUnknown() {
        #expect(P.verdict(nil, scope: []) == nil)
        #expect(P.verdict([Self.zoom(nil)], scope: []) == nil)
        // Running input with no device listed: not "reads nothing".
        #expect(P.verdict([Self.zoom([])], scope: []) == nil)
    }

    /// Two meeting apps: one on a physical mic makes it red whatever the other does; the session's
    /// scope decides which apps count.
    @Test func multipleMeetingApps() {
        let both = [Self.zoom([Self.mic]), Self.teams([Self.builtIn])]
        #expect(P.verdict(both, scope: [])?.micGuard == .meetingUsesPhysicalMic)
        #expect(P.verdict(both, scope: ["us.zoom.xos"]) == .green(appID: "us.zoom.xos", app: "Zoom"))
        #expect(P.verdict(both, scope: ["com.microsoft.teams2"])?.micGuard == .meetingUsesPhysicalMic)
        // One green, one unknown: unknown.
        #expect(P.verdict([Self.zoom([Self.mic]), Self.teams(nil)], scope: []) == nil)
        // One red, one unknown: red.
        #expect(P.verdict([Self.zoom(nil), Self.teams([Self.builtIn])], scope: [])?.micGuard == .meetingUsesPhysicalMic)
    }

    /// Several processes of one app (browser helpers): any of them on a physical mic is red.
    @Test func oneAppManyProcesses() {
        let tabs = [Self.chrome([Self.mic], pid: 301), Self.chrome([Self.builtIn], pid: 302), Self.chrome([], running: false, pid: 303)]
        #expect(P.verdict(tabs, scope: [])?.micGuard == .meetingUsesPhysicalMic)
        #expect(P.verdict([Self.chrome([Self.mic], pid: 301), Self.chrome([], running: false, pid: 303)], scope: [])?.micGuard == .green)
        // A process reading two devices, one of them physical.
        #expect(P.verdict([Self.zoom([Self.mic, Self.builtIn])], scope: [])?.micGuard == .meetingUsesPhysicalMic)
    }

    @Test func aggregates() {
        let onlyMic = P.InputDevice(uid: "agg:1", name: "Mic Agg", isAggregate: true, inputSubDeviceUIDs: [MicPolicy.talkTalkMicUID])
        let mixed = P.InputDevice(uid: "agg:2", name: "Mixed Agg", isAggregate: true,
                                  inputSubDeviceUIDs: [MicPolicy.talkTalkMicUID, "BuiltInMicrophoneDevice"])
        let opaque = P.InputDevice(uid: "agg:3", name: "Opaque Agg", isAggregate: true, inputSubDeviceUIDs: [])
        #expect(P.verdict([Self.zoom([onlyMic])], scope: [])?.micGuard == .green)
        #expect(P.verdict([Self.zoom([mixed])], scope: []) == .physicalMic(appID: "us.zoom.xos", app: "Zoom", device: "Mixed Agg"))
        #expect(P.verdict([Self.zoom([opaque])], scope: [])?.micGuard == .meetingUsesPhysicalMic)
        // A non-aggregate claiming sub-devices is judged by its own UID.
        let fake = P.InputDevice(uid: "x", name: "X", isAggregate: false, inputSubDeviceUIDs: [MicPolicy.talkTalkMicUID])
        #expect(P.verdict([Self.zoom([fake])], scope: [])?.micGuard == .meetingUsesPhysicalMic)
    }

    @Test func browserSettingsPath() {
        #expect(P.settingsPath(appID: "com.google.Chrome", app: "Google Chrome") == "网页里的设备设置，或 Google Chrome 的网站设置 › 麦克风")
        #expect(P.settingsPath(appID: "x.y", app: "Lark") == "Lark 的音频设置")
    }

    // MARK: Monitor

    /// The app switches to the physical mic mid-call and back: red once, cleared once.
    @Test func switchingDevicesMidCall() {
        var m = P.Monitor()
        #expect(m.observe([Self.zoom([Self.mic])], scope: [], now: 0).events.isEmpty)
        #expect(m.state.micGuard == .green)
        let red = m.observe([Self.zoom([Self.builtIn])], scope: [], now: 1)
        #expect(red.events == [.turnedRed(appID: "us.zoom.xos", app: "Zoom", device: "MacBook Pro Microphone")])
        #expect(!m.state.allowsPushToTalk)
        // The same red again: no second cue.
        #expect(m.observe([Self.zoom([Self.builtIn])], scope: [], now: 2).events.isEmpty)
        // Another physical device: a new red (the line names it).
        let usb = P.InputDevice(uid: "usb:mv7", name: "Shure MV7")
        #expect(m.observe([Self.zoom([usb])], scope: [], now: 3).events
                == [.turnedRed(appID: "us.zoom.xos", app: "Zoom", device: "Shure MV7")])
        // Unknown keeps the red line.
        #expect(m.observe([Self.zoom(nil)], scope: [], now: 4).events.isEmpty)
        #expect(m.state.micGuard == nil)
        #expect(m.observe([Self.zoom([Self.mic])], scope: [], now: 5).events == [.clearedRed])
        #expect(m.state.allowsPushToTalk)
    }

    /// The meeting process exits: no reader; red cleared.
    @Test func processExits() {
        var m = P.Monitor()
        _ = m.observe([Self.zoom([Self.builtIn])], scope: ["us.zoom.xos"], now: 0)
        #expect(m.observe([], scope: ["us.zoom.xos"], now: 1).events == [.clearedRed])
        #expect(m.state.micGuard == .noReaderOfTalkTalkMic)
        #expect(m.state.allowsPushToTalk)   // other checks decide; the guard is not red
        #expect(!m.state.verified)
    }

    /// After a coreaudiod restart: push to talk and passthrough wait until green held the settle
    /// time; a meeting app that fell back to the physical mic keeps them off (re-resolved by UID).
    @Test func waitAfterARestart() {
        var m = P.Monitor(config: .init(confirmSettle: 0.5))
        _ = m.observe([Self.zoom([Self.mic])], scope: [], now: 0)
        #expect(m.state.verified)
        m.audioRestarted()
        #expect(m.state.awaitingConfirmation)
        #expect(!m.state.allowsPushToTalk)
        #expect(!m.state.verified)
        // Right after: the process list is not there yet.
        #expect(m.observe(nil, scope: [], now: 1.0).events.isEmpty)
        // Green, but not for long enough: recheck at its end.
        let first = m.observe([Self.zoom([Self.mic], pid: 101)], scope: [], now: 1.2)
        #expect(first.recheckAt == 1.7)
        #expect(m.state.awaitingConfirmation)
        let done = m.observe([Self.zoom([Self.mic], pid: 101)], scope: [], now: 1.7)
        #expect(done.events == [.confirmed])
        #expect(!m.state.awaitingConfirmation)
        #expect(m.state.allowsPushToTalk)
    }

    @Test func fallbackAfterARestartStaysOff() {
        var m = P.Monitor(config: .init(confirmSettle: 0.5))
        _ = m.observe([Self.zoom([Self.mic])], scope: [], now: 0)
        m.audioRestarted()
        _ = m.observe([Self.zoom([Self.mic])], scope: [], now: 1)
        // Fell back to the built-in mic before the settle ended: the wait starts over when green again.
        let red = m.observe([Self.zoom([Self.builtIn])], scope: [], now: 1.3)
        #expect(red.events.count == 1)
        #expect(m.state.awaitingConfirmation)
        _ = m.observe([Self.zoom([Self.mic])], scope: [], now: 5)
        #expect(m.state.awaitingConfirmation)
        #expect(m.observe([Self.zoom([Self.mic])], scope: [], now: 5.5).events == [.confirmed])
    }

    /// Review of a5b2b6b #4: right after the default input was switched, an app following it
    /// shows red for a moment. The verdict is red at once; the events wait the start window.
    @Test func startWindowHidesATransientRed() {
        var m = P.Monitor(config: .init(startSettle: 1.5))
        m.holdRedEvents(from: 0)
        let first = m.observe([Self.zoom([Self.builtIn])], scope: [], now: 0)
        #expect(first.events.isEmpty)
        #expect(first.recheckAt == 1.5)
        #expect(m.state.micGuard == .meetingUsesPhysicalMic)
        #expect(!m.state.allowsPushToTalk)
        // It follows within the window: nothing said at all.
        #expect(m.observe([Self.zoom([Self.mic])], scope: [], now: 0.6).events.isEmpty)
        #expect(m.observe([Self.zoom([Self.mic])], scope: [], now: 2).events.isEmpty)
    }

    @Test func startWindowThenRedForReal() {
        var m = P.Monitor(config: .init(startSettle: 1.5))
        m.holdRedEvents(from: 0)
        #expect(m.observe([Self.zoom([Self.builtIn])], scope: [], now: 0).events.isEmpty)
        #expect(m.observe([Self.zoom([Self.builtIn])], scope: [], now: 1).events.isEmpty)
        // The recheck at the window's end, no change in the HAL: said exactly once.
        let atEnd = m.observe([Self.zoom([Self.builtIn])], scope: [], now: 1.5)
        #expect(atEnd.events == [.turnedRed(appID: "us.zoom.xos", app: "Zoom", device: "MacBook Pro Microphone")])
        #expect(m.observe([Self.zoom([Self.builtIn])], scope: [], now: 3.5).events.isEmpty)
    }

    @Test func resetForgetsEverything() {
        var m = P.Monitor()
        _ = m.observe([Self.zoom([Self.builtIn])], scope: [], now: 0)
        m.audioRestarted()
        m.reset()
        #expect(m.state == P.State())
        // A red after the reset is reported again.
        #expect(m.observe([Self.zoom([Self.builtIn])], scope: [], now: 1).events.count == 1)
    }
}

@Suite struct OutputRouteTransportTests {
    @Test func fourCCs() {
        typealias T = OutputRouteClassifier.Transport
        #expect(T(fourCC: "bltn") == .builtIn)
        #expect(T(fourCC: "usb ") == .usb)
        #expect(T(fourCC: "blue") == .bluetooth)
        #expect(T(fourCC: "blea") == .bluetoothLE)
        #expect(T(fourCC: "hdmi") == .hdmi)
        #expect(T(fourCC: "dprt") == .displayPort)
        #expect(T(fourCC: "airp") == .airPlay)
        #expect(T(fourCC: "thun") == .thunderbolt)
        #expect(T(fourCC: "pci ") == .pci)
        #expect(T(fourCC: "1394") == .firewire)
        #expect(T(fourCC: "virt") == .virtual)
        #expect(T(fourCC: "grup") == .aggregate)
        #expect(T(fourCC: "fgrp") == .aggregate)
        #expect(T(fourCC: "eavb") == .virtual)                   // unrecognized: a speaker (rt-core, decision A)
        #expect(T(fourCC: "0x00000000") == .unknown)
    }

    /// Only "no transport" is `.unknown`; every code the classifier has no case for is a speaker,
    /// even when the device is named External Headphones (§3.7 "其余一律算外放").
    @Test func unrecognizedCodesAreSpeakersAndOnlyNoTransportIsUnknown() {
        typealias T = OutputRouteClassifier.Transport
        #expect(T(fourCC: "") == .unknown)
        for code in ["eavb", "ccwd", "ccwl", "rscr", "rstr", "zzzz", "0x7a7a7a00"] {
            #expect(T(fourCC: code) == .virtual, "\(code)")
            let d = OutputRouteClassifier.Device(uid: "x", name: OutputRouteClassifier.externalHeadphonesName, transport: T(fourCC: code))
            #expect(OutputRouteClassifier.classify(d, confirmedHeadphones: ["x"]) == .speaker, "\(code)")
        }
        let noTransport = OutputRouteClassifier.Device(uid: "x", name: OutputRouteClassifier.externalHeadphonesName,
                                                      transport: T(fourCC: "0x00000000"))
        #expect(OutputRouteClassifier.classify(noTransport, confirmedHeadphones: []) == .headphones)
    }
}
