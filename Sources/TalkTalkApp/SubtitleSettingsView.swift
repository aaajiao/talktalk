// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI

struct SubtitleSettingsView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
                Text("字幕窗口")
            } footer: {
                Text("对方字幕与我的翻译发言显示在同一个窗口。关闭文字显示后，必要的音频状态和问题提示仍会保留。")
            }
            Section {
                LabeledContent("基础字号") {
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
                Text("拖动窗口边缘调整大小，文字同步缩放；高度决定可见内容，长文可滚动。")
            }

            Section {
                LabeledContent("背景不透明度") {
                    HStack {
                        Slider(value: $state.subtitleBackgroundOpacity, in: 0.35...1, step: 0.05)
                            .frame(minWidth: 150)
                            .disabled(reduceTransparency)
                        Text(verbatim: "\(Int((state.subtitleBackgroundOpacity * 100).rounded()))%")
                            .monospacedDigit().frame(width: 54, alignment: .trailing)
                    }
                }
                if reduceTransparency {
                    Label("系统已开启“降低透明度”，字幕背景保持不透明。关闭后会恢复这里保存的偏好。", systemImage: "accessibility")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("窗口背景")
            } footer: {
                Text("使用 macOS 原生毛玻璃背景，默认 85%。只调整背景，文字和按钮不随之变淡。")
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
                .background {
                    if reduceTransparency || state.subtitleBackgroundOpacity >= 1 {
                        RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
                            .opacity(state.subtitleBackgroundOpacity)
                    }
                }
                .environment(\.colorScheme, .dark)
            }

            Section("移动与隐私") {
                Label("拖动标题栏或文字区域移动；拖动边缘调整大小。", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                Label("不抢键盘焦点，不出现在屏幕共享中。", systemImage: "rectangle.slash")
                    .foregroundStyle(.secondary)
                DisclosureGroup("字幕使用说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("灰色小字是原文，白色是中文定稿；草稿单独显示。长句自动换行，过长时可滚动查看。")
                        Text("移动字幕无需按住 ⌥，位置和尺寸会按屏幕记住。也可从菜单切换“显示字幕”，两处保持同步。")
                    }
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}
