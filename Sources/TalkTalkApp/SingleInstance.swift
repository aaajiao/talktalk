import Darwin
import Foundation
import TalkTalkCore

/// One running app per build flavor (ARCHITECTURE.md, "实时音频与生命周期约束": single instance). TalkTalk.app and
/// TalkTalk-Dev.app have different bundle ids and lock files, so they may run side by side; two
/// copies of the same flavor may not (`open -n` would otherwise start a second menu bar icon).
///
/// The lock is an `flock` on `~/Library/Application Support/TalkTalk/.instance-<flavor>.lock`,
/// held for the life of the process (the kernel drops it on any exit, including `kill -9`).
/// A second launch posts `reopenNotification` so the running instance shows its settings window,
/// then exits 0.
enum SingleInstance {
    private nonisolated(unsafe) static var lockFD: Int32 = -1

    static var reopenNotification: Notification.Name {
        Notification.Name("\(Bundle.main.bundleIdentifier ?? "com.aaajiao.talktalk.bare").reopen")
    }

    /// Returns true if this process now owns the instance lock.
    static func acquire(flavor: BuildFlavor = .current, requireLock: Bool = false) -> Bool {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TalkTalk", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let name: String
        switch flavor {
        case .release: name = "release"
        case .dev: name = "dev"
        case .bare: name = "bare"
        }
        let path = base.appendingPathComponent(".instance-\(name).lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return !requireLock } // ordinary app may run on an odd FS; exclusive self-tests may not
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    /// Asks the instance that holds the lock to come forward.
    static func signalRunningInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            reopenNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
