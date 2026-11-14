import Testing
@testable import TalkTalkCore

@Suite struct AppUpdatePolicyTests {
    @Test func onlyExplicitlyEnabledProductionAppCanUseOnlineUpdates() {
        #expect(AppUpdatePolicy.isEnabled(requested: true, bundleIdentifier: BuildFlavor.release.rawValue, isApplicationBundle: true))
        #expect(!AppUpdatePolicy.isEnabled(requested: false, bundleIdentifier: BuildFlavor.release.rawValue, isApplicationBundle: true))
        #expect(!AppUpdatePolicy.isEnabled(requested: true, bundleIdentifier: BuildFlavor.dev.rawValue, isApplicationBundle: true))
        #expect(!AppUpdatePolicy.isEnabled(requested: true, bundleIdentifier: nil, isApplicationBundle: false))
        #expect(!AppUpdatePolicy.isEnabled(requested: true, bundleIdentifier: BuildFlavor.release.rawValue, isApplicationBundle: false))
    }

    @Test func everyActiveOperationDefersRelaunchWithoutAutomaticResume() {
        let cases: [(AppUpdateActivity, AppUpdateActivity.Reason)] = [
            (.init(session: true), .session), (.init(voice: true), .voice),
            (.init(maintenance: true), .maintenance), (.init(diagnostics: true), .diagnostics),
            (.init(onboarding: true), .onboarding), (.init(exporting: true), .exporting),
            (.init(calibration: true), .calibration),
        ]
        for (activity, reason) in cases {
            var state = AppUpdateRelaunchState()
            #expect(activity.blockingReason == reason)
            let result1 = state.shouldPostpone(activity: activity)
            #expect(result1)
            #expect(state.pending && !state.relaunching)
            let result2 = !state.requestResume(activity: activity)
            #expect(result2)
            #expect(state.canResume(activity: .init()))
            #expect(state.pending && !state.relaunching) // idle permits a click, never restarts
            let result3 = state.requestResume(activity: .init())
            #expect(result3)
            #expect(!state.pending && state.relaunching)
            let result4 = !state.requestResume(activity: .init())
            #expect(result4)
        }
    }

    @Test func activityIsRecheckedAtInstallAndAfterPreviouslyIdleResumeButton() {
        var state = AppUpdateRelaunchState()
        let idle = AppUpdateActivity()
        #expect(idle.blockingReason == nil)
        // A session may start while the update is downloading after an idle manual check.
        let result5 = state.shouldPostpone(activity: .init(session: true))
        #expect(result5)
        #expect(state.canResume(activity: idle))
        // Another operation may start while the enabled resume button is still displayed.
        let result6 = !state.requestResume(activity: .init(voice: true))
        #expect(result6)
        #expect(state.pending && !state.relaunching)
        state.reset()
        let result7 = !state.requestResume(activity: idle)
        #expect(result7) // a finished/aborted cycle has no callback
    }

    @Test func idleNativeInstallCommitsRelaunchAndDuplicatePostponementKeepsChoice() {
        var immediate = AppUpdateRelaunchState()
        let result8 = !immediate.shouldPostpone(activity: .init())
        #expect(result8)
        #expect(immediate.relaunching && !immediate.pending)
        immediate.reset()
        #expect(!immediate.relaunching && !immediate.pending)

        var delayed = AppUpdateRelaunchState()
        let result9 = delayed.shouldPostpone(activity: .init(maintenance: true))
        #expect(result9)
        let result10 = delayed.shouldPostpone(activity: .init())
        #expect(result10) // another callback is not a user click
        #expect(delayed.pending && !delayed.relaunching)
    }

    @Test func resumedInstallationStillArmsFinalTerminationGuard() {
        var state = AppUpdateRelaunchState()
        state.willRelaunch()
        #expect(state.relaunching && !state.pending)
        let result11 = !state.requestResume(activity: .init())
        #expect(result11)
        state.reset()
        #expect(!state.relaunching)
    }
}
