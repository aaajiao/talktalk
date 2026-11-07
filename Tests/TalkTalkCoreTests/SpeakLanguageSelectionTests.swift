import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct SpeakLanguageSelectionTests {
    @Test func sourceChangeKeepsGermanAndReplacesInvalidTargets() {
        #expect(SpeakSourceLanguage.allCases == [.zh, .en])
        #expect(SpeakSourceLanguage.zh.targets == [.en, .de])
        #expect(SpeakSourceLanguage.en.targets == [.zh, .de])
        #expect(SpeakLanguageSelection().selectingSource(.en) == .init(source: .en, target: .zh))
        #expect(SpeakLanguageSelection(source: .en, target: .zh).selectingSource(.zh) == .init())
        #expect(SpeakLanguageSelection(target: .de).selectingSource(.en).target == .de)
        #expect(SpeakLanguageSelection(source: .en, target: .de).selectingSource(.zh).target == .de)
        #expect(SpeakLanguageSelection(source: .en, target: .en).target == .zh)
    }

    @Test func preferencesMigrateLegacyMeetingTargetAndKeepPhoneIndependent() throws {
        let suite = "SpeakLanguageSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("de", forKey: "speak.targetLanguage")
        #expect(SpeakLanguagePreferences.load(.meeting, defaults: defaults) == .init(target: .de))
        #expect(SpeakLanguagePreferences.load(.phone, defaults: defaults) == .init())
        let phone = SpeakLanguageSelection(source: .en, target: .zh)
        SpeakLanguagePreferences.save(phone, for: .phone, defaults: defaults)
        #expect(SpeakLanguagePreferences.load(.phone, defaults: defaults) == phone)
        #expect(SpeakLanguagePreferences.load(.meeting, defaults: defaults) == .init(target: .de))
        defaults.set("de", forKey: "speak.sourceLanguage")
        defaults.set("zh", forKey: "speak.targetLanguage")
        #expect(SpeakLanguagePreferences.load(.meeting, defaults: defaults) == .init())
    }

    @Test func subtitleSamplesFollowAllFourDirectionsInBothScenes() {
        for phone in [false, true] {
            for source in SpeakSourceLanguage.allCases {
                for target in source.targets {
                    let sample = SubtitleSpeakingSample(phone: phone, languages: .init(source: source, target: target))
                    #expect(sample.source.hasPrefix(source == .zh ? "周二" : "Tuesday"))
                    let prefix = target == .zh ? "周二" : target == .en ? "Tuesday" : "Dienstag"
                    #expect(sample.translation.hasPrefix(prefix))
                }
            }
        }
    }
}
