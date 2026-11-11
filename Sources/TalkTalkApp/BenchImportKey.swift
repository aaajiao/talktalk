import Foundation
import TalkTalkCloud
import TalkTalkCore
#if TALKTALK_DEV
import AppKit
#endif

@MainActor func runBenchImportKey() -> Never {
    #if TALKTALK_DEV
    BenchImportKey.run(outPath: argumentValue("--out"))
    #else
    fail("--bench import-key exists only in the dev build (TalkTalk-Dev.app)")
    #endif
}

#if TALKTALK_DEV
/// `--bench import-key` (ARCHITECTURE.md M0 day 1; user decision 2026-11-04). Dev build only.
///
/// Copies the key that already exists in the login keychain (the bench item: service
/// `com.aaajiao.talktalk.openai`, account = the macOS user name, written by the user with
/// `security`) into the dev app's own item (`com.aaajiao.talktalk.dev.openai`, account `api-key`),
/// using the same KeychainSecret code as `--bench store-key` and the settings paste box. The app
/// creates the dev item itself, so its default ACL trusts TalkTalk-Dev.app (§7.7). The bench item is
/// left as it is (the Python bench keeps reading it).
///
/// Reading the bench item makes macOS ask once ("TalkTalk wants to use … in your keychain"): its ACL
/// trusts only `security`. The user clicks Allow (and types the login password if asked).
///
/// The key is checked only for length and the `sk-` prefix. It is never shown, logged, written to a
/// file or put on a command line; --out receives lengths, booleans and OSStatus codes only.
///
///   open -W -n -a "$PWD/build/TalkTalk-Dev.app" --args --bench import-key --out <file>
@MainActor
enum BenchImportKey {
    static let sourceService = "com.aaajiao.talktalk.openai"

    static func run(outPath: String?) -> Never {
        var result: [String: Any] = ["op": "import-key", "stored": false]
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        result["bundle_id"] = bundleID
        guard bundleID == "com.aaajiao.talktalk.dev", let target = KeychainSecret.openAI(bundleID: bundleID) else {
            result["error"] = "must run as TalkTalk-Dev.app (bundle id com.aaajiao.talktalk.dev); got '\(bundleID)'"
            writeResult(result, to: outPath)
            exit(2)
        }
        let source = KeychainSecret(service: sourceService, account: NSUserName(), label: "")
        result["source_service"] = source.service
        result["source_account"] = "NSUserName()"
        result["target_service"] = target.service
        result["target_account"] = target.account
        result["target_existed_before"] = target.exists()

        // Foreground app so the keychain access prompt is not hidden behind other windows.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate()

        var key = Data()
        defer { key.resetBytes(in: 0..<key.count) }
        do {
            key = try source.read()
        } catch let failure as KeychainSecret.Failure {
            result["error"] = "reading the bench item: \(failure.description)"
            result["osstatus"] = Int(failure.status)
            result["user_denied"] = failure.status == errSecAuthFailed || failure.status == errSecUserCanceled
            writeResult(result, to: outPath)
            exit(1)
        } catch {
            result["error"] = "reading the bench item: unexpected keychain error"
            writeResult(result, to: outPath)
            exit(1)
        }

        let text = String(decoding: key, as: UTF8.self)
        let normalized = APIKeyShape.normalized(text)
        result["source_length"] = key.count
        result["source_has_sk_prefix"] = normalized.hasPrefix("sk-")
        result["source_had_surrounding_whitespace"] = normalized.utf8.count != key.count
        if let problem = APIKeyShape.problem(normalized) {
            result["error"] = "bench item rejected: \(problem)"
            writeResult(result, to: outPath)
            exit(1)
        }
        let clean = Data(normalized.utf8)
        result["length"] = clean.count
        result["length_is_164"] = clean.count == 164
        do {
            try target.store(clean)
            result["stored"] = true
            let back = try target.read()
            result["readback_length"] = back.count
            result["readback_matches"] = (back == clean)
        } catch let failure as KeychainSecret.Failure {
            result["error"] = "writing the dev item: \(failure.description)"
            result["osstatus"] = Int(failure.status)
        } catch {
            result["error"] = "writing the dev item: unexpected keychain error"
        }
        writeResult(result, to: outPath)
        exit((result["readback_matches"] as? Bool) == true ? 0 : 1)
    }
}
#endif
