import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct ListenLanguageSelectionTests {
    @Test func allScenesOfferSixDirectionsAndAtomicSwap() {
        var directions: [String] = []
        for source in Lang.allCases {
            let selection = ListenLanguageSelection(source: source)
            #expect(selection.targets.count == 2)
            for target in selection.targets {
                let pair = ListenLanguageSelection(source: source, target: target)
                directions.append("\(pair.source.rawValue)-\(pair.target.rawValue)")
                #expect(pair.source != pair.target)
                #expect(pair.swapped.source == target && pair.swapped.target == source)
                #expect(pair.swapped.swapped == pair)
                for scope in ListenLanguagePreferences.Scope.allCases {
                    #expect(ListenLanguagePreferences.normalized(pair, for: scope) == pair)
                }
            }
        }
        #expect(Set(directions) == Set(["zh-en", "zh-de", "en-zh", "en-de", "de-zh", "de-en"]))
        #expect(ListenLanguageSelection(source: .en, target: .de).selectingSource(.zh).target == .de)
        #expect(ListenLanguageSelection(source: .en, target: .zh).selectingSource(.zh).target == .en)
        #expect(ListenLanguageSelection(source: .de, target: .en).selectingTarget(.de).target == .zh)
    }

    @Test func allScenesPersistSixDirectionsWithoutNarrowing() throws {
        let suite = "ListenLanguageSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for scope in ListenLanguagePreferences.Scope.allCases {
            for source in Lang.allCases {
                for target in Lang.allCases where source != target {
                    let pair = ListenLanguageSelection(source: source, target: target)
                    ListenLanguagePreferences.save(pair, for: scope, defaults: defaults)
                    #expect(ListenLanguagePreferences.load(scope, defaults: defaults) == pair)
                }
            }
        }
    }

    @Test func migrationSnapshotsSharedPreferenceAndScenesStayIndependent() throws {
        let suite = "ListenLanguageSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("de", forKey: ListenLanguagePreferences.legacySourceKey)
        for scope in ListenLanguagePreferences.Scope.allCases {
            #expect(ListenLanguagePreferences.load(scope, defaults: defaults) == .init(source: .de))
        }
        defaults.set("en", forKey: ListenLanguagePreferences.legacySourceKey)
        #expect(ListenLanguagePreferences.load(.meeting, defaults: defaults) == .init(source: .de))
        ListenLanguagePreferences.save(.init(source: .zh, target: .en), for: .video, defaults: defaults)
        ListenLanguagePreferences.save(.init(source: .zh, target: .de), for: .phone, defaults: defaults)
        #expect(ListenLanguagePreferences.load(.video, defaults: defaults) == .init(source: .zh, target: .en))
        #expect(ListenLanguagePreferences.load(.phone, defaults: defaults) == .init(source: .zh, target: .de))
        #expect(ListenLanguagePreferences.load(.meeting, defaults: defaults) == .init(source: .de))
        #expect(defaults.string(forKey: ListenLanguagePreferences.legacySourceKey) == "en")
    }

    @Test func corruptedOrSameLanguagePreferencesAreNormalizedAndSaved() throws {
        let suite = "ListenLanguageSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("zh", forKey: "video.listen.sourceLanguage")
        defaults.set("zh", forKey: "video.listen.targetLanguage")
        #expect(ListenLanguagePreferences.load(.video, defaults: defaults) == .init(source: .zh, target: .en))
        #expect(defaults.string(forKey: "video.listen.targetLanguage") == "en")
        defaults.set("unsupported", forKey: "meeting.listen.sourceLanguage")
        defaults.set("de", forKey: "meeting.listen.targetLanguage")
        #expect(ListenLanguagePreferences.load(.meeting, defaults: defaults) == .init(source: .en, target: .de))
        #expect(defaults.string(forKey: "meeting.listen.sourceLanguage") == "en")
        #expect(defaults.string(forKey: "meeting.listen.targetLanguage") == "de")
        defaults.set("de", forKey: "phone.listen.sourceLanguage")
        defaults.set("unsupported", forKey: "phone.listen.targetLanguage")
        #expect(ListenLanguagePreferences.load(.phone, defaults: defaults) == .init(source: .de, target: .zh))
    }
}
