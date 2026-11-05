import Darwin
import Foundation
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkVoice

// voice-m2: the `--voice` part of `TalkTalk --self-test` (ARCHITECTURE.md §12.3, §9). The entry
// point and the JSON line are talktalk-m0's SelfTest.swift; this file only produces the checks.
// Reads file metadata and profile.json; with an installed engine it also generates the en/de
// audition (GPU, a few seconds) and reports read-back WER, the PlayoutStage gain and the speaker
// similarity. Never writes into voice/, never plays audio, never prints text, paths or audio.

func voiceSelfTest(store: VoiceStore = .product, useEngine: Bool = true) async -> SelfTestReport {
    var r = SelfTestReport(suite: "voice")
    let fm = FileManager.default
    let dir = store.voiceURL
    guard store.hasProfile else {
        // No profile is a valid state (SPEAK uses the system voice, C8): not a failure.
        r.checks.append(SelfTestCheck("profile", ok: true, detail: "optional profile absent (SPEAK uses the system voice)"))
        return r
    }
    guard let profile = try? store.loadProfile() else {
        r.checks.append(SelfTestCheck("profile", ok: false, detail: "profile.json unreadable"))
        return r
    }
    r.checks.append(SelfTestCheck("profile", ok: true, detail: "present",
                                  values: ["duration_s": profile.durationSeconds]))

    // §9.3 / §9.2 step 8: 0700 / 0600, backup exclusion, never-index marker.
    func mode(_ path: String) -> mode_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_mode & 0o777 : nil
    }
    let files = [VoiceStore.referenceName, VoiceStore.scriptName, VoiceStore.profileName]
    let wrong = files.filter { mode(dir.appendingPathComponent($0).path) != 0o600 }
    r.checks.append(SelfTestCheck("permissions", ok: mode(dir.path) == 0o700 && wrong.isEmpty,
                                  detail: wrong.isEmpty ? nil : "not 0600: \(wrong.joined(separator: " "))"))
    let excluded = (try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    r.checks.append(SelfTestCheck("backup_excluded", ok: excluded))
    r.checks.append(SelfTestCheck("never_index", ok: fm.fileExists(atPath: dir.appendingPathComponent(VoiceStore.neverIndexName).path)))
    r.checks.append(SelfTestCheck("transcript", ok: profile.checks.status["transcript"].map { $0 != .reject },
                                  detail: profile.checks.status["transcript"]?.rawValue,
                                  values: profile.checks.measurements.cer.map { ["cer": $0] } ?? [:]))

    let paths = EnginePaths.standard()
    let installation = EngineInstallation(engineHome: paths.engineHome())
    let (_, record) = installation.check()
    let startup = await VoiceStartupCheck(store: store, record: record).run()
    r.checks.append(SelfTestCheck("conditioning", ok: nil, detail: startup.details["conditioning"] ?? profile.conditioning))
    r.checks.append(SelfTestCheck("audition_route", ok: true, detail: "monitor output only (never TalkTalk Mic)"))

    guard useEngine, let record, let source = paths.engineSource else {
        r.checks.append(SelfTestCheck("audition", ok: nil, detail: "engine not installed"))
        return r
    }
    let engine = EngineProcess(config: EngineConfig.installed(record: record, installation: installation, paths: paths, source: source,
                                     policy: try? PolicyProfile.loadDefault()))
    let services = EngineVoiceServices(backend: RemoteQwenVoiceBackend(engine: engine))
    do {
        let wav = try Data(contentsOf: dir.appendingPathComponent(VoiceStore.referenceName))
        // Only conditioning built by this engine (runtime, mlx-audio, model, revision) is used;
        // stale or missing conditioning is built in memory for the test only (voice/ is written
        // by the app, not the self-test).
        var blobs = try await services.currentConditioning(profile, store: store)
        r.checks.append(SelfTestCheck("conditioning_current", ok: blobs.isEmpty ? nil : true,
                                      detail: blobs.isEmpty ? "stale or missing: rebuilt in memory" : nil))
        if blobs.isEmpty {
            let script = try String(contentsOf: dir.appendingPathComponent(VoiceStore.scriptName), encoding: .utf8)
            blobs = try await services.buildConditioning(referenceWAV: wav, scriptText: script, modes: profile.cloneModes)
        }
        let a = try await services.audition(conditioning: blobs, modes: profile.modesByLang, profileID: profile.id, referenceWAV: wav)
        for c in a.clips {
            var v: [String: Double] = ["attempts": Double(c.attempts), "seconds": c.seconds]
            if let w = c.wer { v["wer"] = w }
            if c.werPending { v["wer_pending"] = 1 }
            if let s = c.similarity { v["speaker_similarity"] = s }
            r.checks.append(SelfTestCheck("audition_\(c.lang.rawValue)", ok: c.passed,
                                          detail: c.failure?.rawValue ?? (c.similarity == nil ? "similarity: clip too short or engine error" : nil),
                                          values: v))
        }
        r.checks.append(SelfTestCheck("playout_gain", ok: a.playoutGainDb != nil,
                                      values: a.playoutGainDb.map { ["gain_db": $0] } ?? [:]))
    } catch {
        // The type only: engine error texts can carry paths (§12.3: no paths in the report).
        r.checks.append(SelfTestCheck("audition", ok: false, detail: "engine: \(type(of: error))"))
    }
    await engine.stop()
    return r
}
