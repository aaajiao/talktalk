// l10n: zh-Hans (scripts/check-strings.sh)
import Darwin
import Foundation
import TalkTalkCore

/// How one engine process is started and supervised (§7.6). One instance per runtime flavour.
public struct EngineConfig: Sendable {
    public struct Timing: Sendable {
        /// Cold start and every later start (§7.6: 180 s, readread qwen's value).
        public var readyTimeout: Duration = .seconds(180)
        /// Health poll interval during meeting mode.
        public var healthInterval: Duration = .seconds(1)
        /// A health poll without an answer within this time is a miss.
        public var healthTimeout: Duration = .seconds(2)
        /// Consecutive misses that mean "hung".
        public var hangMisses = 2
        /// Pending jobs with no GPU step for this long mean "hung" (paused while `in_long_step`).
        public var stepAgeLimitMs: Double = 4000
        /// stdin closed + SIGTERM, then SIGKILL after this.
        public var termGrace: Duration = .seconds(2)
        /// Restart delays after the 1st, 2nd, 3rd crash.
        public var backoff: [Duration] = [.zero, .seconds(1), .seconds(2)]
        /// This many crashes inside `crashWindow` → `failed`, no automatic restart.
        public var crashLimit = 3
        public var crashWindow: Duration = .seconds(120)
        /// Idle exit after a meeting ends (never during one) and after recording "my voice".
        public var idleAfterMeeting: Duration = .seconds(600)
        public var idleAfterEnrollment: Duration = .seconds(120)

        public init() {}
    }

    public var flavour: String
    public var python: URL
    /// Directory holding `talktalk_engine.py` and the `talktalk_engine` package.
    public var source: URL
    public var modelsDirs: [URL]
    public var warmupDir: URL?
    public var profile: String
    public var roles: [String]
    public var tts: String?
    public var asr: String?
    /// READY is compared with this record, not with EnginePins (§7.5, §7.6).
    public var record: EngineInstallation.Record
    public var paths: EnginePaths
    public var extraArguments: [String] = []
    public var timing = Timing()
    /// Render horizon (§3.3, §6.1 rule 0): passed as `--horizon-ms`, and read by the SPEAK stall rule
    /// (`TTSStall.Config.horizonMs`) so both sides use one value. The app sets it from the active
    /// PolicyProfile (`tts.renderHorizonMs`, which the ClauseQueue reads too); the default is the M2 T2
    /// pick (2026-11-05: the smallest horizon that passed, m0-results "M1/M2 补测").
    public var horizonMs = 1000

    public init(flavour: String = "main", python: URL, source: URL, modelsDirs: [URL], warmupDir: URL?,
                profile: String, roles: [String], tts: String?, asr: String?, record: EngineInstallation.Record,
                paths: EnginePaths, extraArguments: [String] = [], timing: Timing = Timing()) {
        self.flavour = flavour
        self.python = python
        self.source = source
        self.modelsDirs = modelsDirs
        self.warmupDir = warmupDir
        self.profile = profile
        self.roles = roles
        self.tts = tts
        self.asr = asr
        self.record = record
        self.paths = paths
        self.extraArguments = extraArguments
        self.timing = timing
    }

    /// The configuration for an installed engine: roles and models come from install.json.
    /// `policy`: the active PolicyProfile; its `speak.tts.renderHorizonMs` becomes `horizonMs` (the
    /// engine's `--horizon-ms` and the stall rule), the same value the ClauseQueue reads. Without one
    /// the default stays (the M2 T2 pick).
    public static func installed(record: EngineInstallation.Record, installation: EngineInstallation,
                                 paths: EnginePaths, source: URL, roles: [String]? = nil,
                                 policy: PolicyProfile? = nil) -> EngineConfig {
        let r = (roles ?? ["tts", "asr"]).filter { record.roles[$0] != nil }
        var c = EngineConfig(flavour: record.flavour, python: installation.pythonURL, source: source,
                             modelsDirs: [installation.modelsDir], warmupDir: installation.warmupDir,
                             profile: record.profile, roles: r, tts: record.roles["tts"]?.id,
                             asr: record.roles["asr"]?.id, record: record, paths: paths)
        if let policy { c.horizonMs = policy.speak.tts.renderHorizonMs }
        return c
    }

    /// `python3 -I -B talktalk_engine.py --models-dir … --profile … --roles … --tts … --asr …` (§4.4).
    public var arguments: [String] {
        var a = ["-I", "-B", source.appendingPathComponent("talktalk_engine.py").path]
        for d in modelsDirs { a += ["--models-dir", d.path] }
        a += ["--profile", profile, "--roles", roles.joined(separator: ",")]
        if let tts, roles.contains("tts") { a += ["--tts", tts] }
        if let asr, roles.contains("asr") { a += ["--asr", asr] }
        if let warmupDir { a += ["--warmup-dir", warmupDir.path] }
        a += ["--horizon-ms", String(horizonMs)]
        return a + extraArguments
    }

    /// The child's complete environment (§7.6): nothing is inherited, so `READREAD_*`,
    /// `OPENAI_API_KEY`, `PYTHON*` and proxies never reach the engine (§10).
    public static func environment(token: String, paths: EnginePaths, home: String = NSHomeDirectory(),
                                   lang: String? = ProcessInfo.processInfo.environment["LANG"]) -> [String: String] {
        [
            "HOME": home,
            "LANG": lang ?? "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": paths.engineTmp.path,
            "TALKTALK_TOKEN": token,
            "TALKTALK_CACHE_DIR": paths.engineCache.path,
            "HF_HOME": paths.hfHome.path,
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS": "1000",
        ]
    }
}

public enum EngineFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// FATAL before READY: "去设置 › 组件 修复".
    case fatal(String)
    /// READY does not match install.json (readread's `readyMismatch`): both sides listed.
    case readyMismatch([String])
    case timeout
    case crashedTooOften(lastExit: String)
    case launch(String)
    case handshake(String)

    public var description: String {
        switch self {
        case .fatal(let m): String(appLocalized: "engine FATAL: \(m) (去设置 › 组件 修复)")
        case .readyMismatch(let l): "engine READY does not match install.json: " + l.joined(separator: "; ")
        case .timeout: "engine did not become READY in time"
        case .crashedTooOften(let e): "engine crashed 3 times within 2 minutes (last: \(e)); see engine.log"
        case .launch(let m): "engine could not be started: \(m)"
        case .handshake(let m): "engine handshake error: \(m)"
        }
    }
}

public enum EngineStatus: Sendable, Equatable {
    case stopped
    case starting(EngineProgress?)
    case ready(ReadyInfo)
    case restarting(attempt: Int, delay: Duration, reason: String)
    case failed(EngineFailure)
}

/// Supervises one engine process (§7.6): spawn, handshake, READY check, health polling and
/// hang detection in meeting mode, crash restarts with backoff, stop, idle exit.
/// Signals only its own PID's process group; never kills by name (§10).
public actor EngineProcess {
    public let config: EngineConfig
    private let launcher: ProcessLauncher

    public private(set) var status: EngineStatus = .stopped
    /// Valid only while `status` is `.ready`.
    public private(set) var client: EngineClient?
    public var pid: pid_t? { running?.process.pid }

    private struct Running {
        let generation: Int
        let launchedAt: ContinuousClock.Instant
        let process: LaunchedProcess
        let exit: Task<Int32, Never>
        var stdinOpen = true
        var killReason: String?
    }

    private var running: Running?
    private var generation = 0
    private var crashTimes: [ContinuousClock.Instant] = []
    private var observers: [UUID: AsyncStream<EngineStatus>.Continuation] = [:]
    private var monitorTask: Task<Void, Never>?
    private var ttsPreparationDeadlineTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var meetingMode = false
    /// Chosen only by the owner of a cold launch; crash restarts keep that launch's order.
    private var prioritizeASROnLaunch = false
    /// Last health answer (meeting mode), for diagnostics.
    public private(set) var lastHealth: EngineHealth?
    /// Launch counter (diagnostics, tests).
    public private(set) var launches = 0

    public init(config: EngineConfig, launcher: ProcessLauncher = PosixSpawnLauncher()) {
        self.config = config
        self.launcher = launcher
    }

    // MARK: observing

    /// Current status first, then every change.
    public func statusUpdates() -> AsyncStream<EngineStatus> {
        let (stream, cont) = AsyncStream<EngineStatus>.makeStream()
        let id = UUID()
        observers[id] = cont
        cont.yield(status)
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func setStatus(_ s: EngineStatus) {
        status = s
        for c in observers.values { c.yield(s) }
        if case .ready = s {} else if case .starting = s {} else { client = nil }
        ServerLog.note(config.paths.engineLog, "status \(Self.describe(s))")
    }

    static func describe(_ s: EngineStatus) -> String {
        switch s {
        case .stopped: "stopped"
        case .starting(let p): "starting" + (p.map { " \($0.step) \($0.done)/\($0.count)" } ?? "")
        case .ready(let r): "ready pid \(r.pid) port \(r.port)"
        case .restarting(let a, let d, let why): "restarting #\(a) in \(d) (\(why))"
        case .failed(let f): "failed: \(f)"
        }
    }

    // MARK: start / stop

    /// Starts the engine if needed and waits until it is READY (or has failed).
    @discardableResult
    public func start(prioritizingASR: Bool = false) async throws -> ReadyInfo {
        try Task.checkCancellation()
        switch status {
        case .ready(let r): return r
        case .stopped, .failed:
            prioritizeASROnLaunch = prioritizingASR && config.roles.contains("asr")
            launch()
        case .starting, .restarting:
            break
        }
        return try await awaitReady()
    }

    /// READY can expose ASR while TTS is still warming. TTS callers wait on this process's
    /// model state; cancellation or a restart must never carry their request to a new client.
    public func readyTTSClient() async throws -> EngineClient {
        try await readyTTS().client
    }

    /// Voice cache identity uses the same readiness barrier and process snapshot as synthesis.
    public func readyTTSInfo() async throws -> ReadyInfo {
        try await readyTTS().info
    }

    private func readyTTS() async throws -> (info: ReadyInfo, client: EngineClient) {
        let end = ContinuousClock.now + config.timing.readyTimeout
        let info = try await start()
        try Task.checkCancellation()
        guard case .ready = status, info.pid == running?.process.pid, let client else {
            throw EngineAPIError.invalidated
        }
        let launchGeneration = generation
        guard config.roles.contains("tts"), let model = info.models["tts"] else {
            throw RemoteEngineError.tts(code: "tts_not_loaded", message: "")
        }
        if model.state == "ready" { return (info, client) }
        while ContinuousClock.now < end {
            try Task.checkCancellation()
            guard generation == launchGeneration, self.client === client, case .ready = status else {
                throw EngineAPIError.invalidated
            }
            let health: EngineHealth
            do {
                let remaining = (end - ContinuousClock.now).seconds
                guard remaining > 0 else { break }
                health = try await client.health(timeout: min(config.timing.healthTimeout.seconds, remaining))
            } catch {
                try Task.checkCancellation()
                guard generation == launchGeneration, self.client === client else { throw EngineAPIError.invalidated }
                throw error
            }
            try Task.checkCancellation()
            guard generation == launchGeneration, self.client === client, case .ready = status else {
                throw EngineAPIError.invalidated
            }
            observeTTSPreparation(health, generation: launchGeneration, client: client)
            switch health.models["tts"]?.state {
            case "ready":
                let current = ReadyInfo(port: info.port, pid: info.pid, api: info.api, engine: info.engine,
                    runtime: info.runtime, versions: info.versions,
                    models: health.models.mapValues { .init(id: $0.id, rev: $0.rev, state: $0.state) },
                    voice: .init(state: health.voice.state))
                return (current, client)
            case "failed": throw RemoteEngineError.tts(code: "tts_warmup_failed", message: "")
            case nil, "absent": throw RemoteEngineError.tts(code: "tts_not_loaded", message: "")
            default: break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RemoteEngineError.tts(code: "tts_not_ready", message: "")
    }

    /// The user's "重启引擎": clears the crash count and starts afresh.
    @discardableResult
    public func userRestart() async throws -> ReadyInfo {
        crashTimes.removeAll()
        await stop()
        return try await start()
    }

    /// stdin closed → SIGTERM to the process group → SIGKILL after 2 s (§7.6).
    public func stop() async {
        cancelTTSPreparationDeadline()
        idleTask?.cancel(); idleTask = nil
        restartTask?.cancel(); restartTask = nil
        monitorTask?.cancel(); monitorTask = nil
        generation += 1                       // the exit that follows is not a crash
        client?.invalidate()
        if let r = running {
            running = nil
            await terminate(r)
        }
        setStatus(.stopped)
    }

    private func awaitReady() async throws -> ReadyInfo {
        for await s in statusUpdates() {
            switch s {
            case .ready(let r): return r
            case .failed(let f): throw f
            case .stopped: throw CancellationError()
            default: continue
            }
        }
        throw CancellationError()
    }

    private func launch() {
        cancelTTSPreparationDeadline()
        restartTask?.cancel(); restartTask = nil
        generation += 1
        let gen = generation
        let launchedAt = ContinuousClock.now
        launches += 1
        setStatus(.starting(nil))
        let paths = config.paths
        let token = Self.makeToken()
        let process: LaunchedProcess
        do {
            for d in [paths.logs, paths.engineTmp, paths.hfHome, paths.engineCache] {
                try EnginePaths.ensurePrivateDirectory(d)
            }
            ServerLog.rotateIfNeeded(paths.engineLog)
            ServerLog.note(paths.engineLog, "launch #\(launches) flavour \(config.flavour) roles \(config.roles.joined(separator: ","))")
            process = try launcher.launch(LaunchSpec(
                executable: config.python.path,
                arguments: config.arguments + (prioritizeASROnLaunch ? ["--asr-first"] : []),
                environment: EngineConfig.environment(token: token, paths: paths),
                logPath: paths.engineLog.path))
        } catch {
            setStatus(.failed(.launch("\(error)")))
            return
        }
        let launcher = self.launcher
        let exit = Task.detached { await launcher.waitForExit(process.pid) }
        running = Running(generation: gen, launchedAt: launchedAt, process: process, exit: exit)
        Task { [weak self] in
            let st = await exit.value
            await self?.processExited(generation: gen, status: st)
        }
        Task { [weak self] in
            await self?.handshake(generation: gen, process: process, token: token)
        }
    }

    private func handshake(generation gen: Int, process: LaunchedProcess, token: String) async {
        let timeout = config.timing.readyTimeout
        let outcome: HandshakeOutcome = await withTaskGroup(of: HandshakeOutcome.self) { group in
            group.addTask { [weak self] in
                for await line in ServerHandshake.lines(fd: process.handshakeFD) {
                    switch line {
                    case .progress(let p): await self?.progress(generation: gen, p)
                    case .ready(let r): return .ready(r)
                    case .fatal(let m): return .fatal(m)
                    case .unexpected(let s): return .unexpected(s)
                    }
                }
                return .eof
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timeout
            }
            let first = await group.next() ?? .eof
            group.cancelAll()
            return first
        }
        guard gen == generation, var r = running, r.generation == gen else { return }
        switch outcome {
        case .ready(let info):
            let models = info.models.mapValues { (id: $0.id, rev: $0.rev) }
            let bad = EngineInstallation.readyMismatches(
                record: config.record, engine: info.engine, api: info.api, runtime: info.runtime,
                models: models, roles: config.roles)
            if !bad.isEmpty {
                await fail(.readyMismatch(bad), killing: r)
                return
            }
            client = EngineClient(port: info.port, token: token,
                                  controlTimeout: config.timing.healthTimeout.seconds)
            setStatus(.ready(info))
            if info.models["tts"]?.state == "loading", let client {
                startTTSPreparationDeadline(generation: gen, client: client, launchedAt: r.launchedAt)
            }
            if meetingMode { startMonitor() }
        case .fatal(let m):
            r.killReason = "fatal"
            running = r
            await fail(.fatal(m), killing: r)
        case .unexpected(let s):
            await fail(.handshake("unexpected line on the handshake fd: \(s)"), killing: r)
        case .timeout:
            await fail(.timeout, killing: r)
        case .eof:
            break   // the process exited before READY: processExited() treats it as a crash
        }
    }

    private enum HandshakeOutcome: Sendable {
        case ready(ReadyInfo)
        case fatal(String)
        case unexpected(String)
        case timeout
        case eof
    }

    private func progress(generation gen: Int, _ p: EngineProgress) {
        guard gen == generation, case .starting = status else { return }
        setStatus(.starting(p))
    }

    /// A deterministic failure: stop this process and do not restart it.
    private func fail(_ f: EngineFailure, killing r: Running) async {
        cancelTTSPreparationDeadline()
        generation += 1
        running = nil
        monitorTask?.cancel(); monitorTask = nil
        client?.invalidate()
        setStatus(.failed(f))
        await terminate(r)
    }

    private func processExited(generation gen: Int, status st: Int32) {
        guard gen == generation, let r = running, r.generation == gen else { return }
        cancelTTSPreparationDeadline()
        running = nil
        if r.stdinOpen { close(r.process.stdinFD) }
        monitorTask?.cancel(); monitorTask = nil
        client?.invalidate()
        let reason = (r.killReason.map { "\($0), " } ?? "") + WaitStatus.describe(st)
        ServerLog.note(config.paths.engineLog, "engine pid \(r.process.pid) exited: \(reason)")
        let now = ContinuousClock.now
        crashTimes.append(now)
        crashTimes.removeAll { now - $0 > config.timing.crashWindow }
        if crashTimes.count >= config.timing.crashLimit {
            setStatus(.failed(.crashedTooOften(lastExit: reason)))
            return
        }
        let backoff = config.timing.backoff
        let delay = backoff.isEmpty ? .zero : backoff[min(crashTimes.count - 1, backoff.count - 1)]
        setStatus(.restarting(attempt: crashTimes.count, delay: delay, reason: reason))
        restartTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.restartAfterCrash()
        }
    }

    private func restartAfterCrash() {
        guard case .restarting = status else { return }
        launch()
    }

    private func terminate(_ r: Running) async {
        if r.stdinOpen { close(r.process.stdinFD) }
        let killer = Self.signalSequence(launcher: launcher, pid: r.process.pid, grace: config.timing.termGrace)
        _ = await r.exit.value
        killer.cancel()
    }

    /// SIGTERM to the process group now, SIGKILL after `grace` unless cancelled (the caller
    /// cancels it once the process has exited). Awaiting the exit is not cancellable, so the
    /// SIGKILL must come from this timer rather than after a race.
    private static func signalSequence(launcher: ProcessLauncher, pid: pid_t, grace: Duration) -> Task<Void, Never> {
        launcher.signalGroup(pid, SIGTERM)
        return Task.detached {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            launcher.signalGroup(pid, SIGKILL)
        }
    }

    // MARK: meeting mode, health, idle

    /// Meeting mode: health every second and hang detection; never idle-exits. Leaving it
    /// schedules the idle exit (10 minutes).
    public func setMeetingMode(_ on: Bool) {
        meetingMode = on
        if on {
            idleTask?.cancel(); idleTask = nil
            if case .ready = status { startMonitor() }
        } else {
            monitorTask?.cancel(); monitorTask = nil
            scheduleIdleStop(after: config.timing.idleAfterMeeting)
        }
    }

    /// Enrollment work begins (recording "my voice" starts, or a take is saved): cancels an idle
    /// exit that an earlier `enrollmentFinished()` scheduled, so reopening the window within
    /// `idleAfterEnrollment` cannot have the engine stopped mid-save. `enrollmentFinished()`
    /// schedules it again. Meeting mode is unaffected (it never has an idle exit pending).
    /// `start()` on a ready engine deliberately does not cancel it: idle stays the caller's call.
    public func enrollmentStarted() {
        idleTask?.cancel(); idleTask = nil
    }

    /// After recording "my voice" (started with `--roles tts,asr`): exit 2 minutes later.
    public func enrollmentFinished() {
        guard !meetingMode else { return }
        scheduleIdleStop(after: config.timing.idleAfterEnrollment)
    }

    public func scheduleIdleStop(after d: Duration) {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: d)
            guard !Task.isCancelled else { return }
            await self?.idleExpired()
        }
    }

    /// Runs on the idle task. Checks cancellation again once on the actor: a cancel
    /// (`enrollmentStarted()`, meeting mode, a new schedule) can land between the sleep and the hop.
    private func idleExpired() async {
        guard !Task.isCancelled, !meetingMode else { return }
        ServerLog.note(config.paths.engineLog, "idle exit")
        await stop()
    }

    private func startMonitor() {
        monitorTask?.cancel()
        let gen = generation
        let interval = config.timing.healthInterval
        let timeout = config.timing.healthTimeout.seconds
        let maxMisses = config.timing.hangMisses
        monitorTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, let client = await self.client else { return }
                do {
                    let h = try await client.health(timeout: timeout)
                    misses = 0
                    if let why = await self.recordHealth(h, generation: gen, client: client) {
                        await self.killHung(why, ifGeneration: gen)
                        return
                    }
                } catch {
                    if Task.isCancelled { return }
                    misses += 1
                    if misses >= maxMisses {
                        await self.killHung("\(misses) health polls without an answer within \(timeout) s", ifGeneration: gen)
                        return
                    }
                }
            }
        }
    }

    /// Returns a reason when the answer means "hung": pending jobs but no GPU step for > 4 s,
    /// except while the engine declares `in_long_step` (weight materialisation, first shader
    /// compilation). Deferred TTS preparation retains the separate startup deadline. TTS jobs parked at
    /// the render horizon (paused playback, full buffer) do not count: the engine holds them on
    /// purpose (§6.1 rule 0).
    private func recordHealth(_ h: EngineHealth, generation gen: Int, client: EngineClient) -> String? {
        guard gen == generation, self.client === client, case .ready = status else { return nil }
        lastHealth = h
        observeTTSPreparation(h, generation: gen, client: client)
        return Self.hangReason(h.gpu, limitMs: config.timing.stepAgeLimitMs)
    }

    /// A long startup step may exempt the ordinary step watchdog, but never extends the
    /// original launch-to-ready allowance. This also runs without meeting-mode polling or TTS callers.
    private func startTTSPreparationDeadline(generation gen: Int, client: EngineClient,
                                             launchedAt: ContinuousClock.Instant) {
        cancelTTSPreparationDeadline()
        let deadline = launchedAt + config.timing.readyTimeout
        ttsPreparationDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.ttsPreparationDeadlineReached(generation: gen, client: client)
        }
    }

    private func cancelTTSPreparationDeadline() {
        ttsPreparationDeadlineTask?.cancel()
        ttsPreparationDeadlineTask = nil
    }

    private func observeTTSPreparation(_ health: EngineHealth, generation gen: Int, client: EngineClient) {
        guard gen == generation, self.client === client, ttsPreparationDeadlineTask != nil else { return }
        if let state = health.models["tts"]?.state, state == "ready" || state == "failed" {
            cancelTTSPreparationDeadline()
        }
    }

    private func ttsPreparationDeadlineReached(generation gen: Int, client: EngineClient) async {
        guard !Task.isCancelled, ttsPreparationDeadlineTask != nil,
              gen == generation, self.client === client, case .ready = status else { return }
        let health = try? await client.health(timeout: config.timing.healthTimeout.seconds)
        guard !Task.isCancelled, ttsPreparationDeadlineTask != nil,
              gen == generation, self.client === client, case .ready = status else { return }
        if let health { observeTTSPreparation(health, generation: gen, client: client) }
        guard ttsPreparationDeadlineTask != nil else { return }
        ttsPreparationDeadlineTask = nil
        await killHung("TTS preparation exceeded the startup deadline", ifGeneration: gen)
    }

    public static func hangReason(_ gpu: EngineHealth.GPU, limitMs: Double) -> String? {
        guard !gpu.inLongStep, gpu.activeJobs > 0, let age = gpu.lastStepAgeMs, age > limitMs else { return nil }
        return "\(gpu.activeJobs) pending jobs, last GPU step \(Int(age)) ms ago"
    }

    /// A caller-side hang verdict (the SPEAK stall rule's 4 s escalation, §5.7): same handling as
    /// the health monitor's hang (§7.6): kill, then the crash restart with backoff. Ignored unless
    /// the engine is READY.
    public func reportHang(_ why: String) async {
        await killHung(why)
    }

    private func killHung(_ why: String, ifGeneration expected: Int? = nil) async {
        guard expected == nil || expected == generation, case .ready = status, var r = running else { return }
        cancelTTSPreparationDeadline()
        ServerLog.note(config.paths.engineLog, "hung: \(why)")
        r.killReason = "hung (\(why))"
        running = r
        monitorTask?.cancel(); monitorTask = nil
        // Same signal sequence as stop(); the exit is then handled as a crash (backoff restart).
        if r.stdinOpen {
            close(r.process.stdinFD)
            r.stdinOpen = false
            running = r
        }
        let killer = Self.signalSequence(launcher: launcher, pid: r.process.pid, grace: config.timing.termGrace)
        let exit = r.exit
        Task.detached {
            _ = await exit.value
            killer.cancel()
        }
    }

    // MARK: helpers

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytesShim.fill(&bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// 32 random bytes for the per-launch token (arc4random_buf is CSPRNG-backed on Darwin).
enum SecRandomCopyBytesShim {
    static func fill(_ bytes: inout [UInt8]) -> Bool {
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return true
    }
}

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
