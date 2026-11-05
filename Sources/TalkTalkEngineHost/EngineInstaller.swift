import Darwin
import Foundation
import Observation

/// One run of `install-engine.sh` (§7.3, §7.4).
public enum InstallerOp: Sendable, Equatable {
    case install(profile: String?)
    case check
    case addModel(String)
    case removeModel(String)
    case uninstall

    public var arguments: [String] {
        switch self {
        case .install(let p): p.map { ["--profile", $0] } ?? []
        case .check: ["--check"]
        case .addModel(let k): ["--add-model", k]
        case .removeModel(let k): ["--remove-model", k]
        case .uninstall: ["--uninstall"]
        }
    }
}

/// One `--json-progress` line: `{"event":"step"|"download"|"done"|"error",…}`. Plain integers
/// arrive as JSON numbers, everything else as strings (`tt_event`).
public enum InstallerEvent: Sendable, Equatable {
    case step(name: String, model: String?, done: Int?, count: Int?)
    case download(file: String, have: Int64, total: Int64, verified: Bool)
    /// `ok` is set by `--check` only (false: problems found).
    case done(profile: String?, ok: Bool?)
    case error(String)
    case unknown(String)

    /// nil for a line that is not a JSON object with an `event` string.
    public static func parse(_ line: String) -> InstallerEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ev = obj["event"] as? String else { return nil }
        func str(_ k: String) -> String? { obj[k] as? String }
        func int(_ k: String) -> Int64? {
            if let n = obj[k] as? NSNumber { return n.int64Value }
            if let s = obj[k] as? String { return Int64(s) }
            return nil
        }
        switch ev {
        case "step":
            return .step(name: str("step") ?? "", model: str("model"), done: int("done").map(Int.init),
                         count: int("count").map(Int.init))
        case "download":
            return .download(file: str("file") ?? "", have: int("have") ?? 0, total: int("total") ?? 0,
                             verified: int("verified") == 1)
        case "done":
            return .done(profile: str("profile"), ok: int("ok").map { $0 == 1 })
        case "error":
            return .error(str("message") ?? "")
        default:
            return .unknown(ev)
        }
    }
}

/// What the settings page shows while a run is going.
public struct InstallerProgress: Sendable, Equatable {
    public var step: String?
    public var model: String?
    public var stepDone: Int?
    public var stepCount: Int?
    public var file: String?
    public var fileHave: Int64 = 0
    public var fileTotal: Int64 = 0
    /// Bytes of the files verified so far in this run.
    public var verifiedBytes: Int64 = 0

    public init() {}

    public mutating func apply(_ e: InstallerEvent) {
        switch e {
        case .step(let name, let m, let d, let c):
            step = name; model = m; stepDone = d; stepCount = c
        case .download(let f, let have, let total, let verified):
            file = f; fileHave = have; fileTotal = total
            if verified { verifiedBytes += total }
        case .done, .error, .unknown:
            break
        }
    }
}

/// §7.3 `InstallerState`.
public enum InstallerState: Sendable, Equatable {
    case idle
    case running(InstallerOp, InstallerProgress)
    case finished
    case failed(String)
    case cancelled

    public var isRunning: Bool { if case .running = self { true } else { false } }
}

/// Runs `/bin/bash <bundle>/Contents/Resources/installer/scripts/install-engine.sh … --json-progress`
/// (§7.3) with a clean environment. stdout carries the events; stderr is appended to
/// `engine-install.log`. Cancel sends SIGTERM to the process group and SIGKILL after the grace
/// period. The engine is stopped first.
@Observable @MainActor
public final class EngineInstaller {
    public private(set) var state: InstallerState = .idle

    @ObservationIgnored public let script: URL
    @ObservationIgnored public let paths: EnginePaths
    @ObservationIgnored public let engineHome: URL
    @ObservationIgnored let launcher: any ProcessLauncher
    @ObservationIgnored let stopEngine: @Sendable () async -> Void
    @ObservationIgnored let homeDirectory: String
    @ObservationIgnored let lang: String
    @ObservationIgnored let termGrace: Duration
    @ObservationIgnored private var runningPID: pid_t?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cancelRequested = false

    public init(script: URL, paths: EnginePaths, engineHome: URL? = nil,
                launcher: any ProcessLauncher = PosixSpawnLauncher(),
                homeDirectory: String = NSHomeDirectory(), lang: String = "en_US.UTF-8",
                termGrace: Duration = .seconds(2),
                stopEngine: @escaping @Sendable () async -> Void = {}) {
        self.script = script
        self.paths = paths
        self.engineHome = engineHome ?? paths.engineHome()
        self.launcher = launcher
        self.stopEngine = stopEngine
        self.homeDirectory = homeDirectory
        self.lang = lang
        self.termGrace = termGrace
    }

    /// Exactly the §7.3 list; InstallerTests asserts it key for key.
    public nonisolated static func environment(paths: EnginePaths, engineHome: URL, home: String,
                                               lang: String) -> [String: String] {
        var env = [
            "HOME": home,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": lang,
            "TMPDIR": paths.installerTmp.path,
            "TALKTALK_ENGINE_HOME": engineHome.path,
            "TALKTALK_BUILD_CACHE": paths.buildCache.path,
        ]
        if let src = paths.engineSource { env["TALKTALK_ENGINE_SRC_DIR"] = src.path }
        return env
    }

    public func launchSpec(for op: InstallerOp) -> LaunchSpec {
        LaunchSpec(executable: "/bin/bash",
                   arguments: [script.path] + op.arguments + ["--json-progress"],
                   environment: Self.environment(paths: paths, engineHome: engineHome, home: homeDirectory, lang: lang),
                   logPath: paths.installLog.path,
                   workingDirectory: "/")
    }

    /// Runs one operation to the end and returns the final state. A second call while one is
    /// running returns `.failed` without starting anything.
    @discardableResult
    public func run(_ op: InstallerOp) async -> InstallerState {
        guard !state.isRunning else { return .failed("another installer run is in progress") }
        generation += 1
        let gen = generation
        cancelRequested = false
        var progress = InstallerProgress()
        state = .running(op, progress)

        await stopEngine()
        if cancelRequested { return finish(.cancelled) }

        let spec = launchSpec(for: op)
        let launched: LaunchedProcess
        do {
            for dir in [paths.logs, paths.caches, paths.installerTmp, paths.buildCache] {
                try EnginePaths.ensurePrivateDirectory(dir)
            }
            ServerLog.rotateIfNeeded(paths.installLog)
            ServerLog.note(paths.installLog, "install-engine.sh \((op.arguments + ["--json-progress"]).joined(separator: " "))")
            launched = try launcher.launch(spec)
        } catch {
            return finish(.failed("cannot start the installer: \(error)"))
        }
        runningPID = launched.pid
        // The installer never reads stdin; EOF there is harmless.
        close(launched.stdinFD)

        let launcher = self.launcher
        let pid = launched.pid
        let exit = Task.detached { await launcher.waitForExit(pid) }
        var lastError: String?
        var checkOK: Bool?
        for await line in LineReader.lines(fd: launched.handshakeFD) {
            guard let ev = InstallerEvent.parse(line) else { continue }
            switch ev {
            case .error(let m): lastError = m
            case .done(_, let ok): checkOK = ok
            default: break
            }
            progress.apply(ev)
            if generation == gen, !cancelRequested { state = .running(op, progress) }
        }
        let status = await exit.value
        runningPID = nil

        if cancelRequested { return finish(.cancelled) }
        if WaitStatus.exited(status), WaitStatus.exitCode(status) == 0 { return finish(.finished) }
        if op == .check, checkOK == false { return finish(.failed(lastError ?? "check found problems")) }
        return finish(.failed(lastError ?? "install-engine.sh: \(WaitStatus.describe(status))"))
    }

    /// SIGTERM to the installer's process group (curl and pip die with it; a re-run resumes),
    /// SIGKILL after the grace period if it is still there.
    public func cancel() {
        guard state.isRunning else { return }
        cancelRequested = true
        guard let pid = runningPID else { return }
        launcher.signalGroup(pid, SIGTERM)
        let gen = generation
        let grace = termGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.generation == gen, self.runningPID == pid else { return }
            self.launcher.signalGroup(pid, SIGKILL)
        }
    }

    private func finish(_ s: InstallerState) -> InstallerState {
        state = s
        return s
    }
}

/// Newline-delimited text from a pipe, read on its own thread. Finishes at EOF; closes `fd`.
enum LineReader {
    static let maxLineBytes = 64 * 1024

    static func lines(fd: Int32) -> AsyncStream<String> {
        AsyncStream { cont in
            let t = Thread {
                defer { close(fd) }
                var buf = [UInt8]()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    buf.append(contentsOf: chunk[0..<n])
                    while let nl = buf.firstIndex(of: 0x0A) {
                        cont.yield(String(decoding: buf[..<nl], as: UTF8.self))
                        buf.removeSubrange(...nl)
                    }
                    if buf.count > maxLineBytes { buf.removeAll() }   // drop a runaway line, keep reading
                }
                if !buf.isEmpty { cont.yield(String(decoding: buf, as: UTF8.self)) }
                cont.finish()
            }
            t.name = "installer-events"
            t.start()
        }
    }
}
