import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore

/// A fresh directory owned by the current test scope (explicit removal is also allowed).
func makeScratchDir(_ tag: String) throws -> URL {
    try TestTemporaryDirectory.make(prefix: "tt-\(tag)")
}

@Suite(.temporaryFiles) struct FileSystemTests {
    @Test func createsNestedPrivateDirectoriesExcludedFromBackup() throws {
        let root = try makeScratchDir("fs")
        defer { try? FileManager.default.removeItem(at: root) }
        let leaf = root.appendingPathComponent("a/b/diagnostics")
        try FileSystem.ensurePrivateDirectory(leaf)
        #expect(FileSystem.permissions(leaf) == 0o700)
        #expect(FileSystem.permissions(root.appendingPathComponent("a/b")) == 0o700)
        #expect(FileSystem.permissions(root.appendingPathComponent("a")) == 0o700)
        #expect(FileSystem.isExcludedFromBackup(leaf))
        #expect(!FileSystem.isExcludedFromBackup(root.appendingPathComponent("a")))
        // Idempotent.
        try FileSystem.ensurePrivateDirectory(leaf)
        #expect(FileSystem.permissions(leaf) == 0o700)
    }

    @Test func tightensAnExistingDirectory() throws {
        let root = try makeScratchDir("fs")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = root.appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(FileSystem.permissions(d) == 0o755)
        try FileSystem.ensurePrivateDirectory(d)
        #expect(FileSystem.permissions(d) == 0o700)
        #expect(FileSystem.isExcludedFromBackup(d))
        try FileSystem.ensurePrivateDirectory(d, excludeFromBackup: false)
        #expect(FileSystem.isExcludedFromBackup(d))   // never cleared implicitly
    }

    @Test func refusesSymlinksAndFiles() throws {
        let root = try makeScratchDir("fs")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("diagnostics")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: FileSystem.Failure.symlink(link.path)) { try FileSystem.ensurePrivateDirectory(link) }
        let file = root.appendingPathComponent("plain")
        try Data().write(to: file)
        #expect(throws: FileSystem.Failure.notADirectory(file.path)) { try FileSystem.ensurePrivateDirectory(file) }
    }

    @Test func atomicWriteIs0600AndReplacesWholeFiles() throws {
        let root = try makeScratchDir("fs")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("glossary.json")
        try Data("old contents that are longer".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path)
        try FileSystem.writeAtomically(Data("new".utf8), to: f)
        #expect(try Data(contentsOf: f) == Data("new".utf8))
        #expect(FileSystem.permissions(f) == 0o600)
        try FileSystem.writeAtomically(Data(), to: f)
        #expect(try Data(contentsOf: f).isEmpty)
        // No temporary files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["glossary.json"])
    }

    @Test func atomicWriteRefusesASymlinkAndLeavesItsTarget() throws {
        let root = try makeScratchDir("fs")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        let link = root.appendingPathComponent("install.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: FileSystem.Failure.symlink(link.path)) { try FileSystem.writeAtomically(Data("x".utf8), to: link) }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        #expect(FileSystem.isSymlink(link))
    }

    @Test func appendingHandleIs0600AndRefusesSymlinks() throws {
        let root = try makeScratchDir("fs")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("events.jsonl")
        let h = try FileSystem.openForAppending(f)
        h.write(Data("a\n".utf8))
        try h.close()
        let h2 = try FileSystem.openForAppending(f)
        h2.write(Data("b\n".utf8))
        try h2.close()
        #expect(try String(contentsOf: f, encoding: .utf8) == "a\nb\n")
        #expect(FileSystem.permissions(f) == 0o600)
        let link = root.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f)
        #expect(throws: FileSystem.Failure.symlink(link.path)) { _ = try FileSystem.openForAppending(link) }
    }

    @Test func permissionsOfMissingPathIsNil() {
        #expect(FileSystem.permissions(URL(fileURLWithPath: "/nonexistent/tt-\(UUID().uuidString)")) == nil)
    }
}
