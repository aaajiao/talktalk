import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkSession

/// Redesign §7: menu quick start, session header, scenario page rules and the phone StepTrack.
@Suite struct ScenarioFlowTests {
    @Test func quickStartUsesTheLastScenarioAndItsSource() {
        let first = MenuQuickStart.make(last: nil, sourceName: nil, remoteLanguage: "英语")
        #expect(first.mode == .meeting && first.title == "开始会议同传 · 自动" && first.subtitle == "英语 → 中文")
        let zoom = MenuQuickStart.make(last: .meeting, sourceName: MenuQuickStart.sourceName("us.zoom.xos"),
                                       remoteLanguage: "德语")
        #expect(zoom.title == "开始会议同传 · Zoom")
        #expect(zoom.subtitle == "德语 → 中文")
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

    @Test func bottomBarFollowsTheRunningScene() {
        let idle = ScenarioRunState(running: nil, phase: .idle, browsing: .phone)
        #expect(idle.action == .start(.phone) && idle.title == "准备" && idle.accessibilityLabel == "准备电话同传")
        #expect(idle.isEnabled && idle.help(systemInputSwitched: false) == nil && idle.runningSource(meetingApp: "Zoom") == nil)
        let running = ScenarioRunState(running: .meeting, phase: .running, browsing: .meeting)
        #expect(running.action == .end(.meeting) && running.title == "结束" && running.symbol == "stop.fill")
        #expect(running.accessibilityLabel == "结束会议同传")
        #expect(running.help(systemInputSwitched: false) == SubtitleScene.meeting.endHelp(systemInputSwitched: false))
        #expect(running.runningSource(meetingApp: "Zoom") == "Zoom")
        // Browsing another scene: no banner; the button is disabled and names what to end first.
        let other = ScenarioRunState(running: .meeting, phase: .running, browsing: .captions)
        #expect(other.action == .blocked(running: .meeting) && !other.isEnabled && other.title == "开始")
        #expect(other.help(systemInputSwitched: true) == "先结束会议同传")
        let stopping = ScenarioRunState(running: .phone, phase: .stopping, browsing: .meeting)
        #expect(stopping.title == "结束中…" && stopping.symbol == nil && !stopping.isEnabled)
        #expect(stopping.runningSource(meetingApp: nil) == nil)
        #expect(ScenarioRunState(running: .phone, phase: .running, browsing: .phone).runningSource(meetingApp: nil) == "Phone")
        #expect(ScenarioRunState(running: .captions, phase: .starting, browsing: .captions).title == "准备中…")
        // 准备中… on another scene's page names the scene that prepares; a download says so.
        let preparing = ScenarioRunState(running: .phone, phase: .starting, browsing: .meeting)
        #expect(preparing.help(systemInputSwitched: false) == "正在准备电话同传…")
        #expect(ScenarioRunState(running: .phone, phase: .starting, browsing: .phone).help(systemInputSwitched: false) == nil)
        #expect(preparing.help(systemInputSwitched: false, downloadingAssets: true) == "下载中")
        #expect(stopping.help(systemInputSwitched: false, downloadingAssets: true) == "正在结束电话同传…")
        // The menu's and the page's start wait for the same reasons.
        #expect(ScenarioRunState.startBlocked(onboardingNeeded: true, available: false) == "完成引导后可用")
        #expect(ScenarioRunState.startBlocked(onboardingNeeded: false, available: false)
                == "请先结束正在运行的自检或说话测试，或等待语音资源维护完成。")
        #expect(ScenarioRunState.startBlocked(onboardingNeeded: false, available: true) == nil)
    }

    @Test func phoneDeliverySaysWhereMyVoiceGoes() {
        #expect(PhoneDelivery(.translating) == .sentToPhone && PhoneDelivery(.original)?.text == "已送入 Phone")
        #expect(PhoneDelivery(.phoneLocalOnly)?.text == "仅本机 · Phone 未接收")
        #expect(PhoneDelivery(.phoneNotConnected)?.text == "接通后对方才能听到你")
        #expect(PhoneDelivery(.notSent)?.text == "未发送" && PhoneDelivery(.unavailable) == .notSent)
        #expect(PhoneDelivery(.original)?.symbol == SubtitleTokens.VoiceIcon.sentToPhone)
        #expect(PhoneDelivery(.phoneLocalTrial)?.symbol == SubtitleTokens.VoiceIcon.thisMac)
        // The risk capsule stands alone: no "仅本机" beside "对方能听到原声".
        #expect(PhoneDelivery(.remoteHearsOriginal) == nil)
        // 松开确认 before Phone reads TalkTalk Mic stays on this Mac.
        #expect(PhoneDelivery(.switching, phoneInputConfirmed: false) == .thisMacOnly)
        #expect(PhoneDelivery(.switching, phoneInputConfirmed: true) == .sentToPhone)
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
                                       readyToDial: false, callAudioActive: false)
        #expect(idle.prepare == .pending && !idle.dialEnabled)
        let starting = PhoneChecklist.make(phoneSession: true, starting: true, stopping: false, active: false,
                                           readyToDial: false, callAudioActive: false)
        #expect(starting.prepare == .inProgress && !starting.dialEnabled)
        // Prepared and no call audio yet: the dial step is open and waits (the app never dials).
        let ready = PhoneChecklist.make(phoneSession: true, starting: false, stopping: false, active: true,
                                        readyToDial: true, callAudioActive: false)
        #expect(ready.prepare == .done && ready.dialEnabled && ready.dial == .pending)
        let call = PhoneChecklist.make(phoneSession: true, starting: false, stopping: false, active: true,
                                       readyToDial: true, callAudioActive: true)
        #expect(call.dial == .done && call.finish == .pending)
        let stopping = PhoneChecklist.make(phoneSession: true, starting: false, stopping: true, active: true,
                                           readyToDial: true, callAudioActive: false)
        #expect(stopping.prepare == .inProgress && stopping.finish == .inProgress)
        // Readiness lost after it was reached (barrier, physical mic) keeps ① and ② as they were.
        let lost = PhoneChecklist.make(phoneSession: true, starting: false, stopping: false, active: true,
                                       readyToDial: false, callAudioActive: true, wasReady: true)
        #expect(lost.prepare == .done && lost.dialEnabled && lost.dial == .done)
        let neverReady = PhoneChecklist.make(phoneSession: true, starting: false, stopping: false, active: true,
                                             readyToDial: false, callAudioActive: false, wasReady: false)
        #expect(neverReady.prepare == .inProgress && !neverReady.dialEnabled)
    }
}
