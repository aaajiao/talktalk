import Foundation
import TalkTalkCloud
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkSession

/// Reads the saved glossary at request time, so editing terms does not require a new meeting.
struct GlossaryMT: MTEngine {
    let base: any MTEngine
    var id: EngineID { base.id }
    func translate(_ request: MTRequest) async throws -> MTResult {
        try await base.setContext(request.session, glossary: AppGlossary.store.snapshot(target: request.session.direction.target))
        return try await base.translate(request)
    }
    func setContext(_ session: MTSession, glossary: [GlossaryEntry]) async throws {
        try await base.setContext(session, glossary: glossary)
    }
    func cancel(_ job: JobID) async { await base.cancel(job) }
}

/// The meeting's shared OpenAI backend (ARCHITECTURE.md, "引擎、翻译与播放"). LISTEN and SPEAK
/// share the breaker and A/B connections, while each direction keeps its own cloud switch.
/// `make` still returns LISTEN's primary; `Box.speak` exposes SPEAK's backend to its controller.
/// Its lifecycle follows MeetingEvents: keep-warm while the meeting runs, NetworkHealth changes
/// forwarded (offline → Apple at once, back online → OpenAI), `didWake` after sleep.
/// The key is read by OpenAIMT's own key provider only, once per meeting; nothing here touches it.
@MainActor
final class ListenCloud {
    /// Shared with the engine factory (off the main actor) and keep-warm's `isEnabled`.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _mt: OpenAIMT?
        private var _sessionLog: EventLog?
        private var _listenEnabled = false
        private var _active = false
        private var _speakEnabled = false
        /// B is used for the whole meeting (SPEAK or LISTEN hedging).
        private var _warmBAlways = false
        /// B is used only by LISTEN's opening double-send, so it can go cold afterwards.
        private var _warmBForOpening = false
        var mt: OpenAIMT? { lock.withLock { _mt } }
        var speak: OpenAIMT? { lock.withLock { _speakEnabled ? _mt : nil } }
        var warmB: Bool {
            lock.withLock { _warmBAlways || (_warmBForOpening && _mt?.listenOpeningIsOver == false) }
        }
        var active: Bool { lock.withLock { _active } }
        func set(_ mt: OpenAIMT?, speakEnabled: Bool = false) {
            lock.withLock {
                _mt = mt; _speakEnabled = speakEnabled; _warmBAlways = false; _warmBForOpening = false
                if mt == nil { _sessionLog = nil; _listenEnabled = false }
            }
        }
        func setActive(_ on: Bool) { lock.withLock { _active = on } }

        /// A rebuilt LISTEN pipeline keeps the same meeting log. Reuse its backend, including
        /// the nil/disabled choice, so SPEAK, breaker state and warm connections stay together.
        func make(log: EventLog, knownPresence: Bool? = nil, forMeeting: Bool = true) -> OpenAIMT? {
            lock.withLock {
                if _sessionLog === log { return _listenEnabled ? _mt : nil }
                let prefs = TranslationPreferences.load(.standard)
                var mt: OpenAIMT?
                if prefs.cloudConsentGiven, prefs.listenCloudEnabled || prefs.speakCloudEnabled {
                    mt = (try? OpenAIMT.forCurrentApp(model: prefs.model, effort: prefs.effort, log: log,
                                                    knownPresence: knownPresence, forMeeting: forMeeting,
                                                    fastMode: forMeeting && prefs.fastMode)) ?? nil
                }
                let profile = try? PolicyProfile.loadDefault()
                _warmBAlways = prefs.effort == "none" && (
                    (prefs.speakCloudEnabled && profile?.speakHedgePolicy.hedge.enabled == true)
                    || (prefs.listenCloudEnabled && profile?.listenHedgePolicy.hedge.enabled == true))
                _warmBForOpening = prefs.effort == "none" && prefs.listenCloudEnabled
                    && (profile?.listen.finalMT.openingDoubleSendS ?? 0) > 0
                _sessionLog = log; _mt = mt
                _listenEnabled = prefs.listenCloudEnabled; _speakEnabled = prefs.speakCloudEnabled
                return _listenEnabled ? mt : nil
            }
        }
    }

    let box = Box()
    private let network = NetworkHealth()
    private var forward: Task<Void, Never>?
    private var subscription: MeetingSubscription?
    /// NetworkHealth says offline now: the menu says so before the next final falls back.
    private(set) var offline = false
    var onChange: (() -> Void)?

    init(events: MeetingEvents) {
        let box = self.box
        let changes = network.changes
        forward = Task { [weak self] in
            for await c in changes {
                await box.mt?.network(c)
                self?.networkChanged(c)
            }
        }
        subscription = events.subscribe { [weak self] e in self?.handle(e) }
    }

    private func networkChanged(_ c: NetworkHealth.Change) {
        let now = c == .offline ? true : c == .online ? false : offline
        guard now != offline else { return }
        offline = now
        onChange?()
    }

    private func handle(_ e: MeetingEvent) {
        switch e {
        case .started:
            box.setActive(true)
            networkChanged(network.isOnline ? .online : .offline)
            guard let mt = box.mt else { return }
            let box = self.box
            let offline = self.offline
            Task {
                if offline { await mt.network(.offline) }
                await mt.startKeepWarm(isEnabled: { box.active }, warmB: { box.warmB })
            }
        case let .resumed(afterSleep):
            // MeetingLifecycle remembers a sleep even when a lock suspended first.
            if afterSleep, let mt = box.mt { Task { await mt.didWake() } }
        case .ended, .state(.idle):   // a failed start reaches idle without .ended
            box.setActive(false)
            if let mt = box.mt { Task { await mt.endMeeting() } }
            box.set(nil)
        case .suspended, .audioServiceRestarted, .state, .hint, .translation, .stopping:
            break
        }
    }
}
