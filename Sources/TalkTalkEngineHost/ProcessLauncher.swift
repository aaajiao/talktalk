import Darwin
import Foundation

/// What to start (§7.6). The environment is complete: nothing is inherited from the app.
public struct LaunchSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// Appended to as the child's fd 2.
    public var logPath: String
    public var workingDirectory: String

    public init(executable: String, arguments: [String], environment: [String: String], logPath: String,
                workingDirectory: String = "/") {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.logPath = logPath
        self.workingDirectory = workingDirectory
    }
}

/// A spawned child: its own process group (pgid == pid), the write end of its stdin (the
/// parent holds it open for the child's whole life; closing it is the stop signal) and the
/// read end of the handshake pipe (the child's fd 1).
public struct LaunchedProcess: Sendable, Equatable {
    public let pid: pid_t
    public let stdinFD: Int32
    public let handshakeFD: Int32
}

public protocol ProcessLauncher: Sendable {
    func launch(_ spec: LaunchSpec) throws -> LaunchedProcess
    /// Blocks until the child exits and reaps it; returns the raw wait status.
    func waitForExit(_ pid: pid_t) async -> Int32
    /// Sends a signal to the child's process group only (never by name, §10).
    func signalGroup(_ pid: pid_t, _ signal: Int32)
}

public enum LaunchError: Error, Equatable, CustomStringConvertible {
    case pipe(Int32)
    case log(String, Int32)
    case spawn(Int32)

    public var description: String {
        switch self {
        case .pipe(let e): "pipe failed: \(String(cString: strerror(e)))"
        case .log(let p, let e): "cannot open \(p): \(String(cString: strerror(e)))"
        case .spawn(let e): "posix_spawn failed: \(String(cString: strerror(e)))"
        }
    }
}

/// `posix_spawn` with its own process group, CLOEXEC_DEFAULT (no app fd leaks into the child),
/// default signal dispositions, an empty signal mask and QoS user-initiated (§7.6).
public struct PosixSpawnLauncher: ProcessLauncher {
    public init() {}

    public func launch(_ spec: LaunchSpec) throws -> LaunchedProcess {
        var stdinPipe: [Int32] = [0, 0]
        var handshakePipe: [Int32] = [0, 0]
        guard pipe(&stdinPipe) == 0 else { throw LaunchError.pipe(errno) }
        guard pipe(&handshakePipe) == 0 else {
            let e = errno
            close(stdinPipe[0]); close(stdinPipe[1])
            throw LaunchError.pipe(e)
        }
        // The parent's ends must not leak into any other child the app spawns.
        _ = fcntl(stdinPipe[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(handshakePipe[0], F_SETFD, FD_CLOEXEC)
        // A child that exits early must not kill the app with SIGPIPE when we close its stdin.
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)

        let logFD = open(spec.logPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard logFD >= 0 else {
            let e = errno
            [stdinPipe[0], stdinPipe[1], handshakePipe[0], handshakePipe[1]].forEach { close($0) }
            throw LaunchError.log(spec.logPath, e)
        }
        defer {
            close(logFD)
            close(stdinPipe[0])
            close(handshakePipe[1])
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, handshakePipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        posix_spawn_file_actions_addchdir(&actions, spec.workingDirectory)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t()
        sigfillset(&all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_set_qos_class_np(&attr, QOS_CLASS_USER_INITIATED)

        let argv = [spec.executable] + spec.arguments
        let envp = spec.environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnv in
                posix_spawn(&pid, spec.executable, &actions, &attr, cArgv, cEnv)
            }
        }
        guard rc == 0 else {
            close(stdinPipe[1]); close(handshakePipe[0])
            throw LaunchError.spawn(rc)
        }
        return LaunchedProcess(pid: pid, stdinFD: stdinPipe[1], handshakeFD: handshakePipe[0])
    }

    public func waitForExit(_ pid: pid_t) async -> Int32 {
        await withCheckedContinuation { cont in
            let t = Thread {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                cont.resume(returning: status)
            }
            t.name = "engine-wait-\(pid)"
            t.start()
        }
    }

    public func signalGroup(_ pid: pid_t, _ signal: Int32) {
        guard pid > 1 else { return }
        _ = killpg(pid, signal)
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { ptrs.forEach { free($0) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// Wait-status helpers (the C macros are not imported into Swift).
public enum WaitStatus {
    public static func exited(_ s: Int32) -> Bool { (s & 0x7f) == 0 }
    public static func exitCode(_ s: Int32) -> Int32 { (s >> 8) & 0xff }
    public static func signaled(_ s: Int32) -> Bool { (s & 0x7f) != 0 && (s & 0x7f) != 0x7f }
    public static func termSignal(_ s: Int32) -> Int32 { s & 0x7f }
    public static func describe(_ s: Int32) -> String {
        if exited(s) { return "exit \(exitCode(s))" }
        if signaled(s) { return "signal \(termSignal(s))" }
        return "status \(s)"
    }
}
