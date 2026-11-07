import Foundation
import Synchronization
import Testing
@testable import TalkTalkTestSupport

@Suite struct TemporaryFilesTests {
    enum Expected: Error { case failure }

    @Test func removesFilesOnSuccessAndThrowWithoutTouchingOtherScopes() async throws {
        let paths = Mutex<[URL]>([])
        try await TestTemporaryDirectory.withScope {
            let outer = try TestTemporaryDirectory.make(prefix: "tt-cleanup-outer")
            paths.withLock { $0.append(outer) }
            try await TestTemporaryDirectory.withScope {
                let inner = try TestTemporaryDirectory.make(prefix: "tt-cleanup-inner")
                paths.withLock { $0.append(inner) }
                try Data("fixture".utf8).write(to: inner.appendingPathComponent("audio.wav"))
            }
            #expect(FileManager.default.fileExists(atPath: outer.path))
            #expect(!FileManager.default.fileExists(atPath: paths.withLock { $0[1].path }))
            do {
                try await TestTemporaryDirectory.withScope {
                    let failed = try TestTemporaryDirectory.make(prefix: "tt-cleanup-throw")
                    paths.withLock { $0.append(failed) }
                    throw Expected.failure
                }
                Issue.record("Expected the test body error to propagate")
            } catch Expected.failure {}
            #expect(FileManager.default.fileExists(atPath: outer.path))
        }
        for path in paths.withLock({ $0 }) { #expect(!FileManager.default.fileExists(atPath: path.path)) }
    }

    @Test func cancellationStillCleansTheScope() async throws {
        let (ready, continuation) = AsyncStream<URL>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            try await TestTemporaryDirectory.withScope {
                let root = try TestTemporaryDirectory.make(prefix: "tt-cleanup-cancel")
                continuation.yield(root)
                try await Task.sleep(for: .seconds(30))
            }
        }
        var iterator = ready.makeAsyncIterator()
        guard let root = await iterator.next() else { try await task.value; return }
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func parallelScopesCleanIndependently() async throws {
        let paths = Mutex<[URL]>([])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await TestTemporaryDirectory.withScope {
                        let root = try TestTemporaryDirectory.make(prefix: "tt-cleanup-parallel")
                        paths.withLock { $0.append(root) }
                        await Task.yield()
                        #expect(FileManager.default.fileExists(atPath: root.path))
                    }
                }
            }
            try await group.waitForAll()
        }
        let roots = paths.withLock { $0 }
        #expect(Set(roots).count == 20)
        #expect(roots.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func refusesUnscopedAllocation() {
        #expect(throws: TestTemporaryDirectory.Failure.missingScope) {
            _ = try TestTemporaryDirectory.make(prefix: "tt-cleanup-unowned")
        }
    }

    @Test func lateChildCannotAllocateAfterItsTestScopeFinishes() async throws {
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        let child = Mutex<Task<Void, Never>?>(nil)
        try await TestTemporaryDirectory.withScope {
            child.withLock { task in
                task = Task {
                    var iterator = resume.makeAsyncIterator()
                    _ = await iterator.next()
                    #expect(throws: TestTemporaryDirectory.Failure.scopeFinished) {
                        _ = try TestTemporaryDirectory.make(prefix: "tt-cleanup-late")
                    }
                }
            }
        }
        continuation.yield(())
        continuation.finish()
        await child.withLock { $0 }?.value
    }

    @Test func cleanupDoesNotFollowSymlinksAndToleratesExplicitRemoval() async throws {
        try await TestTemporaryDirectory.withScope {
            let outside = try TestTemporaryDirectory.make(prefix: "tt-cleanup-preserved")
            let file = outside.appendingPathComponent("keep")
            try Data("keep".utf8).write(to: file)
            try await TestTemporaryDirectory.withScope {
                let root = try TestTemporaryDirectory.make(prefix: "tt-cleanup-link")
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"),
                                                           withDestinationURL: outside)
                let removed = try TestTemporaryDirectory.make(prefix: "tt-cleanup-removed")
                try FileManager.default.removeItem(at: removed)
            }
            #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        }
    }
}

// The trait must cover instance initialization too, because installer fixtures are created there.
@Suite(.temporaryFiles) struct TemporaryFilesInitializationTests {
    private static let allocated = Mutex<Set<URL>>([])
    let directory: URL
    init() throws { directory = try TestTemporaryDirectory.make(prefix: "tt-cleanup-initializer") }

    @Test func initializerRunsInsideTheScope() {
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(arguments: 0..<4) func parameterizedCasesHaveSeparateScopes(_ index: Int) {
        #expect(Self.allocated.withLock { $0.insert(directory).inserted })
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
