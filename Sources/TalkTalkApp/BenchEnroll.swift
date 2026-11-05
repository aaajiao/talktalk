#if TALKTALK_DEV
import AppKit
import SwiftUI
import TalkTalkAudio
import TalkTalkCore
import TalkTalkVoice

/// Hosts a SwiftUI view in one ordinary window; closing the window ends the process.
@MainActor
final class DevWindowHost: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private static var current: DevWindowHost?

    static func run<V: View>(title: String, size: NSSize, view: V, onClose: @escaping () -> Void,
                             smoke: (() -> Void)? = nil) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let host = DevWindowHost()
        current = host
        host.onClose = onClose
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.delegate = host
        window.isReleasedWhenClosed = false
        host.window = window
        window.makeKeyAndOrderFront(nil)
        app.activate()
        if let smoke {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                smoke()
                exit(0)
            }
        }
        app.run()
        exit(0)
    }

    static func close() {
        current?.window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        let handler = onClose
        onClose = nil
        handler?()
        exit(0)
    }
}

/// TCC judges a process started from a terminal by the terminal's grant (§2.2), so the recording
/// entries run only when LaunchServices started them (`open -n -a`): their parent is launchd.
@MainActor
func requireLaunchServices(_ op: String, outPath: String?) {
    guard BuildFlavor.current == .dev, getppid() == 1 else {
        writeResult(["op": op, "error": "start TalkTalk-Dev.app through LaunchServices: open -W -n -a <abs path>/TalkTalk-Dev.app --args --bench \(op) ... (§2.2)"], to: outPath)
        exit(2)
    }
}

/// `--bench enroll`: the product's enrollment view (§9.2) in a dev window. Saves to the real
/// `~/Library/Application Support/TalkTalk/voice/`, which TalkTalk.app later uses as is.
@MainActor
enum BenchEnrollWindow {
    static func run(outPath: String?, smoke: Bool) -> Never {
        requireLaunchServices("enroll", outPath: outPath)
        let controller = EnrollmentController()
        func result() -> [String: Any] {
            var r = controller.outcomeSummary
            r["op"] = "enroll"
            r["voice_dir"] = "~/Library/Application Support/TalkTalk/voice"
            r["devices"] = controller.devices.map {
                ["transport": $0.info.transport, "sample_rate": $0.info.nominalSampleRate,
                 "accepted": $0.verdict.isAccepted, "reason": $0.verdict.reason ?? ""] as [String: Any]
            }
            return r
        }
        let view = EnrollmentView(controller: controller, onClose: { DevWindowHost.close() })
        DevWindowHost.run(
            title: "TalkTalk Dev — 我的声音", size: NSSize(width: 680, height: 600), view: view,
            onClose: {
                controller.cancelIfActive()
                writeResult(result(), to: outPath)
            },
            smoke: smoke ? {
                var r = result()
                r["smoke"] = true
                r["window_opened"] = true
                writeResult(r, to: outPath)
            } : nil)
    }
}

#endif
