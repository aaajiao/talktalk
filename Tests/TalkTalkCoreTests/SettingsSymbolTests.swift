import AppKit
import Testing
import TalkTalkCore

/// A missing SF Symbol draws nothing. Every glyph the settings window, the menu bar menu, the
/// titlebar and the scene cards name through tokens (settings visual system §4) must exist on
/// this system. `VoiceIcon.originalRisk` is the one exemption: where the SDK lacks it the app
/// composes it from two symbols, which must exist instead.
@Suite struct SettingsSymbolTests {
    private func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    @Test func settingsPageAndMeaningGlyphsExist() {
        typealias S = SubtitleTokens.SettingsIcon
        typealias P = SubtitleTokens.SettingsIcon.Page
        let pages = [P.general, P.scenarios, P.subtitles, P.audio, P.voice, P.models, P.components, P.glossary, P.privacy]
        let meanings = [S.remote, S.myVoice, S.talkTalkMic, S.physicalMic, S.audio, S.recognition, S.translation,
                        S.sourceText, S.subtitles, S.speech, S.me, S.listen, S.thisMac, S.cloud, S.openApp, S.info,
                        S.privacyPromise, S.locked, S.auto, S.engine, S.verify, S.export, S.recording,
                        S.recordingActive, S.slow, S.performance, S.cost, S.glossary, S.headphones, S.speaker,
                        S.troubleshooting, S.voiceOver, S.unavailable]
        let actions = [S.refresh, S.reset, S.add, S.remove, S.close, S.copy, S.finder, S.delete, S.cancel, S.more,
                       S.flowArrow, S.back]
        let flow = [S.link, S.loopBack, S.unknownApp, S.browserTabs, S.noMicrophone, S.iPhone, S.sameAccount,
                    S.sameNetwork, S.handoff, S.subtitlesHidden, S.start, S.stop, S.dial, S.callContinues]
        // StepTrack draws the numbered circles of the system set.
        let steps = (1...3).map { "\($0).circle" }
        let status = [S.statusWarn, S.statusFailed, S.statusOK, S.statusPending, S.statusWaiting,
                      S.statusRecording]
        let subtitles = [S.fontSize, S.fontSmaller, S.fontLarger, S.background, S.backgroundClear,
                         S.backgroundSolid, S.reduceTransparency, S.captionArrangement, S.silenceDim,
                         S.subtitleWindow, S.windowMovable, S.windowNoFocus, S.windowMinimize,
                         S.windowNotShared, S.hoverOnly, S.callsInPhone]
        let general = [S.launchAtLogin, S.notifications, S.allowNotifications, S.announcement, S.onboarding]
        let voice = [S.inputVolume, S.record, S.duration]
        let models = [S.apiKey, S.pasteKey, S.snapshots, S.cloudReminder, S.retiring, S.cloudOff, S.noSpeech]
        let components = [S.download, S.install, S.repair, S.restartEngine, S.inspectFile, S.audioRestart, S.results,
                          S.meetingApps]
        let privacy = [S.transcripts, S.logs, S.autoCleanup, S.diagnosticsBundle, S.textOnly, S.oneSession, S.consent,
                       S.offlineCommands, S.checkValues]
        for name in pages + meanings + actions + flow + steps + status + subtitles + general + voice + models
            + components + privacy {
            #expect(exists(name), "\(name)")
        }
        // The sidebar no longer shares glyphs with the meeting card or with translation.
        #expect(P.scenarios != SubtitleTokens.SceneIcon.meeting && P.models != S.translation)
        #expect(Set(pages).count == pages.count)
    }

    @Test func menuGlyphsExist() {
        typealias M = SubtitleTokens.MenuIcon
        let names = [M.standby, M.listening, M.warming, M.audioUnconfirmed, M.degraded, M.needsAttention,
                     M.micUnused, M.subtitles, M.restoreWindow, M.restoreInput, M.announcement, M.onboarding]
        for name in names {
            #expect(exists(name), "\(name)")
        }
    }

    @Test func voiceAndSceneGlyphsExistAndTheRiskGlyphCanBeComposed() {
        typealias V = SubtitleTokens.VoiceIcon
        typealias C = SubtitleTokens.SceneIcon
        let voice = [V.original, V.originalOff, V.translating, V.playingTranslation, V.sentToPhone, V.openPhone,
                     V.localOnly, V.thisMac, V.reconnecting, V.aborted, V.listening, V.captionLag, V.locked,
                     V.chevron, V.startTranslation, V.stopTranslation, V.end, V.cloud, V.statusWarn,
                     V.statusRisk, V.more]
        for name in voice + [C.meeting, C.phone, C.video] {
            #expect(exists(name), "\(name)")
        }
        // Exempt: drawn as mic.fill with an exclamationmark.circle.fill badge when missing.
        #expect(exists(V.original) && exists(V.originalRiskFallbackBadge))
    }
}
