// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import Observation
import SwiftUI
import TalkTalkCore
import TalkTalkEngineHost

/// Shared with meeting translators; only the editor writes, workers read a lock-protected snapshot.
enum AppGlossary {
    static let store = GlossaryStore(url: EnginePaths.standard().home.appendingPathComponent("glossary.json"))
}

@MainActor @Observable
final class GlossarySettingsModel {
    struct Row: Identifiable { let id = UUID(); var entry: GlossaryEntry }
    var rows: [Row] = []
    var message: String?
    /// The message reports a failure (read/save error, missing term), not a successful save.
    private(set) var messageIsError = false
    private let store: GlossaryStore
    init(store: GlossaryStore = AppGlossary.store) { self.store = store; reload() }
    func reload() {
        do { try store.reload(); rows = store.snapshot().map { Row(entry: $0) }; message = nil }
        catch { report(String(localized: "术语表读取失败：\(error.localizedDescription)"), error: true) }
    }
    func add() { guard rows.count < GlossaryStore.limit else { return }; rows.append(Row(entry: .init(zh: "", en: "", de: ""))) }
    func remove(_ id: UUID) { rows.removeAll { $0.id == id } }
    func save() {
        do {
            try store.save(rows.map(\.entry))
            report(String(localized: "已保存，下次翻译请求生效。"), error: false)
        } catch GlossaryStore.Failure.missingTerm {
            report(String(localized: "每条填写中文，以及至少一种外语译法。"), error: true)
        } catch {
            report(String(localized: "术语表保存失败：\(error.localizedDescription)"), error: true)
        }
    }
    private func report(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}

struct GlossarySettingsView: View {
    @Bindable var model: GlossarySettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                if model.rows.isEmpty {
                    ContentUnavailableView {
                        Label("还没有术语", systemImage: SubtitleTokens.SettingsIcon.glossary)
                    } description: {
                        Text("为产品名、人名和专业词指定译法，也帮助识别中英混说。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(spacing: 12) {
                        HStack {
                            Text("中文").frame(maxWidth: .infinity, alignment: .leading)
                            Text("English").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Deutsch").frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(width: 40, height: 1)
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                        ForEach($model.rows) { $row in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        TextField(String(localized: "中文"), text: $row.entry.zh)
                                        TextField("English", text: $row.entry.en)
                                        TextField("Deutsch", text: $row.entry.de)
                                        Button { model.remove(row.id) } label: {
                                            Image(systemName: "minus.circle")
                                                .frame(width: 24, height: 24).contentShape(Rectangle())
                                        }
                                            .help("删除这条术语").accessibilityLabel(String(localized: "删除这条术语"))
                                            .frame(width: 40)
                                    }
                                    TextField(String(localized: "备注（可选）"), text: Binding(get: { row.entry.note ?? "" }, set: { row.entry.note = $0.isEmpty ? nil : $0 }))
                                }
                                .textFieldStyle(.roundedBorder).padding(4)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button { model.add() } label: {
                    Image(systemName: SubtitleTokens.SettingsIcon.add)
                }
                .buttonStyle(.borderless)
                .help("添加术语")
                .accessibilityLabel(String(localized: "添加术语"))
                .disabled(model.rows.count >= GlossaryStore.limit)
                Text("\(model.rows.count) / 30").foregroundStyle(.secondary)
                Spacer()
                Button("保存") { model.save() }.buttonStyle(.borderedProminent)
            }
            if let message = model.message {
                SettingsStatusLabel(message, model.messageIsError ? .warn : .ok).font(.callout)
            }
            Text("启用云端翻译时，术语随文字发送给 OpenAI；关闭时不发送。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
