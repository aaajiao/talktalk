import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct LaunchAtLoginPolicyTests {
    typealias P = LaunchAtLoginPolicy

    @Test func unsignedBuildCannotRegister() {
        let p = P.present(.notRegistered, bundleSigned: false, stronglyRecommended: true)
        #expect(!p.canToggle && !p.isOn && p.notice == .unsigned)
    }

    @Test func statusMapping() {
        #expect(P.present(.enabled, bundleSigned: true, stronglyRecommended: true)
            == .init(isOn: true, canToggle: true, notice: nil))
        let approval = P.present(.requiresApproval, bundleSigned: true, stronglyRecommended: false)
        #expect(approval.isOn && approval.notice == .awaitingApproval)
        let off = P.present(.notRegistered, bundleSigned: true, stronglyRecommended: false)
        #expect(!off.isOn && off.notice == nil)
        #expect(P.present(.notFound, bundleSigned: true, stronglyRecommended: true).notice == .serviceUnavailable)
    }

    @Test func missingServiceDoesNotInferWhereTheAppIsInstalled() {
        // SMAppService.notFound can occur for an app already in Applications. It must report
        // the missing service rather than tell the user to move a correctly installed app.
        for recommended in [false, true] {
            let presentation = P.present(.notFound, bundleSigned: true, stronglyRecommended: recommended)
            #expect(presentation == .init(isOn: false, canToggle: true, notice: .serviceUnavailable))
        }
        #expect(P.action(wantOn: true, current: .notFound) == .register)
        #expect(P.action(wantOn: false, current: .notFound) == .none)
    }

    @Test func strongRecommendationWhenTheDriverLayerDoesNotCount() {
        let config = SystemInputPlan.Config()
        #expect(config.loginStartStronglyRecommended)
        let p = P.present(.notRegistered, bundleSigned: true, stronglyRecommended: config.loginStartStronglyRecommended)
        #expect(p.notice == .recommended)
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

    @Test func everySessionEndRestoresWithoutAChoiceDialog() {
        let contexts: [P.Context] = [.endMeeting, .quit, .logoutOrShutdown, .automatic]
        for context in contexts {
            #expect(SystemInputPlan.endStep(P.decision(context), callEnded: false) == .restore)
            #expect(SystemInputPlan.endStep(P.decision(context), callEnded: true) == .restore)
        }
    }

    @Test func outcomeMessages() {
        #expect(P.message(.restored(device: "MacBook Pro 麦克风"))?.text == "默认输入已还原为 MacBook Pro 麦克风")
        #expect(P.message(.deferred)?.text == "系统麦克风尚未还原，等待设备就绪或重试")
        #expect(P.message(.deferred)?.style == .yellow)
        // sysinput, review of 9d9b3a4 #1: deferred with macOS's physical pick says so.
        #expect(P.message(.deferredOnPhysical(device: "MacBook Pro 麦克风", micAbsent: true))?.text
                == "系统默认输入是 MacBook Pro 麦克风（TalkTalk Mic 不在），等待还原")
        #expect(P.message(.deferredOnPhysical(device: "MacBook Pro 麦克风", micAbsent: false))?.text
                == "系统默认输入是 MacBook Pro 麦克风（没能切回 TalkTalk Mic），等待还原")
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
        #expect(all.filter { P.quitFailureMessage($0) != nil } == [.deferred, .noRestoreTarget, .writeFailed])
        for o in all where P.reportMessage(o) != nil { #expect(P.reportMessage(o)! == P.message(o)!) }
    }
}
