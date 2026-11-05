import Foundation

/// What a diagnostics bundle may contain (ARCHITECTURE.md §12.3 “导出诊断包”, §12.1, §9.5).
///
/// Path whitelist, deny wins:
///
///     included  Logs/TalkTalk/*.log, *.log.1            process logs (ids, lengths, times, codes)
///               Logs/TalkTalk/sessions/*.jsonl          latency events
///               Application Support/TalkTalk/engine/install.json, driver.json
///     excluded  voice/, .voice-staging-*/, transcripts/, diagnostics/, glossary.json,
///               any audio file, anything reached through a symlink, anything else
///
/// Content filter (every included file passes it line by line):
/// - event lines must be flat JSON objects whose strings are EventLog tags (≤ 64 chars of
///   `[A-Za-z0-9._:-]`): text cannot survive;
/// - log and record lines are dropped when they carry non-ASCII text (transcripts and
///   translations are zh/de/en with accents; our own log lines are ASCII), a request header
///   (Authorization, Cookie, OpenAI-Organization/Project, api keys) or anything key-shaped;
///   the user's home directory becomes `~`.
/// A final key-shaped scan over the assembled tree must come out empty, or the bundle is refused.
/// The OpenAI key itself is never read for any of this (only its shape is known).
public struct DiagnosticsWhitelist: Sendable {
    public enum Kind: String, Codable, Sendable { case log, events, record }

    public enum Exclusion: String, Codable, Sendable, CaseIterable {
        case voice, voiceStaging, transcripts, diagnostics, glossary, audio, symlink, notListed, tooLarge
    }

    public enum Verdict: Sendable, Equatable {
        case include(Kind)
        case exclude(Exclusion)
    }

    /// `Application Support/TalkTalk`.
    public let home: URL
    /// `Logs/TalkTalk`.
    public let logs: URL
    /// Replaced by `~` in log lines.
    public let userHome: String
    public static let maxFileBytes = 32 * 1024 * 1024
    public static let maxLineBytes = 4096
    public static let audioExtensions: Set<String> = ["wav", "caf", "aif", "aiff", "m4a", "mp3", "flac", "aac",
                                                      "pcm", "raw", "opus", "ogg", "f32", "s16"]

    public init(home: URL, logs: URL, userHome: String = NSHomeDirectory()) {
        self.home = home.standardizedFileURL
        self.logs = logs.standardizedFileURL
        self.userHome = userHome
    }

    // MARK: - paths

    public func verdict(for url: URL) -> Verdict {
        let path = url.standardizedFileURL.path
        if Self.audioExtensions.contains(url.pathExtension.lowercased()) { return .exclude(.audio) }
        if let rel = Self.relative(path, to: home.path) {
            let first = rel.split(separator: "/").first.map(String.init) ?? ""
            if first == "voice" { return .exclude(.voice) }
            if first.hasPrefix(".voice-staging-") { return .exclude(.voiceStaging) }
            if first == "transcripts" { return .exclude(.transcripts) }
            if first == "diagnostics" { return .exclude(.diagnostics) }
            if first == "glossary.json" { return .exclude(.glossary) }
            if hasSymlink(path, under: home.path) { return .exclude(.symlink) }
            if rel == "engine/install.json" || rel == "driver.json" { return .include(.record) }
            return .exclude(.notListed)
        }
        if let rel = Self.relative(path, to: logs.path) {
            if hasSymlink(path, under: logs.path) { return .exclude(.symlink) }
            let parts = rel.split(separator: "/")
            if parts.count == 1, rel.hasSuffix(".log") || rel.hasSuffix(".log.1") { return .include(.log) }
            if parts.count == 2, parts[0] == "sessions", rel.hasSuffix(".jsonl") { return .include(.events) }
            return .exclude(.notListed)
        }
        return .exclude(.notListed)
    }

    /// Files the bundle takes, with their place inside it (`logs/…`, `records/…`).
    public func candidates() -> [(url: URL, kind: Kind, bundlePath: String)] {
        let fm = FileManager.default
        var urls: [URL] = []
        for name in (try? fm.contentsOfDirectory(atPath: logs.path))?.sorted() ?? [] {
            urls.append(logs.appendingPathComponent(name))
        }
        let sessions = logs.appendingPathComponent("sessions")
        for name in (try? fm.contentsOfDirectory(atPath: sessions.path))?.sorted() ?? [] {
            urls.append(sessions.appendingPathComponent(name))
        }
        urls.append(home.appendingPathComponent("engine/install.json"))
        urls.append(home.appendingPathComponent("driver.json"))
        var out: [(url: URL, kind: Kind, bundlePath: String)] = []
        for u in urls {
            var st = stat()
            guard lstat(u.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            guard case let .include(kind) = verdict(for: u) else { continue }
            let path: String
            switch kind {
            case .log: path = "logs/" + u.lastPathComponent
            case .events: path = "logs/sessions/" + u.lastPathComponent
            case .record: path = "records/" + u.lastPathComponent
            }
            out.append((url: u, kind: kind, bundlePath: path))
        }
        return out
    }

    static func relative(_ path: String, to root: String) -> String? {
        let r = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(r) else { return nil }
        let rel = String(path.dropFirst(r.count))
        return rel.isEmpty || rel.split(separator: "/").contains("..") ? nil : rel
    }

    /// True when `path` or a directory between `root` and it is a symlink.
    func hasSymlink(_ path: String, under root: String) -> Bool {
        var cur = path
        var st = stat()
        while cur.count > root.count {
            if lstat(cur, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK { return true }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return false
    }

    // MARK: - content

    /// An event line as written by EventLog, or nil when it is not a flat object of numbers,
    /// booleans and tags.
    public static func scrubEventLine(_ line: Substring) -> String? {
        guard line.utf8.count <= maxLineBytes, !containsSecret(line),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["ev"] is String else { return nil }
        for (k, v) in obj {
            guard isTag(k) else { return nil }
            switch v {
            case let s as String: guard isTag(s) else { return nil }
            case is NSNumber: break
            default: return nil
            }
        }
        return String(line)
    }

    /// A process-log or record line, or nil when it must not leave the Mac.
    public func scrubLogLine(_ line: Substring) -> String? {
        guard line.utf8.count <= Self.maxLineBytes, line.unicodeScalars.allSatisfy(\.isASCII),
              !Self.containsSecret(line), !Self.containsHeader(line) else { return nil }
        var s = String(line)
        if !userHome.isEmpty, userHome != "/" { s = s.replacingOccurrences(of: userHome, with: "~") }
        return s
    }

    static func isTag(_ s: String) -> Bool {
        s.count <= 64 && s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0))
        }
    }

    // NSRegularExpression is Sendable; matching is thread-safe and the instances are immutable.
    private static let secret = try! NSRegularExpression(
        pattern: #"sk-[A-Za-z0-9_\-]{16,}|(?i:bearer)\s+[A-Za-z0-9._~+/\-]{16,}"#)
    private static let header = try! NSRegularExpression(
        pattern: #"(?i)\b(proxy-authorization|authorization|set-cookie|cookie|openai-organization|openai-project|x-api-key|api-key|api_key)\b\s*["']?\s*[:=]"#)

    /// Key-shaped text: `sk-` followed by ≥ 16 key characters, or a bearer token.
    public static func containsSecret<S: StringProtocol>(_ s: S) -> Bool { matches(secret, String(s)) }
    public static func containsHeader<S: StringProtocol>(_ s: S) -> Bool { matches(header, String(s)) }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

/// Builds a diagnostics bundle directory from the whitelist (the app zips it, §12.3).
public enum DiagnosticsBundle {
    public struct Manifest: Codable, Sendable, Equatable {
        public struct File: Codable, Sendable, Equatable {
            public var path: String
            public var kind: DiagnosticsWhitelist.Kind?
            public var keptLines: Int
            public var droppedLines: Int
        }
        public var files: [File]
        public var skippedTooLarge: Int
    }

    public enum Failure: Error, Equatable {
        /// Key-shaped content survived the filters (bundle paths): the bundle was not written.
        case secretFound([String])
        case unsafeExtraName(String)
    }

    /// Writes the whitelisted, filtered files plus `extras` (generated JSON: versions, device
    /// names; names without "/") and `manifest.json` into `staging` (0700 directory, 0600 files),
    /// then scans the whole tree. On a hit the staging tree is removed and `secretFound` thrown.
    @discardableResult
    public static func assemble(_ wl: DiagnosticsWhitelist, extras: [String: Data] = [:], into staging: URL) throws -> Manifest {
        try FileSystem.ensurePrivateDirectory(staging)
        var files: [Manifest.File] = []
        var tooLarge = 0
        for c in wl.candidates() {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: c.url.path),
                  let size = attrs[.size] as? Int else { continue }
            if size > DiagnosticsWhitelist.maxFileBytes { tooLarge += 1; continue }
            guard let data = FileManager.default.contents(atPath: c.url.path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var kept: [String] = [], dropped = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let out = c.kind == .events ? DiagnosticsWhitelist.scrubEventLine(line) : wl.scrubLogLine(line)
                if let out { kept.append(out) } else { dropped += 1 }
            }
            let dest = staging.appendingPathComponent(c.bundlePath)
            try FileSystem.ensurePrivateDirectory(dest.deletingLastPathComponent())
            try FileSystem.writeAtomically(Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8), to: dest)
            files.append(.init(path: c.bundlePath, kind: c.kind, keptLines: kept.count, droppedLines: dropped))
        }
        for (name, data) in extras.sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name != "manifest.json" else {
                throw Failure.unsafeExtraName(name)
            }
            try FileSystem.writeAtomically(data, to: staging.appendingPathComponent(name))
            files.append(.init(path: name, kind: nil, keptLines: 0, droppedLines: 0))
        }
        let manifest = Manifest(files: files, skippedTooLarge: tooLarge)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileSystem.writeAtomically(try enc.encode(manifest), to: staging.appendingPathComponent("manifest.json"))
        let hits = secretScan(staging)
        if !hits.isEmpty {
            try? FileManager.default.removeItem(at: staging)
            throw Failure.secretFound(hits)
        }
        return manifest
    }

    /// Bundle-relative paths of files under `tree` with key-shaped content.
    public static func secretScan(_ tree: URL) -> [String] {
        files(tree).filter { DiagnosticsWhitelist.containsSecret(String(decoding: $0.1, as: UTF8.self)) }.map(\.0)
    }

    /// Number of occurrences of `needle` in all files under `tree` (tests plant a fake key).
    public static func count(_ needle: Data, in tree: URL) -> Int {
        guard !needle.isEmpty else { return 0 }
        return files(tree).reduce(0) { n, f in
            var c = 0, from = f.1.startIndex
            while let r = f.1.range(of: needle, in: from..<f.1.endIndex) { c += 1; from = r.upperBound }
            return n + c
        }
    }

    static func files(_ tree: URL) -> [(String, Data)] {
        var out: [(String, Data)] = []
        guard let en = FileManager.default.enumerator(atPath: tree.path) else { return out }
        while let rel = en.nextObject() as? String {
            let p = tree.appendingPathComponent(rel).path
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, let d = FileManager.default.contents(atPath: p) else { continue }
            out.append((rel, d))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
