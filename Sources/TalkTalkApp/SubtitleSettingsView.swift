// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI

struct SubtitleSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var presentation: SubtitlePanel.Presentation { navigation.subtitlePresentation }
    private var video: Bool { presentation == .video }
    private var phone: Bool { presentation == .phone }

    private var fontSize: Binding<Double> {
        Binding(get: {
            switch presentation {
            case .meeting: state.subtitleFontSize
            case .phone: state.phoneSubtitleFontSize
            case .video: state.videoSubtitleFontSize
            }
        }, set: {
            switch presentation {
            case .meeting: state.subtitleFontSize = $0
            case .phone: state.phoneSubtitleFontSize = $0
            case .video: state.videoSubtitleFontSize = $0
            }
        })
    }
    private var opacity: Binding<Double> {
        Binding(get: {
            switch presentation {
            case .meeting: state.subtitleBackgroundOpacity
            case .phone: state.phoneSubtitleBackgroundOpacity
            case .video: state.videoSubtitleBackgroundOpacity
            }
        }, set: {
            switch presentation {
            case .meeting: state.subtitleBackgroundOpacity = $0
            case .phone: state.phoneSubtitleBackgroundOpacity = $0
            case .video: state.videoSubtitleBackgroundOpacity = $0
            }
        })
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SettingsTabButton(title: String(localized: "会议同传"), symbol: "rectangle.split.2x2",
                                  summary: String(localized: "双方发言 · 原文与译文分栏"), selected: presentation == .meeting) { navigation.subtitlePresentation = .meeting }
                SettingsTabButton(title: String(localized: "电话同传"), symbol: "phone",
                                  summary: String(localized: "电话对话 · 原文与译文分栏"), selected: phone) { navigation.subtitlePresentation = .phone }
                SettingsTabButton(title: String(localized: "视频字幕"), symbol: "captions.bubble",
                                  summary: String(localized: "扁宽字幕条 · 原文在上，中文在下"), selected: video) { navigation.subtitlePresentation = .video }
            }
            .padding([.horizontal, .top], 20)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "字幕使用场景"))

            Form {
                Section {
                    Toggle(isOn: $state.subtitlesVisible) {
                        Label("显示字幕（所有场景）", systemImage: "captions.bubble")
                    }
                } footer: {
                    Text("字号、背景和窗口位置按场景分别保存。切换此标签只编辑设置，不会启动或切换正在进行的会话。")
                }

                Section {
                    SubtitleLayoutPreview(presentation: presentation, fontSize: fontSize.wrappedValue)
                        .frame(maxWidth: .infinity)
                        .frame(height: video ? 140 : 310)
                        .padding(12)
                        .background {
                            if reduceTransparency || opacity.wrappedValue >= 1 {
                                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
                            } else {
                                RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
                                    .opacity(opacity.wrappedValue)
                            }
                        }
                        .environment(\.colorScheme, .dark)
                } header: {
                    Text("布局预览")
                } footer: {
                    Text(previewExplanation)
                }

                Section {
                    LabeledContent("基础字号") {
                        HStack {
                            Slider(value: fontSize, in: 16...36, step: 1).frame(minWidth: 150)
                            Text("\(Int(fontSize.wrappedValue)) 磅").monospacedDigit().frame(width: 54, alignment: .trailing)
                        }
                    }
                    Button("恢复默认字号") { fontSize.wrappedValue = video ? 26 : 22 }
                } header: {
                    Text("字幕大小")
                } footer: {
                    Text(video
                         ? String(localized: "每次显示同一句的原文与中文，草稿在原位更新为定稿。长句按完整文字行接续显示，拖动边缘可调整阅读空间。")
                         : String(localized: "连续发言保留最近约一分钟，原译文一起更新。上翻时暂停跟随，点击“回到最新”继续；新一轮翻译会替换自己的上轮文字。"))
                }

                Section {
                    LabeledContent("背景不透明度") {
                        HStack {
                            Slider(value: opacity, in: 0.35...1, step: 0.05)
                                .frame(minWidth: 150).disabled(reduceTransparency)
                            Text(verbatim: "\(Int((opacity.wrappedValue * 100).rounded()))%")
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

                Section("移动与隐私") {
                    Label("拖动标题栏或文字区域移动；拖动边缘调整大小。", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    Label("点击黄色按钮最小化，同传继续；从菜单栏选择“恢复字幕窗口”。", systemImage: "minus.circle")
                    Label("不抢键盘焦点，不出现在屏幕共享中。", systemImage: "rectangle.slash").foregroundStyle(.secondary)
                    Text("底部一行显示运行状态；点击“状态与提示”图标查看说明。关闭文字后仍保留必要状态。")
                        .font(.callout).foregroundStyle(.secondary)
                    if phone {
                        Text("电话窗口标题栏可打开 Phone 或结束同传；拨号、接听和挂断在 Phone 中完成。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var previewExplanation: String {
        switch presentation {
        case .meeting:
            String(localized: "示例文字与音波，不启动音频。上排是对方，下排是自己；左原文、右译文，鼠标所在的一格独立滚动。")
        case .phone:
            String(localized: "示例通话与音波，不拨号、不启动音频。上排是电话对方，下排是自己；每格独立滚动，电话操作位于窗口标题栏。")
        case .video:
            String(localized: "示例文字，不启动音频。视频仅显示原文和中文；长原文不会挤走译文。")
        }
    }
}
