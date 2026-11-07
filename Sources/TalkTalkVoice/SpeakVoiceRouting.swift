// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import TalkTalkCore

/// Which voice SPEAK speaks with right now (§9.4, C8): "my voice" (the clone engine with a loaded
/// profile) or the system voice. One instance for the app's lifetime, shared by the SPEAK pipeline
/// (reads `engine` per clause), the HUD (`hudLabel`) and the voice lifecycle (switches it), so a
/// deletion takes effect for the very next clause of the same session.
public final class SpeakVoiceRouting: @unchecked Sendable {
    public enum Source: Sendable, Equatable {
        /// The saved profile's voice is loaded in the engine (after `loadVoice` succeeded).
        case myVoice(VoiceHandle, playoutGainDb: Double)
        /// A profile exists but its voice is not usable yet: engine starting, conditioning being
        /// (re)built, load failed. `ClauseLedger.CloneAvailability.down`, so §16 decision 5 applies
        /// (silent by default), never a silent switch to the system voice.
        case myVoicePending
        /// No profile (C8), or no engine installed to ever speak with it.
        case systemVoice
    }

    public static var myVoiceLabel: String { String(appLocalized: "我的声音") }
    public static var pendingLabel: String { String(appLocalized: "我的声音（准备中）") }
    public static var systemVoiceLabel: String { String(appLocalized: "系统声音") }

    public let clone: any TTSEngine
    public let system: any TTSEngine
    private let lock = NSLock()
    private var _source: Source
    /// Bumped every time SPEAK leaves "my voice" (pending or system). A load that started before
    /// that may only switch to "my voice" if no one invalidated meanwhile (`useMyVoice(ifEpoch:)`).
    private var _epoch: UInt64 = 0
    private var observers: [UUID: @Sendable (Source) -> Void] = [:]

    public init(clone: any TTSEngine, system: any TTSEngine, source: Source = .systemVoice) {
        self.clone = clone
        self.system = system
        self._source = source
    }

    public var source: Source { lock.withLock { _source } }

    /// The engine the next clause goes to when it is spoken at all (pending: the ledger decides,
    /// and its system-voice fallback goes to `system`).
    public var engine: any TTSEngine {
        if case .myVoice = source { return clone }
        return system
    }

    /// The handle for `TTSRequest.voice`, nil on the system voice.
    public var voice: VoiceHandle? {
        if case let .myVoice(h, _) = source { return h }
        return nil
    }

    /// PlayoutStage fixed gain for the current voice: the enrollment calibration for "my voice",
    /// 0 dB for the system voice (not calibrated).
    public var playoutGainDb: Double {
        if case let .myVoice(_, g) = source { return g }
        return 0
    }

    public var hudLabel: String {
        switch source {
        case .myVoice: Self.myVoiceLabel
        case .myVoicePending: Self.pendingLabel
        case .systemVoice: Self.systemVoiceLabel
        }
    }

    /// What the SPEAK ledger gets per clause (`ClauseLedger.requestTTS(clone:)`).
    public var cloneAvailability: ClauseLedger.CloneAvailability {
        switch source {
        case let .myVoice(h, _): .ready(h)
        case .myVoicePending: .down
        case .systemVoice: .noProfile
        }
    }

    public func useMyVoice(_ handle: VoiceHandle, playoutGainDb: Double) {
        set(.myVoice(handle, playoutGainDb: playoutGainDb))
    }

    /// Switches to "my voice" only if nothing went pending / system since `epoch` was taken (the
    /// engine-status follower may have marked the engine down while the load was in flight).
    /// Returns whether it switched.
    @discardableResult
    public func useMyVoice(_ handle: VoiceHandle, playoutGainDb: Double, ifEpoch epoch: UInt64) -> Bool {
        set(.myVoice(handle, playoutGainDb: playoutGainDb), ifEpoch: epoch) != nil
    }

    public func useSystemVoice() {
        set(.systemVoice)
    }

    public func useMyVoicePending() {
        set(.myVoicePending)
    }

    /// Goes to "pending" and returns the epoch a later `useMyVoice(ifEpoch:)` must match.
    public func markPending() -> UInt64 {
        set(.myVoicePending) ?? 0   // never nil without ifEpoch
    }

    public var epoch: UInt64 { lock.withLock { _epoch } }

    /// Called on every change (from the thread that made it). Keep the token; dropping it does
    /// not unsubscribe, `removeObserver` does.
    @discardableResult
    public func observe(_ body: @escaping @Sendable (Source) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = body }
        return id
    }

    public func removeObserver(_ id: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }

    /// Applies `s` (unless `ifEpoch` no longer matches: nil) and returns the epoch after it, read
    /// under the same lock.
    @discardableResult
    private func set(_ s: Source, ifEpoch: UInt64? = nil) -> UInt64? {
        let (epoch, changed, obs): (UInt64?, Bool, [@Sendable (Source) -> Void]) = lock.withLock {
            if let e = ifEpoch, e != _epoch { return (nil, false, []) }
            let c = _source != s
            _source = s
            if case .myVoice = s {} else { _epoch &+= 1 }
            return (_epoch, c, Array(observers.values))
        }
        if changed { obs.forEach { $0(s) } }
        return epoch
    }
}

/// §9.4 deletion: only our own files, `/v1/voice/unload`, SPEAK → system voice ("系统声音" in the
/// HUD), passthrough gains cleared. Each step runs even if an earlier one could not (an engine
/// that is not running has no voice to unload).
public struct VoiceDeletion: Sendable {
    public let store: VoiceStore
    public let engine: (any VoiceEngineServices)?
    public let routing: SpeakVoiceRouting
    public let passthroughGains: any PassthroughGainStore

    public init(store: VoiceStore, engine: (any VoiceEngineServices)?, routing: SpeakVoiceRouting,
                passthroughGains: any PassthroughGainStore) {
        self.store = store
        self.engine = engine
        self.routing = routing
        self.passthroughGains = passthroughGains
    }

    public struct Outcome: Sendable, Equatable {
        public var filesRemoved: Bool
        public var engineUnloaded: Bool
    }

    @discardableResult
    public func run() async -> Outcome {
        // The route first: a clause that starts while the files go already uses the system voice.
        routing.useSystemVoice()
        store.deleteProfile()
        passthroughGains.removeAll()
        let unloaded = await engine?.unloadVoice() ?? false
        return Outcome(filesRemoved: !store.hasProfile, engineUnloaded: unloaded)
    }
}
