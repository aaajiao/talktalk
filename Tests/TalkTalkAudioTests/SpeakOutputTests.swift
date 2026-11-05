import CAudioCore
import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkAudio

private final class OutputFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var attached = false
    private var failures = 0
    private var callbacks: [@Sendable (FeedOutput.Interruption) -> Void] = []
    private var attaches = 0
    var attachCount: Int { lock.withLock { attaches } }
    func failNextAttach() { lock.withLock { failures += 1 } }
    var hooks: SpeakOutput.FeedHooks {
        .init(attach: { [self] callback in
            try lock.withLock {
                attaches += 1
                if failures > 0 { failures -= 1; throw FeedOutput.Failure(status: -1, what: "fake") }
                attached = true; callbacks.append(callback)
            }
        }, detach: { [self] in lock.withLock { attached = false } }, isAttached: { [self] in lock.withLock { attached } })
    }
    func interrupt(_ index: Int, _ event: FeedOutput.Interruption) {
        let callback = lock.withLock { () -> @Sendable (FeedOutput.Interruption) -> Void in
            if index == callbacks.count - 1 { attached = false }
            return callbacks[index]
        }
        callback(event)
    }
}
private func outputProfile() throws -> PolicyProfile {
    try PolicyProfile.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/PolicyProfile.default.json"))
}

@Suite struct SpeakOutputTests {
    @Test func launchTakeoverAttachesWithoutCreatingASession() async throws {
        let feed = OutputFeed(), profile = try outputProfile()
        let output = try SpeakOutput(profile: profile, liveIO: false, hooks: feed.hooks)
        #expect(await output.prepareLaunchTakeover())
        await output.finishLaunchTakeover()
        #expect(!output.isFeedAttached)
        _ = try await output.beginSession(config: .init(profile))
        await output.finishLaunchTakeover()
        #expect(output.isFeedAttached)
        await output.close()
    }

    @Test func failedAttachRetriesOnDevicesAndStopCannotReattach() async throws {
        let feed = OutputFeed(), profile = try outputProfile()
        feed.failNextAttach()
        let output = try SpeakOutput(profile: profile, liveIO: false, hooks: feed.hooks)
        _ = try await output.beginSession(config: .init(profile))
        #expect(!output.isFeedAttached && output.lastFailure != nil)
        output.devicesChanged(); await output.flushForTesting()
        #expect(output.isFeedAttached && output.lastFailure == nil)
        await output.endSession()
        output.devicesChanged(); await output.flushForTesting()
        #expect(!output.isFeedAttached && feed.attachCount == 2)
        await output.close()
    }

    @Test func nextSessionDropsOldAudioPauseAndLateInterruptions() async throws {
        let feed = OutputFeed(), profile = try outputProfile()
        let output = try SpeakOutput(profile: profile, liveIO: false, hooks: feed.hooks)
        let first = try await output.beginSession(config: .init(profile))
        first.requestYield(at: 0)
        let samples = [Float](repeating: 0.3, count: 960)
        _ = samples.withUnsafeBufferPointer { output.ringO.writeClause($0, frames: $0.count, marks: [.start, .end], tag: 1) }
        await output.endSession()
        #expect(output.ringO.availableFrames == 0)
        #expect(!tt_ring_pause_requested(output.ringO.raw))
        let second = try await output.beginSession(config: .init(profile))
        #expect(first !== second)
        let generation = output.restartGeneration
        feed.interrupt(0, .serviceRestarted)
        await output.flushForTesting()
        #expect(output.restartGeneration == generation && output.isFeedAttached)
        await output.close()
    }

    @Test func restartDefersWhileSuspendedAndKeepsSessionQueue() async throws {
        let feed = OutputFeed(), profile = try outputProfile()
        let output = try SpeakOutput(profile: profile, liveIO: false, hooks: feed.hooks)
        _ = try await output.beginSession(config: .init(profile))
        await output.suspend()
        output.audioServiceRestarted(observedAt: HostClock.now())
        await output.flushForTesting()
        #expect(output.restartGeneration == 0 && !output.isFeedAttached)
        await output.resume()
        #expect(output.restartGeneration == 1 && output.isFeedAttached)
        await #expect(throws: SpeakOutput.Failure.self) { try await output.beginSession(config: .init(profile)) }
        // Same underlying restart, observed before recovery, cannot reset the resumed queue again.
        output.audioServiceRestarted(observedAt: 1)
        await output.flushForTesting()
        #expect(output.restartGeneration == 1)
        await output.close()
    }

    @Test func oldFeedRestartIsIgnoredAfterAnotherSourceRecovers() async throws {
        let feed = OutputFeed(), profile = try outputProfile()
        let output = try SpeakOutput(profile: profile, liveIO: false, hooks: feed.hooks)
        _ = try await output.beginSession(config: .init(profile))
        output.audioServiceRestarted()
        await output.flushForTesting()
        #expect(output.restartGeneration == 1 && feed.attachCount == 2)
        feed.interrupt(0, .serviceRestarted)
        await output.flushForTesting()
        #expect(output.restartGeneration == 1 && output.isFeedAttached)
        await output.close()
    }

    @Test func passthroughArrivalLogUsesCaptureTime() async throws {
        let feed = OutputFeed(), profile = try outputProfile(), log = EventLog(inMemory: { 0 })
        let output = try SpeakOutput(profile: profile, log: log, liveIO: false, hooks: feed.hooks)
        #expect(tt_event_push4(output.events.raw, UInt16(TT_EV_PT_FIRST_SAMPLE), UInt16(TT_EV_SRC_FEED),
                               HostClock.machTicks(fromNanos: 75_000_000), 7, HostClock.machTicks(fromNanos: 50_000_000)))
        await output.pumpForTesting()
        let row = try #require(log.recorded.first)
        #expect(row["ev"] as? String == "pt.first_sample")
        #expect(row["latMs"] as? Int == 25)
        #expect(row["generation"] as? Int == 7)
        await output.close()
    }
}
