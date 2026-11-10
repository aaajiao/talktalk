// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// 使用场景 › 电话同传 (settings visual system §7.2). TalkTalk prepares interpretation; the
/// system Phone app owns dialing, answering and hanging up. Opening this scene only changes the settings
/// view, never the current audio session. The page opens with the live voice row, the speech
/// flow (the meeting's, with Phone as the app) and the three steps; ① is the bottom bar's 准备.
struct PhoneSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    let driver: DriverComponentsPage
    let links: ScenarioLinks
    /// Scrolls the page to a section and flashes it (a node's in-page anchor).
    let scrollTo: (String) -> Void

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    private var facts: ScenarioFacts { ScenarioFacts(state: state, mode: .phone) }

    private var checklist: PhoneChecklist {
        PhoneChecklist.make(phoneSession: facts.phoneSession, starting: state.meetingStarting,
                            stopping: state.meetingStopping, active: state.meetingActive,
                            readyToDial: state.phoneReadyToDial,
                            callAudioActive: state.phoneAudioActive, wasReady: state.phoneReadyThisSession)
    }

    var body: some View {
        let facts = facts
        let checklist = checklist
        Section {
            if facts.phoneSession, state.meetingActive, !state.meetingStopping, let voice = state.phoneVoice {
                liveRow(voice)
            }
            VStack(alignment: .leading, spacing: 10) {
                FlowGrid.phone(facts, driver: driver, links: links)
                FlowGrid.phoneSteps(checklist, problem: state.phoneProblem ?? state.phoneInputHint,
                                    dial: NodeLink(String(appLocalized: "在 Phone 中拨号或接听")) { scrollTo(SettingsAnchor.phoneDial) })
                if let problem = facts.problem {
                    StatusLabel(problem.text, problem.status, help: problem.help)
                }
                FactRow([FactChip(String(appLocalized: "结束同传不会挂断电话"), symbol: Icon.callContinues,
                                  help: String(appLocalized: "挂断请用 Phone"))])
            }
            .padding(.vertical, 4)
        }

        Section {
            openPhoneRow
                .flowFlash(SettingsAnchor.phoneDial, in: navigation.flow)
        }
        .id(SettingsAnchor.phoneDial)

        Section {
            DisclosureGroup(isExpanded: setupExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    FlowGrid.phoneSetup()
                    FactRow([
                        FactChip(String(appLocalized: "Phone 麦克风：使用系统设置"), symbol: Icon.talkTalkMic,
                                 help: String(appLocalized: "在 Phone 菜单“音频 › 麦克风”中选"),
                                 spoken: String(appLocalized: "在 Phone 菜单栏的“音频 › 麦克风”中选择“使用系统设置”")),
                        .risk(String(appLocalized: "否则对方听到原声"), help: String(appLocalized: "Phone 会直接用实体麦克风")),
                        FactChip(String(appLocalized: "用耳机"), symbol: Icon.headphones, help: String(appLocalized: "避免回声"))
                    ])
                }
                .padding(.vertical, 4)
                Button {
                    links.open(.audio, nil, nil)
                } label: {
                    Label("音频设置…", systemImage: Icon.audio)
                }
            } label: {
                SectionHeader(String(appLocalized: "首次连接"), symbol: Icon.iPhone)
            }
        }
    }

    /// Open until a phone session has once been ready to dial, then closed by default; the
    /// user's own choice holds for the window's life. The default is fixed for this visit of the
    /// page, so the first successful prepare does not fold the instructions away under the user
    /// (it closes on the next visit).
    private var setupExpanded: Binding<Bool> {
        Binding(get: {
            if let choice = navigation.phoneSetupExpanded { return choice }
            if let visit = navigation.phoneSetupDefault { return visit }
            let open = !state.phonePreparedOnce
            navigation.phoneSetupDefault = open
            return open
        }, set: { navigation.phoneSetupExpanded = $0 })
    }

    // MARK: ② Phone

    private var openPhoneRow: some View {
        LabeledContent {
            Button {
                state.onOpenPhone?()
            } label: {
                Label("打开 Phone", systemImage: Icon.openApp).labelStyle(.titleAndIcon)
            }
            .disabled(state.onOpenPhone == nil)
            .help(String(appLocalized: "拨号、接听和挂断都在系统 Phone 中完成"))
            .accessibilityLabel(String(appLocalized: "打开 Phone"))
        } label: {
            Label("在 Phone 中拨号或接听", systemImage: SubtitleTokens.SceneIcon.phone)
        }
    }

    // MARK: live voice

    /// Where my voice goes now (§7.2): the capsule, the delivery glyph and its shortest words;
    /// the details button carries the severity by shape (ⓘ, the triangle, the risk glyph). While
    /// the other party hears the original voice the red capsule stands alone.
    private func liveRow(_ voice: VoiceState) -> some View {
        HStack(spacing: 8) {
            VoiceCapsule(state: voice).accessibilityLabel(voice.accessibilityLabel)
            if let delivery = PhoneDelivery(voice.kind, phoneInputConfirmed: facts.phoneCheck.status == .ok) {
                Image(systemName: delivery.symbol)
                    .font(.system(size: Ladder.inline, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: delivery.text).font(.callout)
            }
            Spacer(minLength: 8)
            Button {
                state.phoneStatusDetailsPresented.toggle()
            } label: {
                detailsGlyph(voice.appearance.tone)
            }
            .buttonStyle(.plain)
            .help("发声详情")
            .accessibilityLabel(String(appLocalized: "发声详情"))
            .accessibilityValue(voice.accessibilityLabel)
            .popover(isPresented: $state.phoneStatusDetailsPresented, arrowEdge: .bottom) {
                details(voice)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 13 pt in a 22 × 22 click area: the risk glyph while the other party hears the original
    /// voice, the triangle while Phone does not receive; otherwise ⓘ.
    @ViewBuilder private func detailsGlyph(_ tone: VoiceTone) -> some View {
        Group {
            switch tone {
            case .risk: StatusGlyph(.risk)
            case .warn: StatusGlyph(.warn)
            case .original, .translate, .neutral:
                Image(systemName: Icon.info)
                    .font(.system(size: Ladder.inline, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Ladder.hitArea, height: Ladder.hitArea)
        .contentShape(Rectangle())
    }

    /// No title: the capsule, the full sentence and the way to the audio settings.
    private func details(_ voice: VoiceState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VoiceCapsule(state: voice)
            Text(verbatim: voice.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                state.phoneStatusDetailsPresented = false
                links.open(.audio, nil, nil)
            } label: {
                Label("音频设置…", systemImage: Icon.audio).labelStyle(.titleAndIcon)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}
