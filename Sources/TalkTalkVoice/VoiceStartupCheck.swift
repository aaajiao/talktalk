// l10n: zh-Hans (scripts/check-strings.sh)
import Darwin
import Foundation
import TalkTalkCore

/// §7.5 item 4: `voice/profile.json` parses, the files it needs are there, permissions are
/// 0700 / 0600 (fixed when they are not), and whether a conditioning file for the installed
/// runtime and TTS revision exists. A missing conditioning file is not an error: the engine
/// rebuilds it at warm-up (P3, about 1–2 s). Reads only file metadata and profile.json.
public struct VoiceStartupCheck: StartupCheckItem {
    public let id = "voice"
    public let store: VoiceStore
    /// From install.json: `runtime`, and the TTS role's model key and revision. nil when the engine
    /// is not installed (then the conditioning is reported as "unknown").
    public let runtime: String?
    public let ttsKey: String?
    public let ttsRev: String?

    public init(store: VoiceStore, runtime: String?, ttsKey: String?, ttsRev: String?) {
        self.store = store
        self.runtime = runtime
        self.ttsKey = ttsKey
        self.ttsRev = ttsRev
    }

    public init(store: VoiceStore, record: EngineInstallation.Record?) {
        self.init(store: store, runtime: record?.runtime, ttsKey: record?.roles["tts"]?.id, ttsRev: record?.roles["tts"]?.rev)
    }

    public func run() async -> StartupCheckResult {
        let fm = FileManager.default
        let dir = store.voiceURL
        let profileURL = dir.appendingPathComponent(VoiceStore.profileName)
        guard fm.fileExists(atPath: profileURL.path) else {
            return StartupCheckResult(id: id, level: .notice, summary: "no voice recorded (SPEAK uses the system voice)")
        }
        guard let data = try? Data(contentsOf: profileURL), data.count <= 1 << 20,
              let profile = try? VoiceProfile.decode(data) else {
            return StartupCheckResult(id: id, level: .action, summary: String(appLocalized: "voice profile unreadable (re-record in 设置 › 我的声音)"))
        }
        var needed = [VoiceStore.scriptName]
        needed += profile.references.values.sorted()
        let missing = Array(Set(needed)).sorted().filter { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        if !missing.isEmpty {
            return StartupCheckResult(id: id, level: .action, summary: String(appLocalized: "voice files missing (re-record in 设置 › 我的声音)"),
                                      details: ["missing": missing.joined(separator: " ")])
        }
        let fixed = Self.fixPermissions(dir: dir, files: [VoiceStore.profileName] + needed)
        var d = ["conditioning": conditioningState(dir: dir)]
        if fixed > 0 { d["permissions_fixed"] = String(fixed) }
        return StartupCheckResult(id: id, level: .ok, summary: "voice ready", details: d)
    }

    /// The engine's key (engine/talktalk_engine/main.py, §9.3):
    /// `<runtime>-mlxaudio<version>-<tts key>@<rev12>-<mode>-<pcm fingerprint 16>`. The mlx-audio
    /// version is known only from READY, so this matches every other part: "current" means a file
    /// for this runtime and TTS revision exists; a stale mlx-audio part is rebuilt at warm-up anyway.
    func conditioningState(dir: URL) -> String {
        guard let runtime, let ttsKey, let ttsRev else { return "unknown" }
        let cond = dir.appendingPathComponent(VoiceStore.conditioningName)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cond.path)) ?? []
        let prefix = Self.safeKey("\(runtime)-mlxaudio")
        let model = Self.safeKey("-\(ttsKey)@\(ttsRev.prefix(12))-")
        let files = names.filter { $0.hasSuffix(".safetensors") }
        if files.contains(where: { $0.hasPrefix(prefix) && $0.contains(model) }) { return "current" }
        return files.isEmpty ? "missing" : "stale"
    }

    /// Same mapping as `VoiceStore.writeConditioning` uses for file names.
    static func safeKey(_ key: String) -> String {
        String(key.map { c in c.isASCII && (c.isLetter || c.isNumber || "._@-".contains(c)) ? c : "_" })
    }

    /// 0700 on the directory, 0600 on the files we know (only regular files, never through a link).
    /// Returns how many modes were changed.
    static func fixPermissions(dir: URL, files: [String]) -> Int {
        var changed = 0
        func fix(_ path: String, _ mode: mode_t, directory: Bool) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR, isReg = (st.st_mode & S_IFMT) == S_IFREG
            guard directory ? isDir : isReg else { return }
            if st.st_mode & 0o777 != mode, chmod(path, mode) == 0 { changed += 1 }
        }
        fix(dir.path, 0o700, directory: true)
        let cond = dir.appendingPathComponent(VoiceStore.conditioningName)
        fix(cond.path, 0o700, directory: true)
        for f in Set(files) { fix(dir.appendingPathComponent(f).path, 0o600, directory: false) }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: cond.path)) ?? [] where f.hasSuffix(".safetensors") {
            fix(cond.appendingPathComponent(f).path, 0o600, directory: false)
        }
        return changed
    }
}
