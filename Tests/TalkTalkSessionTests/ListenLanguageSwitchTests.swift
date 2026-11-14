import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkSession

private actor SwitchASR: StreamingASREngine {
    nonisolated let id = EngineID(name: "switch-asr", revision: "1", placement: .cpu)
    private(set) var opened: [(Lang, FakeStream)] = []
    private var blockNext = false
    private var pending: CheckedContinuation<Void, Never>?
    func blockNextOpen() { blockNext = true }
    func unblock() { pending?.resume(); pending = nil }
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        let stream = FakeStream(); opened.append((lang, stream))
        if blockNext {
            blockNext = false
            await withCheckedContinuation { pending = $0 }
        }
        return stream
    }
}

/// The old direction stays in flight until the switch cancels it; later requests finish normally.
private actor HeldSwitchMT: MTEngine {
    nonisolated let id = EngineID(name: "held-switch-apple", revision: "1", placement: .systemService)
    private(set) var requests: [MTRequest] = []
    private(set) var cancels: [JobID] = []
    private var held: [JobID: CheckedContinuation<Void, Error>] = [:]
    var hasHeldRequest: Bool { !held.isEmpty }

    func translate(_ request: MTRequest) async throws -> MTResult {
        try Task.checkCancellation()
        requests.append(request)
        if requests.count == 1 {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled || cancels.contains(request.job) {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        held[request.job] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel(request.job) }
            }
        }
        try Task.checkCancellation()
        let now = HostClock.now()
        return MTResult(text: "translated:\(request.text)", tokens: 1, reasoningTokens: 0, engine: id,
                        hedge: .init(fired: false, winner: .apple, reason: nil, ms: 0),
                        timing: .init(received: now, started: now, firstOutput: now, finished: now))
    }

    func cancel(_ job: JobID) {
        cancels.append(job)
        held.removeValue(forKey: job)?.resume(throwing: CancellationError())
    }

    func releaseHeldRequest() {
        let pending = held
        held.removeAll()
        for continuation in pending.values { continuation.resume() }
    }

    func setContext(_ session: MTSession, glossary: [GlossaryEntry]) async throws {}
}

@MainActor private final class SwitchUI {
    var updates: [SubtitleUpdate] = []
    var resets = 0
    var transcripts: [(String, String)] = []
    var prepared: [Direction] = []
    var finals: [String] { updates.compactMap { if case let .final(_, text, _, _, _) = $0 { text } else { nil } } }
    func reset() { updates.removeAll(); resets += 1 }
}

@MainActor @Suite struct ListenLanguageSwitchTests {
    private func make(_ asr: SwitchASR, apple: (any MTEngine)? = nil, events: MeetingEvents = MeetingEvents(),
                      ui: SwitchUI) throws -> MeetingSession {
        let profile = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        return MeetingSession(profile: profile, makeEngines: { direction, _, _ in
            await MainActor.run { ui.prepared.append(direction) }
            return .init(asr: asr, apple: apple, primary: nil)
        }, events: events, onTranscript: { source, target, _ in ui.transcripts.append((source, target)) },
        onListenReset: { ui.reset() }, onSubtitle: { ui.updates.append($0) })
    }

    @Test func languageSwitchKeepsMeetingAndReplaysOpeningAudio() async throws {
        let asr = SwitchASR(), ui = SwitchUI(), events = MeetingEvents()
        let apple = HeldSwitchMT()
        defer { Task { await apple.releaseHeldRequest() } }
        let session = try make(asr, apple: apple, events: events, ui: ui)
        var lifecycleEvents = 0
        let subscription = events.subscribe { if $0.isLifecycle { lifecycleEvents += 1 } }
        try await session.startListenForTesting(lang: .en)
        let old = await asr.opened[0].1
        old.final("Old English final.")
        try #require(await until { @Sendable in await apple.hasHeldRequest })
        await asr.blockNextOpen()
        let switching = Task { try await session.switchListenLanguage(to: .de) }
        let replacementOpened = await until { @Sendable in await asr.opened.count == 2 }
        #expect(replacementOpened)
        session.feedListenForTesting(Array(repeating: 0, count: 320), at: HostClock.now())
        let new = await asr.opened[1].1
        #expect(new.fed == 0)
        await asr.unblock(); try await switching.value
        #expect(new.fed == 320)
        #expect(session.listenLanguage == .de)
        #expect(session.state == .running(app: "Test meeting"))
        #expect(lifecycleEvents == 0)
        #expect(!(await apple.cancels).isEmpty)
        new.final("Neue deutsche Wörter.")
        #expect(await until { @Sendable in await MainActor.run { ui.finals.count == 1 } })
        #expect(ui.finals[0].contains("Neue deutsche Wörter"))
        #expect(!ui.transcripts.contains { $0.0.contains("Old English") })
        await session.stop(); _ = subscription
    }

    @Test func targetOnlySwitchCancelsOldTranslationAndPreparesTheWholeDirection() async throws {
        let asr = SwitchASR(), ui = SwitchUI()
        let apple = HeldSwitchMT()
        defer { Task { await apple.releaseHeldRequest() } }
        let session = try make(asr, apple: apple, ui: ui)
        try await session.startListenForTesting(lang: .en)
        let old = await asr.opened[0].1
        old.final("Old English sentence.")
        try #require(await until { @Sendable in await apple.hasHeldRequest })
        try await session.switchListenDirection(source: .en, target: .fr)
        #expect(session.listenLanguage == .en && session.listenTarget == .fr)
        #expect(ui.prepared == [.init(source: .en, target: .zh), .init(source: .en, target: .fr)])
        #expect(!(await apple.cancels).isEmpty)
        let fresh = await asr.opened[1].1
        fresh.final("New English sentence.")
        #expect(await until { @Sendable in await MainActor.run { ui.finals.count == 1 } })
        #expect(await apple.requests.last?.session == .listenEnFr)
        #expect(ui.transcripts.allSatisfy { !$0.0.contains("Old English") })
        await #expect(throws: MeetingSession.ListenConfigurationError.self) {
            try await session.switchListenDirection(source: .en, target: .en)
        }
        #expect(session.listenLanguage == .en && session.listenTarget == .fr)
        await session.stop()
        #expect(session.listenLanguage == nil && session.listenTarget == nil)
    }

    @Test func cancelledSelectionCannotChangeThePairOrResetSubtitles() async throws {
        let asr = SwitchASR(), ui = SwitchUI(), session = try make(asr, ui: ui)
        try await session.startListenForTesting(lang: .en, target: .zh)
        let configuration = session.listenConfigurationID, resets = ui.resets
        // This main-actor task cannot start until the current turn yields below.
        let stale = Task { try await session.switchListenDirection(source: .zh, target: .de) }
        stale.cancel()
        await #expect(throws: CancellationError.self) { try await stale.value }
        #expect(session.listenLanguage == .en && session.listenTarget == .zh)
        #expect(session.listenConfigurationID == configuration && ui.resets == resets)
        #expect(ui.prepared == [.init(source: .en, target: .zh)])
        await session.stop()
    }

    @Test func targetChangedDuringStartAndSuspensionUsesLatestPair() async throws {
        let asr = SwitchASR(), ui = SwitchUI(), session = try make(asr, ui: ui)
        await asr.blockNextOpen()
        let starting = Task { try await session.startListenForTesting(lang: .zh, target: .en) }
        #expect(await until { @Sendable in await asr.opened.count == 1 })
        try await session.switchListenDirection(source: .zh, target: .de)
        await asr.unblock(); try await starting.value
        #expect(session.listenLanguage == .zh && session.listenTarget == .de)
        #expect(ui.prepared.last == .init(source: .zh, target: .de))
        session.suspendListenForTesting()
        try await session.switchListenDirection(source: .de, target: .en)
        #expect(session.listenLanguage == nil && session.listenTarget == nil)
        try await session.resumeListenForTesting()
        #expect(session.listenLanguage == .de && session.listenTarget == .en)
        #expect(ui.prepared.last == .init(source: .de, target: .en))
        // The legacy source-only entry point keeps this session's chosen subtitle target.
        try await session.switchListenLanguage(to: .zh)
        #expect(session.listenLanguage == .zh && session.listenTarget == .en)
        await session.stop()
    }

    @Test func rapidSwitchLastSelectionWinsAndStopCannotResurrectIt() async throws {
        let asr = SwitchASR(), ui = SwitchUI(), session = try make(asr, ui: ui)
        try await session.startListenForTesting(lang: .en)
        await asr.blockNextOpen()
        let german = Task { try await session.switchListenLanguage(to: .de) }
        let germanOpened = await until { @Sendable in await asr.opened.count == 2 }
        #expect(germanOpened)
        let english = Task { try await session.switchListenLanguage(to: .en) }
        await asr.unblock()
        _ = await german.result; try await english.value
        #expect(session.listenLanguage == .en)
        #expect(await asr.opened.map { $0.0 } == [.en, .de, .en])
        await asr.blockNextOpen()
        let pending = Task { try await session.switchListenLanguage(to: .de) }
        let pendingOpened = await until { @Sendable in await asr.opened.count == 4 }
        #expect(pendingOpened)
        let stopping = Task { await session.stop() }
        await Task.yield(); await asr.unblock()
        _ = await pending.result; await stopping.value
        #expect(session.state == .idle && session.listenLanguage == nil)
    }

    @Test func suspendedChoiceAndSameLanguageEngineChangeRebuildOnResume() async throws {
        let asr = SwitchASR(), ui = SwitchUI(), session = try make(asr, ui: ui)
        try await session.startListenForTesting(lang: .en)
        session.suspendListenForTesting()
        try await session.switchListenLanguage(to: .de)
        #expect(await asr.opened.count == 1)
        #expect(session.listenLanguage == nil)
        try await session.resumeListenForTesting()
        #expect(session.listenLanguage == .de)
        let configuration = session.listenConfigurationID
        try await session.switchListenLanguage(to: .de, forceRebuild: true)
        #expect(session.listenConfigurationID > configuration)
        #expect(await asr.opened.map { $0.0 } == [.en, .de, .de])
        await session.stop()
    }

    @Test func selectionDuringInitialOpenUsesLatestLanguage() async throws {
        let asr = SwitchASR(), ui = SwitchUI(), session = try make(asr, ui: ui)
        await asr.blockNextOpen()
        let starting = Task { try await session.startListenForTesting(lang: .en) }
        let initialOpened = await until { @Sendable in await asr.opened.count == 1 }
        #expect(initialOpened)
        try await session.switchListenLanguage(to: .de)
        await asr.unblock(); try await starting.value
        #expect(session.listenLanguage == .de)
        #expect(await asr.opened.map { $0.0 } == [.en, .de])
        await session.stop()
    }
}
