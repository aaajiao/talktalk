import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct LaunchAtLoginPolicyTests {
    typealias P = LaunchAtLoginPolicy

    @Test func unsignedBuildCannotRegister() {
        let p = P.present(.notRegistered, bundleSigned: false, stronglyRecommended: true)
        #expect(!p.canToggle && !p.isOn && p.note != nil)
    }

    @Test func statusMapping() {
        #expect(P.present(.enabled, bundleSigned: true, stronglyRecommended: true)
            == .init(isOn: true, canToggle: true, note: nil, offerSystemSettings: false, stronglyRecommended: false))
        let approval = P.present(.requiresApproval, bundleSigned: true, stronglyRecommended: false)
        #expect(approval.isOn && approval.offerSystemSettings)
        let off = P.present(.notRegistered, bundleSigned: true, stronglyRecommended: false)
        #expect(!off.isOn && off.note == nil && !off.stronglyRecommended)
        #expect(P.present(.notFound, bundleSigned: true, stronglyRecommended: false).note != nil)
    }

    @Test func strongRecommendationWhenTheDriverLayerDoesNotCount() {
        var config = SystemInputPlan.Config()
        config.driverLayerCounts = false   // driver 0.1.0 (0.2.0, the default, counts: §8.6 layer 3)
        #expect(config.loginStartStronglyRecommended)
        let p = P.present(.notRegistered, bundleSigned: true, stronglyRecommended: config.loginStartStronglyRecommended)
        #expect(p.stronglyRecommended && p.note == P.recommendation)
    }

    @Test func actions() {
        #expect(P.action(wantOn: true, current: .notRegistered) == .register)
        #expect(P.action(wantOn: true, current: .notFound) == .register)
        #expect(P.action(wantOn: true, current: .enabled) == .none)
        #expect(P.action(wantOn: true, current: .requiresApproval) == .none)
        #expect(P.action(wantOn: false, current: .enabled) == .unregister)
        #expect(P.action(wantOn: false, current: .requiresApproval) == .unregister)
        #expect(P.action(wantOn: false, current: .notRegistered) == .none)
    }
}

@Suite struct SysInputDialogPlanTests {
    typealias P = SysInputDialogPlan

    @Test func asksOnlyWhenTheCallIsStillOn() {
        #expect(P.step(.endMeeting, needsConfirmation: false) == .proceed(.whenCallEnds))
        #expect(P.step(.quit, needsConfirmation: false) == .proceed(.whenCallEnds))
        guard case let .ask(d) = P.step(.endMeeting, needsConfirmation: true) else { Issue.record("no dialog"); return }
        #expect(d.waitButton == "通话结束后再还原" && d.restoreButton == "现在还原")
        guard case let .ask(q) = P.step(.quit, needsConfirmation: true) else { Issue.record("no dialog"); return }
        #expect(q.title != d.title)
    }

    @Test func neverAsksOnLogoutOrAutomaticEnd() {
        #expect(P.step(.logoutOrShutdown, needsConfirmation: true) == .proceed(.restoreNow))
        #expect(P.step(.automatic, needsConfirmation: true) == .proceed(.whenCallEnds))
    }

    @Test func answers() {
        #expect(P.decision(.whenCallEnds) == .whenCallEnds)
        #expect(P.decision(.restoreNow) == .restoreNow)
        #expect(P.decision(.cancel) == nil)
        // The dialog's default matches the switcher's: wait for the call, then restore.
        #expect(SystemInputPlan.endStep(P.decision(.whenCallEnds)!, callEnded: false) == .deferUntilCallEnds)
        #expect(SystemInputPlan.endStep(P.decision(.restoreNow)!, callEnded: false) == .restore)
    }

    @Test func outcomeMessages() {
        #expect(P.message(.restored(device: "MacBook Pro 麦克风"))?.text == "默认输入已还原为 MacBook Pro 麦克风")
        #expect(P.message(.deferred)?.text == "默认输入仍是 TalkTalk Mic，通话结束后还原")
        #expect(P.message(.deferred)?.style == .yellow)
        // sysinput, review of 9d9b3a4 #1: deferred with macOS's physical pick says so.
        #expect(P.message(.deferredOnPhysical(device: "MacBook Pro 麦克风", micAbsent: true))?.text
                == "系统默认输入是 MacBook Pro 麦克风（TalkTalk Mic 不在），通话结束后还原")
        #expect(P.message(.deferredOnPhysical(device: "MacBook Pro 麦克风", micAbsent: false))?.text
                == "系统默认输入是 MacBook Pro 麦克风（没能切回 TalkTalk Mic），通话结束后还原")
        #expect(P.reportMessage(.deferredOnPhysical(device: "X", micAbsent: true))?.style == .yellow)
        #expect(P.message(.noRestoreTarget)?.style == .red)
        #expect(P.message(.writeFailed)?.style == .red)
        #expect(P.message(.nothingToRestore) == nil && P.message(.notOwner) == nil)
    }

    @Test func everyOutcomeButNothingHasALineForTheHUD() {
        // "现在还原" failing is not silent.
        let all: [P.Outcome] = [.restored(device: "X"), .deferred, .nothingToRestore, .noRestoreTarget, .writeFailed, .notOwner]
        #expect(all.filter { P.message($0) != nil } == [.restored(device: "X"), .deferred, .noRestoreTarget, .writeFailed])
        // SysInputDialogs.report leaves the restore to the switcher's notice: said once, not twice.
        #expect(all.filter { P.reportMessage($0) != nil } == [.deferred, .noRestoreTarget, .writeFailed])
        for o in all where P.reportMessage(o) != nil { #expect(P.reportMessage(o)! == P.message(o)!) }
    }
}
