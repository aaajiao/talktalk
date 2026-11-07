import AppKit
import TalkTalkSession

/// The system app owns dialing, answering and hanging up. TalkTalk only opens it; it never
/// passes a telephone URL, stores call history or invokes private telephony APIs.
@MainActor
enum NativePhone {
    enum Failure: Error { case unavailable }

    static func open(activates: Bool = true) async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MeetingMode.phoneAppID) else {
            throw Failure.unavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: (NSRunningApplication?, Error?) -> Void = { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration,
                                               completionHandler: completion)
        }
    }
}
