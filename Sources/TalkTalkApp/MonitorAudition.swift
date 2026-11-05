import TalkTalkAudio
import TalkTalkVoice

/// The real `AuditionMonitor` (§9.2 step 7): the voice audition plays through MonitorOutput on the
/// default output, never on the Feed / TalkTalk Mic. 24 kHz in; MonitorOutput resamples. In
/// meeting mode (the owner calls `MonitorOutput.setMeetingMode`) it is unavailable (§3.4).
struct MonitorAudition: AuditionMonitor {
    let monitor: MonitorOutput

    var isAvailable: Bool { get async { await monitor.isAuditionAvailable } }
    var unavailableReason: String? { get async { await monitor.auditionUnavailableReason } }

    func play(_ samples24k: [Float]) async throws {
        do { try await monitor.playAudition(samples24k, sampleRate: 24_000) } catch let e as MonitorOutput.AuditionError {
            throw Self.map(e)
        }
    }

    func stop() async { monitor.stopAudition() }

    /// MyVoiceSettings shows an AuditionMonitorError's own text, anything else as "试听没有生成：…".
    static func map(_ e: MonitorOutput.AuditionError) -> AuditionMonitorError {
        switch e {
        case .unavailable(let why): .unavailable(why)
        case .interrupted(let why): .interrupted(why)
        }
    }
}
