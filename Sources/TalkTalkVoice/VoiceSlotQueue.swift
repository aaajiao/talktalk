import Foundation

/// One queue for everything that changes the engine's single voice slot or `voice/profile.json`
/// (review of voice-m2: voiceReady, transcript re-check, 试听, deletion, and the enrollment's
/// build / audition / commit). Operations run one after another in submission order, each to the
/// end of its last await, so two of them never interleave. `VoiceLifecycle` owns one and hands it
/// to every `EnrollmentController` it makes.
///
/// Two kinds of cancellation, kept apart (second review, item 2):
/// - the *caller's* task is cancelled (放弃 / 重录): its operation is cancelled too and the caller
///   sees `CancellationError` with `Task.isCancelled` true;
/// - the *queue* cancels it (`cancelAllThenRun`, a deletion): the caller gets `Cancelled`.
/// Any other `CancellationError` comes from the engine (stopped / restarted mid-call) and is an
/// engine error like any other.
public final class VoiceSlotQueue: @unchecked Sendable {
    /// The operation was cancelled or skipped by `cancelAllThenRun`.
    public struct Cancelled: Error, Equatable {}

    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var cancels: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    /// Runs `body` after every operation submitted before it.
    public func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let flag = QueueCancelFlag()
        let id = UUID()
        let task: Task<T, Error> = lock.withLock {
            let t = chain { try Task.checkCancellation(); return try await body() }
            cancels[id] = { flag.set(); t.cancel() }
            return t
        }
        defer { _ = lock.withLock { cancels.removeValue(forKey: id) } }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if flag.isSet { throw Cancelled() }
            throw error
        }
    }

    /// Like `run`, but never skipped and never cancelled by the queue.
    public func runAlways<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let task: Task<T, Error> = lock.withLock { chain { await body() } }
        return await Self.value(of: task)
    }

    /// Atomically: cancels every queued and running operation and queues `body` behind them, so
    /// nothing submitted afterwards can slip in between (deletion, second review item 5).
    public func cancelAllThenRun<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> Task<T, Never> {
        lock.withLock {
            cancels.values.forEach { $0() }
            cancels.removeAll()
            let t = chain { await body() }
            return Task { await Self.value(of: t) }
        }
    }

    /// A chained non-throwing body: its task can only succeed (nothing checks cancellation).
    private static func value<T: Sendable>(of t: Task<T, Error>) async -> T {
        switch await t.result {
        case let .success(v): return v
        case .failure: preconditionFailure("non-throwing voice operation threw")
        }
    }

    /// Must be called with `lock` held.
    private func chain<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let prev = tail
        let t = Task<T, Error> {
            await prev?.value
            return try await body()
        }
        tail = Task { _ = try? await t.value }
        return t
    }
}

private final class QueueCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var isSet: Bool { lock.withLock { v } }
}

/// A cancellation that should drop the work (the caller or the queue), as opposed to an engine
/// that stopped mid-call (an engine error).
func isDeliberateCancel(_ e: any Error) -> Bool {
    e is VoiceSlotQueue.Cancelled || (e is CancellationError && Task.isCancelled)
}
