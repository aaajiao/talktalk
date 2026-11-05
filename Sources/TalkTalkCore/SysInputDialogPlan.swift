// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// When to ask "通话还在" before ending meeting mode or quitting, and what to say afterwards
/// (ARCHITECTURE.md §8.6, §16 决定 4). The decisions are SystemInputSwitcher's
/// (`needsEndConfirmation`, `endMeetingMode(decision:)`, `prepareForQuit(decision:)`); this only
/// picks between showing the dialog and passing a decision straight through.
public enum SysInputDialogPlan {
    public enum Context: Sendable, Equatable {
        /// Menu "结束会议模式".
        case endMeeting
        /// Menu "退出" (or ⌘Q).
        case quit
        /// Logout / shutdown: never ask, restore now (the meeting app is quitting too).
        case logoutOrShutdown
        /// Auto end, end after sleep / lock: never ask, wait for the call to end.
        case automatic
    }

    public enum Step: Sendable, Equatable {
        case proceed(SystemInputPlan.EndDecision)
        case ask(Dialog)
    }

    public struct Dialog: Sendable, Equatable {
        public var title: String
        public var message: String
        /// Default button: `.whenCallEnds`.
        public var waitButton: String
        /// `.restoreNow`.
        public var restoreButton: String
        public var cancelButton: String
    }

    public enum Answer: Sendable, Equatable { case whenCallEnds, restoreNow, cancel }

    public static func step(_ context: Context, needsConfirmation: Bool) -> Step {
        switch context {
        case .logoutOrShutdown: return .proceed(.restoreNow)
        case .automatic: return .proceed(.whenCallEnds)
        case .endMeeting, .quit:
            // The call has ended (or nothing of ours to restore): the switcher restores at once.
            guard needsConfirmation else { return .proceed(.whenCallEnds) }
            return .ask(dialog(context))
        }
    }

    public static func dialog(_ context: Context) -> Dialog {
        let title = context == .quit ? String(localized: "通话还在，现在退出 TalkTalk？")
                                     : String(localized: "通话还在，现在停止会议同传？")
        return Dialog(
            title: title,
            message: String(localized: "会议同传期间系统默认输入是 TalkTalk Mic。还原后，跟随系统默认的会议应用会直接使用实体麦。如果会议应用手动选了 TalkTalk Mic，需要在应用里切换麦克风才能继续发言。"),
            waitButton: String(localized: "通话结束后再还原"),
            restoreButton: String(localized: "现在还原"),
            cancelButton: String(localized: "取消"))
    }

    /// The answer as a switcher decision; nil for cancel (meeting mode goes on, the app stays).
    public static func decision(_ a: Answer) -> SystemInputPlan.EndDecision? {
        switch a {
        case .whenCallEnds: .whenCallEnds
        case .restoreNow: .restoreNow
        case .cancel: nil
        }
    }

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
    public static let deferredStatus = String(localized: "默认输入仍是 TalkTalk Mic，通话结束后还原")

    /// The same while the default input is not TalkTalk Mic but macOS's pick.
    public static func deferredOnPhysicalStatus(device: String, micAbsent: Bool) -> String {
        micAbsent ? String(localized: "系统默认输入是 \(device)（TalkTalk Mic 不在），通话结束后还原")
                  : String(localized: "系统默认输入是 \(device)（没能切回 TalkTalk Mic），通话结束后还原")
    }
}
