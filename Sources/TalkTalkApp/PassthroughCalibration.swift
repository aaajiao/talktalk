// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import Observation
import TalkTalkAudio
import TalkTalkCore
import TalkTalkVoice

/// Explicit, local level calibration. Samples are reduced to sums on arrival and never persisted.
@MainActor @Observable
final class PassthroughCalibration {
    private(set) var running = false
    private(set) var message: String?
    private var capture: MicCapture?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let gains: PassthroughGainStore
    init(gains: PassthroughGainStore) { self.gains = gains }

    func start(device: InputDeviceInfo?, meetingActive: Bool) {
        guard !running, !meetingActive, let device else { return }
        let rule = MicPolicy.Device(uid: device.uid, name: device.name, transport: device.transport, isAggregate: device.isAggregate, isAlive: device.isAlive)
        guard MicPolicy.passesRule2(rule) else { return }
        running = true; message = String(localized: "请按平常音量读一句话，测量约 6 秒；只测电平，不保存录音。")
        let token = UUID(); generation = token
        task = Task { [weak self] in
            guard let self else { return }
            guard await MicrophoneAuthorization.request() == .authorized else {
                if generation == token { running = false; message = String(localized: "需要麦克风权限才能校准。") }
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
                            self.cancel(); self.message = String(localized: "麦克风发生变化，本次校准已取消。")
                        }
                    })
                }.value
                try await Task.sleep(for: .seconds(6))
                await Task.detached { mic.stop() }.value
                guard generation == token, !Task.isCancelled else { return }
                capture = nil; running = false
                guard let rms = meter.speechRmsDb else {
                    message = String(localized: "没有测到足够清晰的语音，或音量已削波，请重新试一次。")
                    return
                }
                let gain = VoiceGains.passthroughGainDb(rawSpeechRmsDbfs: rms)
                gains.setGainDb(gain, micUIDHash: VoiceProfile.micUIDHash(device.uid))
                message = String(localized: "已校准：\(String(format: "%+.1f", gain)) dB。")
            } catch is CancellationError {
                // cancel() already closed capture and updated the UI.
            } catch {
                if generation == token { cancel(); message = String(localized: "校准没有完成：\(error.localizedDescription)") }
            }
        }
    }
    func cancel() {
        if running { message = String(localized: "校准已取消。") }
        generation = UUID(); task?.cancel(); task = nil; running = false
        let old = capture; capture = nil
        if let old { Task.detached { old.stop() } }
    }
}

private final class CalibrationMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let rate: Double
    private var squares = 0.0, frames = 0, clipped = 0
    init(rate: Double) { self.rate = rate }
    func offer(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let power = samples.reduce(0.0) { sum, sample in sum + (sample.isFinite ? Double(sample * sample) : 0) }
        guard power > 0, 10 * log10(power / Double(samples.count)) > -55 else { return }
        let peaks = samples.filter { !$0.isFinite || abs($0) >= 0.99 }.count
        lock.withLock { squares += power; frames += samples.count; clipped += peaks }
    }
    var speechRmsDb: Double? {
        lock.withLock {
            guard Double(frames) >= rate * 0.4, squares > 0, Double(clipped) / Double(frames) < 0.01 else { return nil }
            return 10 * log10(squares / Double(frames))
        }
    }
}
