import Foundation
import Synchronization

/// One meeting's copy of the API key, so a slow Keychain read cannot land inside a sentence's
/// deadline. It lives only in this process, goes only to `OpenAIClient`'s Authorization header
/// and is dropped when the meeting ends. Saving or deleting the key in this app takes effect on
/// the next request; a change made elsewhere (Keychain Access) waits for the next meeting, and
/// so does a meeting already paused by a key error (`CloudHealth` keeps that pause).
public final class MeetingKeyCache: Sendable {
    private struct State {
        var key: String?
        var generation: UInt64 = 0
        var closed = false
    }

    private let state = Mutex(State())
    private let read: @Sendable () throws -> String
    private let generation: @Sendable () -> UInt64

    public init(generation: @escaping @Sendable () -> UInt64 = { KeychainSecret.writeGeneration },
                read: @escaping @Sendable () throws -> String) {
        self.generation = generation
        self.read = read
    }

    /// The lock is held across the read, so concurrent first requests share one Keychain read
    /// and one possible prompt. A failed read is not remembered.
    public func value() throws -> String {
        try state.withLock { s in
            let current = generation()
            if let key = s.key, s.generation == current { return key }
            s.key = nil
            let key = try read()
            if !s.closed { s.key = key; s.generation = current }
            return key
        }
    }

    /// Requests still draining after this read the Keychain themselves.
    public func close() {
        state.withLock { $0.closed = true; $0.key = nil }
    }
}
