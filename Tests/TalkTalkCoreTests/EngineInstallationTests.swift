import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore

/// §7.5 items 1–2 on a temporary engine home with small fake pins (no real model files).
@Suite(.temporaryFiles) struct EngineInstallationTests {
    static let ttsRev = String(repeating: "a", count: 40)
    static let ttsOldRev = String(repeating: "b", count: 40)
    static let asrRev = String(repeating: "c", count: 40)
    static let lock = String(repeating: "d", count: 64)

    static let pins: [EnginePins.Model] = [
        .init(key: "tts-x", repo: "org/TTS-X", revision: ttsRev, compatRevisions: [ttsOldRev], role: "tts",
              license: "MIT", bytes: 7, fileCount: 2,
              files: [.init(path: "config.json", bytes: 2), .init(path: "sub/model.safetensors", bytes: 5)]),
        .init(key: "asr-y", repo: "org/ASR-Y", revision: asrRev, compatRevisions: [], role: "asr",
              license: "MIT", bytes: 3, fileCount: 1, files: [.init(path: "model.safetensors", bytes: 3)]),
    ]

    /// A complete install of both models at their recommended revisions.
    struct Home {
        let url: URL
        init(ttsRev: String = EngineInstallationTests.ttsRev) throws {
            url = try TestTemporaryDirectory.make(prefix: "tt-inst")
            let fm = FileManager.default
            try fm.createDirectory(at: url.appendingPathComponent("python"), withIntermediateDirectories: true)
            try fm.createDirectory(at: url.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
            try Data("3.12.15".utf8).write(to: url.appendingPathComponent("python/.talktalk-python"))
            try Data("lock=x".utf8).write(to: url.appendingPathComponent("venv/.talktalk-venv"))
            let py = url.appendingPathComponent("venv/bin/python3")
            try Data("#!/bin/sh\n".utf8).write(to: py)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
            try writeModel(dir: "TTS-X@\(ttsRev.prefix(12))", rev: ttsRev,
                           files: ["config.json": 2, "sub/model.safetensors": 5])
            try writeModel(dir: "ASR-Y@\(EngineInstallationTests.asrRev.prefix(12))", rev: EngineInstallationTests.asrRev,
                           files: ["model.safetensors": 3])
            try writeRecord(ttsRev: ttsRev)
        }

        func writeModel(dir: String, rev: String, files: [String: Int]) throws {
            let d = url.appendingPathComponent("models/\(dir)")
            for (path, n) in files {
                let f = d.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: n).write(to: f)
            }
            try Data("\(rev)\nkey=x repo=y verified_at=now\n".utf8).write(to: d.appendingPathComponent(".talktalk-verified"))
        }

        func writeRecord(ttsRev: String, lock: String = EngineInstallationTests.lock, api: Int = 2, version: Int = 1) throws {
            let asr = EngineInstallationTests.asrRev
            let json = """
            {"version": \(version), "profile": "max", "engine_api": \(api), "runtime": "python-mlx", "flavour": "main",
             "lock_sha256": "\(lock)", "mlx_audio_commit": "f65753b",
             "roles": {"tts": {"id": "tts-x", "rev": "\(ttsRev)"}, "asr": {"id": "asr-y", "rev": "\(asr)"}},
             "models": [
               {"id": "tts-x", "repo": "org/TTS-X", "rev": "\(ttsRev)", "role": "tts", "dir": "TTS-X@\(ttsRev.prefix(12))"},
               {"id": "asr-y", "repo": "org/ASR-Y", "rev": "\(asr)", "role": "asr", "dir": "ASR-Y@\(asr.prefix(12))"}],
             "installed_at": "2026-11-04T20:32:11Z"}
            """
            try Data(json.utf8).write(to: url.appendingPathComponent("install.json"))
        }

        func setPythonVersion(_ version: String) throws {
            let path = url.appendingPathComponent("install.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            json["python"] = ["version": version, "release": "fixture", "sha256": "fixture-sha"]
            try JSONSerialization.data(withJSONObject: json).write(to: path)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    func inst(_ h: Home, profiles: [String: [String]] = ["max": ["tts-x", "asr-y"]],
              recommendedPythonVersion: String = EnginePins.pythonVersion) -> EngineInstallation {
        EngineInstallation(engineHome: h.url, lockCompat: [Self.lock], engineAPI: 2, pins: Self.pins,
                           profiles: profiles, recommendedPythonVersion: recommendedPythonVersion)
    }

    @Test(arguments: ["3.14.10", "3.15.1", "4.0.0", "development"])
    func currentNewerOrUnknownPythonKeepsExistingCompatibility(_ version: String) throws {
        let h = try Home(); defer { h.remove() }
        try h.setPythonVersion(version)
        let result = inst(h, recommendedPythonVersion: "3.14.10").check()
        #expect(result.state == .installed(profile: "max", models: ["asr-y", "tts-x"]))
        #expect(result.record?.python?.version == version)
        #expect(result.record?.python?.release == "fixture")
    }

    @Test func compatibleOlderPythonOffersOnlyRuntimeUpdateWithoutChangingModels() throws {
        let h = try Home(); defer { h.remove() }
        try h.setPythonVersion("3.12.15")
        let recordURL = h.url.appendingPathComponent("install.json")
        let before = try Data(contentsOf: recordURL)
        let result = inst(h, profiles: ["standard": ["tts-x", "asr-y"]], recommendedPythonVersion: "3.14.10").check()
        #expect(result.state == .outdated(profile: "standard", models: []))
        #expect(result.state.canStartEngine)
        #expect(result.record?.roles["tts"]?.id == "tts-x" && result.record?.roles["asr"]?.id == "asr-y")
        #expect(result.record?.roles["tts"]?.rev == Self.ttsRev)
        #expect(try Data(contentsOf: recordURL) == before)
    }

    @Test func legacyRecordWithoutPythonMetadataRemainsCompatible() throws {
        let h = try Home(); defer { h.remove() }
        let result = inst(h, recommendedPythonVersion: "3.14.10").check()
        #expect(result.record?.python == nil)
        #expect(result.state == .installed(profile: "max", models: ["asr-y", "tts-x"]))
        #expect(result.state.canStartEngine)
    }

    @Test func oldLabelIsClassifiedByActiveRolesWithoutRewritingRecord() throws {
        let h = try Home(); defer { h.remove() }
        let url = h.url.appendingPathComponent("install.json")
        let before = try Data(contentsOf: url)
        let result = inst(h, profiles: ["max": ["tts-x"], "standard": ["tts-x", "asr-y"]]).check()
        #expect(result.state == .installed(profile: "standard", models: ["asr-y", "tts-x"]))
        #expect(result.state.canStartEngine)
        #expect(result.record?.profile == "max")
        #expect(result.record?.roles["asr"]?.id == "asr-y")
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func outdatedInstallAlsoUsesEffectiveProfile() throws {
        let h = try Home(ttsRev: Self.ttsOldRev); defer { h.remove() }
        let state = inst(h, profiles: ["standard": ["tts-x", "asr-y"]]).check().state
        #expect(state == .outdated(profile: "standard", models: ["tts-x"]))
        #expect(state.canStartEngine)
    }

    @Test func customCompositionIsRunnableWithoutClaimingTheDeclaredPreset() throws {
        let h = try Home(); defer { h.remove() }
        let state = inst(h, profiles: ["max": ["tts-x"]]).check().state
        #expect(state == .installed(profile: EngineProfile.customID, models: ["asr-y", "tts-x"]))
        #expect(state.canStartEngine)
    }

    @Test func intentionalAppleRecognitionIgnoresUnusedDownloadedASR() throws {
        let h = try Home(); defer { h.remove() }
        let url = h.url.appendingPathComponent("install.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var roles = try #require(json["roles"] as? [String: Any])
        roles.removeValue(forKey: "asr")
        json["roles"] = roles
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let result = inst(h, profiles: ["max": ["tts-x", "asr-y"], "compact16": ["tts-x"]]).check()
        #expect(result.state == .installed(profile: "compact16", models: ["tts-x"]))
        #expect(result.record?.models.count == 2)
        #expect(result.record?.roles["asr"] == nil)
        // Removing a role can also create a legal custom composition.
        #expect(inst(h).check().state == .installed(profile: EngineProfile.customID, models: ["tts-x"]))
    }

    @Test func completeInstallIsInstalled() throws {
        let h = try Home(); defer { h.remove() }
        let (state, record) = inst(h).check()
        #expect(state == .installed(profile: "max", models: ["asr-y", "tts-x"]))
        #expect(state.canStartEngine)
        #expect(record?.roles["tts"]?.rev == Self.ttsRev)
    }

    @Test func modelReadinessUsesCurrentFilesRatherThanInstallationRecord() throws {
        let h = try Home(); defer { h.remove() }
        let installation = inst(h)
        let modelURL = h.url.appendingPathComponent("models/ASR-Y@\(Self.asrRev.prefix(12))/model.safetensors")
        #expect(installation.isModelReady(id: "asr-y"))
        try FileManager.default.removeItem(at: modelURL)
        #expect(!installation.isModelReady(id: "asr-y")) // stale record cannot claim ready
        try Data(repeating: 0x41, count: 3).write(to: modelURL)
        try FileManager.default.removeItem(at: installation.recordURL)
        #expect(installation.isModelReady(id: "asr-y")) // a verified extra download is reusable
        #expect(!installation.isModelReady(id: "unknown"))
    }

    @Test func modelReadinessRejectsOldRevisionWrongStampAndWrongSize() throws {
        let h = try Home(ttsRev: Self.ttsOldRev); defer { h.remove() }
        let installation = inst(h)
        #expect(!installation.isModelReady(id: "tts-x"))
        let asrDir = h.url.appendingPathComponent("models/ASR-Y@\(Self.asrRev.prefix(12))")
        let stamp = asrDir.appendingPathComponent(".talktalk-verified")
        try Data("wrong\n".utf8).write(to: stamp)
        #expect(!installation.isModelReady(id: "asr-y"))
        try Data("\(Self.asrRev)\n".utf8).write(to: stamp)
        try Data(repeating: 0x41, count: 4).write(to: asrDir.appendingPathComponent("model.safetensors"))
        #expect(!installation.isModelReady(id: "asr-y"))
        try FileManager.default.removeItem(at: stamp)
        #expect(!installation.isModelReady(id: "asr-y"))
    }

    @Test func emptyHomeIsNotInstalled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tt-none-\(UUID().uuidString)")
        let s = EngineInstallation(engineHome: url, lockCompat: [Self.lock], engineAPI: 2, pins: Self.pins).check().state
        #expect(s == .notInstalled)
        #expect(!s.canStartEngine)
    }

    @Test func prevFileMeansUnfinished() throws {
        let h = try Home(); defer { h.remove() }
        try Data("{}".utf8).write(to: h.url.appendingPathComponent("install.json.prev"))
        #expect(inst(h).check().state == .unfinished)
    }

    @Test func unknownLockOrApiIsIncompatible() throws {
        let h = try Home(); defer { h.remove() }
        try h.writeRecord(ttsRev: Self.ttsRev, lock: String(repeating: "e", count: 64))
        guard case .incompatible = inst(h).check().state else { Issue.record("lock"); return }
        try h.writeRecord(ttsRev: Self.ttsRev, api: 1)
        guard case .incompatible(let why) = inst(h).check().state else { Issue.record("api"); return }
        #expect(why.contains("engine API 1"))
        try h.writeRecord(ttsRev: Self.ttsRev, version: 2)
        guard case .incompatible = inst(h).check().state else { Issue.record("version"); return }
    }

    /// "上一版安装 + 新 app" (§7.4): an older revision still in the compat list runs, with a badge.
    @Test func previousRevisionInCompatListIsOutdated() throws {
        let h = try Home(ttsRev: Self.ttsOldRev); defer { h.remove() }
        let s = inst(h).check().state
        #expect(s == .outdated(profile: "max", models: ["tts-x"]))
        #expect(s.canStartEngine)
    }

    @Test func revisionOutsideCompatListIsIncompatible() throws {
        let other = String(repeating: "f", count: 40)
        let h = try Home(ttsRev: other); defer { h.remove() }
        guard case .incompatible(let why) = inst(h).check().state else { Issue.record("rev"); return }
        #expect(why.contains("tts-x"))
    }

    @Test func missingFileIsIncompleteWithPinnedBytes() throws {
        let h = try Home(); defer { h.remove() }
        try FileManager.default.removeItem(at: h.url.appendingPathComponent("models/TTS-X@\(Self.ttsRev.prefix(12))/sub/model.safetensors"))
        #expect(inst(h).check().state == .incomplete(missing: ["tts-x"], bytes: 5))
    }

    @Test func missingModelDirIsIncomplete() throws {
        let h = try Home(); defer { h.remove() }
        try FileManager.default.removeItem(at: h.url.appendingPathComponent("models/ASR-Y@\(Self.asrRev.prefix(12))"))
        #expect(inst(h).check().state == .incomplete(missing: ["asr-y"], bytes: 3))
    }

    @Test func wrongSizeIsDamaged() throws {
        let h = try Home(); defer { h.remove() }
        try Data(repeating: 0, count: 9).write(to: h.url.appendingPathComponent("models/TTS-X@\(Self.ttsRev.prefix(12))/config.json"))
        guard case .damaged(let why) = inst(h).check().state else { Issue.record("size"); return }
        #expect(why.contains("config.json"))
    }

    @Test func stampsAndInterpreterAreRequired() throws {
        let h = try Home(); defer { h.remove() }
        try FileManager.default.removeItem(at: h.url.appendingPathComponent("venv/.talktalk-venv"))
        guard case .damaged = inst(h).check().state else { Issue.record("stamp"); return }
        let h2 = try Home(); defer { h2.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: h2.url.appendingPathComponent("venv/bin/python3").path)
        guard case .damaged = inst(h2).check().state else { Issue.record("exec"); return }
    }

    @Test func verifiedStampMustNameTheRevision() throws {
        let h = try Home(); defer { h.remove() }
        try Data("\(Self.ttsOldRev)\n".utf8).write(to: h.url.appendingPathComponent("models/TTS-X@\(Self.ttsRev.prefix(12))/.talktalk-verified"))
        guard case .damaged = inst(h).check().state else { Issue.record("stamp rev"); return }
    }

    @Test func oversizedRecordIsDamaged() throws {
        let h = try Home(); defer { h.remove() }
        try Data(repeating: 0x20, count: EngineInstallation.maxRecordBytes + 1).write(to: h.url.appendingPathComponent("install.json"))
        guard case .damaged = inst(h).check().state else { Issue.record("size"); return }
    }

    @Test func readyIsComparedWithInstallJSON() throws {
        let h = try Home(); defer { h.remove() }
        let record = try #require(inst(h).check().record)
        let ok = EngineInstallation.readyMismatches(
            record: record, engine: "talktalk-engine", api: 2, runtime: "python-mlx",
            models: ["tts": ("tts-x", Self.ttsRev), "asr": ("asr-y", Self.asrRev)], roles: ["tts", "asr"])
        #expect(ok.isEmpty)
        let bad = EngineInstallation.readyMismatches(
            record: record, engine: "talktalk-engine", api: 1, runtime: "python-mlx",
            models: ["tts": ("tts-x", Self.ttsOldRev)], roles: ["tts", "asr"])
        #expect(bad.count == 3)   // api, tts rev, asr missing
    }

    /// The real pins carry every file with its size (gen-pins.sh).
    @Test func realPinsListFiles() {
        for m in EnginePins.models {
            #expect(m.files.count == m.fileCount, "\(m.key)")
            #expect(m.files.reduce(0) { $0 + $1.bytes } == m.bytes, "\(m.key)")
        }
    }
}
