import Foundation
import Network
import TalkTalkCore

/// Connection keep-warm (§6.3): during meeting mode, with cloud on and a key present, every
/// warm connection sends `GET /v1/models/{model}` when it has been idle for keepWarmIntervalS.
/// B is warmed only while SPEAK hedging or LISTEN double-send is on
/// (`sessions.warmBOnlyIfAnyHedgeEnabled`). On right-⌥ key-down a connection whose last warm-up
/// failed, was not reused, or that has been idle > rewarmOnKeyDownIdleS is warmed at once.
public actor KeepWarm {
    public struct LegState: Sendable, Equatable {
        public var lastActivityMs: Int?
        public var lastWarmOK: Bool?
        public var lastReused: Bool?
        public var lastWarmMs: Double?
    }

    let client: OpenAIClient
    let cloud: PolicyProfile.Cloud
    let sink: CloudEventSink
    /// Gate checked before every request: meeting mode && a cloud switch on && key present.
    let isEnabled: @Sendable () -> Bool
    /// Whether B should be warm now (SPEAK hedging or LISTEN double-send on).
    let warmB: @Sendable () -> Bool
    let onResult: @Sendable (Leg, Bool) -> Void
    var model: String
    var states: [Leg: LegState] = [.A: .init(), .B: .init()]
    var loop: Task<Void, Never>?
    private var warming: Set<Leg> = []
    let t0 = ContinuousClock.now

    public init(client: OpenAIClient, cloud: PolicyProfile.Cloud, model: String,
                isEnabled: @escaping @Sendable () -> Bool, warmB: @escaping @Sendable () -> Bool,
                onResult: @escaping @Sendable (Leg, Bool) -> Void = { _, _ in }, sink: @escaping CloudEventSink = { _ in }) {
        self.client = client; self.cloud = cloud; self.model = model
        self.isEnabled = isEnabled; self.warmB = warmB; self.onResult = onResult; self.sink = sink
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

    public func stop() { loop?.cancel(); loop = nil }

    func tick() async {
        guard isEnabled() else { return }
        let now = nowMs()
        for leg in legs {
            let last = states[leg]!.lastActivityMs
            if last == nil || now - last! >= cloud.keepWarmIntervalS * 1000 { _ = await warm(leg) }
        }
    }

    /// Any real request on that connection counts as activity.
    public func noteActivity(_ leg: Leg, reused: Bool?) {
        states[leg]!.lastActivityMs = nowMs()
        if let reused { states[leg]!.lastReused = reused }
    }

    /// Right-⌥ pressed (§5.2): re-warm the connections that need it.
    public func onKeyDown() async {
        guard isEnabled() else { return }
        let now = nowMs()
        for leg in legs {
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
