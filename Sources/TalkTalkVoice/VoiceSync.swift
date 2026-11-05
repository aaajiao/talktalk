import Foundation
import TalkTalkCore

/// Brings the engine's voice slot and SPEAK's route in line with `voice/profile.json` (§9.2
/// 实现补充, §9.3). Used after READY (`VoiceLifecycle.voiceReady`), after a save
/// (`EnrollmentController`), and to put the saved voice back after an audition. Runs inside
/// `VoiceSlotQueue`; every write is guarded by the profile identity it started from.
///
/// 1. No profile → system voice (C8).
/// 2. Conditioning that is stale for the running engine (other runtime, mlx-audio, model or
///    revision) or missing counts as missing: SPEAK goes to "pending", the conditioning is rebuilt,
///    old blob files go, `conditioning_keys` is rewritten, the audition goes back to
///    `pending_engine` and the playout gain is cleared (it belongs to the old audition).
/// 3. `audition == pending_engine` → run it, store the result and the playout gain. An engine
///    error leaves it pending (retried at the next READY).
/// 4. SPEAK goes to "pending" *before* every `loadVoice` (after an engine restart the slot is
///    empty; a clause sent before the load would get `voice_absent`), and to "my voice" only after
///    the load succeeded. A load that fails leaves it "pending".
public enum VoiceSync {
    public struct Outcome: Sendable, Equatable {
        public var conditioningBuilt = false
        public var auditionChecked = false
        public var routed: SpeakVoiceRouting.Source?

        public init() {}
    }

    public static func align(store: VoiceStore, engine: any VoiceEngineServices, routing: SpeakVoiceRouting?,
                             onAudition: (@Sendable (AuditionResult) async -> Void)? = nil) async -> Outcome {
        var out = Outcome()
        guard let saved = try? store.loadProfile() else {
            routing?.useSystemVoice()
            out.routed = .systemVoice
            return out
        }
        let ident = saved.identity
        var p = saved
        do {
            var blobs = try await engine.currentConditioning(p, store: store)
            if blobs.isEmpty {
                routing?.useMyVoicePending()
                blobs = try await build(p, store: store, engine: engine)
                try Task.checkCancellation()
                try store.replaceSavedConditioning(blobs, expecting: ident)
                p.conditioningEntries = blobs.map { .init(key: $0.key, model: $0.model, mode: $0.mode) }
                p.conditioning = "built"
                p.audition = "pending_engine"
                p.auditionResult = nil
                p.playoutGainDb = nil
                p.checks.status[CheckID.audition.rawValue] = .pending
                try store.replaceProfile(p, expecting: ident)
                out.conditioningBuilt = true
            }
            if p.audition == "pending_engine" {
                do {
                    let wav = try Data(contentsOf: store.voiceURL.appendingPathComponent(VoiceStore.referenceName))
                    let a = try await engine.audition(conditioning: blobs, modes: p.modesByLang, profileID: p.id, referenceWAV: wav)
                    try Task.checkCancellation()
                    apply(a, to: &p)
                    try store.replaceProfile(p, expecting: ident)
                    out.auditionChecked = true
                    await onAudition?(a)
                } catch let e as VoiceStore.Failure where e == .profileChanged {
                    throw e
                } catch where isDeliberateCancel(error) {
                    throw error
                } catch {
                    // Engine trouble during the audition: it stays pending_engine; the voice is still usable.
                }
            }
            try Task.checkCancellation()
            try store.checkStill(ident)
            let epoch = routing?.markPending()
            try await engine.loadVoice(blobs, mode: p.modesByLang[.en] ?? .icl, profileID: p.id)
            try Task.checkCancellation()
            try store.checkStill(ident)
            guard let h = handle(p) else { throw VoiceEngineError.noConditioning(p.modesByLang[.en] ?? .icl) }
            let src = SpeakVoiceRouting.Source.myVoice(h, playoutGainDb: p.playoutGainDb ?? 0)
            if let routing, let epoch {
                // The engine may have gone down while the load ran (follower marked pending).
                out.routed = routing.useMyVoice(h, playoutGainDb: p.playoutGainDb ?? 0, ifEpoch: epoch) ? src : routing.source
            } else {
                out.routed = src
            }
        } catch where isDeliberateCancel(error) {
            // Cancelled by the caller or by a deletion: whoever cancelled sets the route.
        } catch let e as VoiceStore.Failure where e == .profileChanged {
            // Re-recorded or deleted meanwhile: whoever changed it routes.
        } catch {
            routing?.useMyVoicePending()
            out.routed = .myVoicePending
        }
        return out
    }

    /// The engine holds one voice: put the saved profile's back if its conditioning is current
    /// (no rebuild here), else unload. Routes accordingly when `routing` is given.
    public static func restore(store: VoiceStore, engine: any VoiceEngineServices, routing: SpeakVoiceRouting?) async {
        guard let p = try? store.loadProfile() else {
            _ = await engine.unloadVoice()
            routing?.useSystemVoice()
            return
        }
        guard let blobs = try? await engine.currentConditioning(p, store: store), !blobs.isEmpty else {
            _ = await engine.unloadVoice()
            routing?.useMyVoicePending()
            return
        }
        do {
            let epoch = routing?.markPending()
            try await engine.loadVoice(blobs, mode: p.modesByLang[.en] ?? .icl, profileID: p.id)
            try store.checkStill(p.identity)
            if let h = handle(p), let epoch { routing?.useMyVoice(h, playoutGainDb: p.playoutGainDb ?? 0, ifEpoch: epoch) }
        } catch {
            routing?.useMyVoicePending()
        }
    }

    /// SPEAK is already on the saved profile's voice (so the engine holds it: `restore` ran after
    /// the audition and nothing has marked the engine down since). Then a restore is redundant.
    public static func alreadyRestored(store: VoiceStore, routing: SpeakVoiceRouting?) -> Bool {
        guard let routing, case let .myVoice(h, _) = routing.source, let p = try? store.loadProfile(),
              let saved = handle(p) else { return false }
        return h.conditioningKey == saved.conditioningKey && h.profileID == saved.profileID
    }

    static func build(_ p: VoiceProfile, store: VoiceStore, engine: any VoiceEngineServices) async throws -> [ConditioningBlob] {
        let wav = try Data(contentsOf: store.voiceURL.appendingPathComponent(VoiceStore.referenceName))
        let script = try String(contentsOf: store.voiceURL.appendingPathComponent(VoiceStore.scriptName), encoding: .utf8)
        return try await engine.buildConditioning(referenceWAV: wav, scriptText: script, modes: p.cloneModes)
    }

    static func apply(_ a: AuditionResult, to p: inout VoiceProfile) {
        p.audition = a.passed ? "passed" : "failed"
        p.auditionResult = a.summary
        p.playoutGainDb = a.playoutGainDb
        p.checks.status[CheckID.audition.rawValue] = a.passed ? .pass : .reject
    }

    static func handle(_ p: VoiceProfile) -> VoiceHandle? {
        guard let id = UUID(uuidString: p.id), let e = p.speakEntry else { return nil }
        return VoiceHandle(profileID: id, conditioningKey: e.key, mode: e.mode,
                           model: EngineID(name: e.model, revision: "", placement: .engineGPU))
    }
}
