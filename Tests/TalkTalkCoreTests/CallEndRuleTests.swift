import Testing
@testable import TalkTalkCore



@Suite struct CallEndRuleTests {
    static let zoomIn = CallEndRule.Process(appID: "us.zoom.xos", pid: 100, isRunningInput: true, isRunningOutput: false)
    static let zoomOut = CallEndRule.Process(appID: "us.zoom.xos", pid: 100, isRunningInput: false, isRunningOutput: true)
    static let zoomIdle = CallEndRule.Process(appID: "us.zoom.xos", pid: 100, isRunningInput: false, isRunningOutput: false)
    static let zoomHelperIdle = CallEndRule.Process(appID: "us.zoom.xos", pid: 101, isRunningInput: false, isRunningOutput: false)
    static let chromeOut = CallEndRule.Process(appID: "com.google.Chrome", pid: 200, isRunningInput: false, isRunningOutput: true)
    static let chromeIdle = CallEndRule.Process(appID: "com.google.Chrome", pid: 200, isRunningInput: false, isRunningOutput: false)

    /// (time, processes) sequences with the expected verdict after each step.
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let scope: Set<String>
        let steps: [(Double, [CallEndRule.Process], CallEndRule.Verdict)]
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "in call, both directions count", scope: [], steps: [
            (0, [zoomIn], .inCall), (10, [zoomOut], .inCall), (50, [zoomIn, zoomHelperIdle], .inCall)]),
        Row(name: "30 s quiet ends the call", scope: [], steps: [
            (0, [zoomIn], .inCall), (2, [zoomIdle], .quiet(remaining: 30)), (20, [zoomIdle], .quiet(remaining: 12)),
            (31.9, [zoomIdle], .quiet(remaining: 0.1)), (32, [zoomIdle], .ended(.quiet))]),
        Row(name: "muted client stopping mic IO but still playing is in call", scope: [], steps: [
            (0, [zoomOut], .inCall), (100, [zoomOut], .inCall)]),
        Row(name: "activity resets the quiet timer", scope: [], steps: [
            (0, [zoomIdle], .quiet(remaining: 30)), (29, [zoomIn], .inCall), (30, [zoomIdle], .quiet(remaining: 30)),
            (59, [zoomIdle], .quiet(remaining: 1)), (60, [zoomIdle], .ended(.quiet))]),
        Row(name: "process exited ends immediately", scope: [], steps: [
            (0, [zoomIn], .inCall), (1, [], .ended(.exited))]),
        Row(name: "every resolved process must be quiet", scope: [], steps: [
            (0, [zoomIdle, chromeOut], .inCall), (40, [zoomIdle, chromeOut], .inCall),
            (41, [zoomIdle, chromeIdle], .quiet(remaining: 30)), (71, [zoomIdle, chromeIdle], .ended(.quiet))]),
        Row(name: "scope limits to the session's apps", scope: ["us.zoom.xos"], steps: [
            (0, [zoomIdle, chromeOut], .quiet(remaining: 30)), (30, [zoomIdle, chromeOut], .ended(.quiet))]),
        Row(name: "scoped app gone → exited even if others play", scope: ["us.zoom.xos"], steps: [
            (0, [zoomIn, chromeOut], .inCall), (5, [chromeOut], .ended(.exited))]),
    ]

    @Test(arguments: rows) func table(_ row: Row) {
        var st = CallEndRule.State(scope: row.scope)
        for (i, (t, procs, want)) in row.steps.enumerated() {
            let got = CallEndRule.observe(&st, processes: procs, now: t)
            switch (got, want) {
            case let (.quiet(a), .quiet(b)):
                #expect(abs(a - b) < 1e-9, "step \(i)")
            default:
                #expect(got == want, "step \(i)")
            }
        }
    }

    @Test func hasEnded() {
        #expect(CallEndRule.Verdict.ended(.quiet).hasEnded)
        #expect(CallEndRule.Verdict.ended(.exited).hasEnded)
        #expect(!CallEndRule.Verdict.inCall.hasEnded)
        #expect(!CallEndRule.Verdict.quiet(remaining: 1).hasEnded)
    }
}
