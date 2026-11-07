import AppKit
import TalkTalkSession

/// The system app owns calls. TalkTalk only opens it, or hands it a validated number after
/// an explicit user action; it never stores call history or invokes private telephony APIs.
@MainActor
enum NativePhone {
    enum Failure: Error { case unavailable }

    static func open(dialURL: URL? = nil, activates: Bool = true) async throws {
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
            if let dialURL {
                NSWorkspace.shared.open([dialURL], withApplicationAt: appURL,
                                        configuration: configuration, completionHandler: completion)
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration,
                                                   completionHandler: completion)
            }
        }
    }
}
