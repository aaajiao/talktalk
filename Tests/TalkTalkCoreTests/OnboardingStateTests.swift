import Foundation
import Testing
@testable import TalkTalkCore

/// A private UserDefaults suite per test; a "restart" is a new OnboardingState on the same suite.
private final class DefaultsSuite {
    let name = "talktalk.tests.onboarding.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { defaults.removePersistentDomain(forName: name) }
    func relaunch(steps: [OnboardingStep] = OnboardingStep.allCases) -> OnboardingState {
        OnboardingState(defaults: UserDefaults(suiteName: name)!, steps: steps)
    }
}

private let allGranted = OnboardingFacts(microphone: true, speechRecognition: true, inputMonitoring: true,
                                         systemAudioProbe: .granted)

@Suite struct OnboardingStateTests {
    @Test func freshStartsAtStepOne() {
        let s = DefaultsSuite()
        let o = s.relaunch()
        #expect(o.current == .permissions)
        #expect(o.needsOnboarding)
        #expect(OnboardingStep.permissions.number == 1 && OnboardingStep.tryIt.number == 8)
    }

    @Test func permissionsNeedTheThreeGrantsAndAProbeRun() {
        let o = DefaultsSuite().relaunch()
        var f = OnboardingFacts(microphone: true, speechRecognition: true)
        #expect(!o.complete(.permissions, f))
        f.inputMonitoring = true
        #expect(!o.complete(.permissions, f))      // probe not run: blocks
        #expect(o.current == .permissions)
        o.recordSystemAudioProbe(.inconclusive)
        #expect(o.complete(.permissions, f))      // inconclusive passes
        #expect(o.current == .speechAssets)
    }

    @Test func deniedProbeBlocksAndSurvivesARelaunch() {
        let s = DefaultsSuite()
        let o = s.relaunch()
        o.recordSystemAudioProbe(.denied)
        var f = allGranted
        f.systemAudioProbe = nil                    // this process has not run it
        #expect(!o.canContinue(.permissions, f))
        let after = s.relaunch()
        #expect(after.systemAudioProbe == .denied)
        #expect(!after.complete(.permissions, f))
        after.recordSystemAudioProbe(.granted)
        #expect(after.complete(.permissions, f))
    }

    @Test func probeVerdictsInFacts() {
        var f = allGranted
        f.systemAudioProbe = .denied
        #expect(!f.permissionsDone)
        f.systemAudioProbe = .inconclusive
        #expect(f.permissionsDone)
        f.systemAudioProbe = nil
        #expect(!f.permissionsDone)
    }

    @Test func legacyKeysAreRemovedAndDoNotHideOnboarding() {
        let s = DefaultsSuite()
        s.defaults.set(true, forKey: "onboarding.finished")
        s.defaults.set(3, forKey: "onboarding.step")
        let o = s.relaunch()
        #expect(o.needsOnboarding && o.current == .permissions)
        #expect(s.defaults.object(forKey: "onboarding.finished") == nil)
        #expect(s.defaults.object(forKey: "onboarding.step") == nil)
        o.complete(.permissions, allGranted)
        #expect(s.defaults.string(forKey: OnboardingState.Key.step) == OnboardingStep.speechAssets.rawValue)
    }

    @Test func relaunchWithoutAProbeRunDoesNotAdvance() {
        let s = DefaultsSuite()
        s.relaunch().willRelaunch(for: .inputMonitoring)
        let after = s.relaunch()
        var f = allGranted
        f.systemAudioProbe = nil
        after.resume(f)
        #expect(after.current == .permissions)
    }

    @Test func restartReturnsToTheSavedStep() {
        let s = DefaultsSuite()
        let o = s.relaunch()
        o.complete(.permissions, allGranted)
        o.complete(.speechAssets, .init(speechAssets: true))
        o.complete(.driver, .init(driverInstalled: true))
        #expect(o.current == .engine)
        let again = s.relaunch()
        #expect(again.current == .engine)
        #expect(again.needsOnboarding)
    }

    @Test func inputMonitoringRelaunchComesBackAfterStepOne() {
        let s = DefaultsSuite()
        let o = s.relaunch()
        // Mic and speech granted, then Input Monitoring: macOS asks to quit and reopen.
        o.willRelaunch(for: .inputMonitoring)
        #expect(o.current == .permissions)
        // Relaunch: the grant is now visible.
        let after = s.relaunch()
        #expect(after.pendingRelaunch == .inputMonitoring)
        after.resume(allGranted)
        #expect(after.current == .speechAssets)
        #expect(after.pendingRelaunch == nil)
        // And it stays there across another restart.
        #expect(s.relaunch().current == .speechAssets)
    }

    @Test func relaunchWithoutTheGrantStaysAndKeepsTheFlag() {
        let s = DefaultsSuite()
        s.relaunch().willRelaunch(for: .inputMonitoring)
        let after = s.relaunch()
        var f = allGranted
        f.inputMonitoring = false
        after.resume(f)
        #expect(after.current == .permissions)
        #expect(s.relaunch().pendingRelaunch == .inputMonitoring)
    }

    @Test func relaunchWithMicStillMissingStaysOnStepOne() {
        let s = DefaultsSuite()
        s.relaunch().willRelaunch(for: .inputMonitoring)
        let after = s.relaunch()
        after.resume(.init(microphone: false, speechRecognition: true, inputMonitoring: true))
        #expect(after.current == .permissions)
        #expect(after.pendingRelaunch == nil)
    }

    @Test func resumeWithoutPendingRelaunchMovesNothing() {
        let o = DefaultsSuite().relaunch()
        o.resume(allGranted)
        #expect(o.current == .permissions)
    }

    @Test func openAIIsSkippableAndRemembered() {
        let s = DefaultsSuite()
        let o = s.relaunch(steps: [.openAI, .voice])
        #expect(o.current == .openAI)
        #expect(o.skip(.openAI))
        #expect(o.skipped == [.openAI])
        #expect(s.relaunch(steps: [.openAI, .voice]).skipped == [.openAI])
        #expect(!o.skip(.voice))                 // step 6 cannot be skipped
        #expect(!o.complete(.voice, .init(voiceProfile: false)))
        #expect(o.complete(.voice, .init(voiceProfile: true)))
        #expect(o.current == nil && !o.needsOnboarding)
        #expect(!s.relaunch(steps: [.openAI, .voice]).needsOnboarding)
    }

    @Test func voiceStepWaitsWhileATakeIsBeingRecorded() {
        let o = DefaultsSuite().relaunch(steps: [.voice, .tryIt])
        var f = OnboardingFacts(voiceProfile: true)
        f.recordingTake = true                   // re-recording over an existing profile
        #expect(!o.canContinue(.voice, f))
        #expect(!o.complete(.voice, f))
        f.recordingTake = false
        #expect(o.complete(.voice, f))
    }

    @Test func completingASkippableStepWithoutItCountsAsSkipped() {
        let o = DefaultsSuite().relaunch(steps: [.meetingMic, .tryIt])
        #expect(o.complete(.meetingMic, .init(meetingMicVerified: nil)))
        #expect(o.skipped == [.meetingMic])
    }

    @Test func onlyTheCurrentStepMoves() {
        let o = DefaultsSuite().relaunch()
        #expect(!o.complete(.engine, .init(engineInstalled: true)))
        #expect(o.current == .permissions)
    }

    @Test func backAndRestart() {
        let s = DefaultsSuite()
        let o = s.relaunch()
        o.complete(.permissions, allGranted)
        o.back()
        #expect(o.current == .permissions)
        o.back()
        #expect(o.current == .permissions)
        o.complete(.permissions, allGranted)
        o.restart()
        #expect(o.current == .permissions && o.skipped.isEmpty)
        #expect(s.relaunch().current == .permissions)
    }

    @Test func savedStepNotInThisBuildMovesToTheNextShown() {
        let s = DefaultsSuite()
        let all = s.relaunch()
        all.complete(.permissions, allGranted)
        all.complete(.speechAssets, .init(speechAssets: true))
        #expect(all.current == .driver)
        // A build without the M2 steps: driver → engine.
        let m1 = s.relaunch(steps: [.permissions, .speechAssets, .engine, .openAI, .voice, .tryIt])
        #expect(m1.current == .engine)
    }

    @Test func finishingTheLastStep() {
        let s = DefaultsSuite()
        let o = s.relaunch(steps: [.tryIt])
        #expect(o.complete(.tryIt, .init()))
        #expect(o.current == nil)
        let again = s.relaunch(steps: [.tryIt])
        #expect(again.current == nil && !again.needsOnboarding)
    }
}
