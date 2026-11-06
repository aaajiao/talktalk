// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSession

/// Settings › 字幕 (redesign §7 字幕页). The scene cards only choose which scene's settings
/// are edited; they never start or switch a session.
struct SubtitleSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private var presentation: SubtitlePanel.Presentation { navigation.subtitlePresentation }
    private var video: Bool { presentation == .video }
    private var phone: Bool { presentation == .phone }
    private var scene: SubtitleScene {
        switch presentation {
        case .meeting: .meeting
        case .phone: .phone
        case .video: .video
        }
    }

    private static func presentation(for mode: MeetingMode) -> SubtitlePanel.Presentation {
        switch mode {
        case .meeting: .meeting
        case .phone: .phone
        case .captions: .video
        }
    }

    private var display: SubtitleStyle.Display {
        SubtitleStyle.Display(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency,
                              reduceMotion: reduceMotion)
    }

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
    private var backdrop: Binding<SubtitlePreviewBackdrop> {
        let scene = scene
        return Binding(get: { navigation.subtitlePreviewBackdrops[scene] ?? .initial(for: scene) },
                       set: { navigation.subtitlePreviewBackdrops[scene] = $0 })
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SettingsTabButton(title: String(localized: "会议同传"), symbol: SubtitleTokens.SceneIcon.meeting,
                                  summary: String(localized: "双方发言 · 原文与译文分栏"), selected: presentation == .meeting) { navigation.subtitlePresentation = .meeting }
                SettingsTabButton(title: String(localized: "电话同传"), symbol: SubtitleTokens.SceneIcon.phone,
                                  summary: String(localized: "电话对话 · 原文与译文分栏"), selected: phone) { navigation.subtitlePresentation = .phone }
                SettingsTabButton(title: String(localized: "视频字幕"), symbol: SubtitleTokens.SceneIcon.video,
                                  summary: String(localized: "扁宽字幕条 · 原文与中文"), selected: video) { navigation.subtitlePresentation = .video }
            }
            .padding([.horizontal, .top], 20)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "字幕使用场景"))

            Form {
                Section {
                    Toggle(isOn: $state.subtitlesVisible) {
                        Label("显示字幕（所有场景）", systemImage: "captions.bubble")
                    }
                    Toggle(isOn: $state.announceNewTranslations) {
                        Label("朗读新译文（VoiceOver）", systemImage: "text.bubble")
                    }
                } footer: {
                    // The preview sits in a footer: no grouped card around the window picture
                    // (macOS grouped forms ignore listRowBackground).
                    VStack(alignment: .leading, spacing: 20) {
                        Text("字号、背景和窗口位置按场景分别保存；朗读新译文对所有场景生效，只读定稿、不读草稿。切换此标签只编辑设置，不会启动或切换正在进行的会话。")
                        preview
                    }
                }

                Section {
                    LabeledContent("基础字号") {
                        HStack {
                            Slider(value: fontSize, in: 16...36, step: 1).frame(minWidth: 150)
                            Text("\(Int(fontSize.wrappedValue)) 磅").monospacedDigit().frame(width: 54, alignment: .trailing)
                        }
                    }
                    Button("恢复默认字号") { fontSize.wrappedValue = SubtitleOpacityControl.defaultFontSize(for: scene) }
                } header: {
                    Text("字幕大小")
                } footer: {
                    Text(video
                         ? String(localized: "每次显示同一句的原文与中文，草稿在原位更新为定稿。长句分页显示，每页最多两行；中文下方的圆点表示还有下一页。")
                         : String(localized: "对方和自己的发言按句对排列，保留最近约一分钟。向上滚动时整条时间线暂停跟随，点击“新字幕”提示回到最新。"))
                }

                if video { videoCaptionSettings }

                backgroundSettings

                Section("移动与隐私") {
                    Label("拖动标题栏或文字区域移动；视频可在菜单中锁定位置。", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    Label("窗口左上角的最小化按钮收起字幕，同传继续；从菜单栏选择“恢复字幕窗口”。", systemImage: "minus.circle")
                    Label("不抢键盘焦点，不出现在屏幕共享中。", systemImage: "rectangle.slash").foregroundStyle(.secondary)
                    Text("标题栏右侧显示发声状态、右⌥ 和结束操作；点状态查看说明。")
                        .font(.callout).foregroundStyle(.secondary)
                    if phone {
                        Text("电话窗口标题栏有“Phone”和“结束同传”按钮；拨号、接听和挂断在 Phone 中完成。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        // Cards open on the scene chosen in 使用场景 (and follow a session that starts).
        .onAppear { navigation.subtitlePresentation = Self.presentation(for: state.requestedScenario) }
        .onChange(of: state.requestedScenario) { _, mode in navigation.subtitlePresentation = Self.presentation(for: mode) }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("布局预览").font(.headline).foregroundStyle(.primary)
                Spacer()
                Picker("预览背景", selection: backdrop) {
                    Text("浅色网页").tag(SubtitlePreviewBackdrop.lightPage)
                    Text("深色视频帧").tag(SubtitlePreviewBackdrop.darkVideoFrame)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SubtitleLayoutPreview(configuration: .init(
                scene: scene, fontSize: fontSize.wrappedValue, opacity: opacity.wrappedValue,
                videoStyle: state.videoCaptionStyle, videoArrangement: state.videoCaptionArrangement,
                backdrop: backdrop.wrappedValue, display: display))
            Text(previewExplanation)
                .font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private var opacityControl: SubtitleOpacityControl {
        SubtitleOpacityControl.make(scene: scene, videoStyle: state.videoCaptionStyle, reduceTransparency: reduceTransparency)
    }

    private var backgroundSettings: some View {
        Section {
            LabeledContent("背景不透明度") {
                HStack {
                    Slider(value: opacity, in: 0.35...1, step: 0.05)
                        .frame(minWidth: 150).disabled(!opacityControl.enabled)
                    Text(verbatim: "\(Int((opacity.wrappedValue * 100).rounded()))%")
                        .monospacedDigit().frame(width: 54, alignment: .trailing)
                        .foregroundStyle(opacityControl.enabled ? .primary : .secondary)
                }
            }
            switch opacityControl.note {
            case .reduceTransparency?:
                Label(video
                      ? String(localized: "系统已开启“降低透明度”，视频字幕改用实底样式。关闭后会恢复这里保存的偏好。")
                      : String(localized: "系统已开启“降低透明度”，字幕背景保持不透明。关闭后会恢复这里保存的偏好。"),
                      systemImage: "accessibility")
                    .font(.callout).foregroundStyle(.secondary)
            case .strokeHasNoBackground?:
                Label("描边样式不使用背景", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        } header: {
            Text("窗口背景")
        } footer: {
            Text(video
                 ? String(localized: "使用 macOS 原生毛玻璃，默认 85%。只调整背景，文字不随之变淡；低于 75% 时文字加阴影。")
                 : String(localized: "使用 macOS 原生毛玻璃背景，默认 85%。只调整背景，文字和按钮不随之变淡；低于 75% 时文字加阴影。"))
        }
    }

    private var videoCaptionSettings: some View {
        Section {
            Picker("字幕样式", selection: $state.videoCaptionStyle) {
                Text("贴合玻璃").tag(VideoCaptionStyle.fittedGlass)
                Text("描边").tag(VideoCaptionStyle.stroke)
                Text("实底").tag(VideoCaptionStyle.plate)
            }
            .pickerStyle(.segmented)
            Picker("排列", selection: $state.videoCaptionArrangement) {
                Text("原文在上").tag(VideoCaptionArrangement.sourceFirst)
                Text("中文在上").tag(VideoCaptionArrangement.translationFirst)
            }
            .pickerStyle(.segmented)
            Toggle("长静默时变暗", isOn: $state.videoLongSilenceDim)
        } header: {
            Text("视频字幕")
        } footer: {
            Text(videoStyleExplanation + " "
                 + String(localized: "长静默时变暗：最后一页读完 8 秒后仍没有新内容，文字降到 35%；新内容到达立即恢复。"))
        }
    }

    private var videoStyleExplanation: String {
        switch state.videoCaptionStyle {
        case .fittedGlass: String(localized: "贴合玻璃：只在文字后面铺毛玻璃，其余区域完全透明。")
        case .stroke: String(localized: "描边：不铺背景，文字加黑色描边和阴影。")
        case .plate: String(localized: "实底：每行文字后垫深色底块。")
        }
    }

    private var previewExplanation: String {
        switch presentation {
        case .meeting:
            String(localized: "示例文字与音波，不启动音频。对方和自己的发言按句对排列，左原文、右译文；底部状态带显示你的发声状态。")
        case .phone:
            String(localized: "示例通话与音波，不拨号、不启动音频。电话对方和自己的发言按句对排列；电话操作位于窗口标题栏。")
        case .video:
            String(localized: "示例文字，不启动音频。视频只显示原文和中文；标题栏只在鼠标悬停时出现，这里显示悬停时的样子。")
        }
    }
}
