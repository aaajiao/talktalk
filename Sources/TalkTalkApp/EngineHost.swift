import Foundation
import Observation
import TalkTalkApple
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkVoice

/// The app's EngineHost (ARCHITECTURE.md §1, §7.6): one `EngineProcess` per runtime flavour (v1:
/// only the default one), and the voice lifecycle and SPEAK routing built and torn down with it,
/// so `VoiceLifecycle(engineProcess:)` follows exactly the instance SPEAK uses. Held by
/// AppDelegate and passed down (no global, so tests can hand in a fake factory).
///
/// - App launch with the engine installed: the instance is built. `EngineProcess` starts lazily,
///   building it launches nothing.
/// - Installed later (onboarding step 4, Settings › 组件): built when the installation changes.
/// - Fully uninstalled: stopped first, then nil.
/// - Not installed: nil; the routing's clone falls back to `SystemVoiceTTS`, enrollment saves
///   `pending_engine`.
/// - While the app runs an instance is replaced only when install.json changed (换档, 修复):
///   the old one is stopped first, then the new one is built (§7.6).
/// Headless entries (SelfTest, SelfTestVoice, BenchEngineRestart) build their own.
@MainActor
@Observable
final class EngineHost {
    static let defaultFlavour = "main"

    typealias Factory = @MainActor (EngineInstallation.Record, EngineInstallation, EnginePaths, URL) -> EngineProcess

    @ObservationIgnored let paths: EnginePaths
    @ObservationIgnored private let factory: Factory
    private var process: EngineProcess?
    /// install.json the instance was built from.
    private var processRecord: EngineInstallation.Record?
    /// Effective resource profile of the current validated instance. Creating that instance
    /// is lazy: this is available at app launch without starting Python or loading a model.
    var installedProfile: EngineProfile? { processRecord.flatMap { EngineProfile.matching(record: $0) } }
    private var stopping = false
    /// Rebuilt with the engine instance (and only then).
    private(set) var routing: SpeakVoiceRouting
    private(set) var lifecycle: VoiceLifecycle
    @ObservationIgnored let speakBridge: SpeakEngineBridge
    @ObservationIgnored private var auditionMonitor: any AuditionMonitor = UnavailableAuditionMonitor()
    /// The instance appeared or went away.
    @ObservationIgnored var onChange: (() -> Void)?

    init(paths: EnginePaths = .standard(), factory: @escaping Factory = EngineHost.makeProcess) {
        self.paths = paths
        self.factory = factory
        let initial = Self.voice(nil)
        (routing, lifecycle) = initial
        speakBridge = SpeakEngineBridge(routing: initial.0)
        sync()
    }

    /// The one place an app EngineProcess is built. The policy sets `--horizon-ms` from
    /// `speak.tts.renderHorizonMs`, the same number ClauseQueue uses.
    static func makeProcess(record: EngineInstallation.Record, installation: EngineInstallation,
                            paths: EnginePaths, source: URL) -> EngineProcess {
        EngineProcess(config: EngineConfig.installed(record: record, installation: installation, paths: paths,
                                                     source: source, policy: try? PolicyProfile.loadDefault()))
    }

    func engine(for flavour: String = EngineHost.defaultFlavour) -> EngineProcess? {
        flavour == Self.defaultFlavour ? process : nil
    }

    /// Settings › 组件 › 重启引擎 (neither SPEAK nor a meeting asked for it): restart, then idle
    /// out like after enrollment (`enrollmentFinished` leaves meeting mode alone).
    func restartFromSettings() async throws {
        guard let p = process else { return }
        _ = try await p.userRestart()
        await p.enrollmentFinished()
    }

    /// Re-reads the installation: builds the instance when the engine can start and there is
    /// none; when the engine is gone, or install.json is not the one the instance was built
    /// from, stops it first and then drops or rebuilds it. Call at launch and after every
    /// installer run.
    func sync() {
        guard !stopping else { return }   // the stop re-reads the installation when it is done
        let now = startable()
        guard let p = process else {
            if let now { set(make(now), now.record) }
            return
        }
        guard now?.record != processRecord else { return }
        stopping = true
        Task {
            await p.stop()
            stopping = false
            guard process === p else { return }
            let again = startable()   // the installation may have moved on meanwhile
            set(again.map(make), again?.record)
        }
    }

    private struct Startable {
        let installation: EngineInstallation
        let record: EngineInstallation.Record
        let source: URL
    }

    /// The installation as it is now, when the engine can start from it.
    private func startable() -> Startable? {
        let installation = EngineInstallation(engineHome: paths.engineHome())
        let (state, record) = installation.check()
        guard state.canStartEngine, let record, let source = paths.engineSource else { return nil }
        return Startable(installation: installation, record: record, source: source)
    }

    private func make(_ s: Startable) -> EngineProcess { factory(s.record, s.installation, paths, s.source) }

    private func set(_ p: EngineProcess?, _ record: EngineInstallation.Record?) {
        process = p
        processRecord = p == nil ? nil : record
        (routing, lifecycle) = Self.voice(p, monitor: auditionMonitor)
        speakBridge.update(p, routing: routing)
        onChange?()
    }

    /// Called once while assembling the app, before a recording or meeting can start.
    func setAuditionMonitor(_ monitor: any AuditionMonitor) {
        auditionMonitor = monitor
        (routing, lifecycle) = Self.voice(process, monitor: monitor)
        speakBridge.update(process, routing: routing)
        onChange?()
    }

    private static func voice(_ p: EngineProcess?, monitor: any AuditionMonitor = UnavailableAuditionMonitor()) -> (SpeakVoiceRouting, VoiceLifecycle) {
        let system = SystemVoiceTTS()
        let clone: any TTSEngine = p.map { RemoteQwenTTS(engine: $0) } ?? system
        let routing = SpeakVoiceRouting(clone: clone, system: system)
        let lifecycle = VoiceLifecycle(engineProcess: p, monitor: monitor,
                                       routing: routing, passthroughGains: PassthroughGainDefaults())
        return (routing, lifecycle)
    }
}
