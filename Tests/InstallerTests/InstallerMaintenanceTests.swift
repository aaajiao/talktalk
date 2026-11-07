import Foundation
import Synchronization
import Testing
@testable import TalkTalkEngineHost

extension InstallerTests {
    @Test func maintenanceFinishesBeforeSuccessOrFailureReleasesBusyState() async throws {
        for exitCode in [0, 1] {
            let s = try script("maintenance-\(exitCode).sh", "exit \(exitCode)\n")
            let entered = Mutex(false)
            let release = AsyncStream<Void>.makeStream()
            let i = EngineInstaller(script: s, paths: paths, finishMaintenance: {
                entered.withLock { $0 = true }
                for await _ in release.stream { break }
            })
            let run = Task { await i.run(.removeActiveModel("fixture-model")) }
            try await waitFor { entered.withLock { $0 } }
            #expect(i.state.isRunning)
            // A second caller must neither launch nor finish the first caller's maintenance.
            #expect(await i.run(.check) == .failed("another installer run is in progress"))
            release.continuation.yield()
            let result = await run.value
            if exitCode == 0 { #expect(result == .finished) }
            else { #expect(result == .failed("install-engine.sh: exit 1")) }
            #expect(!i.state.isRunning)
        }
    }

    @Test func cancelledBeforeLaunchStillFinishesMaintenanceOnce() async throws {
        let marker = dir.appendingPathComponent("must-not-launch")
        let s = try script("cancel-maintenance.sh", ": > '\(marker.path)'\n")
        let entered = Mutex(false)
        let finished = Mutex(0)
        let release = AsyncStream<Void>.makeStream()
        let i = EngineInstaller(script: s, paths: paths, stopEngine: {
            entered.withLock { $0 = true }
            for await _ in release.stream { break }
        }, finishMaintenance: { finished.withLock { $0 += 1 } })
        let run = Task { await i.run(.removeActiveModel("fixture-model")) }
        try await waitFor { entered.withLock { $0 } }
        i.cancel()
        release.continuation.yield()
        #expect(await run.value == .cancelled)
        #expect(finished.withLock { $0 } == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func setupFailureStillFinishesMaintenanceOnce() async throws {
        let s = try script("unreachable.sh", "exit 0\n")
        // Preparing a private logs directory must fail before any child process can start.
        try FileManager.default.createDirectory(at: paths.logs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: paths.logs)
        let finished = Mutex(0)
        let i = EngineInstaller(script: s, paths: paths,
                                finishMaintenance: { finished.withLock { $0 += 1 } })
        let result = await i.run(.check)
        guard case .failed = result else { Issue.record("expected setup failure"); return }
        #expect(finished.withLock { $0 } == 1)
        #expect(!i.state.isRunning)
    }
}
