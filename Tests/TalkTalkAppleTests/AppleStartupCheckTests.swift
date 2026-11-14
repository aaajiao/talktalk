import TalkTalkCore
import Testing
@testable import TalkTalkApple

@Suite struct AppleStartupCheckTests {
    let baseSpeech = ["zh-CN": "installed", "en-US": "installed"]
    let baseTranslation = ["zh-en": "installed", "en-zh": "installed"]
    let allSpeech = ["zh-CN": "installed", "en-US": "installed", "de-DE": "installed", "fr-FR": "installed"]
    let allTranslation = ["en-zh": "installed", "de-zh": "installed", "zh-en": "installed", "zh-de": "installed",
                          "en-de": "installed", "de-en": "installed", "fr-zh": "installed", "fr-en": "installed",
                          "fr-de": "installed", "zh-fr": "installed", "en-fr": "installed", "de-fr": "installed"]
    let allLanguages = SpeechResourceSelection(languages: Set(Lang.allCases))

    func report(speech: [String: String], reserved: [String] = ["zh-CN", "en-US", "de-DE", "fr-FR"],
                translation: [String: String]? = nil, available: Bool = true) -> AppleStartupCheck.Report {
        .init(transcriberAvailable: available, speech: speech, reserved: reserved, maxReserved: 5,
              translation: translation ?? allTranslation)
    }

    @Test func chineseAndEnglishAloneAreReadyByDefault() {
        let ready = report(speech: baseSpeech, reserved: ["zh-CN", "en-US"], translation: baseTranslation)
        #expect(AppleStartupCheck.evaluate(ready) == .ok)
        #expect(Set(AppleStartupCheck.pairs(for: .init()).map(\.1)) == ["zh-en", "en-zh"])
    }

    @Test func unusedOptionalFailuresAndMissingReservationsDoNotWarn() {
        var speech = baseSpeech
        speech["de-DE"] = "unsupported"
        speech["fr-FR"] = "downloading"
        var translation = baseTranslation
        translation["fr-zh"] = "unsupported"
        translation["en-de"] = "supported"
        translation["fr-de"] = "unknown"
        #expect(AppleStartupCheck.evaluate(report(speech: speech, reserved: ["zh-CN", "en-US"], translation: translation)) == .ok)
    }

    @Test(arguments: [Lang.de, .fr])
    func selectingOptionalLanguageReportsItAndDeselectingClearsWarnings(_ language: Lang) {
        let locale = AppleSpeechASR.localeIdentifier(language)
        var speech = allSpeech; speech[locale] = "supported"
        var translation = allTranslation
        let key = "\(language.rawValue)-zh"
        translation[key] = "supported"
        let resources = report(speech: speech, translation: translation)
        let selected = SpeechResourceSelection().selecting(language, enabled: true)
        guard case let .degraded(problems) = AppleStartupCheck.evaluate(resources, selection: selected) else {
            Issue.record("Selected optional resources must be checked"); return
        }
        #expect(problems.contains("\(locale) 语音资源未下载"))
        #expect(problems.contains { $0.hasPrefix("\(key) 翻译语言包未下载") })
        #expect(AppleStartupCheck.evaluate(resources, selection: selected.selecting(language, enabled: false)) == .ok)
    }

    @Test func translationChecksRequireBothLanguagesToBeSelected() {
        let french = SpeechResourceSelection(languages: [.fr])
        #expect(Set(AppleStartupCheck.pairs(for: french).map(\.1)) == ["zh-en", "en-zh", "fr-zh", "fr-en", "zh-fr", "en-fr"])
        var translation = allTranslation
        translation["fr-de"] = "unsupported"
        translation["de-fr"] = "supported"
        #expect(AppleStartupCheck.evaluate(report(speech: allSpeech, translation: translation), selection: french) == .ok)
        #expect(AppleStartupCheck.pairs(for: allLanguages).count == 12)
        #expect(AppleStartupCheck.evaluate(report(speech: allSpeech), selection: allLanguages) == .ok)
    }

    @Test func requiredMissingSpeechAndTranslationRemainVisible() {
        let speech = ["zh-CN": "supported", "en-US": "installed"]
        let translation = ["zh-en": "supported", "en-zh": "installed"]
        guard case let .degraded(problems) = AppleStartupCheck.evaluate(report(speech: speech, translation: translation)) else {
            Issue.record("Missing required resources must remain visible"); return
        }
        #expect(problems.contains("zh-CN 语音资源未下载"))
        #expect(problems.contains { $0.hasPrefix("zh-en 翻译语言包未下载") })
    }

    @Test func unselectedInstalledLanguageDoesNotMaskUnavailableRecognition() {
        let speech = ["zh-CN": "supported", "en-US": "supported", "fr-FR": "installed"]
        let resources = report(speech: speech)
        guard case .unavailable = AppleStartupCheck.evaluate(resources) else {
            Issue.record("Unselected French must not mask missing selected recognition"); return
        }
        guard case .degraded = AppleStartupCheck.evaluate(resources, selection: .init(languages: [.fr])) else {
            Issue.record("Selected French is usable while required languages still need preparation"); return
        }
    }

    @Test func onlySelectedLanguagesNeedReservations() {
        guard case let .degraded(problems) = AppleStartupCheck.evaluate(report(speech: allSpeech, reserved: ["en-US"])) else {
            Issue.record("Missing required reservation must be reported"); return
        }
        #expect(problems == ["zh-CN 语音资源没有预留，系统可能清理它"])
    }

    @Test func noTranscriberIsUnavailable() {
        guard case .unavailable = AppleStartupCheck.evaluate(report(speech: allSpeech, available: false), selection: allLanguages) else {
            Issue.record("Missing transcriber must remain unavailable"); return
        }
    }
}

@Suite struct AppleStartupCheckItemTests {
    let baseSpeech = ["zh-CN": "installed", "en-US": "installed"]
    let baseTranslation = ["zh-en": "installed", "en-zh": "installed"]

    @Test func levelsFollowTheSelectedResourceVerdict() {
        let ok = AppleStartupCheckItem.result(.init(transcriberAvailable: true, speech: baseSpeech,
                                                   reserved: ["zh-CN", "en-US"], maxReserved: 5, translation: baseTranslation))
        #expect(ok.id == "apple" && ok.level == .ok)
        #expect(ok.details["reserved"] == "2/5" && ok.details["speech.zh-CN"] == "installed")
        var speech = baseSpeech; speech["zh-CN"] = "supported"
        let notice = AppleStartupCheckItem.result(.init(transcriberAvailable: true, speech: speech,
                                                       reserved: ["en-US"], maxReserved: 5, translation: baseTranslation))
        #expect(notice.level == .notice && notice.summary == "zh-CN 语音资源未下载")
        let action = AppleStartupCheckItem.result(.init(transcriberAvailable: false, speech: baseSpeech,
                                                       reserved: [], maxReserved: 5, translation: baseTranslation))
        #expect(action.level == .action)
    }

    @Test func extraUnselectedReportFieldsStayOutOfDetailsAndWarnings() {
        var speech = baseSpeech
        speech["de-DE"] = "unsupported"
        speech["fr-FR"] = "downloading"
        var translation = baseTranslation
        translation["fr-en"] = "unsupported"
        translation["de-fr"] = "supported"
        let resources = AppleStartupCheck.Report(transcriberAvailable: true, speech: speech,
                                                reserved: ["zh-CN", "en-US", "de-DE"], maxReserved: 5, translation: translation)
        let result = AppleStartupCheckItem.result(resources)
        #expect(result.level == .ok)
        #expect(result.details["speech.fr-FR"] == nil && result.details["speech.de-DE"] == nil)
        #expect(result.details["translation.fr-en"] == nil && result.details["translation.de-fr"] == nil)
        let selected = AppleStartupCheckItem.result(resources, selection: .init(languages: [.fr]))
        #expect(selected.level == .notice)
        #expect(selected.details["speech.fr-FR"] == "downloading")
        #expect(selected.details["translation.fr-en"] == "unsupported")
        #expect(selected.details["speech.de-DE"] == nil && selected.details["translation.de-fr"] == nil)
    }

    @Test func detailsHoldNoPaths() {
        let result = AppleStartupCheckItem.result(.init(transcriberAvailable: true, speech: baseSpeech,
                                                       reserved: [], maxReserved: 5, translation: baseTranslation))
        #expect(!(result.details.values.contains { $0.contains("/") && $0.count > 4 } || result.summary.contains("/Users")))
    }
}
