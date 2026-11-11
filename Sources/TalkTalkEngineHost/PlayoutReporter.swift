import Foundation
import Synchronization
import TalkTalkCore

/// `/v1/playout` cadence (ARCHITECTURE.md): during SPEAK one PlayoutReport every 100 ms,
/// and at once when the queue pauses or resumes, an underrun is counted, the tempo changes or the
/// epoch moves (hard interrupt). The report comes from the queue's actual fill
/// (`ClauseQueue.report(at:)`), so the engine's bufferedAhead already includes underruns, floor
/// pauses and tempo.
///
/// Wiring (SPEAK pipeline): `PlayoutReporter(source: { queue.report(at: HostClock.now()) },
/// sink: { await tts.report($0) })`, `start()` when the SPEAK session opens, `stop()` when it ends,
/// `kick()` after anything that changes the queue outside its pump (optional: changes are also
/// caught within one `poll`). Sends are sequential, so the engine never sees them out of order.
///
/// Stall rule input (§5.7, `TTSStall`): `drainable` returns the audio actually moving to the
/// speaker (ringO plus what the ClauseQueue would move now; not what it holds back for preroll or
/// whole-clause mode). It is read on every poll, before the send, and handed to `onDrainable`
/// (`tts.noteDrainable`), so a send stuck on the control connection does not freeze it.
public final class PlayoutReporter: Sendable {
    public struct Config: Sendable, Equatable {
        public var interval: Duration = .milliseconds(100)
        public var poll: Duration = .milliseconds(20)
        public init() {}
    }

    public let config: Config
    private let source: @Sendable () -> PlayoutReport
    private let drainable: (@Sendable () -> Int)?
    private let onDrainable: (@Sendable (Int) -> Void)?
    private let sink: @Sendable (PlayoutReport) async -> Void
    private struct State {
        var task: Task<Void, Never>?
        var last: PlayoutReport?
        var lastSent: ContinuousClock.Instant?
        var kicked = false
        var sent = 0
    }
    private let state = Mutex(State())

    public init(config: Config = .init(), source: @escaping @Sendable () -> PlayoutReport,
                drainable: (@Sendable () -> Int)? = nil, onDrainable: (@Sendable (Int) -> Void)? = nil,
                sink: @escaping @Sendable (PlayoutReport) async -> Void) {
        self.config = config
        self.source = source
        self.drainable = drainable
        self.onDrainable = onDrainable
        self.sink = sink
    }

    /// Reports sent so far (tests, diagnostics).
    public var sentCount: Int { state.withLock { $0.sent } }

    /// The pure part of the cadence: send on the first report, after `interval`, or when a field
    /// that must be reported at once changed.
    public static func shouldSend(previous: PlayoutReport?, current: PlayoutReport,
                                  sinceLastSend: Duration?, interval: Duration, kicked: Bool = false) -> Bool {
        guard let p = previous, let since = sinceLastSend else { return true }
        if kicked || since >= interval { return true }
        return p.paused != current.paused || current.underruns > p.underruns
            || abs(p.tempo - current.tempo) > 1e-6 || p.epoch != current.epoch
    }

    public func start() {
        state.withLock { s in
            guard s.task == nil else { return }
            s.task = Task { [weak self] in
                while !Task.isCancelled, let self {
                    await self.step(at: .now)
                    try? await Task.sleep(for: self.config.poll)
                }
            }
        }
    }

    public func stop() {
        state.withLock { s in
            s.task?.cancel()
            s.task = nil
            s.last = nil
            s.lastSent = nil
            s.kicked = false
        }
    }

    /// The next poll sends whatever the queue reports, without waiting for the interval.
    public func kick() { state.withLock { $0.kicked = true } }

    /// One poll at `now` (the loop passes the clock; tests pass their own instants).
    func step(at now: ContinuousClock.Instant) async {
        if let drainable, let onDrainable { onDrainable(drainable()) }
        let current = source()
        let send = state.withLock { s -> Bool in
            let go = Self.shouldSend(previous: s.last, current: current, sinceLastSend: s.lastSent.map { now - $0 },
                                     interval: config.interval, kicked: s.kicked)
            if go {
                s.last = current
                s.lastSent = now
                s.kicked = false
                s.sent += 1
            }
            return go
        }
        if send { await sink(current) }
    }
}
