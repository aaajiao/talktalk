// l10n: zh-Hans (scripts/check-strings.sh)
import TalkTalkCore
import AppKit
import CoreAudio
import Darwin
import Foundation

/// Known meeting/audio apps. Phone's bundle ID was verified from the installed app and its
/// Core Audio process; call audio still needs end-to-end acceptance. Feishu/Lark is not installed
/// here: its bundle ID and sounding process get added only after `--list-audio-processes`
/// shows them, not guessed.
public struct MeetingApp: Sendable, Equatable, Hashable, Codable {
    public let id: String          // owner bundle id
    private let storedName: String
    /// A known localized app name must follow the interface language even when the
    /// resolver and its process candidates were created before the language changed.
    public var name: String {
        id == "com.tencent.meeting" ? String(appLocalized: "腾讯会议") : storedName
    }
    private enum CodingKeys: String, CodingKey { case id, storedName = "name", isBrowser }

    public init(id: String, name: String, isBrowser: Bool) {
        self.id = id
        storedName = name
        self.isBrowser = isBrowser
    }
    /// A browser: one audio helper serves every tab (§3.1 "浏览器会议").
    public let isBrowser: Bool

    public static let known: [MeetingApp] = [
        MeetingApp(id: "us.zoom.xos", name: "Zoom", isBrowser: false),
        MeetingApp(id: "com.microsoft.teams2", name: "Microsoft Teams", isBrowser: false),
        MeetingApp(id: "com.tencent.meeting", name: "Tencent Meeting", isBrowser: false),
        MeetingApp(id: "com.google.Chrome", name: "Google Chrome", isBrowser: true),
        MeetingApp(id: "com.microsoft.edgemac", name: "Microsoft Edge", isBrowser: true),
        MeetingApp(id: "company.thebrowser.Browser", name: "Arc", isBrowser: true),
        MeetingApp(id: "com.apple.Safari", name: "Safari", isBrowser: true),
        MeetingApp(id: "com.apple.mobilephone", name: "Phone", isBrowser: false),
        MeetingApp(id: "com.apple.FaceTime", name: "FaceTime", isBrowser: false),
    ]

    public static func named(_ bundleID: String) -> MeetingApp? { known.first { $0.id == bundleID } }
}

/// One meeting app with the Core Audio process objects attributed to it.
public struct MeetingCandidate: Sendable, Equatable {
    public let app: MeetingApp
    public let processes: [AudioProcessInfo]
    public var objectIDs: [AudioObjectID] { processes.map { AudioObjectID($0.objectID) } }
    public var isRunningInput: Bool { processes.contains { $0.isRunningInput } }
    public var isRunningOutput: Bool { processes.contains { $0.isRunningOutput } }
}

/// Attributes Core Audio process objects to the app that owns them (§3.1), rules in order:
///   1. the known running application for the same PID, before a possibly inherited audio bundle ID;
///   2. Core Audio bundle-id prefix (`<app>` or `<app>.helper*`);
///   3. parent PID chain (`proc_pidinfo(PROC_PIDTBSDINFO)`), owner = first ancestor with an app bundle id;
///   4. XPC services (parent is launchd, e.g. `com.apple.WebKit.GPU`): the responsible process
///      (`responsibility_get_pid_responsible_for_pid`, SPI: fine for personal use, re-check before
///      distribution); only if that is unavailable, WebKit.GPU → Safari.
/// `CATapDescription.bundleIDs` is not used: it matches exactly and misses helpers and XPC.
/// Read-only; needs no TCC.
public struct MeetingSourceResolver: Sendable {
    public struct ProcessLookup: Sendable {
        public var parentPID: @Sendable (pid_t) -> pid_t?
        public var bundleID: @Sendable (pid_t) -> String?
        public var responsiblePID: @Sendable (pid_t) -> pid_t?

        public init(parentPID: @escaping @Sendable (pid_t) -> pid_t?, bundleID: @escaping @Sendable (pid_t) -> String?,
                    responsiblePID: @escaping @Sendable (pid_t) -> pid_t?) {
            self.parentPID = parentPID; self.bundleID = bundleID; self.responsiblePID = responsiblePID
        }

        public static let system = ProcessLookup(
            parentPID: { pid in
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
                return pid_t(info.pbi_ppid)
            },
            bundleID: { pid in NSRunningApplication(processIdentifier: pid)?.bundleIdentifier },
            responsiblePID: { pid in Responsibility.responsiblePID(pid) })
    }

    public let apps: [MeetingApp]
    public let lookup: ProcessLookup

    public init(apps: [MeetingApp] = MeetingApp.known, lookup: ProcessLookup = .system) {
        self.apps = apps
        self.lookup = lookup
    }

    /// The owner bundle id of a process object (nil if none found).
    public func ownerBundleID(_ p: AudioProcessInfo) -> String? {
        if let b = lookup.bundleID(p.pid), let app = app(forBundlePrefix: b) { return app.id }
        if let b = p.bundleID, let app = app(forBundlePrefix: b) { return app.id }
        // Parent chain, at most 16 levels (launchd is pid 1).
        var pid = p.pid
        var seen = Set<pid_t>()
        for _ in 0..<16 {
            guard pid > 1, seen.insert(pid).inserted else { break }
            if pid != p.pid, let b = lookup.bundleID(pid) { return app(forBundlePrefix: b)?.id ?? b }
            guard let parent = lookup.parentPID(pid) else { break }
            if parent <= 1 {
                // XPC service: ask who is responsible for it.
                if let r = lookup.responsiblePID(pid), r != pid, r > 1, let b = lookup.bundleID(r) {
                    return app(forBundlePrefix: b)?.id ?? b
                }
                if p.bundleID == "com.apple.WebKit.GPU" { return "com.apple.Safari" }
                break
            }
            pid = parent
        }
        return p.bundleID
    }

    private func app(forBundlePrefix b: String) -> MeetingApp? {
        apps.first { b == $0.id || b.hasPrefix($0.id + ".") }
    }

    /// Groups the given processes by meeting app (known apps only).
    public func candidates(_ processes: [AudioProcessInfo]) -> [MeetingCandidate] {
        var groups: [String: [AudioProcessInfo]] = [:]
        for p in processes {
            guard let owner = ownerBundleID(p), apps.contains(where: { $0.id == owner }) else { continue }
            groups[owner, default: []].append(p)
        }
        return apps.compactMap { app in groups[app.id].map { MeetingCandidate(app: app, processes: $0) } }
    }

    /// Explicit global fallback excludes both apps, descendants without bundle IDs, and XPC
    /// services through the responsible process. Only live process metadata is inspected.
    public func globalTapExclusions(_ processes: [AudioProcessInfo], ownPID: pid_t = getpid()) -> [AudioObjectID] {
        func protected(_ bundle: String?) -> Bool {
            guard let bundle else { return false }
            return ["com.aaajiao.talktalk", "com.readread.app"].contains {
                bundle == $0 || bundle.hasPrefix($0 + ".")
            }
        }
        return processes.filter { process in
            if protected(process.bundleID) { return true }
            var pending = [process.pid], seen = Set<pid_t>()
            while let pid = pending.popLast(), seen.count < 64 {
                guard pid > 1, seen.insert(pid).inserted else { continue }
                if pid == ownPID || protected(lookup.bundleID(pid)) { return true }
                if let parent = lookup.parentPID(pid), parent > 1 { pending.append(parent) }
                if let responsible = lookup.responsiblePID(pid), responsible > 1, responsible != pid {
                    pending.append(responsible)
                }
            }
            return false
        }.map(\.objectID)
    }

    /// Whether the responsibility SPI resolved at run time (rule 4 works beyond the WebKit fallback).
    public static var responsibilityAvailable: Bool { Responsibility.available }

    /// Current candidates from Core Audio.
    public func currentCandidates() throws -> [MeetingCandidate] {
        try candidates(AudioProcessList.current())
    }

    /// The default meeting source (§3.1): the meeting apps currently reading the microphone.
    /// More than one → the user picks; `preferred` (the last choice) wins when it is among them.
    public static func defaultSource(_ c: [MeetingCandidate], preferred: String? = nil) -> MeetingCandidate? {
        let inCall = c.filter(\.isRunningInput)
        if let preferred, let p = inCall.first(where: { $0.app.id == preferred }) { return p }
        if inCall.count == 1 { return inCall[0] }
        if inCall.isEmpty, let preferred, let p = c.first(where: { $0.app.id == preferred && $0.isRunningOutput }) { return p }
        return nil
    }
}

/// `responsibility_get_pid_responsible_for_pid` (libquarantine SPI), looked up at run time so a
/// missing symbol degrades to "unknown" instead of a launch failure.
enum Responsibility {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let fn else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }

    static var available: Bool { fn != nil }
}
