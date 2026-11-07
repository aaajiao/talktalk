import Foundation
import Synchronization
import Testing

/// Each test case owns only the directories it creates. Task-local scopes also work with
/// direct `swift test` runs and parallel suites, without changing process-wide TMPDIR.
public enum TestTemporaryDirectory {
    @TaskLocal private static var current: Scope?

    public enum Failure: Error, Equatable { case missingScope, scopeFinished, invalidPrefix }

    public static func make(prefix: String) throws -> URL {
        guard !prefix.isEmpty, prefix.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw Failure.invalidPrefix }
        guard let current else { throw Failure.missingScope }
        return try current.make(prefix: prefix)
    }

    static func withScope(_ body: @Sendable () async throws -> Void) async throws {
        let scope = Scope()
        defer {
            for error in scope.finish() {
                Issue.record(error, sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath,
                                                                   line: #line, column: #column))
            }
        }
        try await $current.withValue(scope) { try await body() }
    }

    private final class Scope: Sendable {
        struct State { var roots: [URL] = []; var finished = false }
        let state = Mutex(State())

        func make(prefix: String) throws -> URL {
            try state.withLock { state in
                guard !state.finished else { throw Failure.scopeFinished }
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                state.roots.append(root)
                return root
            }
        }

        func finish() -> [any Error] {
            let roots = state.withLock { state in
                state.finished = true
                defer { state.roots.removeAll() }
                return state.roots
            }
            return roots.reversed().compactMap { root in
                do { try FileManager.default.removeItem(at: root); return nil }
                catch let error as CocoaError where error.code == .fileNoSuchFile { return nil }
                catch { return error }
            }
        }
    }
}

public struct TemporaryFilesTrait: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(for test: Test, testCase: Test.Case?,
                             performing function: @Sendable () async throws -> Void) async throws {
        try await TestTemporaryDirectory.withScope(function)
    }
}

public extension Trait where Self == TemporaryFilesTrait {
    static var temporaryFiles: Self { Self() }
}
