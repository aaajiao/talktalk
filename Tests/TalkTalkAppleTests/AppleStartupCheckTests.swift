import Testing
@testable import TalkTalkApple

@Suite struct AppleStartupCheckTests {
    func report(speech: [String: String], reserved: [String] = ["zh-CN", "en-US", "de-DE", "fr-FR"],
                translation: [String: String]? = nil, available: Bool = true) -> AppleStartupCheck.Report {
        .init(transcriberAvailable: available, speech: speech, reserved: reserved, maxReserved: 5,
              translation: translation ?? ["en-zh": "installed", "de-zh": "installed", "zh-en": "installed", "zh-de": "installed", "en-de": "installed", "de-en": "installed", "fr-zh": "installed", "fr-en": "installed", "fr-de": "installed", "zh-fr": "installed", "en-fr": "installed", "de-fr": "installed"])
    }
    let all = ["zh-CN": "installed", "en-US": "installed", "de-DE": "installed", "fr-FR": "installed"]

    @Test func everythingInstalledAndReservedIsOK() {
        #expect(AppleStartupCheck.evaluate(report(speech: all)) == .ok)
    }

    @Test func missingGermanIsDegradedNotFatal() {
        var s = all; s["de-DE"] = "supported"
        guard case let .degraded(p) = AppleStartupCheck.evaluate(report(speech: s)) else { Issue.record("not degraded"); return }
        #expect(p == ["de-DE 语音资源未下载"])
    }

    @Test func noRecognitionLanguageAtAllIsUnavailable() {
        let s = ["zh-CN": "supported", "en-US": "supported", "de-DE": "supported"]
        guard case .unavailable = AppleStartupCheck.evaluate(report(speech: s)) else { Issue.record("not unavailable"); return }
    }

    @Test func chineseOnlySpeechStillSupportsVideoSubtitles() {
        let s = ["zh-CN": "installed", "en-US": "supported", "de-DE": "supported"]
        guard case .degraded = AppleStartupCheck.evaluate(report(speech: s)) else {
            Issue.record("Chinese recognition is usable for video subtitles"); return
        }
        var translation = report(speech: all).translation
        translation["de-en"] = "supported"
        guard case let .degraded(problems) = AppleStartupCheck.evaluate(report(speech: all, translation: translation)) else {
            Issue.record("Missing German → English resources must be visible"); return
        }
        #expect(problems.contains { $0.hasPrefix("de-en 翻译语言包未下载") })
    }

    @Test func unreservedAndMissingTranslationPacksAreListed() {
        let r = report(speech: all, reserved: ["en-US"], translation: ["en-zh": "installed", "de-zh": "supported", "zh-en": "installed", "zh-de": "unsupported", "en-de": "installed", "de-en": "installed", "fr-zh": "installed", "fr-en": "installed", "fr-de": "installed", "zh-fr": "installed", "en-fr": "installed", "de-fr": "installed"])
        guard case let .degraded(p) = AppleStartupCheck.evaluate(r) else { Issue.record("not degraded"); return }
        #expect(p.contains("zh-CN 语音资源没有预留，系统可能清理它"))
        #expect(p.contains { $0.hasPrefix("de-zh 翻译语言包未下载") })
        #expect(p.contains { $0.hasPrefix("zh-de 翻译语言包不可用") })
    }

    @Test func frenchResourcesParticipateInReadiness() {
        var speech = all; speech["fr-FR"] = "supported"
        guard case let .degraded(problems) = AppleStartupCheck.evaluate(report(speech: speech)) else {
            Issue.record("missing French must be reported"); return
        }
        #expect(problems == ["fr-FR 语音资源未下载"])
        #expect(AppleSpeechASR.localeIdentifier(.fr) == "fr-FR")
        #expect(AppleStartupCheck.pairs.count == 12)
        var translation = report(speech: all).translation
        translation["fr-zh"] = "supported"
        guard case let .degraded(missing) = AppleStartupCheck.evaluate(report(speech: all, translation: translation)) else {
            Issue.record("missing French translation must be reported"); return
        }
        #expect(missing.contains { $0.hasPrefix("fr-zh 翻译语言包未下载") })
        let frenchOnly = ["zh-CN": "supported", "en-US": "supported", "de-DE": "supported", "fr-FR": "installed"]
        guard case .degraded = AppleStartupCheck.evaluate(report(speech: frenchOnly)) else {
            Issue.record("French recognition alone is usable"); return
        }
    }

    @Test func noTranscriberIsUnavailable() {
        #expect(AppleStartupCheck.evaluate(report(speech: all, available: false)) != .ok)
    }
}

@Suite struct AppleStartupCheckItemTests {
    let speech = ["zh-CN": "installed", "en-US": "installed", "de-DE": "installed", "fr-FR": "installed"]
    let tr = ["en-zh": "installed", "de-zh": "installed", "zh-en": "installed", "zh-de": "installed", "en-de": "installed", "de-en": "installed", "fr-zh": "installed", "fr-en": "installed", "fr-de": "installed", "zh-fr": "installed", "en-fr": "installed", "de-fr": "installed"]

    @Test func levelsFollowTheVerdict() {
        let ok = AppleStartupCheckItem.result(.init(transcriberAvailable: true, speech: speech, reserved: ["zh-CN", "en-US", "de-DE", "fr-FR"], maxReserved: 5, translation: tr))
        #expect(ok.id == "apple" && ok.level == .ok)
        #expect(ok.details["reserved"] == "4/5" && ok.details["speech.de-DE"] == "installed")
        var s = speech; s["de-DE"] = "supported"
        let notice = AppleStartupCheckItem.result(.init(transcriberAvailable: true, speech: s, reserved: ["zh-CN", "en-US", "fr-FR"], maxReserved: 5, translation: tr))
        #expect(notice.level == .notice && notice.summary == "de-DE 语音资源未下载")
        let action = AppleStartupCheckItem.result(.init(transcriberAvailable: false, speech: speech, reserved: [], maxReserved: 5, translation: tr))
        #expect(action.level == .action)
    }

    @Test func detailsHoldNoPaths() {
        let r = AppleStartupCheckItem.result(.init(transcriberAvailable: true, speech: speech, reserved: [], maxReserved: 5, translation: tr))
        #expect(!(r.details.values.contains { $0.contains("/") && $0.count > 4 } || r.summary.contains("/Users")))
    }
}
