// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI

struct SubtitleSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section {
                SpeechFlow(steps: [
                    ("text.bubble", String(localized: "英语／德语原文")),
                    ("character.bubble", String(localized: "中文译文")),
                    ("captions.bubble", String(localized: "成对显示"))
                ])
                Toggle(isOn: $state.subtitlesVisible) {
                    Label("显示字幕", systemImage: "captions.bubble")
                }
            } header: {
                Text("对方与视频的字幕")
            } footer: {
                Text("这里只控制收听字幕；“我说的话”使用独立面板。")
            }
            Section {
                LabeledContent("译文字号") {
                    HStack {
                        Slider(value: $state.subtitleFontSize, in: 16...36, step: 1)
                            .frame(minWidth: 150)
                        Text("\(Int(state.subtitleFontSize)) 磅").monospacedDigit().frame(width: 54, alignment: .trailing)
                    }
                }
                Button("恢复默认字号") { state.subtitleFontSize = 22 }
            } header: {
                Text("字幕大小")
            } footer: {
                Text("字号立即应用，最多保留两组原文与译文。")
            }

            Section("预览") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("字幕").font(.caption).foregroundStyle(.white.opacity(0.75))
                    Text(verbatim: "Let's review the plan for next week.")
                        .font(.system(size: max(12, state.subtitleFontSize * 0.65)))
                        .foregroundStyle(.white.opacity(0.65))
                    Text("我们来看看下周的计划。")
                        .font(.system(size: state.subtitleFontSize, weight: .medium)).foregroundStyle(.white)
                    Text("草稿：先确认时间，再安排下一步。")
                        .font(.system(size: max(14, state.subtitleFontSize * 0.88)))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            Section("移动与隐私") {
                Label("拖动字幕标题栏即可移动。", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                Label("不抢键盘焦点，不出现在屏幕共享中。", systemImage: "rectangle.slash")
                    .foregroundStyle(.secondary)
                DisclosureGroup("字幕使用说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("灰色小字是原文，白色是中文定稿；草稿单独显示。长句自动换行，过长时可滚动查看。")
                        Text("移动字幕无需按住 ⌥，位置会按屏幕记住。也可从菜单切换“显示字幕”，两处保持同步。")
                    }
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}
