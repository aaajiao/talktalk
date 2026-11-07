import Foundation
import Synchronization
import Testing
@testable import TalkTalkCloud

@Suite struct KeyPresenceReuseTests {
    @Test(arguments: [false, true])
    func knownPresenceSkipsTheMetadataQuery(known: Bool) {
        var queries = 0
        let resolved = OpenAIMT.resolveKeyPresence(known) {
            queries += 1
            return !known
        }
        #expect(resolved == known && queries == 0)
    }

    @Test func unknownPresenceQueriesEachTimeAndDoesNotCacheAnOldAnswer() {
        var present = false
        var queries = 0
        let first = OpenAIMT.resolveKeyPresence(nil) { queries += 1; return present }
        present = true
        let second = OpenAIMT.resolveKeyPresence(nil) { queries += 1; return present }
        #expect(!first && second && queries == 2)
    }
}

extension FakeServerCloudTests {
    @Test func eachActualRequestReadsTheCurrentKeyAndDeletionPreventsANewRequest() async throws {
        let replacement = "sk-proj-" + String(repeating: "R", count: 150) + "test"
        let store = Mutex((key: Optional(fakeKey), reads: 0))
        let client = OpenAIClient(cloud: profile.cloud, keyProvider: {
            try store.withLock {
                $0.reads += 1
                guard let key = $0.key else { throw KeychainLike.missing }
                return key
            }
        }, protocolClasses: [.A: [FakeA.self], .B: [FakeB.self]])
        FakeServer.enqueue(.A, FakeServer.good("First response."), FakeServer.good("Second response."))
        for try await _ in client.stream(leg: .A, body: body) {}
        store.withLock { $0.key = replacement }
        for try await _ in client.stream(leg: .A, body: body) {}
        #expect(FakeServer.requests(.A).map(\.authorization) == ["Bearer " + fakeKey, "Bearer " + replacement])
        #expect(store.withLock { $0.reads } == 2)

        store.withLock { $0.key = nil }
        await #expect(throws: OpenAIClient.ClientError.noKey) {
            for try await _ in client.stream(leg: .A, body: body) {}
        }
        #expect(store.withLock { $0.reads } == 3)
        #expect(FakeServer.requests(.A).count == 2)
    }
}
