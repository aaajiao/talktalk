import CoreAudio
import Darwin
import Foundation
import TalkTalkAudio
import TalkTalkCore
import TalkTalkTestSupport

typealias Dev = MicPolicy.Device

enum Devs {
    static let builtIn = Dev(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: "bltn")
    static let usb = Dev(uid: "usb:mv7", name: "Shure MV7", transport: "usb ")
    static let ear4 = Dev(uid: "bt:ear4", name: "ear (4)", transport: "blue")
    static let mic = Dev(uid: MicPolicy.talkTalkMicUID, name: "TalkTalk Mic", transport: "virt")
    static let tuwa = Dev(uid: "tuwa:mic", name: "Tuwa Mic", transport: "virt")
    static let krisp = Dev(uid: "krisp:mic", name: "Krisp Microphone", transport: "virt")
}

/// Shared, ordered log of side effects, to check the fixed restore order.
final class EventTrail: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

/// In-memory HAL.
final class FakeHAL: SysInputHAL, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [Dev]
    private var defaultUID: String?
    private var restarts = 0
    private(set) var writes: [String] = []
    var failWrites = false
    /// Driver 0.2.0 (m2a): with CanBeDefaultDevice = 0 the write returns noErr and does nothing.
    var micSelectable: (() -> Bool)?
    /// Checks run at the moment of a write (e.g. "the record exists").
    var onWrite: ((String) -> Void)?
    /// Runs after capturing a snapshot, outside the lock, to model changes before its use.
    var afterSnapshot: ((SystemInputPlan.Snapshot) -> Void)?
    let trail: EventTrail?

    init(devices: [Dev], defaultUID: String?, trail: EventTrail? = nil) {
        self.devices = devices
        self.defaultUID = defaultUID
        self.trail = trail
    }

    func set(devices: [Dev], defaultUID: String?) {
        lock.withLock {
            self.devices = devices
            self.defaultUID = defaultUID
        }
    }

    func setDefault(_ uid: String?) { lock.withLock { defaultUID = uid } }
    /// coreaudiod restarted (kAudioHardwarePropertyServiceRestarted), with what came back.
    func serviceRestarted(devices: [Dev], defaultUID: String?) {
        lock.withLock {
            restarts += 1
            self.devices = devices
            self.defaultUID = defaultUID
        }
    }
    var writeCount: Int { lock.withLock { writes.count } }

    func snapshot() -> SystemInputPlan.Snapshot {
        let (snapshot, hook) = lock.withLock {
            (SystemInputPlan.Snapshot(devices: devices, defaultInput: devices.first { $0.uid == defaultUID },
                                      serviceRestarts: restarts), afterSnapshot)
        }
        hook?(snapshot)
        return snapshot
    }

    func setDefaultInput(uid: String) -> Bool {
        let hook: ((String) -> Void)? = lock.withLock { onWrite }
        hook?(uid)
        return lock.withLock {
            guard !failWrites, devices.contains(where: { $0.uid == uid }) else { return false }
            if uid == Devs.mic.uid, let sel = micSelectable, !sel() {
                trail?.add("write-ignored:\(uid)")
                return true
            }
            defaultUID = uid
            writes.append(uid)
            trail?.add("write:\(uid)")
            return true
        }
    }

    func defaultInputUID() -> String? { lock.withLock { defaultUID } }
    func startWatching(_ onChange: @escaping @Sendable () -> Void) {}
    func stopWatching() {}
}

/// The driver's 'ttmm' switch. `.v010`: no property, the Mic is always selectable. `.v020`: the
/// Mic's CanBeDefaultDevice follows 'ttmm' (unless `neverSelectable`); `.v023` is always selectable
/// while keeping a separate 'ttmm'. Mode writes can be refused.
final class FakeMeetingSwitch: MeetingModeSwitch, @unchecked Sendable {
    enum Driver { case v010, v020, v023 }
    private let lock = NSLock()
    let driver: Driver
    private var ttmm = false
    var refuse = false
    var neverSelectable = false
    private(set) var writes: [Bool] = []
    /// Every setMeetingMode call, refused ones included.
    private(set) var attempts = 0
    /// Called (outside the lock) with the read count on every `meetingMode()` read.
    var onRead: ((Int) -> Void)?
    private var reads = 0
    let trail: EventTrail?
    init(_ driver: Driver = .v020, ttmm: Bool = false, trail: EventTrail? = nil) {
        self.driver = driver
        self.ttmm = ttmm
        self.trail = trail
    }

    var value: Bool { lock.withLock { ttmm } }
    /// The Mic re-entered the device list: the driver resets it.
    func driverReset() { lock.withLock { ttmm = false } }

    func meetingMode() -> Bool? {
        let (n, hook) = lock.withLock { reads += 1; return (reads, onRead) }
        hook?(n)
        return driver == .v010 ? nil : lock.withLock { ttmm }
    }
    func setMeetingMode(_ on: Bool) -> OSStatus {
        lock.withLock {
            attempts += 1
            guard driver != .v010 else { return OSStatus(kAudioHardwareUnknownPropertyError) }
            if refuse { return OSStatus(kAudioHardwareIllegalOperationError) }
            ttmm = on
            writes.append(on)
            trail?.add("ttmm:\(on ? 1 : 0)")
            return noErr
        }
    }
    func micCanBeDefault() -> Bool? {
        lock.withLock { driver == .v010 || driver == .v023 ? true : (ttmm && !neverSelectable) }
    }
}

final class FakeProcesses: MeetingProcessSource, @unchecked Sendable {
    private let lock = NSLock()
    private var procs: [CallEndRule.Process]?
    init(_ p: [CallEndRule.Process]?) { procs = p }
    func set(_ p: [CallEndRule.Process]?) { lock.withLock { procs = p } }
    func meetingProcesses() -> [CallEndRule.Process]? { lock.withLock { procs } }

    static let zoomInCall = [CallEndRule.Process(appID: "us.zoom.xos", pid: 4242, isRunningInput: true, isRunningOutput: true)]
    static let zoomIdle = [CallEndRule.Process(appID: "us.zoom.xos", pid: 4242, isRunningInput: false, isRunningOutput: false)]
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double
    init(_ t: Double = 1000) { self.t = t }
    var now: Double { lock.withLock { t } }
    func advance(_ d: Double) { lock.withLock { t += d } }
}

final class FakeGuardHandle: SysInputGuardHandle, @unchecked Sendable {
    let pid: Int32
    let lockFD: Int32
    private(set) var quitCalled = false
    private(set) var handOffCalled = false
    let trail: EventTrail?
    init(pid: Int32, lockFD: Int32, trail: EventTrail?) { self.pid = pid; self.lockFD = lockFD; self.trail = trail }
    func quit() { quitCalled = true; trail?.add("guard:quit") }
    func handOff() { handOffCalled = true; trail?.add("guard:handoff") }
}

final class FakeLauncher: SysInputGuardLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var handles: [FakeGuardHandle] = []
    private var exits: [@Sendable (Int32) -> Void] = []
    let trail: EventTrail?
    var fail = false
    init(trail: EventTrail? = nil) { self.trail = trail }

    func launch(lockFD: Int32, paths: SysInputPaths, onExit: @escaping @Sendable (Int32) -> Void) throws -> SysInputGuardHandle {
        try lock.withLock {
            if fail { throw POSIXError(.EAGAIN) }
            let h = FakeGuardHandle(pid: Int32(90_000 + handles.count), lockFD: lockFD, trail: trail)
            handles.append(h)
            exits.append(onExit)
            trail?.add("guard:launch")
            return h
        }
    }

    var last: FakeGuardHandle? { lock.withLock { handles.last } }
    var count: Int { lock.withLock { handles.count } }
    func simulateExit(_ i: Int = -1) { let e = lock.withLock { i < 0 ? exits.last : exits[i] }; e?(0) }
}

/// A fresh directory for the record and lock.
func tempPaths() throws -> SysInputPaths {
    let dir = try TestTemporaryDirectory.make(prefix: "tt-sysinput")
    return SysInputPaths(directory: dir)
}

func mode(of path: String) -> Int {
    var st = stat()
    guard stat(path, &st) == 0 else { return -1 }
    return Int(st.st_mode & 0o777)
}

/// Spawns a program; `inherit` lists descriptors passed with addinherit_np (everything else is
/// close-on-exec by default). stdout goes to a pipe the caller can read.
struct Spawned {
    let pid: pid_t
    let stdout: Int32
    let stderr: Int32

    static func run(_ path: String, _ args: [String], inherit: [Int32] = [], stdin: Int32? = nil) -> Spawned? {
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&out) == 0, pipe(&err) == 0 else { return nil }
        for f in out + err { _ = fcntl(f, F_SETFD, FD_CLOEXEC) }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        if let stdin { posix_spawn_file_actions_adddup2(&fa, stdin, 0) }
        else { posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&fa, out[1], 1)
        posix_spawn_file_actions_adddup2(&fa, err[1], 2)
        for f in inherit { posix_spawn_file_actions_addinherit_np(&fa, f) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        let all = [path] + args
        var argv: [UnsafeMutablePointer<CChar>?] = all.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, &attr, &argv, environ)
        close(out[1]); close(err[1])
        guard rc == 0 else { close(out[0]); close(err[0]); return nil }
        return Spawned(pid: pid, stdout: out[0], stderr: err[0])
    }

    /// Waits up to `timeout` s; returns the exit status (WEXITSTATUS) or nil (still running).
    func wait(timeout: Double) -> (code: Int32?, signal: Int32?)? {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while Date() < deadline {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid {
                let sig = status & 0x7f
                return sig == 0 ? (code: (status >> 8) & 0xff, signal: nil) : (code: nil, signal: sig)
            }
            usleep(10_000)
        }
        return nil
    }

    func readAll(_ fd: Int32) -> String {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return String(decoding: data, as: UTF8.self)
    }

    func readLine(_ fd: Int32) -> String {
        var bytes: [UInt8] = []
        var c: UInt8 = 0
        while read(fd, &c, 1) == 1 {
            if c == 0x0a { break }
            bytes.append(c)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func kill(_ sig: Int32) { _ = Darwin.kill(pid, sig) }
}

func waitUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        usleep(10_000)
    }
    return cond()
}

/// The TalkTalk executable built next to the tests (`swift build` before `swift test`; check.sh does).
enum Product {
    static var talkTalk: String? {
        var candidates: [URL] = []
        if let b = Bundle.allBundles.first(where: { $0.bundleURL.pathExtension == "xctest" }) {
            candidates.append(b.bundleURL.deletingLastPathComponent().appendingPathComponent("TalkTalk"))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/debug/TalkTalk"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    /// Built with -DTALKTALK_DEV (the fake-HAL hook exists).
    static let isDevBuild: Bool = {
        guard let exe = talkTalk, let p = Spawned.run(exe, ["--version"]) else { return false }
        _ = p.wait(timeout: 10)
        return p.readAll(p.stdout).contains("dev hooks: store-key")
    }()
}
