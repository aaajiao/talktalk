// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import Observation
import TalkTalkAudio
import TalkTalkCore
import TalkTalkVoice

/// Explicit, local level calibration. Samples are reduced to sums on arrival and never persisted.
/// While it runs, `levelDb` follows the input five times a second for the level bar; afterwards
/// `outcome` says how it ended (settings › 音频 words it, §7.6).
@MainActor @Observable
final class PassthroughCalibration {
    /// How the last calibration ended.
    enum Outcome: Equatable {
        case calibrated(gainDb: Double)
        /// No clear speech, or the level clipped.
        case unclear
        /// The microphone changed under it.
        case microphoneChanged
        case needsPermission
        case failed(String)
        case cancelled
    }

    private(set) var running = false
    private(set) var outcome: Outcome?
    /// The input level while running (dBFS of the last chunk); nil otherwise.
    private(set) var levelDb: Double?
    private var capture: MicCapture?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let gains: PassthroughGainStore
    init(gains: PassthroughGainStore) { self.gains = gains }

    /// How long one calibration listens.
    static let seconds = 6

    func start(device: InputDeviceInfo?, meetingActive: Bool) {
        guard !running, !meetingActive, let device else { return }
        let rule = MicPolicy.Device(uid: device.uid, name: device.name, transport: device.transport, isAggregate: device.isAggregate, isAlive: device.isAlive)
        guard MicPolicy.passesRule2(rule) else { return }
        running = true; outcome = nil; levelDb = nil
        let token = UUID(); generation = token
        task = Task { [weak self] in
            guard let self else { return }
            guard await MicrophoneAuthorization.request() == .authorized else {
                if generation == token { running = false; outcome = .needsPermission }
                return
            }
            guard generation == token, !Task.isCancelled else { return }
            do {
                let meter = CalibrationMeter(rate: device.nominalSampleRate)
                let mic = try MicCapture(device: device)
                defer { Task.detached { mic.stop() } }
                capture = mic
                try await Task.detached {
                    try mic.start(onChunk: { meter.offer($0.samples) }, onInterruption: { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.cancel(); self.outcome = .microphoneChanged
                        }
                    })
                }.value
                // Five level readings a second for the bar; nothing else is kept.
                for _ in 0..<(Self.seconds * 5) {
                    try await Task.sleep(for: .milliseconds(200))
                    guard generation == token else { return }
                    levelDb = meter.latestDb
                }
                await Task.detached { mic.stop() }.value
                guard generation == token, !Task.isCancelled else { return }
                capture = nil; running = false; levelDb = nil
                guard let rms = meter.speechRmsDb else {
                    outcome = .unclear
                    return
                }
                let gain = VoiceGains.passthroughGainDb(rawSpeechRmsDbfs: rms)
                gains.setGainDb(gain, micUIDHash: VoiceProfile.micUIDHash(device.uid))
                outcome = .calibrated(gainDb: gain)
            } catch is CancellationError {
                // cancel() already closed capture and updated the UI.
            } catch {
                if generation == token { cancel(); outcome = .failed(error.localizedDescription) }
            }
        }
    }
    /// The microphone chosen on the page is gone: nothing starts, and the page says so.
    func microphoneChanged() {
        guard !running else { return }
        outcome = .microphoneChanged
    }

    /// Stops a running calibration (已取消, shown on the page that is still open); otherwise
    /// forgets the last outcome, which belonged to the microphone it was measured on.
    func cancel() {
        outcome = running ? .cancelled : nil
        generation = UUID(); task?.cancel(); task = nil; running = false; levelDb = nil
        let old = capture; capture = nil
        if let old { Task.detached { old.stop() } }
    }

    /// The page or the window goes away: stop and forget the outcome, which belonged to that visit.
    func reset() {
        cancel()
        outcome = nil
    }
}

private final class CalibrationMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let rate: Double
    private var squares = 0.0, frames = 0, clipped = 0, latest = -120.0
    init(rate: Double) { self.rate = rate }
    func offer(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let power = samples.reduce(0.0) { sum, sample in sum + (sample.isFinite ? Double(sample * sample) : 0) }
        let db = power > 0 ? 10 * log10(power / Double(samples.count)) : -120
        lock.withLock { latest = db }
        guard power > 0, db > -55 else { return }
        let peaks = samples.filter { !$0.isFinite || abs($0) >= 0.99 }.count
        lock.withLock { squares += power; frames += samples.count; clipped += peaks }
    }
    /// The last chunk's level, for the bar.
    var latestDb: Double { lock.withLock { latest } }
    var speechRmsDb: Double? {
        lock.withLock {
            guard Double(frames) >= rate * 0.4, squares > 0, Double(clipped) / Double(frames) < 0.01 else { return nil }
            return 10 * log10(squares / Double(frames))
        }
    }
}
