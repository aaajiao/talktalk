import Foundation
import Synchronization
import Testing
@testable import TalkTalkCloud

@Suite struct MeetingKeyCacheTests {
    private final class Keychain: Sendable {
        struct State { var key: String? = "first"; var generation: UInt64 = 0; var reads = 0 }
        let state = Mutex(State())
        var reads: Int { state.withLock { $0.reads } }
        func write(_ key: String?) { state.withLock { $0.key = key; $0.generation += 1 } }
        func cache() -> MeetingKeyCache {
            MeetingKeyCache(generation: { self.state.withLock { $0.generation } }, read: {
                try self.state.withLock {
                    $0.reads += 1
                    guard let key = $0.key else { throw Missing() }
                    return key
                }
            })
        }
        struct Missing: Error {}
    }

    @Test func concurrentRequestsShareOneRead() async throws {
        let keychain = Keychain()
        let cache = keychain.cache()
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<16 { group.addTask { try cache.value() } }
            for try await key in group { #expect(key == "first") }
        }
        #expect(keychain.reads == 1)
    }

    @Test func savingANewKeyTakesEffectOnTheNextRequest() throws {
        let keychain = Keychain()
        let cache = keychain.cache()
        #expect(try cache.value() == "first")
        keychain.write("second")
        #expect(try cache.value() == "second")
        #expect(keychain.reads == 2)
    }

    @Test func deletingTheKeyStopsItBeingUsed() throws {
        let keychain = Keychain()
        let cache = keychain.cache()
        _ = try cache.value()
        keychain.write(nil)
        #expect(throws: Keychain.Missing.self) { try cache.value() }
    }

    @Test func aFailedReadIsRetried() throws {
        let keychain = Keychain()
        keychain.state.withLock { $0.key = nil }
        let cache = keychain.cache()
        #expect(throws: Keychain.Missing.self) { try cache.value() }
        keychain.state.withLock { $0.key = "late" }
        #expect(try cache.value() == "late")
    }

    @Test func closingDropsTheKeyAndNothingIsHeldAfterwards() throws {
        let keychain = Keychain()
        let cache = keychain.cache()
        _ = try cache.value()
        cache.close()
        _ = try cache.value()
        _ = try cache.value()
        #expect(keychain.reads == 3)
    }
}
