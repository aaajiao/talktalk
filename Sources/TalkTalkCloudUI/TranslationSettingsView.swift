// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSettingsUI

/// The language chips the app hands to the 文本翻译 diagram (§7.9): 我的译音 on 译文 and 对方语言
/// on 听到的话. They edit the app's session state, which this module cannot see.
public struct TranslationLanguageChips {
    let speak: AnyView
    let listen: AnyView
    let source: AnyView

    public init<Speak: View, Listen: View, Source: View>(speak: Speak, listen: Listen, source: Source) {
        self.speak = AnyView(speak)
        self.listen = AnyView(listen)
        self.source = AnyView(source)
    }
}

/// Settings › 模型 › 文本翻译 (settings visual system §7.9; ARCHITECTURE.md §11). The page opens
/// with the two-lane diagram, each direction's engine node carrying its OpenAI switch, then
/// DataBoundary; below it the API key (consent and key entry stay in Form rows, never in a
/// popover, §0.2 #16) and, once OpenAI is chosen or a key exists, the OpenAI model rows.
///
///     TranslationSettingsView(model: try TranslationSettingsModel.forCurrentApp())
///
/// `session`: when the running session started (a switch changed during it shows "下次开始生效").
/// `flash`: the settings window's flash; a menu problem row (字幕翻译：Apple 备用) lands on the
/// diagram, `.id(flowAnchor)`, and it flashes. It holds no state of its own beyond the model.
public struct TranslationSettingsView: View {
    @Bindable var model: TranslationSettingsModel
    private let session: Date?
    private let languages: TranslationLanguageChips?
    private let flash: FlowInteraction?

    /// The diagram section's scroll id.
    public nonisolated static let flowAnchor = "model.translation"

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    public init(model: TranslationSettingsModel, session: Date? = nil, languages: TranslationLanguageChips? = nil,
                flash: FlowInteraction? = nil) {
        self.model = model
        self.session = session
        self.languages = languages
        self.flash = flash
    }

    public var body: some View {
        let facts = model.flowFacts
        Form {
            Section {
                flashing(VStack(alignment: .leading, spacing: 10) {
                    flow(facts)
                    if let problem = facts.problem {
                        StatusLabel(problem.text, problem.status, help: problem.help)
                    }
                    DataBoundary(cloudEnabled: facts.cloudConnected, info: [TranslationSettingsText.cloudNotice])
                }
                .padding(.vertical, 4))
            }
            .id(Self.flowAnchor)
            OpenAIKeySection(model: model)
            if facts.showsOpenAISection { openAISection }
        }
        .formStyle(.grouped)
        .labelStyle(.settingsRow)
        .task { await model.loadModels() }
        .onAppear { model.trackSession(session) }
        .onChange(of: session) { _, start in model.trackSession(start) }
        .alert(item: $model.pendingYellow) { y in
            Alert(
                title: Text("\(y.model) 会明显变慢"),
                message: Text("更慢、推理另计费；超时的句子改用 Apple。"),
                primaryButton: .default(Text("仍然使用")) { Task { await model.confirmYellow() } },
                secondaryButton: .cancel(Text("取消")) { model.cancelYellow() })
        }
    }

    // MARK: diagram

    @ViewBuilder private func flashing<Content: View>(_ content: Content) -> some View {
        if let flash { content.flowFlash(Self.flowAnchor, in: flash) } else { content }
    }

    /// 我说的话 → engine → 译文 ‹我的译音›; 听到的话 ‹对方语言› → engine → 中文字幕.
    private func flow(_ facts: TranslationFlowFacts) -> FlowGrid {
        let translating = VoiceState.resolve(audio: .translating, scene: .meeting, phoneInputConfirmed: true)
        let said = FlowNode(String(localized: "我说的话"), glyph: .symbol(Icon.physicalMic),
                            accessory: languages.map { chips in NodeAccessory.controls { chips.source } },
                            help: String(localized: "按选定的中文或英语识别"))
        let target = FlowNode(String(localized: "译文"), glyph: .symbol(Icon.translation),
                              accessory: languages.map { chips in NodeAccessory.controls { chips.speak } })
        let heard = FlowNode(String(localized: "听到的话"), glyph: .symbol(Icon.remote),
                             accessory: languages.map { chips in NodeAccessory.controls { chips.listen } })
        let captions = FlowNode(String(localized: "中文字幕"), glyph: .symbol(Icon.subtitles))
        return FlowGrid(String(localized: "文本翻译路径"), lanes: [
            FlowLane(String(localized: "我说话 · 译音"), gutter: .voice(translating), cells: [
                .node(said), .node(engine(.speak, facts)), .node(target), .empty
            ]),
            FlowLane(String(localized: "听对方"), gutter: .symbol(Icon.listen), cells: [
                .node(heard), .node(engine(.listen, facts)), .node(captions), .empty
            ])
        ])
    }

    /// OpenAI (`network`) or Apple (`laptopcomputer`) with the direction's mini switch; with
    /// OpenAI, Apple stands by as the dashed satellite.
    private func engine(_ direction: TranslationDirection, _ facts: TranslationFlowFacts) -> FlowNode {
        let openAI = facts.choosesOpenAI(direction)
        let badge = facts.badge(direction)
        return FlowNode(openAI ? "OpenAI" : "Apple", glyph: .symbol(openAI ? Icon.cloud : Icon.thisMac),
                        badge: badge?.status, badgeReason: badge?.text,
                        accessory: .controls { cloudSwitch(direction, facts) },
                        satellite: openAI ? FlowSatellite(String(localized: "备用 Apple"), symbol: Icon.thisMac,
                                                          help: String(localized: "OpenAI 超时或出错时接管"), dashed: true)
                            : nil,
                        help: openAI ? String(localized: "文字发给 OpenAI 翻译") : String(localized: "在这台 Mac 上翻译"))
    }

    private func cloudSwitch(_ direction: TranslationDirection, _ facts: TranslationFlowFacts) -> some View {
        Toggle(direction == .speak ? String(localized: "用 OpenAI 翻译我说的话") : String(localized: "用 OpenAI 翻译听到的话"),
               isOn: Binding(get: { facts.choosesOpenAI(direction) }, set: { on in
                   model.update { prefs in
                       if direction == .speak { prefs.speakCloudEnabled = on } else { prefs.listenCloudEnabled = on }
                   }
               }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!facts.switchEnabled(direction))
            .help(facts.switchHelp(direction))
    }

    // MARK: OpenAI

    private var openAISection: some View {
        Section {
            modelRow
            Toggle(isOn: Binding(get: { model.preferences.showSnapshots },
                                 set: { on in model.update { $0.showSnapshots = on } })) {
                Label("显示固定快照", systemImage: Icon.snapshots)
            }
            .help(String(localized: "列出带日期的模型版本"))
            if let notice = model.notice { noticeRow(notice) }
            probeRow
            LabeledContent {
                Text(verbatim: model.costLine).foregroundStyle(.secondary)
            } label: {
                Label("费用", systemImage: Icon.cost)
            }
            .help(TranslationSettingsText.costHelp(yellow: model.isYellow))
            Toggle(isOn: Binding(get: { model.preferences.meetingReminderEnabled },
                                 set: { on in model.update { $0.meetingReminderEnabled = on } })) {
                Label("开始时提醒：文字发给 OpenAI", systemImage: Icon.cloudReminder)
            }
            .disabled(!model.preferences.choosesOpenAI(.listen))
            .help(model.preferences.choosesOpenAI(.listen) ? String(localized: "对方的话以文字发给 OpenAI")
                                                          : String(localized: "听到的话用 OpenAI 时才提醒"))
        } header: {
            SectionHeader("OpenAI", symbol: Icon.cloud)
        }
    }

    /// 模型, trailing in the fixed order (§3.8) value → status → icon button: the picker (suffix
    /// only "默认"; tortoise = slow, clock = going away), the list's state while it loads or
    /// fails, or a choice that waits for the next start, and 重新读取.
    private var modelRow: some View {
        let waits = model.flowFacts.modelWaits
        return LabeledContent {
            HStack(spacing: 6) {
                Picker(String(localized: "模型"), selection: Binding(
                    get: { model.preferences.model },
                    set: { id in Task { await model.select(model: id) } })) {
                    if !choices.contains(where: { $0.id == model.preferences.model }) {
                        Text(verbatim: model.preferences.model).tag(model.preferences.model)
                    }
                    ForEach(choices, id: \.id) { c in
                        choiceLabel(c).tag(c.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!model.hasKey || isRunning(model.listing) || isRunning(model.probe))
                .accessibilityHint(waits ? Text("下次开始生效") : Text(verbatim: ""))
                if case .running = model.listing {
                    StatusGlyph(.busy)
                } else if let line = model.listing.line, line.status == .failed {
                    StatusLabel(line.text, line.status, help: line.help)
                } else if waits {
                    StatusGlyph(.waiting)
                        .help(String(localized: "下次开始生效"))
                        .accessibilityLabel(String(localized: "下次开始生效"))
                }
                IconButton(Icon.refresh, help: String(localized: "重新读取模型列表")) { Task { await model.loadModels() } }
                    .disabled(!model.hasKey || isRunning(model.listing))
            }
        } label: {
            Label("模型", systemImage: Icon.Page.models)
        }
    }

    /// The glyph's meaning goes to VoiceOver in words (choiceSpoken).
    @ViewBuilder private func choiceLabel(_ c: ModelFilter.Choice) -> some View {
        let spoken = Text(verbatim: TranslationSettingsText.choiceSpoken(c))
        if let symbol = TranslationSettingsText.choiceSymbol(c) {
            Label {
                Text(verbatim: TranslationSettingsText.choiceTitle(c))
            } icon: {
                Image(systemName: symbol)
            }
            .accessibilityLabel(spoken)
        } else {
            Text(verbatim: TranslationSettingsText.choiceTitle(c))
                .accessibilityLabel(spoken)
        }
    }

    private var choices: [ModelFilter.Choice] {
        model.picker.models + (model.preferences.showSnapshots ? model.picker.snapshots : [])
    }

    /// "X 已下线 → Y" / "Y 即将下线", dismissed with xmark (知道了).
    private func noticeRow(_ notice: String) -> some View {
        HStack(spacing: 8) {
            StatusLabel(notice, .warn, help: TranslationSettingsText.retirementHelp(model.retirement))
            Spacer(minLength: 8)
            IconButton(Icon.close, help: String(localized: "知道了"),
                       accessibilityLabel: String(localized: "知道了，关闭下线通知")) { model.dismissNotice() }
        }
        .padding(.leading, Ladder.rowTextInset)
    }

    /// 实时可用: 变慢 on the yellow path, the last measurement (or why it failed), 再测一次.
    private var probeRow: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if model.isYellow {
                    FactChip(String(localized: "变慢"), symbol: Icon.slow, tone: .warn,
                             help: String(localized: "需额外推理，响应更慢"))
                }
                if let line = model.probe.line {
                    StatusLabel(line.text, line.status, help: line.help)
                }
                IconButton(Icon.refresh, help: String(localized: "再测一次"),
                           accessibilityLabel: String(localized: "再测一次实时可用")) { Task { await model.reprobe() } }
                    .disabled(!model.hasKey || isRunning(model.probe))
            }
        } label: {
            Label("实时可用", systemImage: Icon.performance)
        }
    }

    private func isRunning(_ c: TranslationSettingsModel.Check) -> Bool {
        if case .running = c { return true }
        return false
    }
}

/// The API key section of 模型 › 文本翻译 (§7.9), for any grouped Form (onboarding step 5 too):
/// before consent the prominent 同意发送文字 with the billing fact; the saved key (`sk-…•••`)
/// with 验证 and 删除 key (confirmed first); the paste field and 保存 (saving verifies); the
/// results, the clipboard reminder included; the OpenAI key page with one ⓘ. Put
/// `.labelStyle(.settingsRow)` on the Form.
public struct OpenAIKeySection: View {
    @Bindable var model: TranslationSettingsModel
    /// Where this section is shown: its own 删除 key confirmation appears only there.
    let host: TranslationSettingsModel.KeySectionHost

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    public init(model: TranslationSettingsModel, host: TranslationSettingsModel.KeySectionHost = .settings) {
        self.model = model
        self.host = host
    }

    public var body: some View {
        let consent = model.preferences.cloudConsentGiven
        Section {
            if !consent { consentRow }
            if case let .saved(masked) = model.keyState { savedKeyRow(masked) }
            pasteRow.disabled(!consent)
            let results = TranslationSettingsText.keyResults(pasteProblem: model.pasteProblem,
                                                             verification: model.verification,
                                                             saved: model.savedHint != nil)
            ForEach(results.indices, id: \.self) { index in
                StatusLabel(results[index].text, results[index].status, help: results[index].help)
                    .padding(.leading, Ladder.rowTextInset)
            }
            HStack(spacing: 8) {
                Link(destination: TranslationSettingsText.keyPageURL) {
                    Label("OpenAI", systemImage: Icon.openApp)
                }
                .help(String(localized: "打开 OpenAI 的 key 页面"))
                Spacer(minLength: 8)
                InfoButton(topic: String(localized: "API key"), lines: [TranslationSettingsText.keyAdvice])
            }
        } header: {
            SectionHeader(String(localized: "API key"), symbol: Icon.apiKey)
        }
    }

    /// The consent (§5.4: visible, with billing), in the row, never in a popover.
    private var consentRow: some View {
        HStack(spacing: 8) {
            Label {
                Button(String(localized: "同意发送文字")) { model.giveConsent() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(Text(verbatim: TranslationSettingsText.cloudNotice))
            } icon: {
                Image(systemName: Icon.cloud)
            }
            Spacer(minLength: 8)
            FactChip(String(localized: "按用量计费"), symbol: Icon.cost, help: String(localized: "费用记在你的 OpenAI 账户"))
        }
    }

    private func savedKeyRow(_ masked: String) -> some View {
        LabeledContent {
            HStack(spacing: 0) {
                IconButton(Icon.verify, help: String(localized: "验证"), accessibilityLabel: String(localized: "验证 key")) {
                    Task { await model.verify() }
                }
                .disabled(isRunning(model.verification))
                IconButton(Icon.delete, help: String(localized: "删除 OpenAI key"), isDestructive: true) {
                    model.keyDeletionAskedBy = host
                }
            }
        } label: {
            Label {
                Text(verbatim: masked).monospaced()
            } icon: {
                Image(systemName: Icon.apiKey)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "已存入钥匙串的 key"))
        // OpenAI shows a secret key once: a slip beside 验证 must not cost the key.
        .alert(String(localized: "删除 OpenAI key？"), isPresented: confirmsDeletion) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "删除 OpenAI key")) { model.deleteKey() }
        } message: {
            Text(String(localized: "只从这台 Mac 的钥匙串删除，不会撤销 OpenAI 账户中的 key。之后需要重新输入 key 才能使用云端翻译。"))
        }
    }

    /// The field's own title would render as a wrapped Form label beside a squeezed field
    /// (582176e): hidden, with "sk-…" as the prompt inside a fixed-width field.
    private var pasteRow: some View {
        HStack(spacing: 8) {
            Image(systemName: Icon.pasteKey)
                .font(.system(size: Ladder.row))
                .foregroundStyle(.secondary)
                .frame(width: Ladder.rowColumn)
                .accessibilityHidden(true)
            SecureField(String(localized: "OpenAI API key"), text: $model.pasteField, prompt: Text(verbatim: "sk-…"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .frame(width: 240)
                .help(model.hasKey ? String(localized: "粘贴新的 key 以替换") : String(localized: "粘贴 OpenAI API key"))
                .accessibilityLabel(model.hasKey ? String(localized: "新的 OpenAI API key") : String(localized: "OpenAI API key"))
                .onSubmit { Task { await model.saveAndVerify() } }
            Button(String(localized: "保存")) { Task { await model.saveAndVerify() } }
                .disabled(model.pasteField.isEmpty)
                .help(String(localized: "存入钥匙串并验证"))
            Spacer(minLength: 0)
        }
    }

    /// This section's 删除 key confirmation; another window's stays closed.
    private var confirmsDeletion: Binding<Bool> {
        Binding(get: { model.keyDeletionAskedBy == host },
                set: { if !$0, model.keyDeletionAskedBy == host { model.keyDeletionAskedBy = nil } })
    }

    private func isRunning(_ c: TranslationSettingsModel.Check) -> Bool {
        if case .running = c { return true }
        return false
    }
}
