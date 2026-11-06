import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkAudio
@testable import TalkTalkSession

@MainActor
@Suite struct PhoneSessionTests {
    private func candidate(_ bundle: String, input: Bool = false, output: Bool = false) -> MeetingCandidate {
        MeetingCandidate(app: MeetingApp.named(bundle)!, processes: [
            AudioProcessInfo(objectID: 1, pid: 100, bundleID: bundle, isRunningInput: input, isRunningOutput: output)
        ])
    }

    @Test func phonePreparationSelectsIdlePhoneInsteadOfAnActiveMeeting() {
        let phone = candidate(MeetingMode.phoneAppID)
        let zoom = candidate("us.zoom.xos", input: true, output: true)
        let faceTime = candidate("com.apple.FaceTime", input: true)
        #expect(MeetingMode.phone.source(in: [zoom, faceTime, phone],
                                         choice: zoom.app.id, preferred: faceTime.app.id)?.app.id == phone.app.id)
        #expect(MeetingMode.meeting.source(in: [zoom, phone], choice: nil, preferred: nil)?.app.id == zoom.app.id)
        #expect(MeetingMode.captions.source(in: [phone, zoom], choice: nil, preferred: nil)?.app.id == zoom.app.id)
    }

    @Test func phoneNeverFallsBackToAnotherAppWhenPhoneIsMissing() {
        let zoom = candidate("us.zoom.xos", input: true, output: true)
        #expect(MeetingMode.phone.source(in: [zoom], choice: zoom.app.id, preferred: zoom.app.id) == nil)
        #expect(MeetingMode.phone.source(in: [], choice: nil, preferred: nil) == nil)
    }

    @Test func meetingsAndVideosNeverSelectOrOfferPhone() {
        let phone = candidate(MeetingMode.phoneAppID, input: true, output: true)
        let chrome = candidate("com.google.Chrome", output: true)
        for mode in [MeetingMode.meeting, .captions] {
            #expect(mode.sourceCandidates(in: [phone, chrome]).map(\.app.id) == [chrome.app.id])
            #expect(mode.source(in: [phone], choice: nil, preferred: phone.app.id) == nil)
            #expect(mode.source(in: [phone, chrome], choice: phone.app.id, preferred: chrome.app.id) == nil)
            #expect(mode.source(in: [phone, chrome], choice: nil, preferred: phone.app.id)?.app.id == chrome.app.id)
        }
        #expect(MeetingMode.phone.sourceCandidates(in: [chrome, phone]).map(\.app.id) == [phone.app.id])
    }

    @Test func meetingPrefersTheMicrophoneWhileVideoPrefersCurrentPlayback() {
        let phone = candidate(MeetingMode.phoneAppID, input: true, output: true)
        let zoom = candidate("us.zoom.xos", input: true)
        let chrome = candidate("com.google.Chrome", output: true)
        let all = [phone, zoom, chrome]
        #expect(MeetingMode.meeting.source(in: all, choice: nil, preferred: chrome.app.id)?.app.id == zoom.app.id)
        #expect(MeetingMode.captions.source(in: all, choice: nil, preferred: zoom.app.id)?.app.id == chrome.app.id)
        // An explicit scene-specific choice overrides the automatic activity heuristic.
        #expect(MeetingMode.meeting.source(in: all, choice: chrome.app.id, preferred: zoom.app.id)?.app.id == chrome.app.id)
        #expect(MeetingMode.captions.source(in: all, choice: zoom.app.id, preferred: chrome.app.id)?.app.id == zoom.app.id)
    }

    @Test func missingExplicitSceneSourceDoesNotFallBackToAnActiveApp() {
        let zoom = candidate("us.zoom.xos", input: true, output: true)
        let chrome = candidate("com.google.Chrome", output: true)
        for mode in [MeetingMode.meeting, .captions] {
            #expect(mode.source(in: [zoom, chrome], choice: "com.microsoft.teams2", preferred: zoom.app.id) == nil)
        }
        // With automatic video selection, two playing apps still require a choice.
        #expect(MeetingMode.captions.source(in: [zoom, chrome], choice: nil, preferred: nil) == nil)
        #expect(MeetingMode.captions.source(in: [zoom, chrome], choice: nil, preferred: chrome.app.id)?.app.id == chrome.app.id)
    }

    @Test func phoneRejectsGlobalCaptureBeforeTouchingAudioHardware() throws {
        let profile = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        let session = MeetingSession(profile: profile, mode: .phone,
                                     makeEngines: { _, _, _ in fatalError("not started") }, onSubtitle: { _ in })
        #expect(throws: MeetingSession.SourceError.phoneRequiresPhoneAudio) {
            try session.setGlobalFallback(true)
        }
        try session.setGlobalFallback(false)
        #expect(!session.usesGlobalFallback)
        #expect(session.state == .idle)
    }

    @Test func phoneSharesSpeechSafetyWhileCaptionsRemainListenOnly() {
        #expect(MeetingMode.phone.supportsSpeaking)
        #expect(MeetingMode.meeting.supportsSpeaking)
        #expect(!MeetingMode.captions.supportsSpeaking)
        let physical = MeetingMicGuardPlan.State(verdict: .physicalMic(appID: MeetingMode.phoneAppID,
                                                                       app: "Phone", device: "Built-in"))
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle, translationDegraded: false,
                                   micGuard: physical, mode: .phone) == .remoteHearsOriginal)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle, translationDegraded: false,
                                   micGuard: .init(verdict: .noReader), mode: .phone) == .audioNeedsCheck)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle, translationDegraded: false,
                                   micGuard: .init(verdict: .green(appID: MeetingMode.phoneAppID, app: "Phone")),
                                   mode: .phone) == .listening)
    }

    @Test func phoneAudioActivityRequiresItsMicrophoneAndClearsOnSuspend() async throws {
        let (session, pipeline) = try makePhoneSession()
        var updates: [Bool] = []
        session.onPhoneAudioActivity = { updates.append($0) }
        try await pipeline.start()
        session.runForTesting(app: "Phone", pipeline: pipeline)
        session.updatePhoneAudioActivity(candidate(MeetingMode.phoneAppID, output: true))
        #expect(!session.phoneAudioActive) // A ringtone/voicemail is not a live microphone.
        session.updatePhoneAudioActivity(candidate(MeetingMode.phoneAppID, input: true))
        #expect(session.phoneAudioActive)
        session.updatePhoneAudioActivity(candidate("com.apple.FaceTime", input: true))
        #expect(!session.phoneAudioActive)
        session.updatePhoneAudioActivity(candidate(MeetingMode.phoneAppID, input: true))
        session.suspendListenForTesting()
        #expect(!session.phoneAudioActive)
        session.updatePhoneAudioActivity(candidate(MeetingMode.phoneAppID, input: true))
        #expect(!session.phoneAudioActive) // Suspended sessions cannot reactivate the UI.
        #expect(updates == [false, true, false, true, false])
        await session.stop()
    }

    @Test func endingPhoneTranslationClearsActivityWithoutAnotherCallEvent() async throws {
        let (session, pipeline) = try makePhoneSession()
        var updates: [Bool] = []
        session.onPhoneAudioActivity = { updates.append($0) }
        try await pipeline.start()
        session.runForTesting(app: "Phone", pipeline: pipeline)
        session.updatePhoneAudioActivity(candidate(MeetingMode.phoneAppID, input: true))
        await session.stop()
        #expect(updates == [true, false])
        #expect(!session.phoneAudioActive)
        #expect(session.state == .idle)
    }

    private func makePhoneSession() throws -> (MeetingSession, ListenPipeline) {
        let profile = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        let session = MeetingSession(profile: profile, mode: .phone,
                                     makeEngines: { _, _, _ in fatalError("not started") }, onSubtitle: { _ in })
        let pipeline = ListenPipeline(lang: .en, profile: profile.listen,
                                      engines: .init(asr: FakeASR(stream: FakeStream()), apple: nil, primary: nil),
                                      log: EventLog(inMemory: HostClock.now), tickMs: 100_000, onUpdate: { _ in })
        return (session, pipeline)
    }
}
