import Foundation
import TalkTalkCore
import Translation

/// T11 (ARCHITECTURE.md), the part that needs no engine: Apple Translation latency for the
/// SPEAK fallback directions zh→en/de and en→zh/de, cold and hot, 30 sentences each, p50 / p95, for
/// each strategy (`lowLatency`, and `highFidelity` on macOS 26.4+); plus the LISTEN draft
/// directions across zh/en/de. NumberGuard runs on every output (the F7 30万→3万
/// risk); only counts are kept, never text. Pairs that are not installed are reported, not
/// downloaded (System Settings › General › Language & Region › Translation Languages).
/// TTS RTF under translation load needs the engine and is not measured here.
@available(macOS 26.4, *)
public struct TranslationBench: Sendable {
    public let sentences: [Lang: [String]]
    public let glossary: [GlossaryEntry]
    public let count: Int
    public let records: JSONLWriter

    public init(sentences: [Lang: [String]], glossary: [GlossaryEntry], count: Int = 30, records: JSONLWriter) {
        self.sentences = sentences; self.glossary = glossary; self.count = count; self.records = records
    }

    static func language(_ l: Lang) -> Locale.Language {
        switch l { case .zh: Locale.Language(identifier: "zh-Hans"); case .en: Locale.Language(identifier: "en"); case .de: Locale.Language(identifier: "de") }
    }

    enum StrategyName: String, CaseIterable { case lowLatency, highFidelity }

    func strategy(_ s: StrategyName) -> TranslationSession.Strategy {
        switch s { case .lowLatency: .lowLatency; case .highFidelity: .highFidelity }
    }

    public func run() async -> [String: Any] {
        var out: [String: Any] = ["op": "bench-translation", "os": ProcessInfo.processInfo.operatingSystemVersionString]
        let pairs: [(Lang, Lang, Bool)] = [(.zh, .en, true), (.zh, .de, true), (.en, .zh, true), (.en, .de, true), (.de, .zh, false), (.de, .en, false)]
        var results: [String: Any] = [:]
        for (src, tgt, speak) in pairs {
            let key = "\(src.rawValue)-\(tgt.rawValue)"
            var r: [String: Any] = [:]
            for st in StrategyName.allCases {
                let avail = await LanguageAvailability(preferredStrategy: strategy(st)).status(from: Self.language(src), to: Self.language(tgt))
                var row: [String: Any] = ["availability": "\(avail)"]
                guard avail == .installed else { r[st.rawValue] = row; continue }
                let texts = Array((sentences[src] ?? []).prefix(count))
                if speak {
                    row["cold"] = await measure(src, tgt, st, texts, cold: true)
                }
                row["hot"] = await measure(src, tgt, st, texts, cold: false)
                r[st.rawValue] = row
            }
            results[key] = r
        }
        out["pairs"] = results
        return out
    }

    func measure(_ src: Lang, _ tgt: Lang, _ st: StrategyName, _ texts: [String], cold: Bool) async -> [String: Any] {
        var ms: [Int] = [], errors: [String: Int] = [:]
        var numberMissing = 0, empty = 0
        var shared: TranslationSession?
        if !cold {
            let s = TranslationSession(installedSource: Self.language(src), target: Self.language(tgt), preferredStrategy: strategy(st))
            do { try await s.prepareTranslation(); _ = try await s.translate(texts.last ?? "") } catch { errors["warmup: \(error)", default: 0] += 1 }
            shared = s
        }
        for (i, t) in texts.enumerated() {
            let session = shared ?? TranslationSession(installedSource: Self.language(src), target: Self.language(tgt), preferredStrategy: strategy(st))
            let t0 = ContinuousClock.now
            do {
                let resp = try await session.translate(t)
                let d = Int((ContinuousClock.now - t0) / .milliseconds(1))
                ms.append(d)
                let target = resp.targetText
                if target.trimmingCharacters(in: .whitespaces).isEmpty { empty += 1 }
                var fields: [String: Any] = ["pair": "\(src.rawValue)-\(tgt.rawValue)", "strategy": st.rawValue, "cold": cold, "i": i, "ms": d]
                let chk = NumberGuard.check(source: t, sourceLang: src, target: target, targetLang: tgt, glossary: glossary)
                if !chk.missing.isEmpty {
                    numberMissing += 1
                    // Numbers only (no text): what the guard expected and what it read in the output.
                    fields["missing_values"] = chk.missing
                    fields["source_values"] = chk.source.map(\.value)
                    fields["target_values"] = chk.target.map(\.value)
                }
                fields["number_missing"] = chk.missing.count
                records.write("t11.translate", fields)
            } catch {
                errors["\(error)", default: 0] += 1
                records.write("t11.translate", ["pair": "\(src.rawValue)-\(tgt.rawValue)", "strategy": st.rawValue, "cold": cold, "i": i,
                                                "error": "\(type(of: error))"])
            }
        }
        return ["ms": benchDist(ms), "errors": errors, "empty": empty, "sentences_with_number_missing": numberMissing]
    }
}
