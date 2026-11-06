import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkSession

/// Redesign §7: menu quick start, session header, scenario page rules and the phone checklist.
@Suite struct ScenarioFlowTests {
    @Test func quickStartUsesTheLastScenarioAndItsSource() {
        let first = MenuQuickStart.make(last: nil, sourceName: nil, remoteLanguage: "英语")
        #expect(first.mode == .meeting && first.title == "开始会议同传 · 自动选择" && first.lastLine == nil)
        let zoom = MenuQuickStart.make(last: .meeting, sourceName: MenuQuickStart.sourceName("us.zoom.xos"),
                                       remoteLanguage: "英语")
        #expect(zoom.title == "开始会议同传 · Zoom")
        #expect(zoom.lastLine == "上次：会议同传 · 英语 → 中文")
        #expect(MenuQuickStart.make(last: .phone, sourceName: "Zoom", remoteLanguage: "德语").title == "准备电话同传")
        #expect(MenuQuickStart.make(last: .captions, sourceName: "Safari", remoteLanguage: "英语").title
                == "开始视频字幕 · Safari")
        #expect(MenuQuickStart.sourceName("") == nil)
    }

    @Test func preferencesRoundTrip() {
        let name = "talktalk.tests.scenario.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ScenarioPreferences.requested(defaults: defaults) == .meeting)
        #expect(ScenarioPreferences.last(defaults: defaults) == nil)
        ScenarioPreferences.setRequested(.captions, defaults: defaults)
        ScenarioPreferences.setLast(.phone, defaults: defaults)
        #expect(ScenarioPreferences.requested(defaults: defaults) == .captions)
        #expect(ScenarioPreferences.last(defaults: defaults) == .phone)
    }

    @Test func sessionHeaderAndClock() {
        #expect(SessionClock.elapsed(723) == "12:03")
        #expect(SessionClock.elapsed(3723) == "1:02:03")
        #expect(SessionClock.elapsed(-5) == "0:00")
        #expect(MenuSessionHeader.title(mode: .meeting, source: "Zoom", elapsed: 723) == "会议同传 · Zoom · 12:03")
        #expect(MenuSessionHeader.title(mode: .phone, source: "x", elapsed: nil) == "电话同传 · Phone")
        #expect(MenuSessionHeader.title(mode: .captions, source: nil, elapsed: 5) == "视频字幕 · 0:05")
    }

    @Test func runningScenarioBannerOnlyWhileBrowsingAnother() {
        let same = ScenarioRunState(running: .meeting, browsing: .meeting)
        #expect(same.banner == nil)
        #expect(same.runningLine(source: "Zoom") == "正在运行：会议同传 · Zoom")
        let other = ScenarioRunState(running: .meeting, browsing: .captions)
        #expect(other.banner?.text == "会议同传正在运行，结束后才能开始视频字幕")
        #expect(other.banner?.returnTitle == "回到会议同传")
        #expect(ScenarioRunState(running: nil, browsing: .phone).runningLine(source: nil) == nil)
        #expect(ScenarioRunState(running: .phone, browsing: .phone).runningLine(source: nil) == "正在运行：电话同传 · Phone")
        #expect(ScenarioRunState.cardSubtitle(elapsed: 723) == "运行中 · 12:03")
    }

    @Test func headerCollapseHasHysteresis() {
        #expect(!ScenarioHeaderCollapse.collapsed(offset: 10, wasCollapsed: false))
        #expect(ScenarioHeaderCollapse.collapsed(offset: 30, wasCollapsed: false))
        #expect(ScenarioHeaderCollapse.collapsed(offset: 10, wasCollapsed: true))
        #expect(!ScenarioHeaderCollapse.collapsed(offset: 2, wasCollapsed: true))
    }

    @Test func browserNoteOnlyForBrowsers() {
        #expect(ScenarioSourceNote.showsBrowserNote(selectedID: "com.google.Chrome"))
        #expect(!ScenarioSourceNote.showsBrowserNote(selectedID: "us.zoom.xos"))
        #expect(!ScenarioSourceNote.showsBrowserNote(selectedID: ""))
    }

    @Test func voiceToneFollowsTheCapsuleColour() {
        let original = VoiceState.resolve(audio: .original, scene: .meeting)
        #expect(original.appearance.tone == .original)
        #expect(VoiceState.resolve(audio: .translating, scene: .meeting).appearance.tone == .translate)
        #expect(VoiceState.resolve(audio: .phoneReady, scene: .phone).appearance.tone == .neutral)
        #expect(VoiceState.resolve(audio: .original, scene: .meeting, risk: .meetingNotUsingMic).appearance.tone == .risk)
        #expect(MeetingMode.captions.scene == .video && MeetingMode.phone.sceneSymbol == SubtitleTokens.SceneIcon.phone)
    }

    @Test func phoneChecklistDimsDialingUntilPrepared() {
        let idle = PhoneChecklist.make(phoneSession: false, starting: false, stopping: false, active: false,
                                       readyToDial: false, dialing: false, callAudioActive: false)
        #expect(idle.prepare == .pending && !idle.dialEnabled)
        let starting = PhoneChecklist.make(phoneSession: true, starting: true, stopping: false, active: false,
                                           readyToDial: false, dialing: false, callAudioActive: false)
        #expect(starting.prepare == .inProgress && !starting.dialEnabled)
        let ready = PhoneChecklist.make(phoneSession: true, starting: false, stopping: false, active: true,
                                        readyToDial: true, dialing: true, callAudioActive: false)
        #expect(ready.prepare == .done && ready.dialEnabled && ready.dial == .inProgress)
        let call = PhoneChecklist.make(phoneSession: true, starting: false, stopping: false, active: true,
                                       readyToDial: true, dialing: false, callAudioActive: true)
        #expect(call.dial == .done && call.finish == .pending)
        let stopping = PhoneChecklist.make(phoneSession: true, starting: false, stopping: true, active: true,
                                           readyToDial: true, dialing: false, callAudioActive: false)
        #expect(stopping.prepare == .inProgress && stopping.finish == .inProgress)
    }
}
