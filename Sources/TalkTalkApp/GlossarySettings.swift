// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import Observation
import SwiftUI
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkSettingsUI

/// Shared with meeting translators; only the editor writes, workers read a lock-protected snapshot.
enum AppGlossary {
    static let store = GlossaryStore(url: EnginePaths.standard().home.appendingPathComponent("glossary.json"))
}

@MainActor @Observable
final class GlossarySettingsModel {
    struct Row: Identifiable { let id = UUID(); var entry: GlossaryEntry }
    var rows: [Row] = []
    /// The last read or save: ok 已保存, warn 需中文 + 至少一种译法, failed 读取失败 / 保存失败
    /// (the error in help). nil before any. The hero shows `currentResult`.
    private(set) var result: SettingsProblem?
    /// A save was refused for a missing term: the fields that still lack it are outlined in red
    /// until the next successful save or read.
    private(set) var showsMissing = false
    /// What the file holds, to tell unsaved edits apart (the 保存 button turns prominent).
    private var saved: [GlossaryEntry] = []
    private let store: GlossaryStore
    init(store: GlossaryStore = AppGlossary.store) { self.store = store; reload() }

    var hasUnsavedChanges: Bool { rows.map(\.entry) != saved }

    /// `result` while it still holds (§7.13: the save result in the hero's status slot):
    /// 已保存 only until the rows differ from the file, 需中文 + 至少一种译法 only while some
    /// term still lacks it (the save rule); a read or save failure stays until the next one.
    /// Otherwise unsaved edits wait for 保存.
    var currentResult: SettingsProblem? {
        let held: SettingsProblem? = switch result?.status {
        case nil: nil
        case .ok?: hasUnsavedChanges ? nil : result
        case .warn?: rows.contains { $0.entry.lacksChinese || $0.entry.lacksTranslation } ? result : nil
        default: result
        }
        if held == nil, hasUnsavedChanges { return SettingsProblem(.waiting, String(appLocalized: "未保存")) }
        return held
    }

    func reload() {
        do {
            try store.reload()
            saved = store.snapshot()
            rows = saved.map { Row(entry: $0) }
            result = nil
            showsMissing = false
        } catch {
            result = SettingsProblem(.failed, String(appLocalized: "读取失败"), help: error.localizedDescription)
        }
    }
    /// The new row's id, for the editor to scroll to and focus; nil at the limit.
    @discardableResult
    func add() -> UUID? {
        guard rows.count < GlossaryStore.limit else { return nil }
        let row = Row(entry: .init(zh: "", en: "", de: ""))
        rows.append(row)
        return row.id
    }
    func remove(_ id: UUID) { rows.removeAll { $0.id == id } }
    func save() {
        // A row left completely empty is not a term: it is dropped, not refused (the store's
        // missing-term rule still holds for every other row).
        rows.removeAll { row in
            [row.entry.zh, row.entry.en, row.entry.de, row.entry.note ?? ""]
                .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        do {
            try store.save(rows.map(\.entry))
            // The store trims; the rows keep their ids (and focus) and take the saved text.
            saved = store.snapshot()
            for index in rows.indices where index < saved.count { rows[index].entry = saved[index] }
            result = SettingsProblem(.ok, String(appLocalized: "已保存"), help: String(appLocalized: "下次翻译请求生效"))
            showsMissing = false
        } catch GlossaryStore.Failure.missingTerm {
            result = SettingsProblem(.warn, String(appLocalized: "需中文 + 至少一种译法"))
            showsMissing = true
        } catch {
            result = SettingsProblem(.failed, String(appLocalized: "保存失败"), help: error.localizedDescription)
        }
    }
}

/// Settings › 术语表 (settings visual system §7.13): a grouped Form with the same margins as
/// the other pages. The hero shows the count of the 30 allowed, whether the terms go to OpenAI,
/// the last save's result while it holds, and the page's actions: add, and the manual 保存
/// (§9.6 #6, prominent while there are unsaved edits). One row per term: 中文 / EN / DE / 备注
/// and its remove button.
struct GlossarySettingsView: View {
    @Bindable var model: GlossarySettingsModel
    /// The settings window's translation page, shared with onboarding step 5: its observable
    /// preferences keep the OpenAI / 仅本机 chip live.
    let translation: TranslationPage

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    /// The row whose 中文 field has focus: a new row gets it.
    @FocusState private var focusedRow: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section { hero(proxy) }
                if model.rows.isEmpty {
                    Section { empty(proxy) }
                } else {
                    Section {
                        columnHeads
                        ForEach($model.rows) { $row in
                            termRow($row).id(row.id)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Adds a row, then brings it into view with the focus in its 中文 field.
    private func addTerm(_ proxy: ScrollViewProxy) {
        guard let id = model.add() else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            focusedRow = id
        }
    }

    /// Text that may travel to OpenAI (§5.4, always visible): the same fact as the data
    /// boundary (`TranslationFlowFacts.cloudConnected`: a key, and an OpenAI direction now or in
    /// the running session). Until the shared `TranslationSettingsModel` (模型 › 翻译,
    /// onboarding step 5) exists in this run, the stored preferences.
    private var cloudTranslation: Bool {
        if let facts = translation.model?.flowFacts { return facts.cloudConnected }
        let prefs = TranslationPreferences.load(.standard)
        return prefs.cloudConsentGiven && prefs.anyCloud
    }

    // MARK: Z2

    private func hero(_ proxy: ScrollViewProxy) -> some View {
        let count = model.rows.count
        let limit = GlossaryStore.limit
        return PageHero(String(appLocalized: "术语表"), symbol: Icon.Page.glossary,
                        help: String(appLocalized: "也帮助识别中英混说")) {
            Text(verbatim: "\(count) / \(limit)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .accessibilityLabel(String(appLocalized: "\(count) 条术语，最多 \(limit) 条"))
            if let result = model.currentResult {
                StatusLabel(result.text, result.status, help: result.help)
            }
            if cloudTranslation {
                FactChip.cloud(String(appLocalized: "云端翻译时发给 OpenAI"), help: String(appLocalized: "术语随要翻译的文字一起发出"),
                               spoken: String(appLocalized: "启用云端翻译时，术语随文字发送给 OpenAI"))
            } else {
                FactChip(String(appLocalized: "仅本机"), symbol: Icon.privacyPromise,
                         help: String(appLocalized: "未启用云端翻译，术语不发出"))
            }
        } trailing: {
            // While the list is empty its own 添加 is the one way in.
            if count > 0 {
                IconButton(Icon.add, help: count >= limit ? String(appLocalized: "\(count) 条术语，最多 \(limit) 条")
                                                          : String(appLocalized: "添加术语")) { addTerm(proxy) }
                    .disabled(count >= limit)
            }
            if model.hasUnsavedChanges {
                Button("保存") { model.save() }.buttonStyle(.borderedProminent)
            } else {
                Button("保存") { model.save() }.buttonStyle(.bordered).disabled(true)
            }
        }
    }

    // MARK: Z3

    private func empty(_ proxy: ScrollViewProxy) -> some View {
        ContentUnavailableView {
            Label("还没有术语", systemImage: Icon.Page.glossary)
        } description: {
            Text("产品名 · 人名 · 专业词")
        } actions: {
            Button { addTerm(proxy) } label: {
                Label("添加", systemImage: Icon.add)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The column names over the fields, after the 22 pt icon column every row keeps.
    private var columnHeads: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Ladder.rowColumn, height: 1)
            Text("中文").frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "EN").frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "DE").frame(maxWidth: .infinity, alignment: .leading)
            Text("备注").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: Ladder.hitArea, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // Each field carries its column's name for VoiceOver.
        .accessibilityHidden(true)
    }

    private func termRow(_ row: Binding<GlossarySettingsModel.Row>) -> some View {
        let entry = row.wrappedValue.entry
        let term = entry.zh.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 8) {
            Color.clear.frame(width: Ladder.rowColumn, height: 1)
            field(String(appLocalized: "中文"), text: row.entry.zh, missing: model.showsMissing && entry.lacksChinese)
                .focused($focusedRow, equals: row.wrappedValue.id)
            field(String(appLocalized: "英语"), text: row.entry.en, missing: model.showsMissing && entry.lacksTranslation)
            field(String(appLocalized: "德语"), text: row.entry.de, missing: model.showsMissing && entry.lacksTranslation)
            field(String(appLocalized: "备注"), text: Binding(get: { row.wrappedValue.entry.note ?? "" },
                                                         set: { row.wrappedValue.entry.note = $0.isEmpty ? nil : $0 }),
                  prompt: String(appLocalized: "备注"), missing: false)
            IconButton(Icon.remove, help: String(appLocalized: "删除这条术语"),
                       accessibilityLabel: term.isEmpty ? String(appLocalized: "删除这条术语") : String(appLocalized: "删除术语“\(term)”"),
                       isDestructive: true) {
                model.remove(row.wrappedValue.id)
            }
        }
    }

    /// A Form row's text field shows no title of its own (it would render as a wrapped label
    /// beside a squeezed field); the column head names it, VoiceOver hears `label`. A field the
    /// last save found missing gets a red outline.
    private func field(_ label: String, text: Binding<String>, prompt: String? = nil, missing: Bool) -> some View {
        TextField(label, text: text, prompt: Text(verbatim: prompt ?? ""))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 40, maxWidth: .infinity)
            .overlay {
                if missing {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.red, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(label)
            .accessibilityHint(missing ? String(appLocalized: "必填") : "")
    }
}
