import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore

/// §7.5 StartupCheck framework, engine items 1–2 and permissions item 5 (m1-engine).
@Suite(.temporaryFiles) struct StartupCheckTests {
    struct Fixed: StartupCheckItem {
        let id: String
        let level: StartupCheckResult.Level
        let delayMs: Int
        func run() async -> StartupCheckResult {
            try? await Task.sleep(for: .milliseconds(delayMs))
            return StartupCheckResult(id: id, level: level, summary: id)
        }
    }

    /// Counts arrivals; `wait` returns true once `n` items have arrived, false after the timeout.
    actor Gate {
        let n: Int
        private var arrived = 0
        init(_ n: Int) { self.n = n }
        func arrive() { arrived += 1 }
        func all() -> Bool { arrived >= n }
    }

    /// Arrives at the gate, then waits for every other item: only possible when the runner starts
    /// them concurrently (a sequential runner leaves the first item alone until the timeout).
    struct Rendezvous: StartupCheckItem {
        let id: String
        let level: StartupCheckResult.Level
        let gate: Gate
        func run() async -> StartupCheckResult {
            await gate.arrive()
            let deadline = ContinuousClock.now + .seconds(10)
            while !(await gate.all()) {
                if ContinuousClock.now > deadline { return StartupCheckResult(id: id, level: level, summary: "alone") }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return StartupCheckResult(id: id, level: level, summary: "together")
        }
    }

    @Test func runnerKeepsItemOrder() async {
        let checker = StartupChecker(items: [Fixed(id: "a", level: .ok, delayMs: 60), Fixed(id: "b", level: .action, delayMs: 0),
                                             Fixed(id: "c", level: .notice, delayMs: 30)])
        let r = await checker.run()
        #expect(r.map(\.id) == ["a", "b", "c"])
        #expect(StartupChecker.worst(r) == .action)
        #expect(StartupChecker.worst([]) == .ok)
    }

    /// Concurrency itself, not wall time (wall time flaked under parallel builds: 0.76 s vs 550 ms).
    @Test func runnerRunsItemsConcurrently() async {
        let gate = Gate(3)
        let checker = StartupChecker(items: ["a", "b", "c"].map { Rendezvous(id: $0, level: .ok, gate: gate) })
        let r = await checker.run()
        #expect(r.map(\.id) == ["a", "b", "c"])
        #expect(r.map(\.summary) == ["together", "together", "together"])
    }

    @Test func engineNotInstalledNeedsAction() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-sc-\(UUID().uuidString)")
        let r = await EngineStartupCheck(installation: EngineInstallation(engineHome: dir)).run()
        #expect(r.id == "engine")
        #expect(r.level == .action)
        #expect(r.summary == "not installed")
    }

    @Test func engineUnfinishedNeedsAction() async throws {
        let dir = try TestTemporaryDirectory.make(prefix: "tt-sc")
        try Data("{}".utf8).write(to: dir.appendingPathComponent("install.json.prev"))
        let r = await EngineStartupCheck(installation: EngineInstallation(engineHome: dir)).run()
        #expect(r.level == .action)
        #expect(r.summary.hasPrefix("unfinished"))
    }

    @Test func permissions() async {
        let all = PermissionsStartupCheck(microphone: { .granted }, inputMonitoring: { true }, speechRecognition: { .granted })
        #expect(await all.run().level == .ok)
        let some = PermissionsStartupCheck(microphone: { .denied }, inputMonitoring: { false }, speechRecognition: { .notDetermined })
        let r = await some.run()
        #expect(r.level == .action)
        #expect(r.summary == "missing: microphone, input_monitoring, speech_recognition")
        #expect(r.details == ["microphone": "denied", "input_monitoring": "not_granted", "speech_recognition": "not_determined"])
    }
}
