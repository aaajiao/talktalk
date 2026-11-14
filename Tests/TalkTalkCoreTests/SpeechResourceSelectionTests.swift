import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct SpeechResourceSelectionTests {
    @Test func baseLanguagesStayRequiredAndOptionalResourcesDoNotBlockReadiness() {
        let base = SpeechResourceSelection()
        #expect(base.orderedLanguages == [.zh, .en])
        #expect(base.selecting(.zh, enabled: false) == base)
        #expect(base.selecting(.en, enabled: false) == base)
        #expect(base.isReady(installed: [.zh, .en]))
        #expect(!base.isReady(installed: [.en, .de, .fr]))
        #expect(base.missingLanguages(installed: [.zh]) == [.en])
        #expect(base.missingLanguages(installed: [.zh, .en]).isEmpty)
        let french = base.selecting(.fr, enabled: true)
        #expect(!french.isReady(installed: [.zh, .en, .de]))
        #expect(french.missingLanguages(installed: [.zh, .en, .de]) == [.fr])
        #expect(french.selecting(.fr, enabled: false).isReady(installed: [.zh, .en]))
        #expect(base.selecting(.de, enabled: true).missingLanguages(installed: [.zh, .en]) == [.de])
    }

    @Test func oldInstallationsDefaultToBaseAndExplicitOptionalChoicesSurviveRelaunch() throws {
        let name = "SpeechResourceSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // A previously chosen scene direction does not silently opt in to resource downloads.
        defaults.set("de", forKey: "meeting.listen.sourceLanguage")
        #expect(SpeechResourceSelection.load(defaults: defaults).languages == [.zh, .en])
        #expect(defaults.object(forKey: SpeechResourceSelection.preferenceKey) == nil)
        let selected = SpeechResourceSelection().selecting(.de, enabled: true).selecting(.fr, enabled: true)
        selected.save(defaults: defaults)
        #expect(SpeechResourceSelection.load(defaults: defaults) == selected)
        let withoutFrench = selected.selecting(.fr, enabled: false)
        withoutFrench.save(defaults: defaults)
        #expect(defaults.stringArray(forKey: SpeechResourceSelection.preferenceKey) == ["zh", "en", "de"])
        #expect(SpeechResourceSelection.load(defaults: defaults) == withoutFrench)
        #expect(defaults.string(forKey: "meeting.listen.sourceLanguage") == "de")
    }

    @Test func invalidOrIncompleteSavedSelectionCannotRemoveTheBase() throws {
        let name = "SpeechResourceSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["fr", "unsupported", "fr"], forKey: SpeechResourceSelection.preferenceKey)
        #expect(SpeechResourceSelection.load(defaults: defaults).orderedLanguages == [.zh, .en, .fr])
        defaults.set([String](), forKey: SpeechResourceSelection.preferenceKey)
        #expect(SpeechResourceSelection.load(defaults: defaults).orderedLanguages == [.zh, .en])
        defaults.set("invalid", forKey: SpeechResourceSelection.preferenceKey)
        #expect(SpeechResourceSelection.load(defaults: defaults).orderedLanguages == [.zh, .en])
    }
}
