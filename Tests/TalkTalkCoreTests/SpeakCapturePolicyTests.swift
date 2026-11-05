import Testing
@testable import TalkTalkCore

@Suite struct SpeakCapturePolicyTests {
    @Test func floorNeverCrossesPreviousAudioOrPassthrough() {
        var seed: UInt64 = 5, previous: UInt64 = 0
        for _ in 0..<256 {
            seed = seed &* 6364136223846793005 &+ 1
            let down = previous + seed % 100_000_000_000
            let close = down > 100_000_000 ? down - 100_000_000 : 0
            let floor = PrerollFloor.compute(keyDown: down, prerollMs: 300, previousClipEnd: previous, passthroughClosedAt: close)
            #expect(floor >= previous && floor >= close)
            #expect(floor >= (down > 300_000_000 ? down - 300_000_000 : 0))
            previous = down + seed % 60_000_000_000
        }
    }
    @Test func hotMicRequiresConfirmedReader() {
        let green = MeetingMicGuardPlan.State(verdict: .green(appID: "zoom", app: "Zoom"))
        #expect(HotMicPolicy.shouldOpen(meetingActive: true, enabled: true, guardState: green))
        #expect(!HotMicPolicy.shouldOpen(meetingActive: false, enabled: true, guardState: green))
        #expect(!HotMicPolicy.shouldOpen(meetingActive: true, enabled: false, guardState: green))
        #expect(!HotMicPolicy.shouldOpen(meetingActive: true, enabled: true, guardState: .init(verdict: .noReader)))
        #expect(!HotMicPolicy.shouldOpen(meetingActive: true, enabled: true, guardState: .init(verdict: green.verdict, awaitingConfirmation: true)))
    }
    @Test func cutterCapsUsesDipAndCompletesOnlyVoicedRemainder() throws {
        let p = try TestResources.profile().speak
        var cutter = SpeakClipCutter(start: 1_000_000_000, profile: p)
        var cuts: [SpeakClipCutter.Cut] = []
        for i in 0..<225 {
            let at = UInt64(1_000_000_000 + i * 20_000_000)
            cuts += cutter.push(start: at, end: at + 20_000_000, voiced: !(190..<200).contains(i), rmsDb: -20)
        }
        #expect(cuts.count == 1)
        #expect(cuts[0].reason == .vadDip)
        #expect(cuts[0].end == 4_900_000_000)
        #expect(cuts.allSatisfy { $0.end - $0.start <= 4_500_000_000 })
        let last = cutter.release(at: 5_500_000_000, trailingSilenceMs: 300)
        #expect(last.count == 1 && last[0].isFinal)
        #expect(cutter.finished)
        var short = SpeakClipCutter(start: 0, profile: p)
        _ = short.push(start: 0, end: 200_000_000, voiced: true, rmsDb: -20)
        #expect(short.release(at: 200_000_000, trailingSilenceMs: 300).isEmpty)
        #expect(short.finished)
    }

    @Test func releaseCapturesOnlyMissingTail() throws {
        var cutter = SpeakClipCutter(start: 0, profile: try TestResources.profile().speak)
        _ = cutter.push(start: 0, end: 500_000_000, voiced: true, rmsDb: -20)
        #expect(cutter.release(at: 500_000_000, trailingSilenceMs: 100).isEmpty)
        #expect(cutter.push(start: 500_000_000, end: 640_000_000, voiced: false, rmsDb: -90).isEmpty)
        let cuts = cutter.push(start: 640_000_000, end: 660_000_000, voiced: false, rmsDb: -90)
        #expect(cuts.count == 1 && cuts[0].end == 650_000_000 && cuts[0].isFinal)
    }
}
