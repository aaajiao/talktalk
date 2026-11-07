import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore

@Suite(.temporaryFiles) struct SubtitleAnalysisTraceTests {
    @Test func defaultOffPrivateAndBounded() throws {
        let scratch = try makeScratchDir("subtitle-analysis")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("diagnostics")
        let row = Data("{\"source\":\"test\"}".utf8)
        let trace = SubtitleAnalysisTrace(root: root, maxBytes: row.count + 1, maxRecords: 2)
        #expect(try trace.append(row, at: 1) == .ignored)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let file = try trace.start(at: 100)
        #expect(FileSystem.permissions(file) == 0o600)
        #expect(FileSystem.permissions(file.deletingLastPathComponent()) == 0o700)
        #expect(FileSystem.isExcludedFromBackup(file.deletingLastPathComponent()))
        #expect(try trace.append(row, at: 99) == .ignored)
        #expect(try trace.append(row, at: 100) == .written)
        #expect(try trace.append(row, at: 101) == .limitReached)
        #expect(try trace.append(row, at: 102) == .ignored)
        #expect(try Data(contentsOf: file) == row + Data([0x0a]))
        trace.stop()
        #expect(try trace.append(row, at: 103) == .ignored)
    }
}
