import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct SpeakLanguageSelectionTests {
    @Test func sourceChangeKeepsGermanAndReplacesInvalidTargets() {
        #expect(SpeakSourceLanguage.allCases == [.zh, .en, .fr])
        #expect(SpeakSourceLanguage.zh.targets == [.en, .de, .fr])
        #expect(SpeakSourceLanguage.en.targets == [.zh, .de, .fr])
        #expect(SpeakSourceLanguage.fr.targets == [.zh, .en, .de])
        #expect(SpeakLanguageSelection().selectingSource(.en) == .init(source: .en, target: .zh))
        #expect(SpeakLanguageSelection(source: .en, target: .zh).selectingSource(.zh) == .init())
        #expect(SpeakLanguageSelection(target: .de).selectingSource(.en).target == .de)
        #expect(SpeakLanguageSelection(source: .en, target: .de).selectingSource(.zh).target == .de)
        #expect(SpeakLanguageSelection(source: .en, target: .en).target == .zh)
        #expect(SpeakLanguageSelection(source: .en, target: .fr).selectingSource(.fr).target == .zh)
        #expect(SpeakLanguageSelection(source: .fr, target: .de).selectingSource(.en).target == .de)
    }

    @Test func preferencesMigrateLegacyMeetingTargetAndKeepPhoneIndependent() throws {
        let suite = "SpeakLanguageSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("de", forKey: "speak.targetLanguage")
        #expect(SpeakLanguagePreferences.load(.meeting, defaults: defaults) == .init(target: .de))
        #expect(SpeakLanguagePreferences.load(.phone, defaults: defaults) == .init())
        let phone = SpeakLanguageSelection(source: .fr, target: .zh)
        SpeakLanguagePreferences.save(phone, for: .phone, defaults: defaults)
        #expect(SpeakLanguagePreferences.load(.phone, defaults: defaults) == phone)
        #expect(SpeakLanguagePreferences.load(.meeting, defaults: defaults) == .init(target: .de))
        defaults.set("de", forKey: "speak.sourceLanguage")
        defaults.set("zh", forKey: "speak.targetLanguage")
        #expect(SpeakLanguagePreferences.load(.meeting, defaults: defaults) == .init())
    }

    @Test func subtitleSamplesFollowAllNineDirectionsInBothScenes() {
        func prefix(_ language: Lang) -> String {
            switch language { case .zh: "周二"; case .en: "Tuesday"; case .de: "Dienstag"; case .fr: "Mardi" }
        }
        for phone in [false, true] {
            for source in SpeakSourceLanguage.allCases {
                for target in source.targets {
                    let sample = SubtitleSpeakingSample(phone: phone, languages: .init(source: source, target: target))
                    #expect(sample.source.hasPrefix(prefix(source.lang)))
                    #expect(sample.translation.hasPrefix(prefix(target.lang)))
                    let session = MTSession.speak(source: source.lang, target: target.lang)
                    #expect(session?.isSpeak == true)
                    #expect(session?.direction == Direction(source: source.lang, target: target.lang))
                }
            }
        }
        #expect(MTSession.allCases.filter(\.isSpeak).count == 9)
        #expect(MTSession.speak(source: .de, target: .fr) == nil)
        #expect(MTSession.speak(source: .fr, target: .fr) == nil)
    }
}
