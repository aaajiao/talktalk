import CoreGraphics
import Foundation
import Testing
@testable import TalkTalkCore
@testable import TalkTalkSession

private final class KeyActions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PushToTalkKey.Action] = []
    private var rawOpenValues: [Bool] = []
    func add(_ value: PushToTalkKey.Action, rawOpen: Bool? = nil) {
        lock.withLock { values.append(value); if let rawOpen { rawOpenValues.append(rawOpen) } }
    }
    var all: [PushToTalkKey.Action] { lock.withLock { values } }
    var rawOpenOnAction: [Bool] { lock.withLock { rawOpenValues } }
}

private func keyProfile() throws -> PolicyProfile.Speak {
    try PolicyProfile.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/PolicyProfile.default.json")).speak
}
private func ns(_ ms: Int) -> HostTime { HostTime(ms) * 1_000_000 }
private let optionFlags: ModifierFlags = [.option, .deviceRightOption]
private let commandFlags: ModifierFlags = [.command, .deviceRightCommand]

@Suite struct KeyTapTranslateTests {
    @Test func translationPreservesTimeBitsAndSource() throws {
        let e = try #require(KeyTap.translate(type: .flagsChanged, keyCode: KeyCode.rightOption,
                                             flags: optionFlags.rawValue, sourceStateID: 1, at: 123))
        #expect(e == .init(time: 123, kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        let repeated = KeyTap.translate(type: .keyDown, keyCode: 8, isRepeat: true, sourceStateID: -1, at: 456)
        #expect(repeated == .init(time: 456, kind: .keyDown(keyCode: 8, isRepeat: true), source: .other))
        #expect(KeyTap.translate(type: .mouseMoved, dx: 3, dy: -2, at: 789)?.kind == .mouseMoved(dx: 3, dy: -2))
        #expect(KeyTap.translate(type: .tapDisabledByTimeout, at: 1)?.kind == .tapDisabled(.disabledByTimeout))
        #expect(KeyTap.translate(type: .tapDisabledByUserInput, at: 2)?.kind == .tapDisabled(.disabledByUserInput))
        #expect(KeyTap.translate(type: .null, at: 0) == nil)
    }
}

@Suite struct KeyTapPollingTests {
    @Test func modifierSidesFollowSamePollFlagsWithoutChangingOtherKeys() {
        let groups: [(ModifierFlags, ModifierFlags, ModifierFlags, UInt16, UInt16)] = [
            (.option, .deviceLeftOption, .deviceRightOption, KeyCode.option, KeyCode.rightOption),
            (.command, .deviceLeftCommand, .deviceRightCommand, KeyCode.command, KeyCode.rightCommand),
            (.control, .deviceLeftControl, .deviceRightControl, KeyCode.control, KeyCode.rightControl),
            (.shift, .deviceLeftShift, .deviceRightShift, KeyCode.shift, KeyCode.rightShift),
        ]
        let other: Set<UInt16> = [8, KeyCode.capsLock, KeyCode.function]
        for (independent, left, right, leftCode, rightCode) in groups {
            #expect(KeyTap.normalizedPolledKeys(other.union([leftCode]), flags: [independent, right]) == other.union([rightCode]))
            #expect(KeyTap.normalizedPolledKeys(other.union([rightCode]), flags: [independent, left]) == other.union([leftCode]))
            #expect(KeyTap.normalizedPolledKeys(other.union([leftCode]), flags: [independent, left, right]) == other.union([leftCode, rightCode]))
            #expect(KeyTap.normalizedPolledKeys(other.union([leftCode]), flags: independent) == other.union([leftCode]))
            #expect(KeyTap.normalizedPolledKeys(other.union([leftCode]), flags: right) == other.union([leftCode]))
        }
    }

    @Test func rightOptionAliasSurvivesFirstPollButChordsStillCancel() throws {
        let profile = try keyProfile()
        let scenarios: [(Set<UInt16>, ModifierFlags, Bool)] = [
            ([KeyCode.option], optionFlags, false),
            ([KeyCode.option], [.option, .deviceLeftOption, .deviceRightOption], true),
            ([KeyCode.option, 8], optionFlags, true),
            ([KeyCode.option], [.option], true), // no side data: keep the raw left/aggregate key
            ([KeyCode.option], [.deviceRightOption], true), // inconsistent flags are not evidence
        ]
        for (raw, flags, cancelled) in scenarios {
            let actions = KeyActions()
            let key = PushToTalkKey(config: .init(speak: profile), onAction: { actions.add($0) })
            key.setAvailability(.allowed, at: 0)
            key.handle(.init(time: 0, kind: .tapEnabled))
            key.handle(.init(time: ns(1), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
            key.handle(.init(time: ns(20), kind: .poll(.init(keysDown: KeyTap.normalizedPolledKeys(raw, flags: flags),
                                                            flags: flags, secureInput: false))))
            if cancelled {
                #expect(actions.all == [.machine(.began(at: ns(1))), .machine(.cancelled(at: ns(20)))])
                #expect(key.phase == .mustRelease)
            } else {
                #expect(actions.all == [.machine(.began(at: ns(1)))])
                #expect(key.isActive)
            }
        }
    }
}

@Suite struct PushToTalkKeyTests {
    @Test func toggleIgnoresChordsAndKeepsRecordingThroughTypingAndMouse() throws {
        let actions = KeyActions()
        let key = PushToTalkKey(config: .init(speak: try keyProfile()), interaction: .toggle,
                               onAction: { actions.add($0) })
        key.setAvailability(.allowed, at: 0)
        key.handle(.init(time: 0, kind: .tapEnabled))
        key.handle(.init(time: 0, kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        key.handle(.init(time: ns(1), kind: .keyDown(keyCode: 8, isRepeat: false)))
        key.handle(.init(time: ns(2), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.handle(.init(time: ns(3), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        key.handle(.init(time: ns(4), kind: .keyUp(keyCode: 8)))
        key.handle(.init(time: ns(10), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.handle(.init(time: ns(15), kind: .keyDown(keyCode: 8, isRepeat: false)))
        key.handle(.init(time: ns(16), kind: .keyUp(keyCode: 8)))
        key.handle(.init(time: ns(20), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        #expect(actions.all.isEmpty && !key.recordingActive)

        key.handle(.init(time: ns(30), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.handle(.init(time: ns(40), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        key.handle(.init(time: ns(50), kind: .keyDown(keyCode: 8, isRepeat: false)))
        key.handle(.init(time: ns(60), kind: .keyUp(keyCode: 8)))
        key.handle(.init(time: ns(70), kind: .mouseDown))
        key.handle(.init(time: ns(80), kind: .scroll))
        key.handle(.init(time: ns(90), kind: .mouseMoved(dx: 20, dy: 10)))
        key.handle(.init(time: ns(100), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(key.recordingActive && key.isActive && key.needsPolling)
        // Option-scroll and Option-Command are gestures, not the stop toggle.
        key.handle(.init(time: ns(110), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.handle(.init(time: ns(120), kind: .scroll))
        key.handle(.init(time: ns(130), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        key.handle(.init(time: ns(140), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.handle(.init(time: ns(150), kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: optionFlags.union(commandFlags))))
        key.handle(.init(time: ns(160), kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: optionFlags)))
        key.handle(.init(time: ns(170), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        #expect(key.recordingActive && actions.all == [.machine(.began(at: ns(30)))])
        key.handle(.init(time: ns(180), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.handle(.init(time: ns(190), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        #expect(!key.recordingActive)
        #expect(actions.all == [.machine(.began(at: ns(30))), .machine(.released(at: ns(190), reason: .keyUp))])
    }

    @Test func lostReleaseAndMustReleaseKeepPolling() throws {
        let actions = KeyActions()
        let key = PushToTalkKey(config: .init(speak: try keyProfile()), onAction: { actions.add($0) })
        key.setAvailability(.allowed, at: 0)
        key.handle(.init(time: 0, kind: .tapEnabled))
        key.handle(.init(time: ns(1), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.handle(.init(time: ns(500), kind: .poll(.init(keysDown: [], flags: []))))
        #expect(key.needsPolling && key.isActive)
        key.tick(now: ns(601))
        #expect(actions.all.last == .machine(.released(at: ns(500), reason: .lostKeyUp)))
        #expect(!key.needsPolling)
        key.handle(.init(time: ns(700), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.handle(.init(time: ns(720), kind: .keyDown(keyCode: 8, isRepeat: false)))
        #expect(key.phase == .mustRelease && key.needsPolling)
        key.handle(.init(time: ns(740), kind: .poll(.init(keysDown: [], flags: []))))
        #expect(!key.needsPolling)
    }

    @Test func blockedHoldNeverResumesAndDoesNotCountTowardDoubleTap() throws {
        let actions = KeyActions()
        let key = PushToTalkKey(config: .init(speak: try keyProfile()), onAction: { actions.add($0) })
        key.handle(.init(time: 0, kind: .tapEnabled))
        key.handle(.init(time: ns(1), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        #expect(actions.all == [.refused(at: ns(1), reason: .notInSession)])
        key.setAvailability(.allowed, at: ns(20))
        key.handle(.init(time: ns(30), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        #expect(actions.all.count == 1)
        for down in [100, 200] {
            key.handle(.init(time: ns(down), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
            key.handle(.init(time: ns(down + 40), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        }
        #expect(actions.all.last == .machine(.doubleTapped(at: ns(240))))
    }

    @Test func maxHoldAndAvailabilityCancel() throws {
        let actions = KeyActions()
        let key = PushToTalkKey(config: .init(speak: try keyProfile()), onAction: { actions.add($0) })
        key.setAvailability(.allowed, at: 0)
        key.handle(.init(time: 0, kind: .tapEnabled))
        key.handle(.init(time: ns(1), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.tick(now: ns(60_001))
        #expect(actions.all.last == .machine(.released(at: ns(60_001), reason: .maxHold)))
        #expect(key.needsPolling)
        key.handle(.init(time: ns(60_020), kind: .poll(.init(keysDown: [], flags: []))))
        key.handle(.init(time: ns(60_040), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        key.setAvailability(.blocked(.meetingUsesPhysicalMic), at: ns(60_050))
        #expect(actions.all.last == .machine(.cancelled(at: ns(60_050))))
    }
}

@Suite struct PassthroughRuntimeTests {
    private func runtime(scope: KeyTap.Scope = .meeting, diagnostics: Bool = false,
                         log: EventLog? = nil, actions: KeyActions = KeyActions(), automatic: Bool = false,
                         interaction: PushToTalkKey.Interaction = .hold) throws -> (PassthroughRuntime, InMemoryPassthroughStateSink) {
        let sink = InMemoryPassthroughStateSink()
        let runtime = PassthroughRuntime(profile: try keyProfile(), scope: scope, diagnosticsEnabled: diagnostics,
                                         automaticOriginal: automatic, interaction: interaction, sink: sink, log: log,
                                         onPushToTalk: { actions.add($0, rawOpen: sink.current.open) })
        runtime.updateFacts(at: 0) { $0 = .allGood }
        runtime.gate.setMicWarm(true); runtime.gate.setCueAudible(false)
        runtime.handle(.init(time: 0, kind: .tapEnabled))
        runtime.handle(.init(time: 0, kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        if automatic {
            runtime.setTranslationBusy(false, at: 0)
            runtime.handle(.init(time: 0, kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        }
        return (runtime, sink)
    }
    private func open(_ runtime: PassthroughRuntime) {
        runtime.handle(.init(time: ns(1), kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: commandFlags)))
        for ms in stride(from: 21, through: 461, by: 20) {
            runtime.handle(.init(time: ns(ms), kind: .poll(.init(keysDown: [KeyCode.rightCommand], flags: commandFlags, secureInput: false))))
        }
    }

    @Test func toggleTwoTapsStartStopAndWaitForTranslationDrain() throws {
        let actions = KeyActions()
        let (runtime, sink) = try runtime(actions: actions, automatic: true, interaction: .toggle)
        runtime.handle(.init(time: ns(10), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        #expect(!sink.current.open && actions.all.isEmpty) // physical fence precedes gesture confirmation
        runtime.handle(.init(time: ns(40), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        let recording = runtime.meetingAudioSnapshot(at: ns(40))
        #expect(recording.held == false && recording.recordingActive && recording.busy && !recording.originalOpen)
        runtime.actionHandled(translationBusy: false, at: ns(50)) // even an idle pipeline cannot bypass the latch
        runtime.handle(.init(time: ns(60), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(!sink.current.open && runtime.meetingAudioSnapshot(at: ns(60)).recordingActive)
        runtime.handle(.init(time: ns(70), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        runtime.handle(.init(time: ns(100), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        #expect(actions.all == [.machine(.began(at: ns(10))), .machine(.released(at: ns(100), reason: .keyUp))])
        #expect(actions.rawOpenOnAction == [false, false]) // two quick taps never hard-clear the queue
        #expect(!runtime.meetingAudioSnapshot(at: ns(100)).recordingActive)
        runtime.setTranslationBusy(false, at: ns(110))
        runtime.handle(.init(time: ns(120), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(!sink.current.open) // released action has not reached the pipeline yet
        runtime.actionHandled(translationBusy: true, at: ns(130))
        runtime.handle(.init(time: ns(140), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(!sink.current.open)
        runtime.setTranslationBusy(false, at: ns(150))
        #expect(runtime.meetingAudioSnapshot(at: ns(150)).canRestoreOriginal && !sink.current.open)
        runtime.handle(.init(time: ns(160), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(sink.current.open)
        runtime.stop(at: ns(170))
    }

    @Test func toggleFaultsCancelAndRequireAnotherCleanTap() throws {
        for fault in 0..<3 {
            let actions = KeyActions()
            let (runtime, sink) = try runtime(actions: actions, automatic: true, interaction: .toggle)
            runtime.handle(.init(time: ns(10), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
            runtime.handle(.init(time: ns(40), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
            runtime.actionHandled(translationBusy: false, at: ns(50))
            switch fault {
            case 0: runtime.handle(.init(time: ns(60), kind: .poll(.init(keysDown: [], flags: [], secureInput: true))))
            case 1: runtime.systemEvent(.micFormatChanged, at: ns(60))
            default: runtime.handle(.init(time: ns(60), kind: .tapDisabled(.disabledByTimeout)))
            }
            #expect(actions.all.last == .machine(.cancelled(at: ns(60))))
            #expect(!runtime.meetingAudioSnapshot(at: ns(60)).recordingActive && !sink.current.open)
            runtime.handle(.init(time: ns(65), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
            runtime.actionHandled(translationBusy: false, at: ns(66))
            runtime.updateFacts(at: ns(70)) { $0.awaitingAudioConfirmation = false }
            runtime.handle(.init(time: ns(80), kind: .tapEnabled))
            runtime.handle(.init(time: ns(90), kind: .poll(.init(keysDown: [KeyCode.rightOption], flags: optionFlags, secureInput: false))))
            #expect(!runtime.meetingAudioSnapshot(at: ns(90)).recordingActive && !sink.current.open)
            runtime.handle(.init(time: ns(100), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
            runtime.handle(.init(time: ns(110), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
            #expect(sink.current.open && !runtime.meetingAudioSnapshot(at: ns(110)).recordingActive)
            runtime.handle(.init(time: ns(120), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
            runtime.handle(.init(time: ns(150), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
            #expect(actions.all.last == .machine(.began(at: ns(120))))
            #expect(runtime.meetingAudioSnapshot(at: ns(150)).recordingActive)
            runtime.stop(at: ns(160))
        }
    }

    @Test func toggleDemoRequiresRealKeyUpAndNeverUsesDoubleTapClear() throws {
        let actions = KeyActions()
        let (runtime, sink) = try runtime(scope: .onboarding, actions: actions, interaction: .toggle)
        runtime.handle(.init(time: ns(1), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags), source: .other))
        runtime.handle(.init(time: ns(20), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: []), source: .other))
        runtime.handle(.init(time: ns(30), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        runtime.handle(.init(time: ns(40), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        runtime.handle(.init(time: ns(150), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        runtime.handle(.init(time: ns(160), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        #expect(actions.all.isEmpty && !runtime.meetingAudioSnapshot(at: ns(160)).recordingActive)
        runtime.handle(.init(time: ns(170), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        runtime.handle(.init(time: ns(200), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        runtime.handle(.init(time: ns(210), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        runtime.handle(.init(time: ns(220), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        runtime.handle(.init(time: ns(330), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        runtime.handle(.init(time: ns(340), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        #expect(runtime.meetingAudioSnapshot(at: ns(340)).recordingActive)
        runtime.handle(.init(time: ns(350), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        runtime.handle(.init(time: ns(380), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        #expect(actions.all == [.machine(.began(at: ns(170))), .machine(.released(at: ns(380), reason: .keyUp))])
        #expect(!sink.current.open && !runtime.meetingAudioSnapshot(at: ns(380)).recordingActive)
        runtime.stop(at: ns(390))
    }

    @Test func automaticOriginalClosesBeforePTTActionsAndWaitsForDrain() throws {
        let actions = KeyActions()
        let (runtime, sink) = try runtime(actions: actions, automatic: true)
        #expect(sink.current.open && sink.current.openAt == 0)
        #expect(sink.current.source == .mic && sink.current.deadline == .max)
        let initial = runtime.meetingAudioSnapshot(at: 0)
        #expect(initial.held == false && !initial.busy && initial.originalOpen && initial.hardwarePollFresh)
        let firstGeneration = sink.current.generation
        runtime.updateFacts(at: ns(1)) { $0.settingEnabled = false } // retired manual preference
        runtime.handle(.init(time: ns(2), kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: commandFlags)))
        runtime.handle(.init(time: ns(20), kind: .poll(.init(keysDown: [KeyCode.rightCommand], flags: commandFlags, secureInput: false))))
        #expect(sink.current.open) // ordinary Command use is not an audio gate anymore
        runtime.handle(.init(time: ns(30), kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: [])))
        runtime.handle(.init(time: ns(40), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        #expect(!sink.current.open && runtime.translationHeld)
        let held = runtime.meetingAudioSnapshot(at: ns(40))
        #expect(held.held == true && held.busy && !held.originalOpen && !held.canRestoreOriginal)
        #expect(held.originalReadiness == .available) // PTT intent is not a hardware failure
        #expect(actions.all == [.machine(.began(at: ns(40)))])
        #expect(actions.rawOpenOnAction == [false]) // the synchronous fence precedes delivery

        runtime.handle(.init(time: ns(240), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        runtime.setTranslationBusy(false, at: ns(250)) // stale idle before queued actions ran
        let pendingRelease = runtime.meetingAudioSnapshot(at: ns(250))
        #expect(pendingRelease.held == false && pendingRelease.busy && !pendingRelease.canRestoreOriginal)
        runtime.handle(.init(time: ns(260), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(!sink.current.open)
        runtime.actionHandled(translationBusy: false, at: ns(270)) // began was handled
        runtime.handle(.init(time: ns(280), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(!sink.current.open)
        runtime.actionHandled(translationBusy: true, at: ns(290)) // released, translation still draining
        runtime.handle(.init(time: ns(300), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(!sink.current.open)
        runtime.setTranslationBusy(false, at: ns(310))
        #expect(!sink.current.open) // only a fresh hardware poll may open/renew
        let beforeSnapshot = sink.current
        let restoring = runtime.meetingAudioSnapshot(at: ns(310))
        #expect(restoring.held == false && !restoring.busy && !restoring.originalOpen)
        #expect(restoring.hardwarePollFresh && restoring.canRestoreOriginal)
        #expect(sink.current == beforeSnapshot) // display reads neither open nor renew the gate
        runtime.handle(.init(time: ns(320), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(sink.current.open && sink.current.openAt == ns(320))
        #expect(runtime.meetingAudioSnapshot(at: ns(320)).originalOpen)
        #expect(sink.current.generation != firstGeneration)
        #expect(actions.rawOpenOnAction.allSatisfy { !$0 })
        runtime.stop(at: ns(330))
        #expect(!sink.current.open)
        let stopped = runtime.meetingAudioSnapshot(at: ns(330))
        #expect(stopped.held == nil && !stopped.hardwarePollFresh && !stopped.canRestoreOriginal)
    }

    @Test func refusedPTTHoldsOriginalClosedUntilPhysicalRelease() throws {
        let actions = KeyActions()
        let (runtime, sink) = try runtime(actions: actions, automatic: true)
        runtime.updateFacts(at: ns(1)) { $0.selfTestRunning = true }
        runtime.handle(.init(time: ns(10), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        #expect(actions.all == [.refused(at: ns(10), reason: .awaitingAudioConfirmation)])
        runtime.updateFacts(at: ns(20)) { $0.selfTestRunning = false }
        runtime.setTranslationBusy(false, at: ns(20))
        runtime.handle(.init(time: ns(40), kind: .poll(.init(keysDown: [KeyCode.rightOption], flags: optionFlags, secureInput: false))))
        #expect(runtime.translationHeld && !sink.current.open)
        runtime.handle(.init(time: ns(80), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        runtime.handle(.init(time: ns(100), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(sink.current.open && !runtime.translationHeld)
        runtime.vad(speech: true, at: ns(50), reportedAt: ns(105))
        #expect(sink.current.open) // ordinary speech before reopening is allowed for default raw
        runtime.stop(at: ns(110))
    }

    @Test func automaticLeaseNeedsHardwarePollAndRecoveryNeedsFreshFacts() throws {
        let (runtime, sink) = try runtime(automatic: true)
        let lease = sink.current.leaseUntil
        let expired = runtime.meetingAudioSnapshot(at: lease)
        #expect(!expired.originalOpen && !expired.hardwarePollFresh && !expired.canRestoreOriginal)
        #expect(sink.current.open) // the read reports expiry without mutating the RT state
        runtime.setTranslationBusy(false, at: lease + 1)
        #expect(!sink.current.open && sink.current.leaseUntil == lease)
        runtime.handle(.init(time: ns(120), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(sink.current.open)
        runtime.systemEvent(.micFormatChanged, at: ns(130))
        let interrupted = runtime.meetingAudioSnapshot(at: ns(130))
        #expect(interrupted.held == nil && !interrupted.hardwarePollFresh && !interrupted.canRestoreOriginal)
        runtime.handle(.init(time: ns(140), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(!sink.current.open)
        let awaitingDevice = runtime.meetingAudioSnapshot(at: ns(140))
        #expect(awaitingDevice.hardwarePollFresh && !awaitingDevice.canRestoreOriginal)
        #expect(awaitingDevice.originalReadiness == .unavailable(.awaitingAudioConfirmation))
        runtime.updateFacts(at: ns(150)) { $0.awaitingAudioConfirmation = false }
        #expect(!sink.current.open)
        runtime.handle(.init(time: ns(160), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(sink.current.open)
        runtime.suspend(at: ns(170))
        #expect(!runtime.meetingAudioSnapshot(at: ns(170)).hardwarePollFresh)
        runtime.updateFacts(at: ns(180)) { $0.awaitingAudioConfirmation = false }
        runtime.handle(.init(time: ns(190), kind: .tapEnabled))
        runtime.handle(.init(time: ns(200), kind: .poll(.init(keysDown: [KeyCode.rightOption], flags: optionFlags, secureInput: false))))
        #expect(!sink.current.open)
        runtime.handle(.init(time: ns(220), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(sink.current.open)
        runtime.handle(.init(time: ns(221), kind: .poll(.init(keysDown: [], flags: [], secureInput: true))))
        let secure = runtime.meetingAudioSnapshot(at: ns(221))
        #expect(secure.hardwarePollFresh && !secure.canRestoreOriginal)
        #expect(secure.originalReadiness == .unavailable(.secureInput))
        runtime.handle(.init(time: ns(222), kind: .poll(.init(keysDown: [], flags: [], secureInput: nil))))
        #expect(!runtime.meetingAudioSnapshot(at: ns(222)).canRestoreOriginal)
        runtime.handle(.init(time: ns(223), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        runtime.updateFacts(at: ns(224)) { $0.speakerMode = true }
        let speaker = runtime.meetingAudioSnapshot(at: ns(224))
        #expect(speaker.originalReadiness == .unavailable(.speakerMode) && speaker.translationReadiness == .available)
        runtime.updateFacts(at: ns(225)) { $0.speakerMode = nil }
        #expect(runtime.meetingAudioSnapshot(at: ns(225)).translationReadiness == .unavailable(.unknown(.speakerMode)))
        runtime.updateFacts(at: ns(226)) { $0.speakerMode = false }
        runtime.handle(.init(time: ns(227), kind: .tapDisabled(.disabledByTimeout)))
        runtime.handle(.init(time: ns(228), kind: .tapEnabled))
        runtime.handle(.init(time: ns(229), kind: .poll(.init(keysDown: [], flags: [], secureInput: false)), source: .other))
        let unconfirmedPoll = runtime.meetingAudioSnapshot(at: ns(229))
        #expect(unconfirmedPoll.held == nil && !unconfirmedPoll.hardwarePollFresh && !unconfirmedPoll.canRestoreOriginal)
        runtime.handle(.init(time: ns(230), kind: .poll(.init(keysDown: [], flags: [], secureInput: false))))
        #expect(runtime.meetingAudioSnapshot(at: ns(230)).originalOpen)
        runtime.stop(at: ns(240))
        runtime.setTranslationBusy(false, at: ns(250))
        #expect(!sink.current.open)
    }

    @Test func systemEventsCloseAndRequireFreshPress() throws {
        for event in PassthroughSystemEvent.allCases {
            let (runtime, sink) = try runtime()
            open(runtime)
            #expect(sink.current.open)
            runtime.systemEvent(event, at: ns(470))
            #expect(!sink.current.open)
            runtime.updateFacts(at: ns(475)) { $0.awaitingAudioConfirmation = false }
            runtime.handle(.init(time: ns(481), kind: .poll(.init(keysDown: [KeyCode.rightCommand], flags: commandFlags, secureInput: false))))
            #expect(!sink.current.open)
            runtime.stop(at: ns(490))
        }
    }

    @Test func secureInputAndUnknownFactsRefuse() throws {
        let (runtime, sink) = try runtime()
        runtime.updateFacts(at: 0) { $0.speakerMode = nil }
        open(runtime)
        #expect(!sink.current.open)
        runtime.stop(at: ns(500))
        let (secure, secureSink) = try self.runtime()
        open(secure)
        #expect(secureSink.current.open)
        secure.handle(.init(time: ns(470), kind: .poll(.init(keysDown: [KeyCode.rightCommand], flags: commandFlags, secureInput: true))))
        #expect(!secureSink.current.open)
        secure.stop(at: ns(500))
    }

    @Test func onboardingAllowsPTTButNeverPassthrough() throws {
        let actions = KeyActions()
        let (runtime, sink) = try runtime(scope: .onboarding, actions: actions)
        runtime.updateFacts(at: 0) { $0.meetingModeActive = false; $0.micGuard = .noReaderOfTalkTalkMic }
        runtime.handle(.init(time: ns(1), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: optionFlags)))
        #expect(actions.all == [.machine(.began(at: ns(1)))])
        runtime.handle(.init(time: ns(100), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])))
        open(runtime)
        #expect(!sink.current.open)
        runtime.stop(at: ns(500))
    }

    @Test func stopLogsOnlyAggregateIntervalsWhenEnabled() throws {
        let log = EventLog(inMemory: { 0 })
        let (runtime, _) = try runtime(diagnostics: true, log: log)
        runtime.handle(.init(time: ns(1), kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: commandFlags)))
        runtime.handle(.init(time: ns(101), kind: .keyDown(keyCode: 8, isRepeat: false)))
        runtime.stop(at: ns(120)); runtime.stop(at: ns(130))
        let rows = log.recorded.filter { $0["ev"] as? String == "pt.intervals" }
        #expect(rows.count == 1)
        #expect(rows.first?["total"] as? Int == 1)
        #expect(rows.first?["bin_10"] as? Int == 1)
        #expect(rows.first?["key"] == nil)
        #if !TALKTALK_DEV
        let disabledLog = EventLog(inMemory: { 0 })
        let (disabled, _) = try self.runtime(log: disabledLog)
        disabled.stop(at: 0)
        #expect(!disabledLog.recorded.contains { $0["ev"] as? String == "pt.intervals" })
        #endif
    }
}
