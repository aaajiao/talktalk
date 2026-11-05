import AVFoundation
import Foundation

/// Microphone TCC state (ARCHITECTURE.md §2.2, §3.2). The first request shows the system prompt
/// for the responsible app (TalkTalk-Dev.app when started through `open -n -a`). When the
/// microphone is denied, a Core Audio IOProc still runs but reads exact zeros, so callers check
/// this before recording instead of trusting the data.
public enum MicrophoneAuthorization: String, Sendable {
    case authorized, denied, restricted, notDetermined

    public static var current: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Asks once if undetermined; returns the resulting state.
    public static func request() async -> MicrophoneAuthorization {
        if current == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return current
    }
}
