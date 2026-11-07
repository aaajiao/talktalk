import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore

/// A fake key: key-shaped, never a real one. Planted all over a fake log tree; the bundle must
/// contain it zero times (M1 完成标准 “日志和诊断包里扫描不到 key”).
private let fakeKey = "sk-proj-FAKEtalktalkTEST0000000000000000000000"

private struct Tree {
    let root: URL
    var home: URL { root.appendingPathComponent("Application Support/TalkTalk") }
    var logs: URL { root.appendingPathComponent("Logs/TalkTalk") }
    var user: String { root.path }

    init() throws {
        root = try makeScratchDir("diag")
        let fm = FileManager.default
        for d in ["engine", "voice", ".voice-staging-1234", "transcripts", "diagnostics/s1"] {
            try fm.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: logs.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        func put(_ base: URL, _ rel: String, _ s: String) throws {
            try Data(s.utf8).write(to: base.appendingPathComponent(rel))
        }
        try put(logs, "app.log", """
            2026-11-04T10:00:00Z app start build=dev
            2026-11-04T10:00:01Z key present=true len=\(fakeKey.count)
            2026-11-04T10:00:02Z oops key=\(fakeKey)
            2026-11-04T10:00:03Z Authorization: Bearer \(fakeKey)
            2026-11-04T10:00:04Z header authorization=redacted?
            2026-11-04T10:00:05Z request {"headers":{"Authorization":"Bearer abcdefghijklmnopqrstuvwxyz"}}
            2026-11-04T10:00:06Z engine path=\(root.path)/Application Support/TalkTalk/engine
            2026-11-04T10:00:07Z subtitle 你好，今天的会议开始了
            2026-11-04T10:00:08Z OpenAI-Organization: org-123
            2026-11-04T10:00:09Z Sätze gehören nicht hierher
            """)
        try put(logs, "engine.log", "ready api=2\nCookie: session=1\nopenai_api_key \(fakeKey)\n")
        try put(logs, "engine.log.1", "rotated ok\n")
        try put(logs, "notes.txt", "not whitelisted \(fakeKey)\n")
        try put(logs.appendingPathComponent("sessions"), "2026-11-04T100000-abc.jsonl", """
            {"ev":"listen.start","lang":"en","primary":true,"t":100}
            {"ev":"cloud.req","conn":"A","t":200,"ttfb_ms":312,"x_request_id":"req_0123abcd"}
            {"ev":"mt.final","t":300,"text":"hello there everyone"}
            {"ev":"mt.final","t":301,"sentence":1,"chars":12}
            {"ev":"cloud.req","t":302,"auth":"\(fakeKey)"}
            {"ev":"listen.sentence","t":303,"nested":{"a":1}}
            {"ev":"x","t":304,"note":"你好"}
            not json at all \(fakeKey)
            """)
        try put(home, "engine/install.json", "{\"profile\":\"max\",\"home\":\"\(root.path)/x\",\"engine_api\":2}\n")
        try put(home, "driver.json", "{\"version\":\"1.0\"}\n")
        try put(home, "glossary.json", "{\"Termin\":\"会议\"}\n")
        try put(home, "voice/ref.wav", "RIFF \(fakeKey)")
        try put(home, ".voice-staging-1234/take.caf", "caf \(fakeKey)")
        try put(home, "transcripts/t1.jsonl", "{\"text\":\"你好 \(fakeKey)\"}\n")
        try put(home, "diagnostics/s1/mic.caf", "caf \(fakeKey)")
        try put(home, "diagnostics/s1/events.jsonl", "{\"ev\":\"x\",\"t\":1}\n")
        try put(logs, "capture.wav", "RIFF \(fakeKey)")
        // A symlink in the log tree pointing into voice/.
        try fm.createSymbolicLink(at: logs.appendingPathComponent("evil.log"), withDestinationURL: home.appendingPathComponent("voice/ref.wav"))
    }

    var whitelist: DiagnosticsWhitelist { DiagnosticsWhitelist(home: home, logs: logs, userHome: user) }
}

@Suite(.temporaryFiles) struct DiagnosticsWhitelistPathTests {
    @Test func verdicts() throws {
        let t = try Tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let wl = t.whitelist
        func v(_ base: URL, _ rel: String) -> DiagnosticsWhitelist.Verdict { wl.verdict(for: base.appendingPathComponent(rel)) }
        #expect(v(t.logs, "app.log") == .include(.log))
        #expect(v(t.logs, "engine.log.1") == .include(.log))
        #expect(v(t.logs, "sessions/2026-11-04T100000-abc.jsonl") == .include(.events))
        #expect(v(t.home, "engine/install.json") == .include(.record))
        #expect(v(t.home, "driver.json") == .include(.record))
        #expect(v(t.home, "voice/profile.json") == .exclude(.voice))
        #expect(v(t.home, "voice/ref.wav") == .exclude(.audio))
        #expect(v(t.home, ".voice-staging-1234/meta.json") == .exclude(.voiceStaging))
        #expect(v(t.home, "transcripts/t1.jsonl") == .exclude(.transcripts))
        #expect(v(t.home, "diagnostics/s1/events.jsonl") == .exclude(.diagnostics))
        #expect(v(t.home, "glossary.json") == .exclude(.glossary))
        #expect(v(t.home, "sysinput-restore.json") == .exclude(.notListed))
        #expect(v(t.home, "engine/venv/x.py") == .exclude(.notListed))
        #expect(v(t.logs, "capture.wav") == .exclude(.audio))
        #expect(v(t.logs, "notes.txt") == .exclude(.notListed))
        #expect(v(t.logs, "evil.log") == .exclude(.symlink))
        #expect(v(t.logs, "sessions/../../../Application Support/TalkTalk/voice/x.log") == .exclude(.voice))
        #expect(wl.verdict(for: URL(fileURLWithPath: "/etc/passwd")) == .exclude(.notListed))
    }

    @Test func symlinkedSessionsDirectoryIsExcluded() throws {
        let t = try Tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let fm = FileManager.default
        try fm.removeItem(at: t.logs.appendingPathComponent("sessions"))
        try fm.createSymbolicLink(at: t.logs.appendingPathComponent("sessions"), withDestinationURL: t.home.appendingPathComponent("transcripts"))
        try Data("{\"ev\":\"x\",\"t\":1}\n".utf8).write(to: t.home.appendingPathComponent("transcripts/z.jsonl"))
        #expect(t.whitelist.verdict(for: t.logs.appendingPathComponent("sessions/z.jsonl")) == .exclude(.symlink))
        #expect(!t.whitelist.candidates().contains { $0.kind == .events })
    }

    @Test func candidates() throws {
        let t = try Tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let paths = t.whitelist.candidates().map(\.bundlePath).sorted()
        #expect(paths == ["logs/app.log", "logs/engine.log", "logs/engine.log.1",
                          "logs/sessions/2026-11-04T100000-abc.jsonl", "records/driver.json", "records/install.json"])
    }
}

@Suite(.temporaryFiles) struct DiagnosticsWhitelistContentTests {
    @Test func eventLinesMustBeFlatTags() {
        #expect(DiagnosticsWhitelist.scrubEventLine(#"{"ev":"mt.final","t":3,"sentence":1,"approx":false}"#) != nil)
        #expect(DiagnosticsWhitelist.scrubEventLine(#"{"ev":"mt.final","t":3,"text":"hello world"}"#) == nil)
        #expect(DiagnosticsWhitelist.scrubEventLine(#"{"ev":"x","t":3,"n":{"a":1}}"#) == nil)
        #expect(DiagnosticsWhitelist.scrubEventLine(#"{"ev":"x","t":3,"a":[1]}"#) == nil)
        #expect(DiagnosticsWhitelist.scrubEventLine(#"{"ev":"x","t":3,"a":null}"#) == nil)
        #expect(DiagnosticsWhitelist.scrubEventLine(#"{"t":3}"#) == nil)
        #expect(DiagnosticsWhitelist.scrubEventLine(#"{"ev":"x","bad key":1}"#) == nil)
        #expect(DiagnosticsWhitelist.scrubEventLine("[1,2]") == nil)
        let long = String(repeating: "a", count: 65)
        #expect(DiagnosticsWhitelist.scrubEventLine(Substring(#"{"ev":"x","tag":"\#(long)"}"#)) == nil)
    }

    @Test func logLinesDropTextHeadersAndKeys() {
        let wl = DiagnosticsWhitelist(home: URL(fileURLWithPath: "/h/A"), logs: URL(fileURLWithPath: "/h/L"), userHome: "/Users/someone")
        #expect(wl.scrubLogLine("ready api=2 ms=31") == "ready api=2 ms=31")
        #expect(wl.scrubLogLine("path=/Users/someone/Library/x") == "path=~/Library/x")
        #expect(wl.scrubLogLine("字幕 hello") == nil)
        #expect(wl.scrubLogLine("Grüße") == nil)
        #expect(wl.scrubLogLine("Authorization: Bearer x") == nil)
        #expect(wl.scrubLogLine(#"{"authorization" : "x"}"#) == nil)
        #expect(wl.scrubLogLine("cookie=abc") == nil)
        #expect(wl.scrubLogLine("OpenAI-Project: proj_1") == nil)
        #expect(wl.scrubLogLine("key \(fakeKey)") == nil)
        #expect(wl.scrubLogLine("token Bearer abcdefghijklmnopqrstu") == nil)
        #expect(wl.scrubLogLine("sk-short is fine") == "sk-short is fine")
        #expect(wl.scrubLogLine(Substring(String(repeating: "x", count: 5000))) == nil)
    }
}

@Suite(.temporaryFiles) struct DiagnosticsBundleTests {
    @Test func fakeKeyScanFindsNothingAndNoTextLeaves() throws {
        let t = try Tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let key = Data(fakeKey.utf8)
        // The plant worked: the source trees are full of the key.
        #expect(DiagnosticsBundle.count(key, in: t.logs) >= 5)
        #expect(DiagnosticsBundle.count(key, in: t.home) >= 4)

        let staging = t.root.appendingPathComponent("tmp/bundle")
        let extras = ["versions.json": Data(#"{"app":"0.1","engine_api":2}"#.utf8),
                      "devices.json": Data(#"["MacBook Pro Microphone","TalkTalk Mic"]"#.utf8)]
        let m = try DiagnosticsBundle.assemble(t.whitelist, extras: extras, into: staging)

        // M1: zero hits for the fake key in the bundle (and in the temp tree that made it).
        #expect(DiagnosticsBundle.count(key, in: staging) == 0)
        #expect(DiagnosticsBundle.count(key, in: t.root.appendingPathComponent("tmp")) == 0)
        #expect(DiagnosticsBundle.secretScan(staging).isEmpty)

        let files = DiagnosticsBundle.files(staging)
        #expect(files.map(\.0) == ["devices.json", "logs/app.log", "logs/engine.log", "logs/engine.log.1",
                                   "logs/sessions/2026-11-04T100000-abc.jsonl", "manifest.json",
                                   "records/driver.json", "records/install.json", "versions.json"])
        for (path, data) in files {
            let s = String(decoding: data, as: UTF8.self)
            // No text content: nothing outside ASCII, no transcript words, no header, no home path.
            if path != "devices.json" { #expect(data.allSatisfy { $0 < 0x80 }, "non-ASCII in \(path)") }
            #expect(!s.contains("hello there"), "text in \(path)")
            #expect(!DiagnosticsWhitelist.containsHeader(s), "header in \(path)")
            #expect(!s.contains(t.root.path), "home path in \(path)")
            #expect(FileSystem.permissions(staging.appendingPathComponent(path)) == 0o600)
        }
        #expect(FileSystem.permissions(staging) == 0o700)
        #expect(FileSystem.permissions(staging.appendingPathComponent("logs/sessions")) == 0o700)

        let app = String(decoding: files.first { $0.0 == "logs/app.log" }!.1, as: UTF8.self)
        #expect(app.contains("app start build=dev"))
        #expect(app.contains("engine path=~/Application Support"))
        let events = String(decoding: files.first { $0.0 == "logs/sessions/2026-11-04T100000-abc.jsonl" }!.1, as: UTF8.self)
        #expect(events.split(separator: "\n").count == 3)
        #expect(events.contains("req_0123abcd"))
        let ev = m.files.first { $0.path == "logs/sessions/2026-11-04T100000-abc.jsonl" }!
        #expect(ev.keptLines == 3 && ev.droppedLines == 5)
        let log = m.files.first { $0.path == "logs/app.log" }!
        #expect(log.keptLines == 3 && log.droppedLines == 7)
    }

    @Test func aKeyInAGeneratedExtraRefusesTheBundle() throws {
        let t = try Tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let staging = t.root.appendingPathComponent("tmp/bundle2")
        #expect(throws: DiagnosticsBundle.Failure.secretFound(["versions.json"])) {
            try DiagnosticsBundle.assemble(t.whitelist, extras: ["versions.json": Data("k=\(fakeKey)".utf8)], into: staging)
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func extraNamesCannotEscapeTheBundle() throws {
        let t = try Tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let staging = t.root.appendingPathComponent("tmp/bundle3")
        for bad in ["../x.json", "a/b.json", ".hidden", "manifest.json", ""] {
            #expect(throws: DiagnosticsBundle.Failure.unsafeExtraName(bad)) {
                try DiagnosticsBundle.assemble(t.whitelist, extras: [bad: Data()], into: staging)
            }
        }
    }
}
