import AppKit
import Darwin
import Foundation
import TalkTalkAudio
import TalkTalkCore

/// `TalkTalk --sysinput-guard --lock-fd N [--sysinput-dir D]` (ARCHITECTURE.md §8.6 layer 2).
///
/// Headless: no NSApplication, no single-instance lock, no mic, no tap. It must have inherited
/// the record lock from the app (posix_spawn addinherit_np); without it, it exits 3 and changes
/// nothing. stdin is the app's pipe: `quit` → exit without restoring; EOF → wait for the call to
/// end (a Mic vanish during the call is waited out, and the Mic switched back to when it
/// returns), restore by the record, delete it, exit. SIGTERM / SIGINT /
/// SIGHUP keep their default action: exit, no restore.
///
/// Dev build only (cross-process tests, never the real default input):
///   --sysinput-fake-hal <json>   SysInputFileHAL instead of Core Audio (devices, default, processes)
///   --sysinput-poll <seconds>    poll period instead of 2 s
@MainActor
enum SysInputGuardMain {
    static let exitUsage: Int32 = 2
    static let exitNoLock: Int32 = 3

    static func run(_ args: [String]) -> Never {
        // Before the first log line: a closed stderr pipe must be EPIPE, not a kill.
        signal(SIGPIPE, SIG_IGN)
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let paths = value("--sysinput-dir").map { SysInputPaths(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? .standard()
        let nsapp = NSApp != nil
        guard let fdText = value("--lock-fd"), let fd = Int32(fdText) else {
            say("no --lock-fd: the guard only runs when started by TalkTalk (nsapp=\(nsapp ? 1 : 0))")
            exit(exitNoLock)
        }
        guard SysInputLock.verifyInherited(fd: fd, path: paths.lock.path) else {
            say("fd \(fd) is not the inherited record lock; exiting without changes (nsapp=\(nsapp ? 1 : 0))")
            exit(exitNoLock)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Keep the inherited lock alive for the life of the process (closing it would drop the
        // lock once the app is gone).
        let held = SysInputLock(path: paths.lock.path, inheritedFD: fd)

        var config = SystemInputPlan.Config.default
        var hal: SysInputHAL = CoreAudioSysInputHAL()
        var processes: MeetingProcessSource = ResolverProcessSource()
        var meetingSwitch: MeetingModeSwitch? = CoreAudioMeetingModeSwitch()
        #if TALKTALK_DEV
        if let fake = value("--sysinput-fake-hal") {
            let f = SysInputFileHAL(path: fake)
            hal = f
            processes = f
            meetingSwitch = nil
        }
        if let p = value("--sysinput-poll").flatMap(Double.init), p > 0 { config.pollInterval = p }
        #endif
        say("start pid=\(getpid()) lock-fd=\(fd) nsapp=\(nsapp ? 1 : 0)")
        let g = SysInputGuard(environment: .init(hal: hal, processes: processes,
                                                 store: SysInputRecordStore(paths: paths), config: config,
                                                 meetingSwitch: meetingSwitch),
                              input: 0)
        let code = g.run()
        say("done: \(g.outcome.map { "\($0)" } ?? "?")")
        withExtendedLifetime(held) {}
        exit(code)
    }

    private static func say(_ s: String) {
        SysInputGuard.writeStderr("sysinput-guard: " + s + "\n")
    }
}
