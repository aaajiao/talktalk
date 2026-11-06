// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkAudio
import TalkTalkCore

/// Automatic input restoration for meeting end and app quit; no normal choice dialog.
@MainActor
enum SysInputDialogs {
    /// Keep the existing before-end callback contract: restoration failure is reported and its
    /// record remains recoverable, but does not prevent the user's request to stop the session.
    @discardableResult
    static func endMeeting(switcher: SystemInputSwitcher, context: SysInputDialogPlan.Context = .endMeeting,
                           hud: PTTHUD?) -> Bool {
        report(switcher.endMeetingMode(decision: SysInputDialogPlan.decision(context)), status: switcher.status, hud: hud)
        return true
    }

    /// The switcher restores immediately, or leaves the owned record with the recovery guard.
    static func quit(switcher: SystemInputSwitcher, hud: PTTHUD? = nil) -> NSApplication.TerminateReply {
        let result = switcher.prepareForQuit(decision: SysInputDialogPlan.decision(.quit))
        report(result, status: switcher.status, hud: hud)
        if let reason = SysInputDialogPlan.quitFailureMessage(outcome(result, status: switcher.status)) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "麦克风尚未还原")
            alert.informativeText = String(localized: "\(reason)\n\n已保留恢复记录。请在“系统设置 › 声音 › 输入”中检查并选择实体麦克风，也可下次启动 TalkTalk 后重试。")
            alert.addButton(withTitle: String(localized: "打开声音设置并退出"))
            alert.addButton(withTitle: String(localized: "退出 TalkTalk"))
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                let sound = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
                if !NSWorkspace.shared.open(sound) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
            }
        }
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
        if let m = SysInputDialogPlan.reportMessage(outcome(r, status: status)) {
            // The default-input chips' glyph (HUDModel.Warning.defaultInputChanged and kin).
            hud?.show(m.text, m.style, label: titlebarLabel("系统麦克风未还原"), symbol: "mic.badge.xmark")
        }
    }
}
