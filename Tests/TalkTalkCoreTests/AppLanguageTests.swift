import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct AppLanguageTests {
    @Test func missingOrUnsupportedPreferenceFollowsSystemWithoutWriting() throws {
        let suite = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppLanguage.load(defaults: defaults) == .system)
        #expect(defaults.persistentDomain(forName: suite)?[AppLanguage.preferenceKey] == nil)
        defaults.set("de", forKey: AppLanguage.preferenceKey)
        #expect(AppLanguage.load(defaults: defaults) == .system)
        // Reading a future or malformed choice must not silently replace it on disk.
        #expect(defaults.string(forKey: AppLanguage.preferenceKey) == "de")
    }

    @Test(arguments: ["zh", "zh-Hans", "zh-Hant", "zh-CN", "zh-TW", "zh-HK", "zh-MO", "zh-SG", "zh-Hant-TW", "ZH_hant_HK"])
    func chinesePrimaryLanguageUsesChinese(_ primary: String) {
        #expect(AppLanguage.system.resolved(preferredLanguages: [primary, "en-US"]) == .chinese)
    }

    @Test(arguments: [[String](), ["en-US"], ["de-DE"], ["fr-FR", "zh-Hans"], ["en-US", "zh-Hant"], ["ja-JP", "zh-CN"], ["zho"], [""]])
    func otherPrimaryLanguagesUseEnglishEvenWhenChineseIsSecondary(_ languages: [String]) {
        #expect(AppLanguage.system.resolved(preferredLanguages: languages) == .english)
    }

    @Test func explicitChoicePersistsAndLeavesSpeechPreferencesUntouched() throws {
        let suite = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speechPreferences = [
            "speak.sourceLanguage": "en", "speak.targetLanguage": "de",
            "phone.speak.sourceLanguage": "zh", "phone.speak.targetLanguage": "en",
            "meeting.listen.sourceLanguage": "de", "meeting.listen.targetLanguage": "zh",
            "phone.listen.sourceLanguage": "en", "phone.listen.targetLanguage": "de",
            "video.listen.sourceLanguage": "zh", "video.listen.targetLanguage": "en",
        ]
        defaults.setPersistentDomain(speechPreferences, forName: suite)
        for choice in [AppLanguage.english, .chinese, .system] {
            choice.save(defaults: defaults)
            let reopened = try #require(UserDefaults(suiteName: suite))
            #expect(AppLanguage.load(defaults: reopened) == choice)
            #expect(reopened.string(forKey: AppLanguage.preferenceKey) == choice.rawValue)
            for (key, value) in speechPreferences {
                #expect(reopened.string(forKey: key) == value)
            }
            let expected = speechPreferences.merging([AppLanguage.preferenceKey: choice.rawValue]) { _, new in new }
            #expect(reopened.persistentDomain(forName: suite) as? [String: String] == expected)
        }
        #expect(AppLanguage.english.resolved(preferredLanguages: ["zh-Hant"]) == .english)
        #expect(AppLanguage.chinese.resolved(preferredLanguages: ["de-DE"]) == .chinese)
    }

    @Test func launchOverrideIsVolatileAndPreservesOtherArguments() {
        // A recording double prevents a process-global Foundation argument domain from being
        // touched while tests run in parallel; only the production launch method is exercised.
        let defaults = LaunchDefaults()
        AppLanguage.chinese.applyAtLaunch(defaults: defaults)
        #expect(defaults.domain["AppleLanguages"] as? [String] == ["zh-Hans"])
        #expect(defaults.domain["unrelatedArgument"] as? String == "keep")
        #expect(defaults.updatedDomainName == UserDefaults.argumentDomain)
        #expect(defaults.persistentWrites == 0)
        AppLanguage.english.applyAtLaunch(defaults: defaults)
        #expect(defaults.domain["AppleLanguages"] as? [String] == ["en"])
        #expect(defaults.domain["unrelatedArgument"] as? String == "keep")
        #expect(defaults.persistentWrites == 0)
    }
}

private final class LaunchDefaults: UserDefaults {
    var domain: [String: Any] = ["AppleLanguages": ["de-DE"], "unrelatedArgument": "keep"]
    var updatedDomainName: String?
    var persistentWrites = 0

    init() { super.init(suiteName: "AppLanguageTests.Launch.\(UUID().uuidString)")! }

    override func volatileDomain(forName domainName: String) -> [String: Any] { domain }
    override func setVolatileDomain(_ domain: [String: Any], forName domainName: String) {
        self.domain = domain
        updatedDomainName = domainName
    }
    override func set(_ value: Any?, forKey defaultName: String) { persistentWrites += 1 }
}
