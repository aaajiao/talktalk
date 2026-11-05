// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Presentation and automatic restore policy for ending meeting interpretation or quitting.
/// The switcher still checks ownership, current input and available physical devices before writing.
public enum SysInputDialogPlan {
    public enum Context: Sendable, Equatable {
        case endMeeting, quit, logoutOrShutdown, automatic
    }

    /// Ending TalkTalk's audio session restores its input change even if a call remains active.
    /// No normal end/quit choice dialog is presented.
    public static func decision(_ context: Context) -> SystemInputPlan.EndDecision { .restoreNow }

    /// SystemInputSwitcher.EndResult, mirrored (TalkTalkAudio is above Core).
    public enum Outcome: Sendable, Equatable {
        case restored(device: String)
        case deferred
        /// Deferred, but the default input is a physical device macOS picked (the Mic gone, or the
        /// switch back failed): the menu and HUD say which (review of 9d9b3a4 #1).
        case deferredOnPhysical(device: String, micAbsent: Bool)
        case nothingToRestore
        case noRestoreTarget
        case writeFailed
        case notOwner
    }

    /// What the HUD / menu says after the end. nil: nothing to say.
    public static func message(_ o: Outcome) -> (text: String, style: HUDLine.Style)? {
        switch o {
        case let .restored(d): (HUDModel.Warning.defaultInputRestored(to: d).text, .normal)
        case .deferred: (deferredStatus, .yellow)
        case let .deferredOnPhysical(d, absent): (deferredOnPhysicalStatus(device: d, micAbsent: absent), .yellow)
        case .noRestoreTarget: (String(localized: "没有可还原的实体麦克风，请在“系统设置 › 声音 › 输入”里选一个"), .red)
        case .writeFailed: (String(localized: "没能还原系统默认输入，请在“系统设置 › 声音 › 输入”里改回"), .red)
        case .nothingToRestore, .notOwner: nil
        }
    }

    /// What SysInputDialogs.report shows after an end: every message but the restore, which the
    /// switcher's `.restored(device, note)` notice already brings to the HUD (once, with the note).
    public static func reportMessage(_ o: Outcome) -> (text: String, style: HUDLine.Style)? {
        if case .restored = o { return nil }
        return message(o)
    }

    /// Quit must make a still-pending restoration visible before its windows disappear.
    /// Successful restores, manual input changes and another owner's record need no alert.
    public static func quitFailureMessage(_ o: Outcome) -> String? {
        switch o {
        case .deferred, .deferredOnPhysical, .noRestoreTarget, .writeFailed: message(o)?.text
        case .restored, .nothingToRestore, .notOwner: nil
        }
    }

    /// SystemInputSwitcher.EntryResult values that mean "default input not switched" (§8.6):
    /// yellow HUD line. `.micNotSelectable` is sysinput's driver-0.2.0 case (6692c14).
    public enum EntryIssue: Sendable, Hashable {
        case micMissing, noPhysicalInput, writeFailed, recordWriteFailed, guardLaunchFailed, micNotSelectable

        public var text: String {
            switch self {
            case .micMissing: String(localized: "TalkTalk Mic 不在，系统默认输入没有切换")
            case .noPhysicalInput: String(localized: "没有实体麦克风，系统默认输入没有切换")
            case .writeFailed: String(localized: "没能把系统默认输入切到 TalkTalk Mic")
            case .recordWriteFailed: String(localized: "没能写下还原记录，系统默认输入没有切换")
            case .guardLaunchFailed: String(localized: "还原守护进程没能启动，系统默认输入没有切换")
            case .micNotSelectable: String(localized: "TalkTalk Mic 现在不能设为默认输入，系统默认输入没有切换")
            }
        }
    }

    /// Menu bar status while the restore waits for the call (§8.6).
    public static let deferredStatus = String(localized: "系统麦克风尚未还原，等待设备就绪或重试")

    /// The same while the default input is not TalkTalk Mic but macOS's pick.
    public static func deferredOnPhysicalStatus(device: String, micAbsent: Bool) -> String {
        micAbsent ? String(localized: "系统默认输入是 \(device)（TalkTalk Mic 不在），等待还原")
                  : String(localized: "系统默认输入是 \(device)（没能切回 TalkTalk Mic），等待还原")
    }
}
