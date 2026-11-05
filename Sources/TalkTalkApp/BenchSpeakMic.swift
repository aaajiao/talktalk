import Foundation
import TalkTalkAudio
import TalkTalkCore

/// Dev-only capture diagnostics: numbers only, no audio/transcript/device identifier is persisted.
func runBenchSpeakMic() -> Never {
    #if TALKTALK_DEV
    Task { @MainActor in
        guard await MicrophoneAuthorization.request() == .authorized else {
            writeResult(["ok": 0, "microphoneDenied": 1], to: argumentValue("--out")); exit(1)
        }
        do {
            let requested = Double(argumentValue("--seconds") ?? "") ?? 20
            let seconds = requested.isFinite ? min(120, max(1, requested)) : 20
            let profile = try PolicyProfile.loadDefault()
            let mic = try MicIngest(profile: profile.speak)
            mic.setHot(true)
            try await Task.sleep(for: .seconds(seconds))
            let stats = mic.stats
            mic.stop()
            let elapsed = stats.lastHost >= stats.firstHost ? Double(stats.lastHost - stats.firstHost) / 1e9 : 0
            let result: [String: Double] = ["ok": stats.blocks > 0 ? 1 : 0, "deviceRate": stats.deviceRate,
                "blocks": Double(stats.blocks), "frames16k": Double(stats.frames16k),
                "vadOnsets": Double(stats.onsets), "rateRestarts": Double(stats.rateRestarts),
                "droppedBlocks": Double(stats.droppedBlocks), "captureSeconds": elapsed,
                "driftMs": (stats.audioSeconds - elapsed) * 1000]
            writeResult(result, to: argumentValue("--out")); exit(stats.blocks > 0 ? 0 : 1)
        } catch {
            writeResult(["ok": 0, "captureFailed": 1], to: argumentValue("--out")); exit(1)
        }
    }
    dispatchMain()
    #else
    fail("--bench speak-mic exists only in the dev build")
    #endif
}
