import Foundation
import Network
import TalkTalkCore

/// Connection keep-warm (§6.3): during meeting mode, with cloud on and a key present, every
/// warm connection sends `GET /v1/models/{model}` when it has been idle for keepWarmIntervalS.
/// B is warmed only while SPEAK hedging or LISTEN double-send is on
/// (`sessions.warmBOnlyIfAnyHedgeEnabled`). On right-⌥ key-down a connection whose last warm-up
/// failed, was not reused, or that has been idle > rewarmOnKeyDownIdleS is warmed at once.
///
/// With `primerBody`, a leg's first warm-up after the client builds its session (meeting start,
/// each rebuild) is instead one minimal `POST /v1/responses` (prime): in the 2026-11-24…26 meetings
/// the first translation request on a connection that had carried only GETs was translated in time
/// 2 times out of 19 (15 got no response headers by the deadline, 1 had headers but no text, 1 was a
/// hedge copy cancelled when the other leg won), while later ones on a connection answered even
/// after 15 s or more idle (37 of 37 across all logs, 2 of 2 since 11-24).
public actor KeepWarm {
    public struct LegState: Sendable, Equatable {
        public var lastActivityMs: Int?
        public var lastWarmOK: Bool?
        public var lastReused: Bool?
        public var lastWarmMs: Double?
        /// The client session generation this leg's primer went out on (or is going out on).
        public var primedGeneration: Int?
        /// After a primer that never reached the server: the loop's next one for that generation waits
        /// until `atMs`; a rebuilt session primes at once.
        public var primeRetry: PrimeRetry?
    }

    public struct PrimeRetry: Sendable, Equatable {
        public var generation: Int
        public var atMs: Int
    }

    let client: OpenAIClient
    let cloud: PolicyProfile.Cloud
    let sink: CloudEventSink
    /// Gate checked before every request: meeting mode && a cloud switch on && key present.
    let isEnabled: @Sendable () -> Bool
    /// Whether B should be warm now (SPEAK hedging or LISTEN double-send on).
    let warmB: @Sendable () -> Bool
    let onResult: @Sendable (Leg, Bool) -> Void
    /// The primer request's body (the caller's current model, effort and tier); nil: no primer.
    let primerBody: (@Sendable () async -> Data?)?
    var model: String
    var states: [Leg: LegState] = [.A: .init(), .B: .init()]
    var loop: Task<Void, Never>?
    private var warming: Set<Leg> = []
    /// Primers in flight, each a task of its own (startPrime); `run` tells a restarted one apart.
    private var primers: [Leg: (run: Int, task: Task<Void, Never>)] = [:]
    private var primerRuns = 0
    let t0 = ContinuousClock.now

    public init(client: OpenAIClient, cloud: PolicyProfile.Cloud, model: String,
                isEnabled: @escaping @Sendable () -> Bool, warmB: @escaping @Sendable () -> Bool,
                onResult: @escaping @Sendable (Leg, Bool) -> Void = { _, _ in },
                primerBody: (@Sendable () async -> Data?)? = nil, sink: @escaping CloudEventSink = { _ in }) {
        self.client = client; self.cloud = cloud; self.model = model
        self.isEnabled = isEnabled; self.warmB = warmB; self.onResult = onResult; self.primerBody = primerBody
        self.sink = sink
    }

    func nowMs() -> Int { Int((ContinuousClock.now - t0) / .milliseconds(1)) }

    public func state(_ leg: Leg) -> LegState { states[leg]! }

    public func setModel(_ m: String) { model = m }

    var legs: [Leg] { warmB() ? [.A, .B] : [.A] }

    /// Starts the periodic loop (checks once per second which connection is due).
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stops the loop and cancels the primers in flight; a cancelled one goes out again on the next start.
    public func stop() {
        loop?.cancel(); loop = nil
        for primer in primers.values { primer.task.cancel() }
        primers = [:]
    }

    func tick() async {
        guard isEnabled() else { return }
        let now = nowMs()
        for leg in legs {
            // A leg still without its primer gets no GET: the first POST after only GETs is what went unanswered.
            if needsPrime(leg) {
                let retry = states[leg]!.primeRetry
                if retry == nil || retry!.generation != client.generation(leg) || now >= retry!.atMs { startPrime(leg) }
                continue
            }
            let last = states[leg]!.lastActivityMs
            if last == nil || now - last! >= cloud.keepWarmIntervalS * 1000 { _ = await warm(leg) }
        }
    }

    func needsPrime(_ leg: Leg) -> Bool {
        primerBody != nil && states[leg]!.primedGeneration != client.generation(leg)
    }

    /// Starts `leg`'s primer as a task of its own: one stuck before headers (up to requestTimeoutS)
    /// holds up neither the loop nor the other leg's primer or keep-warm.
    func startPrime(_ leg: Leg) {
        guard primers[leg] == nil, needsPrime(leg) else { return }
        primerRuns += 1
        let run = primerRuns
        primers[leg] = (run, Task { await self.prime(leg, run: run) })
    }

    /// One primer on `leg` for the client's current session generation. Once it reaches the server,
    /// whatever its outcome (a timeout before headers included), it is that session's only primer and
    /// counts as activity, but not as a keep-warm result (no onResult, so no failure streak or reset).
    /// One that never reached it (offline, no route, no key) is neither: the loop tries again
    /// keepWarmIntervalS later (a rebuilt session at once), a key press at once. Stopped before it
    /// ends, it goes out again on the next start; cut off by a rebuild, the new session gets its own
    /// on the next tick.
    func prime(_ leg: Leg, run: Int? = nil) async {
        defer { if let run, primers[leg]?.run == run { primers[leg] = nil } }
        guard isEnabled(), !Task.isCancelled, !warming.contains(leg), let primerBody, needsPrime(leg) else { return }
        let generation = client.generation(leg)
        warming.insert(leg)
        defer { warming.remove(leg) }
        states[leg]!.primedGeneration = generation
        guard let body = await primerBody(), isEnabled(), !Task.isCancelled else {
            if Task.isCancelled || !isEnabled() { states[leg]!.primedGeneration = nil }
            return
        }
        let start = ContinuousClock.now
        func elapsed() -> Double { Double((ContinuousClock.now - start) / .microseconds(1)) / 1000 }
        var id: String?, status: Int?, headersMs: Double?, failure: (any Error)?
        do {
            for try await item in client.stream(leg: leg, body: body) {
                switch item {
                case .started(let clientRequestID): id = clientRequestID
                case .headers(let h), .httpError(let h, _): status = h.status; headersMs = elapsed()
                case .sse: break
                }
            }
        } catch { failure = error }
        guard !Task.isCancelled else { states[leg]!.primedGeneration = nil; return }
        if status == nil, let failure, Self.neverReachedServer(failure) {
            states[leg]!.primedGeneration = nil
            states[leg]!.primeRetry = .init(generation: generation, atMs: nowMs() + cloud.keepWarmIntervalS * 1000)
        } else {
            states[leg]!.primeRetry = nil
            states[leg]!.lastActivityMs = nowMs()
        }
        sink(.prime(leg: leg, clientRequestID: id, status: status, headersMs: headersMs, ms: elapsed()))
    }

    /// No response and an error other than a timeout (the request went out and got no answer in
    /// time) or a cancellation (a rebuild cut it off; the new session primes on its own).
    static func neverReachedServer(_ error: any Error) -> Bool {
        guard let url = error as? URLError else { return true }
        return url.code != .timedOut && url.code != .cancelled
    }

    /// Any real request on that connection counts as activity.
    public func noteActivity(_ leg: Leg, reused: Bool?) {
        states[leg]!.lastActivityMs = nowMs()
        if let reused { states[leg]!.lastReused = reused }
    }

    /// Right-⌥ pressed (§5.2): re-warm the connections that need it. A leg still without its primer
    /// gets the primer now (none goes out twice), also while the loop waits to retry one that never
    /// reached the server.
    public func onKeyDown() async {
        guard isEnabled() else { return }
        let now = nowMs()
        for leg in legs {
            if needsPrime(leg) { startPrime(leg); continue }
            let s = states[leg]!
            let idle = s.lastActivityMs.map { now - $0 > cloud.rewarmOnKeyDownIdleS * 1000 } ?? true
            if idle || s.lastWarmOK == false || s.lastReused == false { _ = await warm(leg) }
        }
    }

    /// One `GET /v1/models/{model}` on `leg`. No request when disabled.
    @discardableResult
    public func warm(_ leg: Leg) async -> Bool {
        guard isEnabled(), !Task.isCancelled, !warming.contains(leg) else { return false }
        warming.insert(leg)
        defer { warming.remove(leg) }
        let path = cloud.keepWarmPath.replacingOccurrences(of: "{model}", with: model)
        let start = ContinuousClock.now
        var ok = false
        do {
            let r = try await client.get(leg: leg, path: path)
            ok = r.headers.status == 200
        } catch {
            ok = false
        }
        guard !Task.isCancelled else { return false }
        let ms = Double((ContinuousClock.now - start) / .microseconds(1)) / 1000
        states[leg]!.lastActivityMs = nowMs()
        states[leg]!.lastWarmOK = ok
        states[leg]!.lastWarmMs = ms
        sink(.keepWarm(leg: leg, ok: ok, ms: ms))
        onResult(leg, ok)
        return ok
    }

    /// Records the reuse flag from a keep-warm's metrics (wired by the caller from CloudEvent).
    public func noteReused(_ leg: Leg, _ reused: Bool) { states[leg]!.lastReused = reused }
}

/// NWPathMonitor wrapper (§6.3, §6.4 step 5): offline → straight to Apple; a changed path while
/// online → rebuild both sessions.
public final class NetworkHealth: Sendable {
    public enum Change: Sendable, Equatable { case offline, online, pathChanged }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "talktalk.network-health")
    public let changes: AsyncStream<Change>
    private let continuation: AsyncStream<Change>.Continuation

    public init() {
        (changes, continuation) = AsyncStream<Change>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let cont = continuation
        let last = LastPath()
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let signature = path.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",")
            switch last.update(satisfied: satisfied, signature: signature) {
            case .some(let c): cont.yield(c)
            case .none: break
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel(); continuation.finish() }

    public var isOnline: Bool { monitor.currentPath.status == .satisfied }

    final class LastPath: @unchecked Sendable {
        private var satisfied: Bool?
        private var signature = ""
        private let lock = NSLock()
        func update(satisfied s: Bool, signature sig: String) -> Change? {
            lock.lock(); defer { lock.unlock() }
            defer { satisfied = s; signature = sig }
            guard let prev = satisfied else { return nil }
            if prev && !s { return .offline }
            if !prev && s { return .online }
            if s && sig != signature { return .pathChanged }
            return nil
        }
    }
}
