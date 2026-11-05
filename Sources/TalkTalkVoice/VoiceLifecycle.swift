import Foundation
import TalkTalkCore
import TalkTalkEngineHost

/// Everything the app does with "my voice" outside one recording (§9.2–§9.4), in one place, so the
/// settings page (talktalk-listen), the SPEAK pipeline and the diagnostics page share one state:
/// - at init: SPEAK is routed by the saved profile (profile → "pending" until the voice is loaded,
///   none → system voice; §16 decision 5 then keeps a press silent rather than switching voice);
/// - `voiceReady()`: on every READY, align the engine's voice and SPEAK with the profile
///   (`VoiceSync.align`: rebuild stale conditioning, pending audition, load, route);
/// - `transcriptRecheck()`: when health reports ASR ready, re-check a `pending` transcript row
///   with Qwen3-ASR (skipped without an ASR role);
/// - `makeEnrollment()`: an `EnrollmentController` sharing this queue, monitor, routing, gains;
/// - `delete()`: §9.4 (only our files, `/v1/voice/unload` last, SPEAK → "系统声音", gains cleared);
/// - `audition()` / `play(_:)`: the 试听 buttons of the saved profile.
/// Every operation on the voice slot or profile.json goes through `queue`, one at a time.
@MainActor
public final class VoiceLifecycle {
    public let store: VoiceStore
    public let engine: (any VoiceEngineServices)?
    public let monitor: any AuditionMonitor
    public let routing: SpeakVoiceRouting
    public let passthroughGains: any PassthroughGainStore
    public let queue: VoiceSlotQueue
    /// The saved profile's last audition (in memory only).
    public private(set) var savedAudition: AuditionResult?
    /// The engine-status follower started by the `engineProcess` init (ends with the lifecycle).
    private var follower: Task<Void, Never>?
    /// How long `follow` waits for ASR after a READY before giving up on the transcript re-check.
    public var asrWait: Duration = .seconds(180)

    public init(store: VoiceStore = .product, engine: (any VoiceEngineServices)?, monitor: any AuditionMonitor,
                routing: SpeakVoiceRouting, passthroughGains: any PassthroughGainStore,
                queue: VoiceSlotQueue = VoiceSlotQueue()) {
        self.store = store
        self.engine = engine
        self.monitor = monitor
        self.routing = routing
        self.passthroughGains = passthroughGains
        self.queue = queue
        routeAtLaunch()
    }

    /// The production wiring over an engine process (nil = no engine installed).
    public convenience init(store: VoiceStore = .product, engineProcess: EngineProcess?, monitor: any AuditionMonitor,
                            routing: SpeakVoiceRouting, passthroughGains: any PassthroughGainStore) {
        self.init(store: store, engine: engineProcess.map { EngineVoiceServices(backend: RemoteQwenVoiceBackend(engine: $0)) },
                  monitor: monitor, routing: routing, passthroughGains: passthroughGains)
        if let engineProcess {
            follower = follow(engineReady: Self.readyStream(engineProcess))
        }
    }

    /// `EngineProcess.statusUpdates()` as "READY or not".
    nonisolated static func readyStream(_ e: EngineProcess) -> AsyncStream<Bool> {
        AsyncStream { cont in
            let t = Task {
                for await s in await e.statusUpdates() {
                    if case .ready = s { cont.yield(true) } else { cont.yield(false) }
                }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    /// Follows the engine (second review, item 1): every time it is not READY (idle exit, crash,
    /// restart, starting) SPEAK goes to "pending" at once if there is a profile — a clause must not
    /// reach `/v1/tts` before the voice is loaded again. Every READY runs `voiceReady()`, then the
    /// transcript re-check once ASR is ready (polled, up to `asrWait`).
    public func follow(engineReady updates: AsyncStream<Bool>) -> Task<Void, Never> {
        Task { [weak self] in
            var readyWork: Task<Void, Never>?
            for await ready in updates {
                guard let self else { return }
                readyWork?.cancel()
                readyWork = nil
                if !ready {
                    if self.store.hasProfile, self.engine != nil { self.routing.useMyVoicePending() }
                    continue
                }
                readyWork = Task { [weak self] in
                    guard let self else { return }
                    await self.voiceReady()
                    await self.recheckWhenASRReady()
                }
            }
            readyWork?.cancel()
        }
    }

    private func recheckWhenASRReady() async {
        guard let engine, (try? store.loadProfile())?.checks.status[CheckID.transcript.rawValue] == .pending else { return }
        let end = ContinuousClock.now + asrWait
        while !Task.isCancelled, ContinuousClock.now < end {
            switch await engine.readiness().asr {
            case .ready:
                await transcriptRecheck()
                return
            case .absent:
                return
            case .loading:
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Before the engine is READY: a saved profile means "my voice, pending"; no profile (or no
    /// engine installed to ever load one) means the system voice.
    public func routeAtLaunch() {
        if store.hasProfile, engine != nil { routing.useMyVoicePending() } else { routing.useSystemVoice() }
    }

    public func makeEnrollment() -> EnrollmentController {
        EnrollmentController(store: store, engine: engine, monitor: monitor, routing: routing,
                             passthroughGains: passthroughGains, queue: queue)
    }

    /// §9.4. SPEAK switches first; queued and running voice operations are cancelled, then the
    /// deletion runs after them, so the unload is the last thing the engine hears.
    @discardableResult
    public func delete() async -> VoiceDeletion.Outcome {
        savedAudition = nil
        routing.useSystemVoice()
        // Cancel and queue the deletion in one step, before any await, so nothing submitted
        // meanwhile can route SPEAK back to the voice being deleted (second review, item 5).
        let d = VoiceDeletion(store: store, engine: engine, routing: routing, passthroughGains: passthroughGains)
        let deletion = queue.cancelAllThenRun { await d.run() }
        await monitor.stop()
        return await deletion.value
    }

    /// Call on every engine READY (and after a restart). See `VoiceSync.align`.
    @discardableResult
    public func voiceReady() async -> VoiceSync.Outcome {
        guard let engine else {
            routeAtLaunch()
            return VoiceSync.Outcome()
        }
        let store = self.store, routing = self.routing
        let out = try? await queue.run {
            await VoiceSync.align(store: store, engine: engine, routing: routing) { a in
                await MainActor.run { self.savedAudition = a }
            }
        }
        return out ?? VoiceSync.Outcome()
    }

    /// Call when `/v1/health` reports `models.asr.state == ready`. Without an ASR role, or before
    /// ASR is ready, nothing happens (the row stays `pending`).
    @discardableResult
    public func transcriptRecheck() async -> TranscriptRecheck.Outcome {
        guard let engine, await engine.readiness().asr == .ready, let asr = engine.transcriber else { return .unavailable }
        let store = self.store
        return (try? await queue.run { await TranscriptRecheck.run(store: store, transcriber: asr) }) ?? .unavailable
    }

    /// Generates the audition of the saved profile (the settings page's 试听 buttons,
    /// `--self-test --voice`). Uses only conditioning current for the running engine; stale or
    /// missing conditioning is rebuilt first (`VoiceSync.align`).
    public func audition() async throws -> AuditionResult {
        guard let engine else { throw AuditionMonitorError.unavailable("引擎尚未就绪") }
        let store = self.store, routing = self.routing
        let a = try await queue.run { () async throws -> AuditionResult in
            var p = try store.loadProfile()
            var blobs = try await engine.currentConditioning(p, store: store)
            if blobs.isEmpty {
                _ = await VoiceSync.align(store: store, engine: engine, routing: routing)
                p = try store.loadProfile()
                blobs = try await engine.currentConditioning(p, store: store)
                guard !blobs.isEmpty else { throw VoiceEngineError.noConditioning(p.modesByLang[.en] ?? .icl) }
            }
            let wav = try Data(contentsOf: store.voiceURL.appendingPathComponent(VoiceStore.referenceName))
            let a = try await engine.audition(conditioning: blobs, modes: p.modesByLang, profileID: p.id, referenceWAV: wav)
            try store.checkStill(p.identity)
            return a
        }
        savedAudition = a
        return a
    }

    public func play(_ lang: Lang) async throws {
        guard let clip = savedAudition?.clip(lang), !clip.samples.isEmpty else { return }
        try await monitor.play(clip.samples)
    }
}
