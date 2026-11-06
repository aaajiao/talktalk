import Testing
@testable import TalkTalkSettingsUI

/// Settings visual system §2, §3.3, §3.5: one problem line (the most severe), and a node's state
/// in words for VoiceOver and the tooltip.
@Suite struct FlowGridTests {
    @Test func theProblemLineShowsOnlyTheMostSevere() {
        let warn = SettingsProblem(.warn, "Zoom 未打开")
        let failed = SettingsProblem(.failed, "无可用麦克风")
        let risk = SettingsProblem(.risk, "对方能听到原声")
        #expect(SettingsProblem.mostSevere([warn, failed, nil]) == failed)
        #expect(SettingsProblem.mostSevere([warn, failed, risk]) == risk)
        #expect(SettingsProblem.mostSevere([SettingsProblem(.warn, "a"), SettingsProblem(.warn, "b")])?.text == "a")
        #expect(SettingsProblem.mostSevere([SettingsProblem(.ok, "已就绪"), SettingsProblem(.busy, "检查中")]) == nil)
        // A full sentence shows its first clause; the sentence moves to help.
        let phone = SettingsProblem(.warn, sentence: "Phone 的音频尚未就绪。请打开 Phone 后重新准备电话同传。")
        #expect(phone.text == "Phone 的音频尚未就绪" && phone.help == "Phone 的音频尚未就绪。请打开 Phone 后重新准备电话同传。")
        #expect(SettingsProblem(.warn, sentence: "未发送").help == nil)
    }

    @Test func nodesSayTheirStateAndWhereTheyLead() {
        let ready = FlowNode("对方", glyph: .symbol("person.wave.2"))
        #expect(ready.accessibilityValue == "已就绪" && ready.tooltip == nil && !ready.isCardButton)
        // The risk state always carries the risk badge and its red line.
        let risk = FlowNode("对方听到原声", glyph: .symbol("person.wave.2"), state: .risk)
        #expect(risk.badge == .risk && risk.riskText == "对方能听到原声" && risk.accessibilityValue == "对方能听到原声")
        let app = FlowNode("Zoom", glyph: .app(bundleID: nil, fallback: "app.dashed"), badge: .ok,
                           badgeReason: "Zoom 正在用 TalkTalk Mic", link: NodeLink("音频 · TalkTalk Mic") {},
                           help: "静音请用会议应用的按钮")
        #expect(app.isCardButton && app.accessibilityValue == "Zoom 正在用 TalkTalk Mic")
        #expect(app.tooltip == "Zoom 正在用 TalkTalk Mic · 静音请用会议应用的按钮")
        let link = FlowNode("双语字幕", glyph: .symbol("captions.bubble"), state: .off, link: NodeLink("字幕") {})
        #expect(link.tooltip == "字幕" && link.accessibilityValue == "已关闭")
    }

    @Test func stepsReadTheirNumberAndProgress() {
        let step = FlowNode("拨号／接听", glyph: .step(2, .todo), state: .dimmed)
        #expect(step.accessibilityLabel == "第 2 步，拨号／接听")
        #expect(step.accessibilityValue == "未完成，暂不可用")
        #expect(FlowNode("准备", glyph: .step(1, .done)).accessibilityValue == "已完成")
    }

    @Test func arrowsJoinOnlyNeighbouringContent() {
        let node = FlowCell.node(FlowNode("a", glyph: .symbol("mic")))
        let lane = FlowLane("听对方", cells: [node, node, .pass, .empty])
        #expect(lane.hasArrow(after: 0) && lane.hasArrow(after: 1) && !lane.hasArrow(after: 2))
        #expect(!FlowLane("x", cells: [node]).hasArrow(after: 0))
    }
}
