// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkAudio
import TalkTalkCore

/// "结束会议模式" / "退出" while the call is still on (ARCHITECTURE.md §8.6, §16 决定 4):
/// the default button is "通话结束后再还原". The decision model is SystemInputSwitcher's; the
/// when-to-ask rule and the texts are SysInputDialogPlan's (Core, unit-tested).
@MainActor
enum SysInputDialogs {
    /// Set by NSWorkspace.willPowerOffNotification (logout, restart, shutdown): quitting then
    /// restores at once without a dialog.
    private(set) static var poweringOff = false
    private static var observer: NSObjectProtocol?

    static func installPowerOffObserver() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { poweringOff = true }
        }
    }

    /// The decision to hand to `endMeetingMode` / `prepareForQuit`; nil when you cancelled.
    static func decision(_ context: SysInputDialogPlan.Context, switcher: SystemInputSwitcher) -> SystemInputPlan.EndDecision? {
        let ctx: SysInputDialogPlan.Context = (context == .quit && poweringOff) ? .logoutOrShutdown : context
        switch SysInputDialogPlan.step(ctx, needsConfirmation: switcher.needsEndConfirmation) {
        case let .proceed(d): return d
        case let .ask(dialog): return SysInputDialogPlan.decision(ask(dialog))
        }
    }

    static func ask(_ d: SysInputDialogPlan.Dialog) -> SysInputDialogPlan.Answer {
        let a = NSAlert()
        a.messageText = d.title
        a.informativeText = d.message
        a.addButton(withTitle: d.waitButton)      // default (Return)
        a.addButton(withTitle: d.restoreButton)
        let cancel = a.addButton(withTitle: d.cancelButton)
        cancel.keyEquivalent = "\u{1b}"
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: return .whenCallEnds
        case .alertSecondButtonReturn: return .restoreNow
        default: return .cancel
        }
    }

    /// "结束会议模式": asks if needed, ends the switcher's part, tells the HUD. false: cancelled
    /// (meeting mode goes on).
    @discardableResult
    static func endMeeting(switcher: SystemInputSwitcher, context: SysInputDialogPlan.Context = .endMeeting,
                           hud: PTTHUD?) -> Bool {
        guard let d = decision(context, switcher: switcher) else { return false }
        report(switcher.endMeetingMode(decision: d), status: switcher.status, hud: hud)
        return true
    }

    /// `applicationShouldTerminate`: `.terminateCancel` when you cancelled; otherwise the switcher
    /// has restored or handed the record to the guard.
    static func quit(switcher: SystemInputSwitcher) -> NSApplication.TerminateReply {
        guard let d = decision(.quit, switcher: switcher) else { return .terminateCancel }
        _ = switcher.prepareForQuit(decision: d)
        return .terminateNow
    }

    /// `status`: the switcher's right after, so a deferred end says what the default input really is.
    static func outcome(_ r: SystemInputSwitcher.EndResult,
                        status: SystemInputSwitcher.Status = .idle) -> SysInputDialogPlan.Outcome {
        switch r {
        case let .restored(d): .restored(device: d)
        case .deferred:
            if case let .deferredOnPhysical(d, absent, _) = status { .deferredOnPhysical(device: d, micAbsent: absent) }
            else { .deferred }
        case .nothingToRestore: .nothingToRestore
        case .noRestoreTarget: .noRestoreTarget
        case .writeFailed: .writeFailed
        case .notOwner: .notOwner
        }
    }

    /// The yellow / red lines (waiting for the call, restore failed, no restore target).
    /// "默认输入已还原为 X" is not posted here: the switcher's onNotice `.restored(d, note)` already
    /// says it, with the §8.6 note (PTTHUD.sysInput).
    static func report(_ r: SystemInputSwitcher.EndResult, status: SystemInputSwitcher.Status, hud: PTTHUD?) {
        if let m = SysInputDialogPlan.reportMessage(outcome(r, status: status)) { hud?.show(m.text, m.style) }
    }
}
