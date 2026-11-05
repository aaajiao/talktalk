import SwiftUI
import TalkTalkCore

/// Settings › 翻译 (ARCHITECTURE.md §11, §7.7). Reusable: the M1 settings window embeds it,
///
///     TranslationSettingsView(model: try TranslationSettingsModel.forCurrentApp())
///
/// It holds no state of its own beyond the model.
public struct TranslationSettingsView: View {
    @Bindable var model: TranslationSettingsModel

    public init(model: TranslationSettingsModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                Text("把识别出来的原文翻译成目标语言。OpenAI 和 Apple 翻译都只处理文字；语音识别和语音合成使用各自的模型。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("这里的翻译引擎与 OpenAI 模型选择在下次开始同传或字幕时生效。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Label("原文 → 译文", systemImage: "character.bubble") }
            directionSection
            if model.hasKey { modelSection }
            keySection
        }
        .formStyle(.grouped)
        .task { await model.loadModels() }
        .alert(item: $model.pendingYellow) { y in
            Alert(
                title: Text("\(y.model) 会明显变慢"),
                message: Text("""
                    这个模型需要额外推理，响应更慢，推理费用另计。\
                    实时翻译达到等待时限时会改用 Apple 翻译，因此部分句子可能不会由所选模型完成。
                    """),
                primaryButton: .default(Text("仍然使用")) { Task { await model.confirmYellow() } },
                secondaryButton: .cancel(Text("取消")) { model.cancelYellow() })
        }
    }

    // MARK: key

    @ViewBuilder private var keySection: some View {
        Section {
            Label {
                Text(TranslationSettingsText.cloudNotice).font(.callout)
            } icon: {
                Image(systemName: "cloud")
            }
            if !model.preferences.cloudConsentGiven {
                HStack {
                    Text("第一次填 key 前，请确认你同意上面的说明。").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("同意") { model.giveConsent() }
                }
            }
            if case .saved(let masked) = model.keyState {
                LabeledContent("当前 key") {
                    HStack {
                        Text(masked).monospaced()
                        Button("验证") { Task { await model.verify() } }
                            .disabled(isRunning(model.verification))
                        Button("删除", role: .destructive) { model.deleteKey() }
                    }
                }
            }
            HStack {
                SecureField(model.hasKey ? "粘贴新的 key 以替换" : "粘贴 OpenAI API key（sk-…）", text: $model.pasteField)
                    .textContentType(.password)
                    .onSubmit { Task { await model.saveAndVerify() } }
                Button(model.hasKey ? "替换并验证" : "保存并验证") { Task { await model.saveAndVerify() } }
                    .disabled(model.pasteField.isEmpty || !model.preferences.cloudConsentGiven)
            }
            if let p = model.pasteProblem { Text(p).foregroundStyle(.red).font(.callout) }
            if let h = model.savedHint { Text(h).foregroundStyle(.secondary).font(.callout) }
            checkRow(model.verification)
            HStack {
                Text(TranslationSettingsText.keyAdvice).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Link("OpenAI key 页面", destination: TranslationSettingsText.keyPageURL).font(.footnote)
            }
        } header: {
            Label("OpenAI API key", systemImage: "key")
        }
    }

    // MARK: model

    @ViewBuilder private var modelSection: some View {
        Section {
            if let n = model.notice {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(n).font(.callout)
                    Spacer()
                    Button("知道了") { model.dismissNotice() }
                }
            }
            LabeledContent("OpenAI 文本翻译模型") {
                HStack {
                    Picker("", selection: Binding(
                        get: { model.preferences.model },
                        set: { id in Task { await model.select(model: id) } })) {
                        if !choices.contains(where: { $0.id == model.preferences.model }) {
                            Text(model.preferences.model).tag(model.preferences.model)
                        }
                        ForEach(choices, id: \.id) { c in
                            Text(label(c)).tag(c.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(isRunning(model.listing) || isRunning(model.probe))
                    Button { Task { await model.loadModels() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                        .help("重新读取模型列表")
                        .accessibilityLabel("重新读取模型列表")
                }
            }
            checkRow(model.listing)
            LabeledContent("实时翻译可用性检查") {
                HStack {
                    if model.isYellow {
                        Label("会明显变慢", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Button("再测一次") { Task { await model.reprobe() } }.disabled(isRunning(model.probe))
                }
            }
            checkRow(model.probe)
            LabeledContent("费用", value: model.costLine)
            DisclosureGroup("更多模型选项") {
                Toggle("显示固定快照", isOn: Binding(get: { model.preferences.showSnapshots },
                                                 set: { v in model.update { $0.showSnapshots = v } }))
                Text("固定快照用于选择特定版本；日常使用可保留默认模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Label("OpenAI · 云端文本翻译", systemImage: "cloud")
        }
    }

    private var choices: [ModelFilter.Choice] {
        model.picker.models + (model.preferences.showSnapshots ? model.picker.snapshots : [])
    }

    private func label(_ c: ModelFilter.Choice) -> String {
        var s = c.id
        if c.isDefault { s += "（默认）" }
        if c.retiring { s += "（即将下线）" }
        if c.known?.supportsEffortNone == false { s += "（会明显变慢）" }
        return s
    }

    // MARK: directions

    @ViewBuilder private var directionSection: some View {
        Section {
            Toggle("用 OpenAI 翻译我说的话", isOn: Binding(
                get: { model.preferences.speakCloudEnabled },
                set: { v in model.update { $0.speakCloudEnabled = v } }))
            Label("中文（可夹英语）→ 英语 / 德语译音", systemImage: "mic")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("用 OpenAI 翻译听到的话", isOn: Binding(
                get: { model.preferences.listenCloudEnabled },
                set: { v in model.update { $0.listenCloudEnabled = v } }))
            Label("英语 / 德语 → 中文字幕", systemImage: "captions.bubble")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("开始会议同传时提醒云端文字传输", isOn: Binding(
                get: { model.preferences.meetingReminderEnabled },
                set: { v in model.update { $0.meetingReminderEnabled = v } }))
                .disabled(!model.preferences.listenCloudEnabled)
            Text("提醒你：对方的话会以文字发给 OpenAI 翻译。")
                .font(.caption).foregroundStyle(.secondary)
            Text("关闭某个方向的 OpenAI 后，该方向使用 Apple 本地文本翻译；OpenAI 超时或不可用时也由 Apple 备用。")
                .font(.callout).foregroundStyle(.secondary)
            if !model.preferences.anyCloud {
                Text("两个方向都关：全部走 Apple 翻译，不保温，也不连接 OpenAI。").font(.callout).foregroundStyle(.secondary)
            } else if !model.hasKey {
                Text("没有 key 时，开着的方向也走 Apple 翻译。").font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Label("两个翻译方向", systemImage: "arrow.left.arrow.right")
        }
    }

    // MARK: helpers

    private func isRunning(_ c: TranslationSettingsModel.Check) -> Bool {
        if case .running = c { return true }
        return false
    }

    @ViewBuilder private func checkRow(_ c: TranslationSettingsModel.Check) -> some View {
        switch c {
        case .idle: EmptyView()
        case .running(let s): HStack { ProgressView().controlSize(.small); Text(s).font(.callout) }
        case .ok(let s): Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .failed(let s): Label(s, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
        }
    }
}
