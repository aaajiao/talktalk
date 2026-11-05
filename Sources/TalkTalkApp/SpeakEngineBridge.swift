import Foundation
import Synchronization
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkVoice

/// App-owned adapters keep concrete engine/voice types out of TalkTalkSession. Installation
/// changes replace this snapshot, so neither the pipeline nor reporter retain old voice routing.
final class SpeakEngineBridge: SpeakEngineControl, @unchecked Sendable {
    private struct State {
        var process: EngineProcess?
        var routing: SpeakVoiceRouting
        var observer: UUID?
        var subscribers: [UUID: AsyncStream<SpeakEngineStatus>.Continuation] = [:]
    }
    private let storage: Mutex<State>
    init(routing: SpeakVoiceRouting) { storage = Mutex(State(routing: routing)); update(nil, routing: routing) }
    deinit {
        let (routing, observer, subscribers) = storage.withLock { ($0.routing, $0.observer, Array($0.subscribers.values)) }
        if let observer { routing.removeObserver(observer) }
        subscribers.forEach { $0.finish() }
    }

    func update(_ process: EngineProcess?, routing: SpeakVoiceRouting) {
        let old = storage.withLock { state -> (SpeakVoiceRouting, UUID?) in
            let old = (state.routing, state.observer)
            state.process = process; state.routing = routing; state.observer = nil
            return old
        }
        if let id = old.1 { old.0.removeObserver(id) }
        let id = routing.observe { [weak self] _ in self?.publish() }
        storage.withLock { $0.observer = id }
        publish()
    }

    var process: EngineProcess? { storage.withLock { $0.process } }
    var routing: SpeakVoiceRouting { storage.withLock { $0.routing } }
    private var currentStatus: SpeakEngineStatus {
        if case .myVoicePending = routing.source { return .lost }
        return .ready
    }
    private func publish() {
        let value = currentStatus
        let subscribers = storage.withLock { Array($0.subscribers.values) }
        subscribers.forEach { $0.yield(value) }
    }
    var status: AsyncStream<SpeakEngineStatus> {
        AsyncStream { [weak self] continuation in
            guard let self else { continuation.finish(); return }
            let id = UUID()
            storage.withLock { $0.subscribers[id] = continuation }
            continuation.yield(currentStatus)
            continuation.onTermination = { [weak self] _ in
                self?.storage.withLock { $0.subscribers[id] = nil }
            }
        }
    }

    func snapshot() -> SpeakVoiceSnapshot {
        let routing = self.routing
        let source = routing.source
        let availability: ClauseLedger.CloneAvailability
        let gain: Double
        let label: HUDModel.Voice
        switch source {
        case .myVoice(let handle, let db): availability = .ready(handle); gain = db; label = .mine
        case .myVoicePending: availability = .down; gain = 0; label = .mine
        case .systemVoice: availability = .noProfile; gain = 0; label = .system
        }
        let systemHandle = VoiceHandle(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                       conditioningKey: "system", mode: .system, model: routing.system.id)
        return SpeakVoiceSnapshot(clone: routing.clone, system: routing.system, systemHandle: systemHandle,
                                  cloneAvailability: availability, playoutGainDb: gain, hudVoice: label)
    }

    func pressActive(_ active: Bool) async {
        guard let process, let client = await process.client else { return }
        try? await client.setSession(meeting: true, speakActive: active)
    }
    func cancelSpeak() async { try? await process?.client?.cancel(scope: .speak) }
    func report(_ report: PlayoutReport) async { await routing.clone.report(report) }
    func noteDrainable(_ ms: Int) { (routing.clone as? RemoteQwenTTS)?.noteDrainable(ms) }

    struct ASR: ClipASREngine {
        let bridge: SpeakEngineBridge
        var id: EngineID { .init(name: "qwen-asr", revision: "current", placement: .engineGPU) }
        func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, job: JobID,
                        priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
            guard let process = bridge.process else { throw RemoteEngineError.voiceNotReady }
            return try await RemoteQwenASR(engine: process).transcribe(clip, hint: hint, context: context,
                job: job, priority: priority, deadline: deadline)
        }
        func cancel(_ job: JobID) async {
            guard let process = bridge.process else { return }
            await RemoteQwenASR(engine: process).cancel(job)
        }
    }
}
