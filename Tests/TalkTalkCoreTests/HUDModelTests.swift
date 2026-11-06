import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct PhoneSpeechPresentationTests {
    @Test func originalNeedsBothTheOpenGateModeAndConfirmedPhoneInput() {
        let waiting = HUDModel.MeetingAudio.original.phonePresentation(inputConfirmed: false)
        let sending = HUDModel.MeetingAudio.original.phonePresentation(inputConfirmed: true)
        #expect(waiting.tone == .ready)
        #expect(waiting.title != sending.title)
        #expect(sending.tone == .original)
        #expect(sending.title == "原声发送中")
        #expect(sending.detail.contains("送入 Phone"))
        #expect(!sending.detail.contains("对方已听"))
    }

    @Test func preparedPhoneRemainsReadyWithoutClaimingRawTransmission() {
        for confirmed in [false, true] {
            let ready = HUDModel.MeetingAudio.phoneReady.phonePresentation(inputConfirmed: confirmed)
            #expect(ready.tone == .ready)
            #expect(ready.title.contains("就绪"))
            #expect(!ready.title.contains("发送中"))
        }
        #expect(HUDModel.MeetingAudio.phoneReady.phonePresentation(inputConfirmed: false).detail.contains("未确认 Phone 接入"))
    }

    @Test func recordingAndRemainingAudioHaveDifferentActionsAndEmphasis() {
        let recording = HUDModel.MeetingAudio.translating.phonePresentation(inputConfirmed: true)
        let draining = HUDModel.MeetingAudio.draining.phonePresentation(inputConfirmed: true)
        #expect(recording.tone == .translation && draining.tone == .progress)
        #expect(recording.action.contains("结束发言"))
        #expect(draining.action.contains("继续翻译"))
        #expect(recording.detail.contains("原声已关闭"))
        #expect(draining.detail.contains("原声保持关闭"))
    }

    @Test func localTranslationDoesNotClaimPhoneIsReceiving() {
        for mode in [HUDModel.MeetingAudio.translating, .draining] {
            let local = mode.phonePresentation(inputConfirmed: false)
            #expect(local.detail.contains("本机"))
            #expect(local.detail.contains("未确认 Phone 接入"))
            #expect(local.tone != .original)
        }
    }

    @Test func restoringAndFailuresCannotBecomeSendingIndicators() {
        let restoring = HUDModel.MeetingAudio.restoringOriginal.phonePresentation(inputConfirmed: true)
        let failed = HUDModel.MeetingAudio.unavailable(reason: "设备断开").phonePresentation(inputConfirmed: true)
        #expect(restoring.tone == .progress)
        #expect(failed.tone == .unavailable && failed.detail == "设备断开")
        #expect(restoring.title != "原声发送中" && failed.title != "原声发送中")
    }
}

/// The §11 / §3.8 "state → text" table. The expected strings are copied from ARCHITECTURE.md.
@Suite struct HUDModelTests {
    static let warnings: [(HUDModel.Warning, String, HUDLine.Style)] = [
        (.meetingNotUsingMic, "会议没用 TalkTalk Mic", .red),
        (.remoteHearsYourVoice, "会议正在用实体麦，对方仍可能听到原声；按键翻译已停用", .red),
        (.floorPaused(segments: 3), "对方在说话 · 已暂停 3 段", .yellow),
        (.numberMaybeWrong("三十万"), "数字可能有误：三十万", .yellow),
        (.skipped(segments: 2), "已跳过 2 段", .yellow),
        (.segmentNotSent, "这段未发送", .yellow),
        (.sentenceMaybeIncomplete, "该句可能不完整", .yellow),
        (.unsupportedTextNotSent, "这段文字暂不支持，未发送", .yellow),
        (.speakerMode, "正在外放，请戴耳机", .yellow),
        (.audioRestarting, "音频系统重启中", .yellow),
        (.meetingSilent, "会议当前没有声音", .normal),
        (.meetingSeemsOver, "会议似乎已结束", .normal),
        (.tccUnconfirmed, "没能确认系统录音权限", .yellow),
        (.defaultInputChanged(to: "MacBook Pro 麦克风"), "系统默认输入被改成了 MacBook Pro 麦克风", .yellow),
        (.switchedBackAfterInsert(device: "AirPods"), "AirPods 接入后系统换了默认输入，已切回 TalkTalk Mic", .normal),
        (.switchBackFailed(current: "MacBook Pro 麦克风"), "没能切回 TalkTalk Mic，系统默认输入是 MacBook Pro 麦克风", .yellow),
        (.defaultInputRestored(to: "MacBook Pro 麦克风"), "默认输入已还原为 MacBook Pro 麦克风", .normal),
        (.openAIUnreachable, "OpenAI 暂时连不上，改用 Apple 翻译", .yellow),
        (.openAIKeyInvalid, "OpenAI key 无效或额度用完，已改用 Apple 翻译", .yellow),
        (.modelRetired, "所选模型已下线，已换回 gpt-6-luna", .yellow),
        (.passthroughTip, "会议默认传原声；点按右⌥开始翻译，再按结束，译音播完后恢复原声", .normal),
        (.defaultInputRestoredElsewhere(to: "MacBook Pro 麦克风", original: "Tuwa Mic", originalMissing: false),
         "默认输入已还原为 MacBook Pro 麦克风（原来的 Tuwa Mic 是虚拟设备，不还原到它）", .normal),
        (.defaultInputRestoredElsewhere(to: "MacBook Pro 麦克风", original: "ear4", originalMissing: true),
         "默认输入已还原为 MacBook Pro 麦克风（原来的 ear4 不在了）", .normal),
        (.defaultInputNotSwitched(.micMissing), "TalkTalk Mic 不在，系统默认输入没有切换", .yellow),
        (.defaultInputNotSwitched(.noPhysicalInput), "没有实体麦克风，系统默认输入没有切换", .yellow),
        (.defaultInputNotSwitched(.writeFailed), "没能把系统默认输入切到 TalkTalk Mic", .yellow),
        (.defaultInputNotSwitched(.recordWriteFailed), "没能写下还原记录，系统默认输入没有切换", .yellow),
        (.defaultInputNotSwitched(.guardLaunchFailed), "还原守护进程没能启动，系统默认输入没有切换", .yellow),
        (.defaultInputNotSwitched(.micNotSelectable), "TalkTalk Mic 现在不能设为默认输入，系统默认输入没有切换", .yellow),
    ]

    @Test func everyWarningHasItsText() {
        for (w, text, style) in Self.warnings {
            var m = HUDModel()
            m.post(w, now: 0)
            let lines = m.lines(now: 0)
            #expect(lines.count == 1)
            #expect(lines.first?.style == style, "\(w)")
            #expect((lines.first?.detail ?? lines.first?.text) == text, "\(w)")
        }
    }

    @Test func conditionsStayNoticesFade() {
        var m = HUDModel()
        m.post(.meetingNotUsingMic, now: 0)
        m.post(.segmentNotSent, now: 0)
        #expect(m.lines(now: 3.9).count == 2)
        #expect(m.lines(now: 4.0) == [HUDModel.Warning.meetingNotUsingMic.line])
        #expect(m.lines(now: 1000) == [HUDModel.Warning.meetingNotUsingMic.line])
        m.clear(.meetingNotUsingMic)
        #expect(m.lines(now: 1000).isEmpty)
        #expect(m.nextExpiry(after: 0) == 4)
        #expect(m.nextExpiry(after: 1000) == nil)
    }

    @Test func countedConditionReplacesItsOlderCount() {
        var m = HUDModel()
        m.post(.floorPaused(segments: 1), now: 0)
        m.post(.floorPaused(segments: 2), now: 0)
        #expect(m.lines(now: 0) == [HUDModel.Warning.floorPaused(segments: 2).line])
        m.clear(.floorPaused(segments: 0))
        #expect(m.lines(now: 0).isEmpty)
    }

    @Test func keyInvalidOncePerMeeting() {
        var m = HUDModel()
        m.meetingStarted()
        m.post(.openAIKeyInvalid, now: 0)
        m.post(.openAIKeyInvalid, now: 10)
        #expect(!m.lines(now: 10).contains { $0.text.hasPrefix("OpenAI key") })
        m.meetingEnded()
        m.meetingStarted()
        m.post(.openAIKeyInvalid, now: 20)
        #expect(m.lines(now: 20).contains { $0.text.hasPrefix("OpenAI key") })
        // Unreachable is not limited.
        m.post(.openAIUnreachable, now: 30)
        m.post(.openAIUnreachable, now: 40)
        #expect(m.lines(now: 43).filter { $0.text.hasPrefix("OpenAI 暂时") }.count == 1)
    }

    @Test func redWarningsComeFirst() {
        var m = HUDModel()
        m.meetingStarted()
        m.pushToTalkAvailable = true
        m.post(.speakerMode, now: 0)
        m.post(.remoteHearsYourVoice, now: 0)
        let l = m.lines(now: 0)
        #expect(l.map(\.text) == ["会议仍会发送原声 · 翻译已停用", "点按右⌥开始翻译", "正在外放，请戴耳机"])
    }

    // MARK: passthrough (§3.8)

    @Test func shortCommandPressShowsNothing() {
        var m = HUDModel()
        m.passthrough(.pressed, now: 0)
        #expect(m.lines(now: 0.1).isEmpty)
        m.passthrough(.cancelled, now: 0.3)          // released before 400 ms / a ⌘ shortcut
        #expect(m.lines(now: 0.3).isEmpty)
        #expect(m.lines(now: 2).isEmpty)
        m.passthrough(.refused(reason: nil), now: 3) // outside meeting mode / setting off
        #expect(m.lines(now: 3).isEmpty)
    }

    @Test func passthroughLines() {
        var m = HUDModel()
        m.passthrough(.pressed, now: 0)
        m.passthrough(.waitingForClause, now: 0.4)
        #expect(m.lines(now: 0.5) == [HUDLine("原声 · 等这句说完", .red)])
        m.passthrough(.opened, now: 1)
        m.passthrough(.level(0.4), now: 1.1)
        #expect(m.lines(now: 1.1) == [HUDLine("原声 · 对方正在听你说", .redBanner, level: 0.4)])
        m.passthrough(.countdown(secondsLeft: 6), now: 24)
        #expect(m.lines(now: 24) == [HUDLine("原声 · 对方正在听你说", .redBanner, level: 0.4)])
        m.passthrough(.countdown(secondsLeft: 5), now: 25)
        #expect(m.lines(now: 25) == [HUDLine("原声 · 对方正在听你说 · 还剩 5 s", .redBanner, level: 0.4)])
        m.passthrough(.countdown(secondsLeft: 1), now: 29)
        #expect(m.lines(now: 29).first?.text == "原声 · 对方正在听你说 · 还剩 1 s")
        m.passthrough(.closed(reason: "超过 30 s"), now: 30)
        #expect(m.lines(now: 30.5) == [HUDLine("原声已关闭：超过 30 s")])
        #expect(m.nextExpiry(after: 30.5) == 31)
        #expect(m.lines(now: 31).isEmpty)
    }

    @Test func normalCloseShowsOneSecond() {
        var m = HUDModel()
        m.passthrough(.opened, now: 0)
        m.passthrough(.closed(reason: nil), now: 2)
        #expect(m.lines(now: 2.99) == [HUDLine("原声已关闭")])
        #expect(m.lines(now: 3).isEmpty)
    }

    @Test func everyCloseReasonLine() {
        // PassthroughCloseReason.hudText values (§3.8 关闭原因).
        for r in ["按了其他键", "超过 30 s", "音频系统重启", "会议没用 TalkTalk Mic", "先等提示音再说", "原声直通已中断"] {
            var m = HUDModel()
            m.passthrough(.opened, now: 0)
            m.passthrough(.closed(reason: r), now: 1)
            #expect(m.lines(now: 1) == [HUDLine("原声已关闭：\(r)")])
        }
    }

    @Test func everyRefusalShowsGrayForOneAndAHalfSeconds() {
        // PassthroughPolicy.DenyReason / PassthroughRefusal hudText values (§3.8 不可用时).
        let reasons = ["外放时不能用原声直通", "会议 App 正在用实体麦，对方本来就听得到你", "会议没用 TalkTalk Mic",
                       "安全输入开启中", "先等提示音再说", "原声直通暂不可用", "自检进行中，原声直通暂不可用",
                       "按键说话进行中", "按键监听失效，原声直通暂不可用", "音频系统重启中", "当前麦克风不能用于原声直通"]
        for r in reasons {
            var m = HUDModel()
            m.passthrough(.pressed, now: 0)
            m.passthrough(.refused(reason: r), now: 0.5)
            #expect(m.lines(now: 0.5) == [HUDLine(r, .secondary)])
            #expect(m.lines(now: 1.99) == [HUDLine(r, .secondary)])
            #expect(m.lines(now: 2.0).isEmpty)
        }
    }

    @Test func passthroughShowsWithoutMeetingSubtitles() {
        // The HUD has its own visibility: it does not depend on the subtitle panel.
        var m = HUDModel()
        m.meetingStarted()
        m.passthrough(.opened, now: 0)
        #expect(m.isVisible(now: 0))
        #expect(m.lines(now: 0).first?.style == .redBanner)
    }

    @Test func releaseWhileWaitingForTheClauseClearsTheLine() {
        var m = HUDModel()
        m.passthrough(.pressed, now: 0)
        m.passthrough(.waitingForClause, now: 0.4)
        m.passthrough(.cancelled, now: 0.9)
        #expect(m.lines(now: 0.9).isEmpty)
    }

    @Test func silentRefusalWhileWaitingClearsTheLine() {
        var m = HUDModel()
        m.passthrough(.waitingForClause, now: 0.4)
        m.passthrough(.refused(reason: nil), now: 0.6)   // e.g. setting turned off
        #expect(m.lines(now: 0.6).isEmpty)
    }

    @Test func cancelDoesNotClearAFadingCloseLine() {
        var m = HUDModel()
        m.passthrough(.opened, now: 0)
        m.passthrough(.closed(reason: nil), now: 1)
        m.passthrough(.cancelled, now: 1.25)
        #expect(m.lines(now: 1.25) == [HUDLine("原声已关闭")])
    }

    @Test func levelAndCountdownIgnoredWhenNotOpen() {
        var m = HUDModel()
        m.passthrough(.level(0.9), now: 0)
        m.passthrough(.countdown(secondsLeft: 3), now: 0)
        #expect(m.lines(now: 0).isEmpty)
    }

    // MARK: push to talk (M2)

    @Test func meetingAudioSeparatesNormalProgressFromPhysicalMicRisk() {
        var model = HUDModel()
        model.meetingStarted()
        for audio in [HUDModel.MeetingAudio.original, .switching, .translating, .draining, .restoringOriginal] {
            model.meetingAudio = audio
            #expect(model.lines(now: 0) == [HUDLine(audio.text, .normal)])
        }
        model.meetingAudio = .unavailable(reason: "设备待确认")
        #expect(model.lines(now: 0) == [HUDLine("音频暂不可用", .yellow, detail: "TalkTalk 音频暂不可用：设备待确认", symbol: "exclamationmark.triangle")])
        model.post(.remoteHearsYourVoice, now: 0)
        #expect(model.lines(now: 0).contains(HUDModel.Warning.remoteHearsYourVoice.line))
        #expect(!model.lines(now: 0).contains { $0.text.contains("原声已关闭") })
        #expect(!model.lines(now: 0).contains { $0.text == "音频暂不可用" })
        let warning = model.lines(now: 0).first
        #expect(warning?.style == .red)
        #expect(warning?.detail?.contains("对方仍可能听到原声") == true)
    }

    @Test func pushToTalkLines() {
        var m = HUDModel()
        #expect(m.lines(now: 0).isEmpty)          // outside meeting mode: nothing
        m.meetingStarted()
        #expect(m.lines(now: 0).isEmpty)          // no push to talk wired yet (M1): no hint
        m.pushToTalkAvailable = true
        #expect(m.lines(now: 0) == [HUDLine("点按右⌥开始翻译", .secondary)])
        m.pushToTalk = .holding(level: 0.5, preview: "明年的预算", committed: ["我们先看"], queued: 2)
        #expect(m.lines(now: 0) == [HUDLine("正在识别中文", .normal, level: 0.5), HUDLine("✓ 我们先看", .check),
                                    HUDLine("明年的预算", .secondary), HUDLine("待播 2 段", .secondary)])
        m.pushToTalk = .playing(lang: .de, voice: .mine, source: .openAI, queued: 0)
        #expect(m.lines(now: 0) == [HUDLine("正在播放译音（DE）"), HUDLine("我的声音", .secondary),
                                    HUDLine("OpenAI", .secondary)])
        m.pushToTalk = .playing(lang: .en, voice: .system, source: .apple, queued: 1)
        #expect(m.lines(now: 0) == [HUDLine("正在播放译音（EN）"), HUDLine("系统声音", .secondary),
                                    HUDLine("Apple 本地翻译", .secondary), HUDLine("待播 1 段", .secondary)])
        m.pushToTalk = .playing(lang: .en, voice: .fallbackModel, source: .openAI, queued: 0)
        #expect(m.lines(now: 0)[1] == HUDLine("备用模型", .secondary))
    }

    @Test func meetingEndClearsEverythingButSysInputNotices() {
        var m = HUDModel()
        m.meetingStarted()
        m.post(.meetingNotUsingMic, now: 0)
        m.post(.segmentNotSent, now: 0)
        m.passthrough(.opened, now: 0)
        m.meetingEnded()
        #expect(m.lines(now: 0).isEmpty)
    }

    @Test func compactMeetingStatusFollowsTheGateNotRenderActivity() throws {
        var model = HUDModel()
        model.meetingStarted(); model.pushToTalkAvailable = true
        model.meetingAudio = .original
        let original = try #require(model.compactStatus(now: 0))
        #expect(original.summary.text == HUDModel.MeetingAudio.original.text)
        model.meetingAudio = .translating
        model.pushToTalk = .holding(level: 0.1, preview: "开头", committed: [], queued: 0)
        let holding = try #require(model.compactStatus(now: 0))
        model.pushToTalk = .holding(level: 0.9, preview: "更长的开头", committed: ["已提交"], queued: 4)
        #expect(model.compactStatus(now: 0.1)?.summary == holding.summary)
        model.pushToTalk = .playing(lang: .de, voice: .mine, source: .apple, queued: 2)
        let playing = try #require(model.compactStatus(now: 0.2))
        #expect(playing.summary == holding.summary)
        #expect(playing.summary.text.contains("原声已关闭"))
        #expect(playing.summary.level == nil && playing.summary.detail == nil)
        #expect(playing.details.contains { $0.text == "待播 2 段" })
        #expect(playing.details.contains { $0.text == "我的声音" })
        #expect(playing.details.contains { $0.text == "Apple 本地翻译" })
        model.meetingAudio = .draining
        #expect(model.compactStatus(now: 0.3)?.summary.text == HUDModel.MeetingAudio.draining.text)
        model.meetingAudio = .restoringOriginal
        let restoring = try #require(model.compactStatus(now: 0.3))
        #expect(restoring.summary.style == .normal)
        #expect(restoring.summary.text == "正在恢复原声" && restoring.summary.text != original.summary.text)
        model.meetingAudio = .unavailable(reason: "设备已断开")
        let unavailable = try #require(model.compactStatus(now: 0.3))
        #expect(unavailable.summary.style == .yellow)
        #expect(unavailable.details.contains { $0.detail?.contains("设备已断开") == true })
        model.meetingAudio = .original
        #expect(model.compactStatus(now: 0.4)?.summary == original.summary)
    }

    @Test func compactWarningsKeepRiskAndUnsentContentAheadOfProgress() throws {
        var model = HUDModel()
        model.meetingStarted(); model.meetingAudio = .original
        model.post(.passthroughTip, now: 0)
        model.post(.segmentNotSent, now: 0)
        let remoteIssue = HUDLine("对方字幕暂不可用", .yellow, detail: "请检查语音资源", symbol: "exclamationmark.triangle")
        let extras = [remoteIssue, HUDLine("云端文字传输提醒", .yellow), HUDLine("刚刚恢复", .normal)]
        #expect(model.compactStatus(now: 1, extraLines: extras)?.summary.text == "这段未发送")
        model.post(.remoteHearsYourVoice, now: 0)
        let risk = try #require(model.compactStatus(now: 1, extraLines: extras + [HUDLine("另一个错误", .red)]))
        #expect(risk.summary.text == HUDModel.Warning.remoteHearsYourVoice.summary)
        #expect(risk.summary.style == .red)
        #expect(risk.details.contains(HUDModel.Warning.segmentNotSent.line))
        #expect(risk.details.contains(remoteIssue))
        model.clear(.remoteHearsYourVoice); model.clear(.segmentNotSent)
        #expect(model.compactStatus(now: 1, extraLines: extras)?.summary.text == remoteIssue.text)
    }

    @Test func preparedPhoneWaitingIsNeutralAndDoesNotClaimConnectedAudio() throws {
        var model = HUDModel()
        model.meetingStarted()
        model.meetingAudio = .phoneReady
        let status = try #require(model.compactStatus(now: 0))
        #expect(status.summary.style == .normal)
        #expect(status.summary.text == "电话同传已就绪 · 点按右⌥即可开始翻译")
        #expect(model.meetingAudio?.modeBadge == HUDLine("已就绪", .check, symbol: "phone"))
        #expect(model.meetingAudio?.operationHint == "点按右⌥开始翻译，可在拨号前试说")
        #expect(status.details.allSatisfy { $0.style != .yellow && $0.style != .red })
        model.meetingAudio = .unavailable(reason: "安全输入开启中")
        #expect(model.compactStatus(now: 1)?.summary.style == .yellow)
        model.meetingAudio = .phoneReady
        #expect(model.compactStatus(now: 2)?.summary == status.summary)
    }

    @Test func waitingPhoneKeepsRealAudioAndPermissionWarningsVisible() throws {
        for warning in [HUDModel.Warning.remoteHearsYourVoice, .audioRestarting, .tccUnconfirmed,
                        .switchBackFailed(current: "Built-in"), .segmentNotSent] {
            var model = HUDModel()
            model.meetingStarted(); model.meetingAudio = .phoneReady
            model.post(warning, now: 0)
            let status = try #require(model.compactStatus(now: 1))
            #expect(status.summary.text == warning.summary)
            #expect(status.summary.style == warning.style)
            #expect(status.details.contains { $0.text == HUDModel.MeetingAudio.phoneReady.text })
            model.clear(warning)
            #expect(model.compactStatus(now: 1)?.summary.style == .normal)
        }
    }

    @Test func compactDemoAndListeningStayStableAndExtraDetailsAreDeduplicated() throws {
        var model = HUDModel()
        #expect(model.compactStatus(now: 0) == nil)
        model.meetingStarted()
        #expect(model.compactStatus(now: 0)?.details.contains { $0.text == "正在收听" } == true)
        model.pushToTalkAvailable = true
        model.post(.meetingSilent, now: 0)
        #expect(model.compactStatus(now: 0)?.summary.text == "正在收听")
        model.pushToTalk = .holding(level: 0.2, preview: "草稿", committed: [], queued: 0)
        let holding = try #require(model.compactStatus(now: 0))
        model.pushToTalk = .playing(lang: .en, voice: .system, source: .openAI, queued: 3)
        #expect(model.compactStatus(now: 0.2)?.summary == holding.summary)
        #expect(holding.summary.text == "按键翻译中")
        let extra = HUDLine("还原需要处理", .red, detail: "完整设备原因", symbol: "mic.badge.xmark", settingsDestination: .audio)
        let status = try #require(model.compactStatus(now: 0.3, extraLines: [extra, extra]))
        #expect(status.details.filter { $0 == extra }.count == 1)
        #expect(status.summary.text == extra.text && status.summary.detail == nil)
        #expect(status.details.contains { $0.text == "系统声音" })
    }

    @Test func compactCountedWarningsChangeOnlyTheirDetails() throws {
        var model = HUDModel()
        model.meetingStarted(); model.meetingAudio = .draining
        model.post(.floorPaused(segments: 1), now: 0)
        let paused = try #require(model.compactStatus(now: 0))
        model.post(.floorPaused(segments: 7), now: 0.1)
        let morePaused = try #require(model.compactStatus(now: 0.1))
        #expect(morePaused.summary == paused.summary)
        #expect(morePaused.summary.text == "对方在说话 · 译音已暂停")
        #expect(morePaused.details.contains(HUDModel.Warning.floorPaused(segments: 7).line))
        model.post(.skipped(segments: 1), now: 0.2)
        let skipped = try #require(model.compactStatus(now: 0.2))
        model.post(.skipped(segments: 3), now: 0.3)
        #expect(model.compactStatus(now: 0.3)?.summary == skipped.summary)
        #expect(skipped.summary.text == "部分内容已跳过")
        #expect(model.compactStatus(now: 0.3)?.details.contains(HUDModel.Warning.skipped(segments: 3).line) == true)
    }

    @Test func speechTranscriptSurvivesReleaseAndDrainThenExpiresOrIsReplaced() {
        var model = HUDModel()
        model.meetingStarted(); model.pushToTalkAvailable = true; model.speechWorkPending = true
        let original = String(repeating: "完整原文不能截断。", count: 12)
        model.receiveTranscript(.init(press: 1, source: original, target: "", isFinal: false), now: 0)
        model.pushToTalk = .idle // releasing/playing callbacks do not own the transcript
        #expect(model.visibleTranscript(at: 100)?.source == original)
        model.receiveTranscript(.init(press: 1, source: original, target: "The complete translation.", isFinal: true,
                                      unsubmittedSource: "短尾"), now: 100)
        model.meetingAudio = .unavailable(reason: "paused") // paused output is still busy
        model.refreshTranscriptLifetime(now: 100)
        #expect(model.nextExpiry(after: 100) == nil)
        #expect(model.visibleTranscript(at: 200)?.unsubmittedSource == "短尾")
        model.speechWorkPending = false; model.refreshTranscriptLifetime(now: 200)
        #expect(model.nextExpiry(after: 200) == 260)
        #expect(model.visibleTranscript(at: 250) != nil)
        model.expireTranscript(at: 260, reading: true)
        #expect(model.visibleTranscript(at: 261) != nil)
        model.receiveTranscript(.init(press: 2, source: "新一轮", target: "", isFinal: false), now: 261)
        model.receiveTranscript(.init(press: 1, source: "迟到的旧结果", target: "old", isFinal: true), now: 262)
        #expect(model.visibleTranscript(at: 270)?.source == "新一轮")
        model.receiveTranscript(.init(press: 2, source: "新一轮定稿", target: "New turn.", isFinal: true), now: 270)
        model.receiveTranscript(.init(press: 2, source: "迟到的草稿", target: "", isFinal: false), now: 271)
        #expect(model.visibleTranscript(at: 329)?.source == "新一轮定稿")
        model.expireTranscript(at: 330)
        #expect(model.transcript == nil)
        model.receiveTranscript(.init(press: 2, source: "不能复活过期结果", target: "", isFinal: true), now: 331)
        #expect(model.transcript == nil)
    }

    @Test func originalAudioAllowsNewPressResetButRejectsRecognitionDrafts() {
        var model = HUDModel()
        model.meetingStarted(); model.meetingAudio = .original
        model.receiveTranscript(.init(press: 1, source: "上一轮", target: "Previous turn.", isFinal: true), now: 0)
        #expect(model.visibleTranscript(at: 1)?.source == "上一轮")
        model.receiveTranscript(.init(press: 2, source: "", target: "", isFinal: false), now: 1)
        #expect(model.transcript?.press == 2)
        #expect(model.visibleTranscript(at: 1) == nil)
        model.receiveTranscript(.init(press: 1, source: "迟到的上一轮", target: "Old.", isFinal: true), now: 2)
        model.receiveTranscript(.init(press: 2, source: "原声草稿", target: "", isFinal: false), now: 2)
        model.receiveTranscript(.init(press: 2, source: "", target: "", isFinal: false,
                                      unsubmittedSource: "未提交草稿"), now: 2)
        #expect(model.transcript?.press == 2)
        #expect(model.visibleTranscript(at: 2) == nil)
        model.meetingAudio = .translating
        model.receiveTranscript(.init(press: 2, source: "新一轮", target: "", isFinal: false), now: 3)
        #expect(model.visibleTranscript(at: 3)?.source == "新一轮")
    }

    /// The restore notice may arrive just before or after meetingEnded (listen's order): it stays
    /// its 4 s either way, and so does an entry result posted around meetingStarted.
    @Test func sysInputNoticesOutliveMeetingStartAndEnd() {
        let restored = HUDModel.Warning.defaultInputRestored(to: "MacBook Pro 麦克风").line
        var before = HUDModel()
        before.meetingStarted()
        before.post(.defaultInputRestored(to: "MacBook Pro 麦克风"), now: 1)
        before.meetingEnded()
        #expect(before.lines(now: 2) == [restored])
        #expect(before.lines(now: 5).isEmpty)

        var after = HUDModel()
        after.meetingStarted()
        after.meetingEnded()
        after.post(.defaultInputRestored(to: "MacBook Pro 麦克风"), now: 1)
        #expect(after.lines(now: 2) == [restored])

        var entry = HUDModel()
        entry.post(.defaultInputNotSwitched(.micNotSelectable), now: 0)
        entry.meetingStarted()
        #expect(entry.lines(now: 1).contains(HUDModel.Warning.defaultInputNotSwitched(.micNotSelectable).line))

        let sys: [HUDModel.Warning] = [.defaultInputChanged(to: "X"), .switchedBackAfterInsert(device: "X"),
                                       .defaultInputRestored(to: "X"),
                                       .defaultInputRestoredElsewhere(to: "X", original: "Y", originalMissing: true),
                                       .defaultInputNotSwitched(.writeFailed), .switchBackFailed(current: "X")]
        let others: [HUDModel.Warning] = [.segmentNotSent, .meetingNotUsingMic, .passthroughTip, .openAIKeyInvalid]
        let sysFlags = sys.map { $0.isSysInput }, otherFlags = others.map { $0.isSysInput }
        #expect(sysFlags == [true, true, true, true, true, true])
        #expect(otherFlags == [false, false, false, false])
    }
}

@Suite struct RefreshLimiterTests {
    @Test func atMostTwicePerSecond() {
        var r = RefreshLimiter()
        #expect(r.request(now: 0) == .now)
        r.didRender(now: 0)
        #expect(r.request(now: 0.1) == .at(0.5))
        #expect(r.request(now: 0.2) == .merged)
        r.didRender(now: 0.5)
        #expect(r.request(now: 1.25) == .now)
        r.didRender(now: 1.25)
        #expect(r.request(now: 1.5) == .at(1.75))
    }
}
