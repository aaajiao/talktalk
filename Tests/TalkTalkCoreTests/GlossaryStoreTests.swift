import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct GlossaryStoreTests {
    @Test func privateVersionedStorageAndTargetSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("talktalk-glossary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("glossary.json")
        let store = GlossaryStore(url: url)
        try store.save([.init(zh: " 术语 ", en: " term ", de: "", note: "note")])
        #expect(FileSystem.permissions(url) == 0o600)
        #expect(FileSystem.permissions(root) == 0o700)
        #expect(store.snapshot(target: .en).first?.zh == "术语")
        #expect(store.snapshot(target: .de).isEmpty)
        let second = GlossaryStore(url: url)
        #expect(second.snapshot() == store.snapshot())
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
    }
    @Test func invalidEditsDoNotReplaceSavedTerms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("talktalk-glossary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlossaryStore(url: root.appendingPathComponent("glossary.json"))
        let entry = GlossaryEntry(zh: "词", en: "word", de: "Wort")
        try store.save([entry])
        #expect(throws: GlossaryStore.Failure.self) { try store.save(Array(repeating: entry, count: 31)) }
        #expect(throws: GlossaryStore.Failure.self) { try store.save([.init(zh: "", en: "x", de: "")]) }
        #expect(store.snapshot() == [entry])
    }
    /// The editor's red outlines name exactly what the save refuses.
    @Test func missingFieldsMatchTheSaveRule() {
        let blankChinese = GlossaryEntry(zh: "  ", en: "term", de: "")
        #expect(blankChinese.lacksChinese && !blankChinese.lacksTranslation)
        let noTranslation = GlossaryEntry(zh: "词", en: " ", de: "")
        #expect(!noTranslation.lacksChinese && noTranslation.lacksTranslation)
        let germanOnly = GlossaryEntry(zh: "词", en: "", de: "Wort")
        #expect(!germanOnly.lacksChinese && !germanOnly.lacksTranslation)
    }
}
