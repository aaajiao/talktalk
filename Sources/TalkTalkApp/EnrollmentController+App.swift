import TalkTalkVoice

extension EnrollmentController {
    /// Closing the window (dev window or settings) mid-take releases the microphone and drops
    /// the staging directory. A finished take waiting in review is simply dropped with the controller.
    /// Both window-close paths (Settings › 我的声音, `--bench enroll`) come here, so this is also
    /// where the engine started for the enrollment is told it may idle-exit (§7.6, `finish()`).
    func cancelIfActive() {
        switch phase {
        case .idle, .saved, .failed, .review: break
        default: cancel()
        }
        finish()
    }
}
