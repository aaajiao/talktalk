#if TALKTALK_DEV
import AppKit
import Foundation
import TalkTalkCloud
import TalkTalkCore

/// `--bench store-key` (ARCHITECTURE.md §7.7, §14 M0 day 1). Dev build only.
///
/// Shows a minimal NSAlert with an NSSecureTextField; you paste the key and press Save. The app
/// writes it with the same KeychainSecret code the M1 settings paste box will use, so the item is
/// created by TalkTalk-Dev.app itself (service com.aaajiao.talktalk.dev.openai, account api-key).
/// The key is never echoed. --out receives only lengths, the service name and OSStatus codes.
///
/// Must be started through LaunchServices so the item's creator is the app, not a terminal:
///   open -W -n -a build/TalkTalk-Dev.app --args --bench store-key --out <file>
@MainActor
enum BenchStoreKey {
    static func run(outPath: String?) -> Never {
        var result: [String: Any] = ["op": "store-key", "stored": false]
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        result["bundle_id"] = bundleID
        guard bundleID == "com.aaajiao.talktalk.dev", let secret = KeychainSecret.openAI(bundleID: bundleID) else {
            result["error"] = "must run as TalkTalk-Dev.app (bundle id com.aaajiao.talktalk.dev); got '\(bundleID)'"
            writeResult(result, to: outPath)
            exit(2)
        }
        result["service"] = secret.service
        result["account"] = secret.account
        result["existed_before"] = secret.exists()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate()

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "sk-…"
        let alert = NSAlert()
        alert.messageText = "TalkTalk Dev：保存 OpenAI API key"
        alert.informativeText = """
            把 OpenAI 网站上创建的 key 粘贴到下面，点“保存”。它只写进登录钥匙串的 \
            \(secret.service)（account \(secret.account)），不回显、不写日志。
            保存后请清空剪贴板（通用剪贴板和剪贴板管理器会留副本）。
            """
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        var key = APIKeyShape.normalized(field.stringValue)
        field.stringValue = ""
        guard response == .alertFirstButtonReturn else {
            result["cancelled"] = true
            writeResult(result, to: outPath)
            exit(1)
        }
        result["length"] = key.count
        if let problem = APIKeyShape.problem(key) {
            key = ""
            result["error"] = "key rejected: \(problem)"
            writeResult(result, to: outPath)
            exit(1)
        }
        do {
            try secret.store(Data(key.utf8))
            result["stored"] = true
            let back = try secret.read()
            result["readback_length"] = back.count
            result["readback_matches"] = (back == Data(key.utf8))
        } catch let failure as KeychainSecret.Failure {
            result["error"] = failure.description
            result["osstatus"] = Int(failure.status)
        } catch {
            result["error"] = "unexpected keychain error"
        }
        key = ""
        writeResult(result, to: outPath)
        exit((result["readback_matches"] as? Bool) == true ? 0 : 1)
    }
}
#endif
