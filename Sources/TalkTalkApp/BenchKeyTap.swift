import Foundation
import TalkTalkCore
import TalkTalkSession

/// `--bench keytap --inject` only replays pure state-machine events into an in-memory sink.
/// The ordinary mode observes real user input; it never opens a mic, Feed, or output device.
func runBenchKeyTap() -> Never {
    #if TALKTALK_DEV
    do {
        if arguments.contains("--inject") {
            let result = try keyShortcutBench()
            writeResult(result, to: argumentValue("--out"))
            exit(result["opens"] == 0 ? 0 : 1)
        }
        let requested = Double(argumentValue("--seconds") ?? "") ?? 30
        let seconds = requested.isFinite ? min(120, max(1, requested)) : 30
        let counts = KeyTapCounts()
        let tap = KeyTap(scope: .meeting) { counts.receive($0) }
        try tap.start()
        if arguments.contains("--stall") {
            Thread.sleep(forTimeInterval: seconds / 2)
            tap.stallForBench()
            Thread.sleep(forTimeInterval: seconds / 2 + 1.1)
        } else { Thread.sleep(forTimeInterval: seconds) }
        tap.stop()
        writeResult(counts.result, to: argumentValue("--out"))
        exit(0)
    } catch {
        writeResult(["ok": 0, "tapUnavailable": 1], to: argumentValue("--out"))
        exit(1)
    }
    #else
    fail("--bench keytap exists only in the dev build")
    #endif
}

#if TALKTALK_DEV
private final class KeyTapCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = ["ok": 1, "secureInputSeen": 0, "pollGapMaxMs": 0]
    private var previousPoll: HostTime?
    func receive(_ event: KeyInputEvent) {
        lock.withLock {
            let key: String
            switch event.kind {
            case .flagsChanged: key = "modifierEvents"
            case .keyDown: key = "keyDownEvents"
            case .keyUp: key = "keyUpEvents"
            case .mouseDown: key = "mouseDownEvents"
            case .scroll: key = "scrollEvents"
            case .mouseMoved: key = "movementEvents"
            case .tapEnabled: key = "tapEnables"
            case .tapDisabled: key = "tapDisables"
            case let .poll(snapshot):
                key = "polls"
                if snapshot.secureInput == true { counts["secureInputSeen"] = 1 }
                if let previousPoll { counts["pollGapMaxMs"] = max(counts["pollGapMaxMs"] ?? 0, HostClock.ms(previousPoll, to: event.time)) }
                previousPoll = event.time
            }
            counts[key, default: 0] += 1
        }
    }
    var result: [String: Int] { lock.withLock { counts } }
}

private func keyShortcutBench() throws -> [String: Int] {
    let profile = try PolicyProfile.loadDefault().speak.passthrough
    let context = PassthroughKeyMachine.DevInjection(benchMode: true, otherTalkTalkMicReaders: 0)
    var opens = 0
    // Five shortcut families × 34 offsets = 170. No CGEvent posting, real key state, or HAL calls.
    for family in 0..<5 {
        for offset in 0..<34 {
            let sink = InMemoryPassthroughStateSink(keepsHistory: true)
            let gate = PassthroughGate(config: .init(profile: profile), sink: sink)
            gate.updateFacts(at: 0) { $0 = .allGood }
            gate.setMicWarm(true); gate.setCueAudible(false)
            let controller = PassthroughController(machine: .init(config: .init(profile: profile)!), gate: gate)
            func send(_ kind: KeyInputEvent.Kind, _ ms: Int) {
                controller.inject(.init(time: HostTime(ms) * 1_000_000, kind: kind), context)
            }
            send(.tapEnabled, 0)
            send(.flagsChanged(keyCode: KeyCode.rightCommand, flags: [.command, .deviceRightCommand]), 1)
            let delay = offset * 390 / 33
            for ms in stride(from: 20, through: delay, by: 20) {
                send(.poll(.init(keysDown: [KeyCode.rightCommand], flags: [.command, .deviceRightCommand], secureInput: false)), ms + 1)
            }
            if family == 4 { send(.mouseDown, delay + 1) }
            else { send(.keyDown(keyCode: [8, 9, 48, 49][family], isRepeat: false), delay + 1) }
            for ms in stride(from: delay + 20, through: 600, by: 20) {
                send(.poll(.init(keysDown: [], flags: [], secureInput: false)), ms + 1)
            }
            opens += Set(sink.history.filter(\.open).map(\.generation)).count
        }
    }
    // The real Mic zero deadline requires P3/P6 and a device measurement; do not fabricate it.
    return ["cases": 170, "opens": opens, "physicalZeroLatencyMeasured": 0]
}
#endif
