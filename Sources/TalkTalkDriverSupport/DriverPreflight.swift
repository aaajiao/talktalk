// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
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
        /// Someone has IO running on TalkTalk Mic (app names, "pid N" when there is none).
        case micInUse([String])
        /// `sysinput-restore.json` exists: the default input has not been put back yet.
        case restoreRecordPresent

        public var text: String {
            switch self {
            case .meetingModeOn: String(localized: "先结束会议模式。")
            case .meetingInProgress(let apps): String(localized: "先离开会议（\(DriverPreflight.names(apps)) 正在通话）。")
            case .micInUse(let who): String(localized: "TalkTalk Mic 正被使用（\(DriverPreflight.names(who))），先离开会议。")
            case .restoreRecordPresent: String(localized: "先结束会议模式，等系统默认输入还原。")
            }
        }
    }

    public enum Warning: Sendable, Equatable, Hashable {
        /// Apps with audio output running right now (they hear a ~1–2 s gap).
        case audioWillStop([String])

        public var text: String {
            switch self {
            case .audioWillStop(let apps):
                String(localized: "重启音频服务会让所有 App 的声音中断约 1–2 秒，包括 \(DriverPreflight.names(apps)) 正在播放的内容。")
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
        /// The running apps' own names by pid (`NSRunningApplication.localizedName`), for the
        /// TalkTalk Mic users that are no known meeting app.
        public var appNames: [Int32: String]

        public init(meetingModeOn: Bool = false, meetings: [MeetingCandidate] = [], mic: DriverDeviceInfo? = nil,
                    micUsers: [DriverDiagnostics.Client]? = [], restoreRecordExists: Bool = false,
                    processes: [AudioProcessInfo] = [], ownPID: Int32 = getpid(), appNames: [Int32: String] = [:]) {
            self.meetingModeOn = meetingModeOn
            self.meetings = meetings
            self.mic = mic
            self.micUsers = micUsers
            self.restoreRecordExists = restoreRecordExists
            self.processes = processes
            self.ownPID = ownPID
            self.appNames = appNames
        }

        public static func current(meetingModeOn: Bool, hal: any DriverHAL = CoreAudioDriverHAL(),
                                   resolver: MeetingSourceResolver = MeetingSourceResolver(),
                                   sysinput: SysInputPaths = .standard()) -> Inputs {
            let processes = (try? AudioProcessList.current()) ?? []
            let micUsers = hal.diagnostics()?.micUsers
            var names: [Int32: String] = [:]
            for user in micUsers ?? [] {
                names[user.pid] = NSRunningApplication(processIdentifier: user.pid)?.localizedName
            }
            return Inputs(meetingModeOn: meetingModeOn, meetings: resolver.candidates(processes),
                          mic: hal.device(uid: DriverIdentity.micUID), micUsers: micUsers,
                          restoreRecordExists: SysInputRecordStore(paths: sysinput).exists, processes: processes,
                          appNames: names)
        }
    }

    public static func evaluate(_ i: Inputs) -> DriverPreflight {
        var blockers: [Blocker] = []
        if i.meetingModeOn { blockers.append(.meetingModeOn) }
        let active = i.meetings.filter { $0.isRunningInput || $0.isRunningOutput }.map(\.app.name)
        if !active.isEmpty { blockers.append(.meetingInProgress(Array(Set(active)).sorted())) }
        if let all = i.micUsers {
            let users = all.filter { $0.pid != i.ownPID }
            if !users.isEmpty {
                blockers.append(.micInUse(users.map { name(pid: $0.pid, bundleID: $0.bundleID, i.appNames) }.uniqued()))
            }
        } else if i.mic?.isRunningSomewhere == true {
            blockers.append(.micInUse([String(localized: "未知 App")]))
        }
        if i.restoreRecordExists { blockers.append(.restoreRecordPresent) }

        var warnings: [Warning] = []
        let playing = i.processes.filter { $0.isRunningOutput && $0.pid != i.ownPID }
            .map { name(pid: $0.pid, bundleID: $0.bundleID, [:]) }.uniqued()
        if !playing.isEmpty { warnings.append(.audioWillStop(playing)) }
        return DriverPreflight(blockers: blockers, warnings: warnings)
    }

    /// An app as the blockers and warnings name it: the meeting app's name (as the meeting
    /// blocker says it), else the app's own name, else its bundle id's last part, else "pid N".
    static func name(pid: Int32, bundleID: String?, _ appNames: [Int32: String]) -> String {
        if let bundleID, let app = MeetingApp.named(bundleID) { return app.name }
        if let own = appNames[pid] { return own }
        if let bundleID { return displayName(bundleID) }
        return String(localized: "pid \(pid)")
    }

    /// App names in a sentence: "Zoom、Teams".
    static func names(_ apps: [String]) -> String { apps.joined(separator: String(localized: "、")) }

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
