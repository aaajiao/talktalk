import Darwin
import Foundation
import TalkTalkCore

// Layer 2 of §8.6: the guard. Same executable, headless mode `TalkTalk --sysinput-guard`.
// It exists only while there is a restore record. The app starts it with posix_spawn in its own
// process group, stdin = a pipe from the app, and the record lock's descriptor inherited
// (addinherit_np). While the pipe is open it does nothing. On EOF (the app crashed, was
// `kill -9`'d, got SIGTERM, or quit while a restore was deferred) it waits for the call to end,
// restores by the record, deletes it and exits. TalkTalk Mic vanishing during the call does not
// end the wait: macOS's pick stays, and when the Mic returns the guard switches back to it
// (§8.6 "coreaudiod 重启"). SIGTERM to the
// guard itself: exit without restoring (a new app is taking over, or logout; layer 4 finishes).

// MARK: launching (app side)

public protocol SysInputGuardHandle: AnyObject {
    var pid: Int32 { get }
    /// "Exit, do not restore" (the app restored, or voided the record): writes `quit`, closes the pipe.
    func quit()
    /// Close the pipe without `quit`: the guard sees EOF and takes over (app quitting with a deferred restore).
    func handOff()
}

public protocol SysInputGuardLauncher: Sendable {
    /// `onExit` runs on an arbitrary queue when the guard process exits (status as from waitpid).
    func launch(lockFD: Int32, paths: SysInputPaths, onExit: @escaping @Sendable (Int32) -> Void) throws -> SysInputGuardHandle
}

public struct PosixSpawnGuardLauncher: SysInputGuardLauncher {
    public struct SpawnError: Error, Equatable { public let what: String; public let code: Int32 }

    public let executable: String
    /// Extra arguments (dev/test: `--sysinput-fake-hal`, `--sysinput-poll`).
    public let extraArguments: [String]

    public init(executable: String = Bundle.main.executablePath ?? CommandLine.arguments[0], extraArguments: [String] = []) {
        self.executable = executable
        self.extraArguments = extraArguments
    }

    public func launch(lockFD: Int32, paths: SysInputPaths, onExit: @escaping @Sendable (Int32) -> Void) throws -> SysInputGuardHandle {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SpawnError(what: "pipe", code: errno) }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, readEnd, 0)          // dup2 to a new fd clears CLOEXEC
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addinherit_np(&fa, 2)
        posix_spawn_file_actions_addinherit_np(&fa, lockFD)        // M0-T8 d6: not adddup2(fd, fd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group; nothing but 0/1/2 and the lock is inherited; default signal actions.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var def = sigset_t()
        sigemptyset(&def)
        for s in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT] { sigaddset(&def, s) }
        posix_spawnattr_setsigdefault(&attr, &def)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let args = [executable, "--sysinput-guard", "--lock-fd", String(lockFD),
                    "--sysinput-dir", paths.directory.path] + extraArguments
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fa, &attr, &argv, environ)
        close(readEnd)
        guard rc == 0 else {
            close(writeEnd)
            throw SpawnError(what: "posix_spawn", code: rc)
        }
        return SpawnedGuard(pid: pid, writeFD: writeEnd, onExit: onExit)
    }
}

private final class ReapOnce: @unchecked Sendable {
    let lock = NSLock()
    var done = false
}

final class SpawnedGuard: SysInputGuardHandle, @unchecked Sendable {
    let pid: Int32
    /// Our end of the guard's stdin pipe (-1 once closed). Read by tests (@testable).
    private(set) var writeFD: Int32
    /// Test hook (@testable): called with (fd, close's return value) whenever our pipe end is closed.
    var onPipeClosed: (@Sendable (Int32, Int32) -> Void)?
    private let lock = NSLock()
    private let source: DispatchSourceProcess

    init(pid: Int32, writeFD: Int32, onExit: @escaping @Sendable (Int32) -> Void) {
        self.pid = pid
        self.writeFD = writeFD
        let once = ReapOnce()
        let reap: @Sendable (Bool) -> Void = { blocking in
            once.lock.lock()
            defer { once.lock.unlock() }
            guard !once.done else { return }
            var status: Int32 = 0
            guard waitpid(pid, &status, blocking ? 0 : WNOHANG) == pid else { return }
            once.done = true
            onExit(status)
        }
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                  queue: .global(qos: .utility))
        source.setEventHandler { [source] in
            reap(true)
            source.cancel()
        }
        source.resume()
        // The process may already have exited before the source was armed.
        reap(false)
    }

    func quit() {
        lock.withLock {
            guard writeFD >= 0 else { return }
            let msg = "quit\n"
            _ = msg.withCString { Darwin.write(writeFD, $0, strlen($0)) }
            closePipe()
        }
    }

    deinit {
        // A guard that exited by itself is never told quit/handOff: close our end of its pipe.
        // The process source is not cancelled here: it keeps itself alive until the guard exits
        // and is reaped (no zombie after quit()).
        if writeFD >= 0 { closePipe() }
    }

    /// Caller holds `lock` (or is deinit).
    private func closePipe() {
        let fd = writeFD
        let rc = close(fd)
        writeFD = -1
        onPipeClosed?(fd, rc)
    }

    func handOff() {
        lock.withLock {
            guard writeFD >= 0 else { return }
            closePipe()
        }
    }
}

// MARK: the guard (child side)

/// The guard's main loop. Runs on its own serial queue; `run()` blocks the calling thread until it
/// is done and returns the exit code. Everything it needs is injected, so tests run it in-process
/// against a fake HAL with a pipe they control.
public final class SysInputGuard: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case quitByApp            // "quit" from the app: exit, no restore
        case recordGone           // nothing to do
        case restored(String)     // uid written
        case droppedRecord(SystemInputPlan.DropReason)
    }

    public struct Environment: Sendable {
        public var hal: SysInputHAL
        public var processes: MeetingProcessSource
        public var store: SysInputRecordStore
        public var config: SystemInputPlan.Config
        public var now: @Sendable () -> Double
        public var log: @Sendable (String) -> Void
        /// 'ttmm' = 1 (and CanBeDefault read back) before a switch back to TalkTalk Mic during the
        /// call (§8.6 "coreaudiod 重启"), back to 0 after the restore. m2a: the bundle's executable run directly is an
        /// accepted Feed client (the spawned guard is the same binary, not measured separately);
        /// if the write fails anyway, the next launch's idle check does it.
        public var meetingSwitch: MeetingModeSwitch?

        public init(hal: SysInputHAL, processes: MeetingProcessSource, store: SysInputRecordStore,
                    config: SystemInputPlan.Config = .default, meetingSwitch: MeetingModeSwitch? = nil,
                    now: @escaping @Sendable () -> Double = { Double(HostClock.now()) / 1e9 },
                    log: @escaping @Sendable (String) -> Void = { msg in
                        SysInputGuard.writeStderr("sysinput-guard: " + msg + "\n")
                    }) {
            self.hal = hal
            self.processes = processes
            self.store = store
            self.config = config
            self.now = now
            self.log = log
            self.meetingSwitch = meetingSwitch
        }
    }

    private let env: Environment
    private let input: Int32
    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.sysinput-guard")
    private let done = DispatchSemaphore(value: 0)
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var orphaned = false
    private var finished = false
    public private(set) var outcome: Outcome?

    private var tracker = SystemInputPlan.Tracker()
    private var callState = CallEndRule.State()
    private var callEnded = false
    private var monitor: SystemInputPlan.DeferredMonitor?
    private var switchBackFailureLogged = false

    /// stderr without Foundation: `FileHandle.write` raises an uncaught ObjC exception on EPIPE/EIO
    /// (an app started with `| tee` and then ^C'd) and would abort the guard before it restores.
    /// Errors are ignored; with SIGPIPE ignored a closed pipe is just EPIPE.
    public static func writeStderr(_ s: String) {
        var bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeMutableBytes { Darwin.write(2, $0.baseAddress! + off, $0.count - off) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            off += n
        }
    }

    public init(environment: Environment, input: Int32 = 0) {
        self.env = environment
        self.input = input
    }

    /// Blocks until done. Exit code 0 in every orderly case.
    public func run() -> Int32 {
        queue.sync { start() }
        done.wait()
        return 0
    }

    private func start() {
        // Track device history from the start, so a Mic vanish just before EOF is known.
        tracker.update(env.hal.snapshot(), now: env.now())
        let rs = DispatchSource.makeReadSource(fileDescriptor: input, queue: queue)
        rs.setEventHandler { [weak self] in self?.readInput() }
        readSource = rs
        rs.resume()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let period = max(0.05, env.config.pollInterval)
        t.schedule(deadline: .now() + period, repeating: period)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        let q = queue
        env.hal.startWatching { [weak self] in
            q.async { [weak self] in self?.tick() }
        }
    }

    private func readInput() {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = Darwin.read(input, &buf, buf.count)
        if n < 0, errno == EINTR || errno == EAGAIN { return }
        if n <= 0 {
            readSource?.cancel()
            readSource = nil
            if !orphaned {
                orphaned = true
                env.log("pipe closed: the app is gone; waiting for the call to end")
                tick()
            }
            return
        }
        buffer.append(contentsOf: buf[0..<n])
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line == "quit" { finish(.quitByApp); return }
        }
    }

    private func tick() {
        guard !finished else { return }
        let now = env.now()
        let snap = env.hal.snapshot()
        tracker.update(snap, now: now)
        guard orphaned else { return }
        guard let record = env.store.read() else { finish(.recordGone); return }
        if monitor == nil {
            // The session's meeting apps scope "通话结束" even if the first process read fails.
            callState = CallEndRule.State(scope: Set(record.meetingApps))
            monitor = SystemInputPlan.DeferredMonitor(original: record.original, replacementUID: record.replacementUID,
                                                      config: env.config, layer4UID: record.layer4UID,
                                                      layer4ArmedUntil: Self.armDeadline(record, now: now,
                                                                                         config: env.config))
        }
        if let procs = env.processes.meetingProcesses() {
            callEnded = CallEndRule.observe(&callState, processes: procs, now: now).hasEnded
        }
        guard var m = monitor else { return }
        // "现在还原" at quit that failed: restore without waiting, never back to the Mic.
        let decision = m.observe(snap, tracker: tracker, callEnded: callEnded || record.restoreNow == true, now: now)
        monitor = m
        // What we learned (macOS's pick, layer 4's device) goes back into the record, so the app
        // reopening during the call (layer-4 takeover) does not take it for your change. We hold
        // the lock (review of 9d9b3a4 #4).
        if m.replacementUID != record.replacementUID || m.layer4UID != record.layer4UID {
            var r = record
            r.replacementUID = m.replacementUID
            r.layer4UID = m.layer4UID
            do { try env.store.write(r) } catch { env.log("could not write what it learned back to the record") }
        }
        switch decision {
        case .wait:
            break
        case .noTarget:
            env.log("nothing physical to restore to; waiting")
        case .switchToMic:
            // TalkTalk Mic is back (coreaudiod restart) with the call on and the default still on
            // macOS's pick: the Mic again, record kept until the call ends (review 2026-11-05 #4).
            if switchBackToMic() {
                env.log("TalkTalk Mic is back; switched the default input back to it")
                switchBackFailureLogged = false
            } else {
                monitor?.switchBackFailed(now: now)   // retried for up to contestWindow
                if !switchBackFailureLogged {
                    env.log("switching the default input back to TalkTalk Mic failed; will retry")
                    switchBackFailureLogged = true
                }
            }
        case let .dropRecord(reason):
            releaseMeetingMode()
            env.store.delete()
            finish(.droppedRecord(reason))
        case let .restore(target):
            if env.hal.writeAndConfirm(uid: target.device.uid) {
                releaseMeetingMode()
                env.store.delete()
                env.log("restored the default input")
                finish(.restored(target.device.uid))
            } else {
                env.log("writing the default input failed; will retry")
            }
        }
    }

    /// The record's layer-4 deadline, if it is from this boot; never more than one window ahead
    /// (a value from a bad clock must not widen it).
    static func armDeadline(_ r: SysInputRecord, now: Double, config: SystemInputPlan.Config) -> Double? {
        guard let until = r.layer4ArmedUntilUptime, let boot = r.bootSessionUUID,
              boot == SysInputProcess.bootSessionUUID() else { return nil }
        return min(until, now + config.layer4ArmWindow)
    }

    /// 'ttmm' = 1 and CanBeDefault read back first (the driver reset it when the Mic re-entered
    /// the device list), then the write, read back.
    private func switchBackToMic() -> Bool {
        if let sw = env.meetingSwitch,
           MeetingModeGate.makeMicSelectable(sw, timeout: env.config.micSelectableTimeout) != .ready { return false }
        return env.hal.writeAndConfirm(uid: MicPolicy.talkTalkMicUID)
    }

    private func releaseMeetingMode() {
        guard let sw = env.meetingSwitch else { return }
        if !MeetingModeGate.release(sw, defaultInputUID: env.hal.defaultInputUID()), sw.meetingMode() == true {
            env.log("could not set the meeting-mode switch back to 0; the next launch will")
        }
    }

    private func finish(_ o: Outcome) {
        guard !finished else { return }
        finished = true
        outcome = o
        timer?.cancel()
        readSource?.cancel()
        env.hal.stopWatching()
        done.signal()
    }
}

// MARK: process helpers (layer 4)

public enum SysInputProcess {
    /// `kern.bootsessionuuid`: changes on every boot (CLOCK_UPTIME_RAW values compare only within one).
    public static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The resolved executable path of `pid`, nil if it is gone.
    public static func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return resolved(String(decoding: bytes, as: UTF8.self))
    }

    public static func resolved(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// Whether `pid` runs exactly `path` (by path, never by name).
    public static func runs(_ pid: Int32, executable path: String) -> Bool {
        guard !path.isEmpty, let p = executablePath(pid) else { return false }
        return p == resolved(path)
    }

    public static var currentExecutable: String {
        resolved(Bundle.main.executablePath ?? CommandLine.arguments[0])
    }
}
