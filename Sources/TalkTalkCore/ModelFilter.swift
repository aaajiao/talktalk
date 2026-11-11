import Foundation

/// The settings model picker (ARCHITECTURE.md, "三种使用场景"): GPT-6 and later text models only.
///
/// - id must match `^gpt-(major)(.minor)?-(tier)(-YYYY-MM-DD)?$` with major ≥ 6 (one-word tier;
///   multi-part names such as `gpt-7-luna-mini` are filtered out until the rule is widened);
/// - the tier must not be a non-text variant (`excludedTiers`); specialised text tiers (codex,
///   chat, pro, ...) stay visible and the probe decides;
/// - a non-empty `shutdown_date` hides the model, except the current selection (marked);
/// - dated snapshots go into a separate "fixed snapshots" group;
/// - order: major desc, minor desc, created desc, id asc; `gpt-6-luna` is the default.
public enum ModelFilter {
    public static let defaultModel = "gpt-6-luna"

    public static let excludedTiers: Set<String> = [
        "realtime", "audio", "transcribe", "tts", "speech", "image", "search", "live", "translate",
        "whisper", "embedding", "moderation", "computer",
    ]

    /// One row of `GET /v1/models` (`data[]`): only id, created, object, owned_by, shutdown_date.
    public struct Listed: Codable, Sendable, Equatable {
        public var id: String
        public var created: Int
        public var object: String?
        public var owned_by: String?
        public var shutdown_date: String?
        public init(id: String, created: Int, object: String? = "model", owned_by: String? = nil, shutdown_date: String? = nil) {
            self.id = id; self.created = created; self.object = object; self.owned_by = owned_by; self.shutdown_date = shutdown_date
        }
    }

    public struct ParsedID: Sendable, Equatable {
        public var major: Int
        public var minor: Int?
        public var tier: String
        public var date: String?
    }

    public struct Choice: Sendable, Equatable {
        public var id: String
        public var parsed: ParsedID
        public var created: Int
        public var isDefault: Bool
        /// Current selection that has a shutdown_date: shown with “即将下线”.
        public var retiring: Bool
        public var known: KnownModel?
    }

    public struct Picker: Sendable, Equatable {
        public var models: [Choice]
        public var snapshots: [Choice]
    }

    /// Static facts for known ids (O3, O4). Everything else is decided by the probe.
    public struct KnownModel: Sendable, Equatable {
        /// nil = unknown, the probe decides. false = yellow path (effort low, §11).
        public var supportsEffortNone: Bool?
        /// Estimated cost per meeting hour incl. hedging (§11, 估); nil = "see OpenAI pricing".
        public var usdPerMeetingHour: Double?
    }

    public static let known: [String: KnownModel] = [
        "gpt-6-luna": KnownModel(supportsEffortNone: true, usdPerMeetingHour: 0.06),
        "gpt-6.1-terra": KnownModel(supportsEffortNone: nil, usdPerMeetingHour: 0.55),
        "gpt-6-sol": KnownModel(supportsEffortNone: nil, usdPerMeetingHour: 1.10),
        "gpt-6.1-sol": KnownModel(supportsEffortNone: false, usdPerMeetingHour: nil),   // lowest effort is low
        "gpt-6-astra": KnownModel(supportsEffortNone: false, usdPerMeetingHour: nil),   // docs: none → 400
    ]

    private static let pattern = try! NSRegularExpression(
        pattern: #"^gpt-(?<major>[0-9]+)(?:\.(?<minor>[0-9]+))?-(?<tier>[a-z]+)(?:-(?<date>[0-9]{4}-[0-9]{2}-[0-9]{2}))?$"#)

    public static func parse(_ id: String) -> ParsedID? {
        let ns = id as NSString
        guard let m = pattern.firstMatch(in: id, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let major = group("major").flatMap(Int.init), let tier = group("tier") else { return nil }
        return ParsedID(major: major, minor: group("minor").flatMap(Int.init), tier: tier, date: group("date"))
    }

    public static func isEligible(_ p: ParsedID) -> Bool { p.major >= 6 && !excludedTiers.contains(p.tier) }

    public static func picker(_ listed: [Listed], current: String?) -> Picker {
        var models: [Choice] = [], snapshots: [Choice] = []
        for l in listed {
            guard let p = parse(l.id), isEligible(p) else { continue }
            let retiring = !(l.shutdown_date ?? "").isEmpty
            if retiring && l.id != current { continue }
            let c = Choice(id: l.id, parsed: p, created: l.created, isDefault: l.id == defaultModel,
                           retiring: retiring, known: known[l.id])
            if p.date != nil { snapshots.append(c) } else { models.append(c) }
        }
        return Picker(models: models.sorted(by: order), snapshots: snapshots.sorted(by: order))
    }

    static func order(_ a: Choice, _ b: Choice) -> Bool {
        if a.parsed.major != b.parsed.major { return a.parsed.major > b.parsed.major }
        let am = a.parsed.minor ?? 0, bm = b.parsed.minor ?? 0
        if am != bm { return am > bm }
        if a.created != b.created { return a.created > b.created }
        return a.id < b.id
    }

    public enum Resolution: Sendable, Equatable {
        case keep(String)
        /// Fell back to the default; notify once (“所选模型已下线，已换回 gpt-6-luna”).
        case fellBackToDefault(from: String)
        /// The default itself is gone or retiring: keep using it, notify once, never auto-switch.
        case defaultRetiring
    }

    /// Retirement fallback (§11): the selection disappeared from the list, got a shutdown_date,
    /// or returned 404 → back to gpt-6-luna. Checked when settings open and when a meeting starts.
    public static func resolve(selection: String, listed: [Listed], got404: Bool = false) -> Resolution {
        let row = listed.first { $0.id == selection }
        let gone = row == nil || !(row?.shutdown_date ?? "").isEmpty || got404
        guard gone else { return .keep(selection) }
        if selection == defaultModel { return .defaultRetiring }
        return .fellBackToDefault(from: selection)
    }
}
