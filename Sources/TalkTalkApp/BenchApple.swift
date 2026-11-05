import AppKit
import Foundation
import TalkTalkApple
import TalkTalkCore

// `--bench speech` (T10) and `--bench translation` (T11), dev build only. Both touch TCC-guarded
// or system services, so run them through LaunchServices:
//   open -W -n -a build/TalkTalk-Dev.app --args --bench speech [--part finalize,presses,soak,startup] [--per-voice 50] [--presses 200]
//       [--minutes 60] [--lag-bucket-s 600] [--lag-baseline 1] [--lag-stat p90|p50|mean] [--soak-jitter-ms 940] [--load mlx] [--load-block 10] [--startup-reps 3] --out <file>
//   --load mlx: the installed engine synthesizes clause after clause (warm-up reference voice, never
//   "my voice"): ① runs fully loaded, ④ alternates idle / loaded blocks. Hold the gpu lock
//   (scripts/with-lock.sh quiet -- open -W …). Test audio: ~/Library/Application Support/TalkTalk-bench/t10/,
//   removed at the end of the run.
//   open -W -n -a build/TalkTalk-Dev.app --args --bench translation [--count 30] --out <file>
// --out gets the summary JSON, <file>.jsonl one record per sentence (counts and times only).

@MainActor func runBenchSpeech() -> Never {
    #if TALKTALK_DEV
    runAppleBench { records in
        var o = SpeechBench.Options()
        if let p = argumentValue("--part") { o.parts = p.split(separator: ",").map(String.init) }
        if let n = argumentValue("--per-voice").flatMap({ Int($0) }) { o.sentencesPerVoice = n }
        if let n = argumentValue("--presses").flatMap({ Int($0) }) { o.presses = n }
        if let n = argumentValue("--minutes").flatMap({ Double($0) }) { o.soakMinutes = n }
        if let n = argumentValue("--lag-bucket-s").flatMap({ Double($0) }) { o.lagBucketS = n }
        if let n = argumentValue("--lag-baseline").flatMap({ Int($0) }) { o.lagBaselineBuckets = n }
        if let v = argumentValue("--lag-stat") {
            guard let st = T10Analysis.LagDrift.Stat(rawValue: v) else { return ["op": "bench-speech", "error": "--lag-stat: p50, p90 or mean"] }
            o.lagStat = st
        }
        if let n = argumentValue("--soak-jitter-ms").flatMap({ Int($0) }) { o.soakJitterMs = max(0, n) }
        if let n = argumentValue("--load-block").flatMap({ Int($0) }) { o.loadBlock = n }
        if let n = argumentValue("--startup-reps").flatMap({ Int($0) }) { o.startupReps = n }
        let profile = try PolicyProfile.loadDefault()
        let c = try AppleBenchCorpus.load()
        var load: EngineTTSLoad?
        if argumentValue("--load") == "mlx" {
            load = try await EngineTTSLoad.start(sentences: c.listenEn.map { ($0, "en") } + c.listenDe.map { ($0, "de") })
        }
        let audio = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TalkTalk-bench/t10", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        var r = await SpeechBench(options: o, finalize: profile.listen.finalize, corpus: [.en: c.listenEn, .de: c.listenDe],
                                  zhSentences: c.speakChains.flatMap { $0 }, records: records, load: load, audioDir: audio).run()
        if let load {
            await load.stop()
            r["mlx_engine"] = load.describe()
        }
        return r
    }
    #else
    fail("--bench speech exists only in the dev build (TalkTalk-Dev.app)")
    #endif
}

@MainActor func runBenchTranslation() -> Never {
    #if TALKTALK_DEV
    runAppleBench { records in
        let c = try AppleBenchCorpus.load()
        let n = argumentValue("--count").flatMap { Int($0) } ?? 30
        guard #available(macOS 26.4, *) else { return ["error": "TranslationSession.Strategy needs macOS 26.4"] }
        return await TranslationBench(sentences: [.zh: c.numberSentences, .en: c.listenEn, .de: c.listenDe],
                                      glossary: c.glossary, count: n, records: records).run()
    }
    #else
    fail("--bench translation exists only in the dev build (TalkTalk-Dev.app)")
    #endif
}

#if TALKTALK_DEV
struct AppleBenchCorpus: Decodable {
    var glossary: [GlossaryEntry]
    var speakChains: [[String]]
    var listenEn: [String]
    var listenDe: [String]
    var numberSentences: [String]
    static func load() throws -> AppleBenchCorpus {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: ResourceLocator.url(for: "bench/t4_corpus.json")))
    }
}

/// Runs `body` off the main thread while AppKit spins, writes the summary, exits.
@MainActor func runAppleBench(_ body: @escaping @Sendable (JSONLWriter) async throws -> [String: Any]) -> Never {
    let out = argumentValue("--out")
    let records = JSONLWriter(path: out.map { $0 + ".jsonl" })
    Task.detached {
        var result: [String: Any]
        do { result = try await body(records) } catch { result = ["error": "\(error)"] }
        result["bundle_id"] = Bundle.main.bundleIdentifier ?? NSNull()
        records.close()
        let r = result
        await MainActor.run { writeResult(r, to: out); exit(r["error"] == nil ? 0 : 1) }
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
    exit(0)
}
#endif
