import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore

@Suite(.temporaryFiles) struct DiagnosticsStoreTests {
    private func makeEntry(_ name: String, in root: URL) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("data"))
    }

    @Test func countsDataAndDeletesEverythingIncludingFinderFiles() throws {
        let scratch = try makeScratchDir("diagnostics-store")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("diagnostics")
        try makeEntry("20261109T120000-abc123", in: root)
        try makeEntry("\(SubtitleAnalysisTrace.directoryPrefix)2026", in: root)
        try makeEntry("\(SubtitleAnalysisTrace.directoryPrefix)2027", in: root)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))

        let store = DiagnosticsStore(root: root)
        #expect(store.inventory() == .init(recordings: 1, analyses: 2))
        #expect(store.removeAll().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func aFolderHoldingOnlyFinderFilesHasNothingToDelete() throws {
        let scratch = try makeScratchDir("diagnostics-store")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data().write(to: scratch.appendingPathComponent(".DS_Store"))
        #expect(DiagnosticsStore(root: scratch).inventory().total == 0)
    }

    @Test func aMissingFolderIsEmpty() throws {
        let scratch = try makeScratchDir("diagnostics-store")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = DiagnosticsStore(root: scratch.appendingPathComponent("missing"))
        #expect(store.inventory().total == 0)
        #expect(store.removeAll().isEmpty)
    }

    @Test func linksAreNeverFollowed() throws {
        let scratch = try makeScratchDir("diagnostics-store")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outside = scratch.appendingPathComponent("outside")
        try makeEntry("keep", in: outside)
        let keep = outside.appendingPathComponent("keep/data")

        let root = scratch.appendingPathComponent("diagnostics")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(DiagnosticsStore(root: root).removeAll().isEmpty)
        #expect(FileManager.default.fileExists(atPath: keep.path))

        let linkedRoot = scratch.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        #expect(DiagnosticsStore(root: linkedRoot).inventory().total == 0)
        DiagnosticsStore(root: linkedRoot).removeAll()
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }
}
