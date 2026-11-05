import Foundation
import TalkTalkAudio
import TalkTalkCore

/// §8.4 install step 1 and the uninstall check: nothing may be using TalkTalk Mic, no meeting may
/// be going on, and no default-input restore record may exist (§8.6). Restarting coreaudiod cuts
/// every app's audio for about 1–2 s, so apps currently playing are named in a warning.
public struct DriverPreflight: Sendable, Equatable {
    public enum Blocker: Sendable, Equatable, Hashable {
        /// TalkTalk's own meeting mode is on (install and uninstall are refused, §8.4).
        case meetingModeOn
        /// Meeting processes doing audio IO (names of the apps).
        case meetingInProgress([String])
        /// Someone has IO running on TalkTalk Mic (bundle ids or PIDs).
        case micInUse([String])
        /// `sysinput-restore.json` exists: the default input has not been put back yet.
        case restoreRecordPresent

        public var text: String {
            switch self {
            case .meetingModeOn: "先结束会议模式。"
            case .meetingInProgress(let apps): "先离开会议（\(apps.joined(separator: "、")) 正在通话）。"
            case .micInUse(let who): "TalkTalk Mic 正被使用（\(who.joined(separator: "、"))），先离开会议。"
            case .restoreRecordPresent: "先结束会议模式，等系统默认输入还原。"
            }
        }
    }

    public enum Warning: Sendable, Equatable, Hashable {
        /// Apps with audio output running right now (they hear a ~1–2 s gap).
        case audioWillStop([String])

        public var text: String {
            switch self {
            case .audioWillStop(let apps):
                "重启音频服务会让所有 App 的声音中断约 1–2 秒，包括 \(apps.joined(separator: "、")) 正在播放的内容。"
            }
        }
    }

    public var blockers: [Blocker]
    public var warnings: [Warning]

    public init(blockers: [Blocker] = [], warnings: [Warning] = []) {
        self.blockers = blockers
        self.warnings = warnings
    }

    public var canProceed: Bool { blockers.isEmpty }

    /// What the decision depends on, gathered by `Inputs.current`.
    public struct Inputs: Sendable, Equatable {
        public var meetingModeOn: Bool
        public var meetings: [MeetingCandidate]
        public var mic: DriverDeviceInfo?
        /// From the driver's 'ttdg' (nil: diagnostics unavailable, fall back to IsRunningSomewhere).
        public var micUsers: [DriverDiagnostics.Client]?
        public var restoreRecordExists: Bool
        public var processes: [AudioProcessInfo]
        public var ownPID: Int32

        public init(meetingModeOn: Bool = false, meetings: [MeetingCandidate] = [], mic: DriverDeviceInfo? = nil,
                    micUsers: [DriverDiagnostics.Client]? = [], restoreRecordExists: Bool = false,
                    processes: [AudioProcessInfo] = [], ownPID: Int32 = getpid()) {
            self.meetingModeOn = meetingModeOn
            self.meetings = meetings
            self.mic = mic
            self.micUsers = micUsers
            self.restoreRecordExists = restoreRecordExists
            self.processes = processes
            self.ownPID = ownPID
        }

        public static func current(meetingModeOn: Bool, hal: any DriverHAL = CoreAudioDriverHAL(),
                                   resolver: MeetingSourceResolver = MeetingSourceResolver(),
                                   sysinput: SysInputPaths = .standard()) -> Inputs {
            let processes = (try? AudioProcessList.current()) ?? []
            return Inputs(meetingModeOn: meetingModeOn, meetings: resolver.candidates(processes),
                          mic: hal.device(uid: DriverIdentity.micUID), micUsers: hal.diagnostics()?.micUsers,
                          restoreRecordExists: SysInputRecordStore(paths: sysinput).exists, processes: processes)
        }
    }

    public static func evaluate(_ i: Inputs) -> DriverPreflight {
        var blockers: [Blocker] = []
        if i.meetingModeOn { blockers.append(.meetingModeOn) }
        let active = i.meetings.filter { $0.isRunningInput || $0.isRunningOutput }.map(\.app.name)
        if !active.isEmpty { blockers.append(.meetingInProgress(Array(Set(active)).sorted())) }
        if let all = i.micUsers {
            let users = all.filter { $0.pid != i.ownPID }
            if !users.isEmpty { blockers.append(.micInUse(users.map { $0.bundleID ?? "pid \($0.pid)" }.uniqued())) }
        } else if i.mic?.isRunningSomewhere == true {
            blockers.append(.micInUse(["未知 App"]))
        }
        if i.restoreRecordExists { blockers.append(.restoreRecordPresent) }

        var warnings: [Warning] = []
        let playing = i.processes.filter { $0.isRunningOutput && $0.pid != i.ownPID }
            .map { $0.bundleID.map(Self.displayName) ?? "pid \($0.pid)" }.uniqued()
        if !playing.isEmpty { warnings.append(.audioWillStop(playing)) }
        return DriverPreflight(blockers: blockers, warnings: warnings)
    }

    /// The bundle id's last component, capitalised ("com.example.readread" → "Readread"), so the
    /// warning names apps without reading any other app's files.
    static func displayName(_ bundleID: String) -> String {
        guard let last = bundleID.split(separator: ".").last, !last.isEmpty else { return bundleID }
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
