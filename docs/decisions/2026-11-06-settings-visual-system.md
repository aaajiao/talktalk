# TalkTalk 设置：图示优先的视觉系统（定稿规格）

> 状态：2026-11-06 用户审阅示意页后批准（“全部同意，开始”），§9.6 六项删除同时确认；按 §9.1 实施。基线是 HEAD e36b0b3（含 95cdf11：共享固定场景头、字幕预览背景跟随系统外观；4849095：一步退出）。
> 实施：§9.1 的 8 步（12 行，含协调修正共 13 个提交）已于 2026-11-07 在 main 落地，提交号见 §9.1。实现时按代码和实测做出的裁决写在各节的“实现记录”里，与该节正文冲突时以实现记录为准。仍待用户决定的只有 §7.4 “共享屏幕不可见” chip 的可见词；§8.7 的菜单栏图标已于 2026-11-07 确认保留各问题的形状。
> 来源：三份候选设计和两位评审。评审 1 选“图示优先（Diagram-First）”，评审 2 选“图即界面（Diagram-as-Interface）”。本规格的取舍是：以 Diagram-First 的页面骨架、命中规则和 Grid 实现为底；场景页采用 Diagram-as-Interface 的“图即控件”写法；共享 target 和“无角标即就绪”两条规则取自 State Board。两位评审意见冲突的地方，统一在 §0.2 裁决。
> 已核实的事实：
> - 设置窗口可调整大小，内容区默认 880×640，最小 820×600（`SettingsWindowController.swift:189-208`）。所以内容列默认约 690pt，最小约 630pt。
> - `TranslationSettingsView` 位于 TalkTalkCloudUI，`DriverComponentView` 位于 TalkTalkDriverSupport，`EnrollmentView` 位于 TalkTalkVoice。三者都不能 import TalkTalkApp。
> - `ScrollViewReader.scrollTo` 已在 `AudioSettings.swift:177-212` 中可用。
> - `SubtitlePanel.swift:304` 已用 KVO 观察 `isVoiceOverEnabled`。
> - 本机用 `NSImage(systemSymbolName:)` 检查了本文用到的 88 个符号，只有 `mic.badge.exclamationmark` 返回 nil。它是合成字形，已有回退方案（`SubtitleTokens.swift:186`）。

> 2026-11-07 分类调整（用户批准）：两页保留，原“模型”更名“识别与翻译”，只保留语音识别与文本翻译；语音合成的图、状态与使用规则归入“我的声音”，无声音档案时也先显示概览，点“录制”才进入录制流程。原“组件”更名“安装与维护”，两张卡为“语音资源”和“TalkTalk Mic”；前者保留本地引擎、模型下载、档位与维护操作，后者保留驱动操作。既有卡片、流程图、颜色与控件样式不变。内部导航标识兼容旧入口；旧合成入口转到我的声音。本文旧实现记录中的名称按此更新解释。

---

### 2026-11-07 删除操作统一补充

数据删除与卸载的入口统一使用动态系统红色：文字入口用共享 `SettingsDestructiveButton` 的原生 small push 按钮，图标与维护菜单用显式 `isDestructive`；禁用时灰显且不执行动作。声音档案、本场诊断录音、过期数据清理、完全卸载采用正常标签加右侧按钮。API key、声音档案、本地模型、引擎、TalkTalk Mic、本场诊断录音、手动过期清理与完全卸载均使用明确对象与后果的原生确认、保留取消；用户已主动选择的最终删除确认由 macOS 画普通系统按钮，不手动染红；“删除诊断数据？”确认同样是普通系统按钮，“全部删除”为默认键。术语表移除只改未保存编辑，保留立即移除的轻量行为；忘记耳机类型、恢复默认、停止、关闭不作为数据删除染红。所有实际删除 owner、会话阻断、管理员授权及自动清理规则保持。

## 0. 裁决摘要

### 0.1 一句话

每页开头都是一个**图形**：卡片行、流程图或状态方块，三者取一。图回答“声音和文字去了哪里、现在好了没有”。控件尽量挂在图的节点上；放不进节点的控件放进带固定图标列的原生 Form 行。可见文字只剩四类：控件名、状态词、安全事实和确认弹窗。

### 0.2 评审冲突的明确裁决

| # | 冲突 | 裁决 | 理由 |
|---|---|---|---|
| 1 | 是否每页都必须有 FlowDiagram（DaI）。DF 只在讲“去向”的页画图 | **只在讲去向的页画流程图**。通用、术语表用 `PageHero`，不画假流程 | 评审 1：箭头会暗示并不存在的因果，“开机→告知→通知”就是这种情况 |
| 2 | FlowGrid 的实现：自定义 `Layout`（DaI）或 SwiftUI `Grid`（DF） | **SwiftUI `Grid`，固定节点高、列等宽**。回环用横跨列的 `GridRow`，不用 overlay `Path` | 离 8c87ba7 的滚动布局循环最远；不需要几何回传 |
| 3 | 节点内嵌控件后的命中方式（DaI：背景按钮叠控件） | **DF 规则**：没有控件的节点整卡是按钮；有控件的节点只有右下角 24×24 chevron 是链接；chevron 常显（SB） | 避免 Button 里嵌 Menu/Toggle；VoiceOver 读序清楚 |
| 4 | 运行横幅：DaI 保留，DF/SB 删除 | **删除 RunBanner**。运行状态由场景卡的绿点和计时，加底栏的“● 场景 · 来源 · 12:03”承担 | 卡片上的图形已经承载这条信息；列入 §9.6 待用户确认 |
| 5 | 录音横幅：DF 删除，只留卡片角标；DaI/SB 保留 | **保留 RecordingBanner**，同时加卡片角标 | 隐私关键事实不能只靠 11pt 角标（评审 2） |
| 6 | 选中卡片是否保留 ✓（DaI 保留，DF/SB 删） | **删除 ✓**。选中改为 2pt accent 描边、10% accent 底色和 accent 图标，形状、填充、颜色三重线索；右上角留给状态角标 | 只靠颜色在增强对比或灰色强调色下太弱（评审 2）；底色补上这一点 |
| 7 | 行首图标：13pt/20 列（DaI）或 15pt/22 列（DF/SB） | **15pt，放在 22pt 列**；分组标题图标也用 15pt、同一列 | 两套方案一致；分组标题与行同列，满足反馈 (d) |
| 8 | 状态图形：12pt（DaI/DF）或 13pt（SB） | **13pt**，与行内图标按钮同级 | 少一档尺寸。DF 的 12 和 13 只差 1pt，正是“大大小小不一样”的来源（评审 2） |
| 9 | 导出说明：用划掉的图标（DaI）还是文字 | **FactChip“不含 key 与文字” + ⓘ 列出项目** | 纯图标有歧义（评审 2） |
| 10 | 语音合成页的场景条：纯图标（DaI）还是文字 | **图标 + 最短文字**：“会议·电话生成译音”“视频不生成” | 它说明对方能否听到声音，属于安全语义 |
| 11 | 字幕窗口行为：DaI 用纯图标 chip | **图标 + 最短文字**：可拖动 / 不抢焦点 / 收起后继续 / 共享屏幕不可见 | 同 #9 |
| 12 | 视频样式缩略图要不要文字 | **缩略图下方加 caption2 名称**（≤4 字） | DaI 自己在风险里写的回退方案；没有悬停也能看懂 |
| 13 | 菜单中“关于”是否配 info.circle | **菜单应用信息行使用单色双对话框图标，软件名与完整版本号同处一行；“退出”不配图** | 一义一形：info.circle 只表示“打开说明” |
| 14 | 音频、我的声音是否加 PageHero（DF） | **不加**，直接以流程图开头 | 避免 Hero 状态与节点角标重复显示同一事实（评审 2） |
| 15 | 共享组件放在哪里 | **新库 target `TalkTalkSettingsUI`**，第一次提交就建 | 否则文本翻译、虚拟麦克风、录音窗口无法复用，各模块尺寸会再次漂移 |
| 16 | 弹层里能放什么 | **主控件永不进弹层**；弹层只放次要操作和安全长句（SB）。API key 输入、同意按钮留在 Form 行里 | 涉及同意和计费的流程不能藏起来（评审 2） |

---

## 1. 原则

### 1.1 用户原话

- “所有设置页面，希望能主要以图示的方式讲清楚，能不用的文字就不用。这是我们之前的一大原则，现在有点把它改回去了。所以我觉得这个一定要整体来规划，必须是一套简洁、以视觉为主的设置页面逻辑”
- “设计要符合苹果的标准”
- “能用图标表达的就不要写字（图形一定要起到足够的作用）”
- “每一页都有很多注释，有些纯粹是废话”
- “所有设置列表里的那些小图标，都大大小小不一样了”

### 1.2 三条原则

1. **图示讲清楚。** 每页先给图形：卡片行、流程图或状态方块。图形承载状态（角标、计时、实线/虚线、灰显），所以它不是装饰。“图形一定要起到足够的作用”的检验标准是：把文字遮住，用户仍能看出哪个子页需要处理、对方此刻听到什么、哪些东西会离开这台 Mac。
2. **能不用的文字就不用。** 页面上不允许常显的灰色段落。说明按以下顺序安放：画进图 → 写进控件名或菜单项 → `.help` → 无障碍文本 → ⓘ（只用于安全事实）→ 确认弹窗。无障碍文本承载的信息量不得少于被删掉的可见文字。
3. **苹果标准就是原生，不是纯文字。** 原生的含义包括：SF Symbols、系统材质（`.bar` 和 `.thinMaterial`）、原生 Form/Toggle/Picker/Menu/NSPopover、侧栏使用系统图标尺寸、每一层只有一个固定尺寸、一种含义只用一种形状、VoiceOver 体验对等。HIG 不能作为删除图形的理由。34c0724 那次“HIG pass”把卡片换成纯文字分段控件、去掉分组标题图标和流程图，这些都要恢复（§6）。

### 1.3 硬性例外：安全语义的词保留“图标 + 最短文字”，不得改成纯图标

原声、译音、对方听到原声、对方听到译音、对方能听到原声、已送入 Phone、仅本机 · Phone 未接收、未发送、已中止、本机播放、接通后对方才能听到你、播完回到原声、通话不会挂断 / 结束同传不会挂断电话。

完整清单见 §5.4。

---

## 2. 页面骨架（每页从上到下的固定结构）

宽度按以下数值计算：内容列 = 窗口内容宽 − 侧栏 190；左右各留 20pt 内边距；Form 分组卡片内边距 12。

- 默认窗口：内容列 690，分组卡片内可用宽约 626。
- 最小窗口（820）：内容列 630，可用宽约 566。

```
┌ 窗口标题 = 侧栏页名（系统绘制；页内不再写页名）
│
├ Z0  ReturnPill（可选，固定，不滚动）            高 24，上 10，左对齐内边距
├ Z1  导航带（固定，不滚动，永不收起）——三选一，按优先级：
│       a. GlobalRow + CardRow（仅字幕页：GlobalRow 28 在卡片上方）
│       b. CardRow（使用场景、模型、组件、隐私与诊断）  卡高 64，上 12、下 12
│       c. 无（单页）
│     下方一条原生 Divider
├ Z1b 固定横幅（可选）：RecordingBanner（隐私与诊断三个子页）  高 32
│
├ ── Form(.grouped) 开始滚动 ──
├ Z2  主图：Form 第一个 Section，无 header，三选一：
│       FlowGrid（讲去向的页）/ SubtitleLayoutPreview（字幕）/ DataBoundary（数据与隐私）
│       单页没有流程图时，用 PageHero 方块（通用、术语表）
│     主图下方同一 Section 内：
│       · 问题行：最多 1 行，当前优先级最高的问题（risk > failed > warn > waiting）
│       · FactRow：0–1 行安全事实 chip
├ Z3  控件 Section：只放节点装不下的控件，0–4 个
│       header = SectionHeader（15pt 图标在 22 列 + ≤4 字 + 可选 ⓘ），图标 = 锚定节点的图标
│       Section 只有 1–2 行、且主图已说明内容时，不写 header
│       每行用 .settingsRow 标签样式；没有 footer
├ Z4  破坏性 Section（最后；trash 行，红色）
├ ── Form 结束 ──
└ Z5  ScenarioBottomBar（只在使用场景页；固定，高 56，.bar 材质）
```

**规则**

- 页内不出现与侧栏、卡片或节点重名的标题。
- `DisclosureGroup` 只能用来装数据或图：全部模型、详情、数值、技术详情、首次连接图。不能用来装说明文字。
- 切换卡片时滚动回顶部：`.id(selection)` 放在 Form 上。
- 每页的主图都在固定导航带之下，所以导航带的位置不随内容变化。
- 跨页跳转（节点 chevron）在目标页显示 ReturnPill，返回时恢复来源的页面、子页、场景和滚动锚点。
- 节点上的 `.anchor` 会滚动到同图标的 Section，并闪一次 2pt accent 描边，持续 0.8s；开启“减少动态效果”时不闪。
- `SettingsProblem(sentence:)` 取首句，英文以“. ”“; ”、句末“.”和换行为分界。

---

## 3. 组件库

### 3.0 模块归属

新建库 target **`TalkTalkSettingsUI`**，依赖 TalkTalkCore。下列依赖它：

- TalkTalkApp
- TalkTalkCloudUI（TranslationSettingsView、OpenAIOnboardingStep）
- TalkTalkDriverSupport（DriverComponentView）
- TalkTalkVoice（EnrollmentView）

以下组件全部放在这个 target，加 `public`：

- 来自 `SettingsFlowComponents.swift`：VoiceCapsule、Keycap、InfoButton、SettingsStatus 及其状态标签
- 来自 `SubtitleStyle` 的合成风险字形绘制（或者通过协议注入）
- §3 中所有新组件

不放进去的组件：ScenarioBottomBar，以及依赖 TalkTalkSession 状态的工厂函数。`FlowGrid.meeting(state)` 这类工厂留在各自模块，只调用共享组件。

**实现记录（第 1 次提交 7077444 起）**

- 迁入的比清单多。SwiftUI 的 VoiceCapsule、Keycap 包着 `VoiceCapsuleView`、`KeycapActionView`，这两个类继承 `TitlebarControl`，用到 `HoverClearing` 和 `SubtitleStyle`，所以它们连同整份 `SubtitleStyle` 原样迁入，`TitlebarControl` 改为 `open`。`SubtitleStyle.toneColor(VoiceTone)` 依赖 TalkTalkSession，留在 App 的扩展里（`SubtitleStyle+Tone.swift`）。
- 之后的提交在本 target 新增：`CardBadge`／`CardItem`／`SettingsCard`／`CardRow`／`GlobalRow`、`ReturnPill`／`FlowInteraction`、`FlowGrid` 一族与 `NodeChip`、`AppIcon`、`SettingsProblem`、`PageHero`、`DataBoundary`、`ThumbnailChoice`、`RecordingBanner`。新增测试目标 `TalkTalkSettingsUITests`（`CardBadgeTests`、`FlowGridTests`）。
- 组件的文字参数都是已本地化的 `String`，调用方传 `String(localized:)`。所以 `check-strings.sh` 的 KEY_CALLEES 不列这些组件，直接传入的中文字面量会被标为未本地化。
- `SessionClock` 从 TalkTalkSession 移到 TalkTalkCore，卡片计时与菜单标题用同一算法。
- 留在各自模块的：App 的 `ScenarioBottomBar`、`ScenarioCardHeader`（三张场景卡的 `CardRow` 薄封装）以及 `FlowGrid.meeting/phone/video/audio/myVoice/engine` 等工厂；TalkTalkDriverSupport 的 `FlowGrid.driver`。

### 3.1 SettingsCard + CardRow

取代 `SettingsTabButton`、`SettingsSubpagePicker`（ModelSettingsView.swift:122-152）以及 `ScenarioCardHeader` 的内部实现。

- **作用**：全窗口唯一的子页和场景导航，用于使用场景、字幕（同一组场景卡）、模型（卡间有箭头）、组件、隐私与诊断，以及引导的场景多选。
- **尺寸**
  - 卡高固定 64，行内等宽，间距 12。
  - 识别与翻译页卡间插 FlowArrow（`arrow.right` 11pt semibold tertiary），间距加宽到 24。
  - 圆角 10，`.bordered` 外观。
  - 内容为 VStack(spacing 6)：图标 22pt regular、hierarchical，放在 28×24 框；标题 13pt semibold，单行，≤4 字。
  - 不显示摘要行。
- **状态**
  - 选中：2pt accent strokeBorder，`accentColor.opacity(0.10)` 底色，图标变 accent。
  - 运行中（只有场景卡）：左上角内缩 6 处放 8pt 语音色圆点，加 caption2 等宽数字“12:03”。“运行中”三个字只出现在 AX。
  - 角标：右上角内缩 6 处放 StatusGlyph 11pt，垫 15pt `windowBackgroundColor` 圆底。只在非就绪时出现，优先级 failed > risk > warn > pending。**没有角标 = 就绪。**
  - 特殊信息角标：文本翻译卡在启用 OpenAI 时显示 `network` 11pt；字幕分析卡记录中显示 `record.circle` 橙色；故障检查卡在诊断录音中显示 `record.circle.fill` 红色。
  - multiSelect（引导）：选中态相同，AX 特征为 `.isToggle`。
- **无障碍**：label = 标题；value = “已选择 / 运行中 12:03 / 需要处理：<短因>”；hint = 摘要。整行设 `.accessibilityElement(children: .contain)`，以页名作 label。
- **摘要的唯一来源**（只用于 `.help` 和 hint）：
  - `MeetingMode.sceneSummary`：会议同传“电脑会议 · 双向同传”、电话同传“iPhone 号码 · 双向同传”、视频字幕“看视频 · 双语字幕”。
  - `SubpageItem.summary`：语音识别“声音 → 原文”、文本翻译“原文 → 译文”、语音合成“译文 → 声音”、引擎与模型“本地识别与合成”、虚拟麦克风“把声音送进会议”、数据与隐私“去向与保留”、字幕分析“检查本次字幕”、故障检查“自检与导出”。
- **SwiftUI**

  ```swift
  public struct CardItem<ID: Hashable> { id, title, symbol, summary, badge: SettingsStatus?, cornerSymbol: String?, runningSince: Date? }
  public struct CardRow<ID: Hashable>: View { items, selection: Binding<ID>, arrows: Bool = false, multiSelect = false }
  ```

  - Binding 取自 `@Observable SettingsNavigation`：现有 `modelStage`、`componentsTab`、`diagnosticsTab`，以及场景的 `requestedScenario`（使用场景和字幕共用）。不用 @State。
  - `TimelineView(.periodic(by: 1))` 只包住计时 Text，并且只在有 `runningSince` 时存在。
  - CardRow 放在 Form 之外的 VStack 顶部（与 95cdf11 的固定头相同）。
  - 删除 `ScenarioHeaderCollapse`（若仍存在）和 `SettingsSubpagePicker`。
- **实现记录（第 2 次提交 a0b370b）**
  - API：`CardItem<ID>(id:, title:, symbol:, summary:, badge: CardBadge?, runningSince: Date?)`；`CardRow(_ label:, items:, selection: Binding<ID>, arrows: Bool = false)`，引导用 `CardRow(_ label:, items:, selected: Set<ID>, toggle:)`；`SettingsCard(title:symbol:summary:selected:badge:runningSince:multiSelect:action:)`；`GlobalRow { … }`。`label` 是整行 VoiceOver 容器的名字。
  - 上面的 `badge` 与 `cornerSymbol` 合并成一个右上角类型 `CardBadge`：`.status(SettingsStatus, reason)`、`.cloud(reason)`、`.analysing(reason)`，一张卡只有一个角。`CardBadge.mostSevere`（failed > risk > recording > warn > pending > waiting／busy > 字幕分析 > 云端）供需要合并多个候选的卡片使用，目前只有 `CardBadgeTests` 调用它，各卡片都直接给出一个候选；诊断录音的 `.status(.recording)` 排在警示之前，只有字幕分析与云端角标排在所有状态之后。文本翻译卡自己在警示与云端之间取警示（`TranslationFlowFacts.cardBadge`）；警示占角时，help 与 VoiceOver 仍说已启用 OpenAI。
  - 场景卡的选择绑定 `AppState.requestedScenario`（持久化的场景选择本来就在这里），不是 SettingsNavigation 的属性；ReturnPill 返回时按 `target.scenario` 恢复。
  - 运行时间：上面“运行中 12:03”这一个 AX 值拆成两个相邻元素，卡片的值“运行中”和独立的计时元素“运行时间 12:03”。只有这样计时才能随时更新，又不用把卡片包进 TimelineView（8c87ba7 的规则）。VoiceOver 读到的计时是绘制时的快照。
  - `ScenarioRunState.cardSubtitle` 随摘要行删除；`MeetingMode.sceneSummary` 与子页摘要只用于 help 和 VoiceOver 提示。
  - 新增 `AppState.listenASRFallback`，驱动语音识别卡的“已转 Apple 备用”警示。引擎卡未安装为 warn（§7.11）；语音识别卡缺 ASR 模型、虚拟麦克风卡未安装驱动为 pending。
  - 文本翻译卡的角标读本页同一份 `TranslationSettingsModel.flowFacts`（第 5 次提交）。它的 help 可能超过 20 字，例如“原文 → 译文 · key 未通过验证 · 已启用 OpenAI”：云端安全事实优先于 help 的字数预算。
  - 没有卡片的单页（通用、音频、我的声音、术语表）也有导航带下的那条分隔线，用来隔开 ReturnPill 与 Form。显示 ReturnPill 时分隔线上方留 10，与胶囊上方相同，胶囊不贴在线上（收尾整理提交）。

### 3.2 PageHero

只用于通用和术语表。

- **作用**：没有流程可画的单页用它开头，同时显示页面级状态。
- **尺寸**
  - HStack(spacing 12)，整体高 56，放在 Form 第一个 Section。
  - 方块 40×40，圆角 9，`.quaternary` 底，内放 22pt hierarchical accent 符号（与侧栏同一令牌）。
  - 右侧是 StatusLabel：本页当前最高优先级的状态，全部就绪时显示 ok“已就绪”。
  - 最右侧可放页级操作（IconButton 或一个 `.bordered` 按钮）。
- **无障碍**：方块的 `.help` 写本页用途；AX 为“<页名>，<状态>”。
- **SwiftUI**：`PageHero<Trailing: View>(symbol:, status:, text:, help:, @ViewBuilder trailing:)`。
- **实现记录（第 4b 次提交 f8a6be2）**：API 为 `PageHero(_ page:, symbol:, help:, @ViewBuilder status:, @ViewBuilder trailing:)`，另有只带 `status` 的初始化。`page` 是侧栏名，也是 VoiceOver 读到的第一个词。状态槽是 ViewBuilder，术语表在里面同时放计数、上次结果和隐私 chip。没有大字号退化（§3.3）。PageHero 与术语表网格在 820 宽下也没有 `ViewThatFits` 退化（第 8 次提交推迟，属行为改动），是否截断需截图确认（`docs/remaining-work.md`）。

### 3.3 FlowGrid / FlowLane / FlowNode

取代 `SpeechFlow`、`SpeakingLanes`、`FlowNodeCard`，以及 `OpenAIOnboardingStep` 私有的 `pathStep`/`pathArrow`。

- **作用**：讲“声音和文字怎么走”的主图，用于三个场景、音频、我的声音、模型三个子页、虚拟麦克风、字幕分析、故障检查，以及引导第 3、4、7、8 步。
- **网格**
  - 列 0 是泳道标签列（gutter），宽 64；之后最多 4 个节点列，节点列之间是 16pt 箭头列；列间距 0，泳道间距 10。
  - 节点列宽 = (可用宽 − 64 − 3×16) / 4。默认窗口约 128pt，最小窗口约 113pt。
  - 单泳道且没有 gutter 的图，gutter 宽为 0。
  - 同一图里含义相同的节点必须在同一列。例如“识别与翻译”在会议、电话、视频三张图里都在第 2 列。
  - 短泳道的空列画“穿过”：1pt tertiary 横线，末端是箭头。
  - 节点永不拉伸到别的列。
  - **方向一律从左到右**。不采用 SB 的右到左听泳道。
- **FlowNode 尺寸**
  - 同一张图里所有节点等高：没有附件的图为 60，任一节点有附件则全图为 82。
  - 圆角 10，`.quaternary` 底，内边距 8。
  - 第一行：图标 18pt regular、hierarchical secondary，放在 24×22 框，或者放 18pt 应用真实图标（`NSWorkspace.icon(forFile:)`）；每个节点恰好一个图形。
  - 标题 12pt callout，单行，`minimumScaleFactor(0.85)`，≤6 字（产品名不计）。
  - 附件槽高 20，可放 1–2 个 NodeChip，或 mini Toggle、Keycap、VoiceCapsule、caption2 次要值，或 ≤2 个 IconButton。
- **FlowNode 状态**（`NodeState`）
  - ready：默认外观。
  - live：图标用语音色。
  - pending：带角标。
  - needsAction：1pt 橙色 60% 描边 + 角标。
  - risk：1pt 红描边，加红色合成字形角标，标题下多一行红色 caption 写风险短句。**不能只靠颜色。**
  - off：不透明度 40%，1pt 虚线分隔色描边。
  - 角标位置：图标右上角，11pt 放在 15pt 圆底上。
- **命中规则**
  - 节点没有附件控件：整卡是 `Button(.plain)`，按下时底色变 `.tertiary`。
  - 节点有附件控件：只有右下角 24×24 的 `chevron.right` 9pt semibold tertiary 是链接。
  - chevron 常显，不依赖悬停。
  - 目标分两种：`.page(section, subpage)` 跨页跳转，显示 ReturnPill；`.anchor(id)` 页内滚动并闪烁。
- **FlowSatellite**：节点下方的 22pt 胶囊，内容为 11pt 图标 + ≤6 字。用 1pt 点线连接到节点。虚线描边表示备用路径（备用 Apple、系统声音），实线描边表示当前生效或链接（链接时带 9pt chevron）。每个节点最多一个；有卫星时图高增加 32。
- **LaneLabel（gutter）**：可放 VoiceCapsule 原声或译音（高 20，原声下方加 caption2“默认”）；或放 15pt 图标：`ear` 表示听对方，`person.crop.circle.fill` 表示我，`mic.slash` 表示不用麦克风。
- **LoopRow**：位于原声泳道和译音泳道之间，高 22，横跨节点列 2–4。内容为 `arrow.uturn.backward` 11pt、Keycap“右⌥”、`stop.fill` 11pt、caption“播完回到原声”。
  - 实现裁决（第 3 次提交实测）：`gridCellColumns` 横跨（含 `gridCellUnsizedAxes(.horizontal)`）会让 `Grid` 放弃等分节点列，630 宽下节点只剩理想宽约 71pt。所以回环放在节点列 2，胶囊按自身宽度 `fixedSize`，向右画过该行空着的列 3–4。这是 FlowGrid 里唯一的 fixedSize，只用于这个叶子视图。
- **无障碍**
  - 整图是一个容器，label 为图名（如“会议同传声音路径”）。
  - 每条泳道是一个 group，label 用 gutter 名（“听对方”“我说话 · 原声”“我说话 · 译音”）。
  - 节点 label 为标题；value 为状态词（已就绪 / 需处理 / 对方能听到原声 / 已关闭）；hint 为目的地。
  - 附件控件是独立的 AX 元素。读序为节点、它的控件、链接。
- **SwiftUI**
  - `FlowGrid(lanes: [FlowLane], loop: LoopRow?)`，用 `Grid(horizontalSpacing: 0, verticalSpacing: 10)` 渲染，每条泳道一个 `GridRow`。
  - 节点用 `.frame(maxWidth: .infinity, minHeight: h, maxHeight: h)`。
  - 不使用 GeometryReader、PreferenceKey，也不用 fixedSize 包裹。
  - 内容列在最小宽 630 下仍能放下（4×113）。
  - 大字号退化（第 5 次提交实测裁决）：读环境值 `dynamicTypeSize ≥ .xxLarge`，不量几何，也不用 `ViewThatFits` 判断要不要折（它按理想宽度判断，正常字号下节点标题一截断就会误折）。折叠时 gutter 宽度降为 0，泳道标签移进该泳道首个节点的附件槽，VoiceOver 把泳道名读在节点名前；FactRow 一律竖排，DataBoundary 两栏改为上下排、箭头朝下。
  - 原声 / 译音胶囊是安全词（§1.3），折叠后也不能被挤掉：槽里放不下时，键帽先缩成只画“右⌥”，仍放不下就只留胶囊（键帽的词仍在 AX 里）。泳道放两个胶囊（音频），或胶囊泳道的首节点带控件时，整张图保留 gutter 列不折。图标 gutter 在放不下时让位给节点自己的附件。折进节点的胶囊和键帽只是示意，点击穿过它们落到节点按钮上。
  - Apple 文档写明 macOS 用户目前不能改 `dynamicTypeSize`（开发者论坛也这样答复），所以这套退化在 Mac 上只在视图自己设定 `.dynamicTypeSize(_:)` 时出现。PageHero、术语表网格、滑杆行和缩略图因此不另做大字号退化，只有本条和 §3.11 的 FactRow 有。
  - 模型定义：`FlowNodeModel { id, glyph: .symbol(String) | .appIcon(bundleID) | .step(n, StepState), title, state: NodeState, badge: SettingsStatus?, target: NodeTarget?, accessory: NodeAccessory?, satellite: FlowSatellite?, help, axValue }`。
  - 悬停和闪烁状态放在 `@Observable FlowInteraction { flashed: String? }`，由 SettingsNavigation 持有；0.8s 后用 Task 清空。
- **实现记录（第 3 次提交 7ab201a，及 4c、4d、5）**
  - API：`FlowGrid(_ label:, lanes: [FlowLane], loop: LoopRow? = nil)`；`FlowLane(_ label:, gutter: LaneLabel?, cells: [FlowCell], arrows: [Int: String])`；`FlowCell` 为 `.node(FlowNode)`、`.pass`、`.carry(VoiceState, spoken:)`（音频页耳机译音在连线上叠的胶囊）和 `.empty`；`LaneLabel` 为 `.voice(VoiceState, caption:)`、`.voices([VoiceState])`（音频页原声叠译音）和 `.symbol(String)`。`FlowNode(_ title:, glyph:, state:, badge:, badgeReason:, riskText:, link: NodeLink?, accessory: NodeAccessory?, satellite: FlowSatellite?, help:)`；`FlowGlyph` 为 `.symbol`、`.app(bundleID:fallback:)`、`.step(n, StepState)`。`NodeLink(_ destination:, action:)` 的 `destination` 同时是 VoiceOver 提示和默认 tooltip。`NodeAccessory.controls { … }` 表示节点只经 chevron 链接，`.display { … }` 表示整卡仍是按钮，`.keycap(key)` 是键帽附件。`FlowSatellite(_ text:, symbol:, help:, dashed:, link:)`，`LoopRow(after:, key:, text:, spoken:)`。上文的 `FlowNodeModel`、`NodeTarget` 没有单独建模：`.page` 与 `.anchor` 两种目标都由 `NodeLink` 的闭包完成。
  - `NodeState` 为 ready、live、needsAction、risk、off、dimmed。pending 不是节点状态，而是角标（`badge: .pending`）；dimmed（50%）用于还不能做的步骤。
  - 泳道不是 AX group，因为 Grid 的一行不能作为无障碍容器。整图是一个以图名命名的容器；每条泳道以 gutter 开头，gutter 是以泳道名命名的标题元素。
  - `FlowInteraction` 只有 `flashed` 与 `flash(_:)`，没有悬停状态。闪烁描的是分组标题（`SectionHeader`），不是整个分组：SwiftUI 的 grouped Form 不能给一个 Section 描边。
  - 跨页链接可带分组锚点（`SettingsNavigation.open(_:_:scenario:anchor:)` 与 `takeAnchor()`），目标页用共用的 `settingsAnchorTarget` 滚动并闪烁；有待处理的锚点时，`pageAppeared` 不滚回顶部。
  - 节点上的键帽（`NodeAccessory.keycap`）和折进节点的胶囊只是示意：不是按钮，不接收点击，点击穿过它们落到节点上（第 5 次提交）。底下的 `KeycapActionView` 不是无障碍元素、不设 toolTip；`NodeAccessory.keycap` 以文字“右⌥ 开始翻译”代表它（§3.16），节点的 help 仍是 tooltip。折进节点的胶囊对 VoiceOver 隐藏，泳道名由节点标签读出；回环自己说出键帽的词。
- 流程图高度估算的内容预算为 560（820 宽窗口下详情区约 569）。

### 3.4 NodeChip

- **作用**：把来源应用、对方语言、我的译音、识别引擎、翻译引擎、档位等选择器并进节点，删掉独立的 Picker 行。
- **尺寸**
  - 高 20，胶囊，`.quinary` 底，11pt medium 文字。
  - 前置 12pt 应用图标或符号；后置 `chevron.down` 8pt（`SubtitleTokens.Size.capsuleChevronSize`）。
  - 最大宽 = 节点宽 − 16，文字尾部截断（实机上中间截断把 “Google Chrome” 显示成 “G…me”，2026-11-07 改为尾部截断），全名放 `.help`。
  - 一个节点放两个 chip 时，应用 chip 只显示图标加截断名，语言 chip 固定 34pt 宽（“EN ▾”）。
- **状态**
  - 会话中锁定：`lock.fill` 9pt 替换 chevron，禁用，`.help`“会话中不可更换”。
  - 来源缺失：前置 `exclamationmark.triangle.fill` 9pt 橙色，节点问题行显示“<App> 未打开”。
- **菜单项**（13pt 图）：`wand.and.stars` 自动 / 各应用（真实图标）/ 未就绪的应用（三角 + 名称）/ 分隔线 / `arrow.clockwise` 刷新列表。
- **无障碍**：label 依次为“声音来源”“对方语言”“我的译音”“识别引擎”“翻译方式”“档位”“合成模型”。
- **SwiftUI**：`Menu { … } label: { chipLabel }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()`。如果 macOS 丢掉了菜单项图片，退回 `NSPopUpButton`（NSViewRepresentable，`.inline` bezel，controlSize `.small`）。绑定沿用现有 state：`state.remoteLanguage`（会议、电话、视频共用，即“对方语言”）、`state.speakLanguage`（“我的译音”）、来源选择、ASR 偏好。
- **实现记录（第 3 次提交 7ab201a，582176e）**：API 为 `NodeChip(_ title:, leading: .none | .symbol | .app(bundleID:), width:, warn:, locked:, accessibilityLabel:, help:, items: [NodeChipItem])`，菜单项为 `NodeChipItem(_ title:, glyph: .none | .symbol | .app | .warn, isOn:, isEnabled:, action:)` 与 `.separator`，菜单是带图标的 AppKit 菜单。一个节点放两个 chip 时，自动来源只写“自动 ▾”，不画魔杖：在 113pt 的节点里，图标会把“自动”挤成省略号；菜单里的“自动”仍带 `wand.and.stars`。环境禁用时 chip 半透明；锁定的 chip 保持不透明，只换次要色文字和 `lock.fill`。别的场景运行时，来源 chip 的 help 为“先结束<场景>”，比“会话中不可更换”更能说明该做什么；语言 chip 不锁定（语言偏好按场景独立，非活动场景也可编辑，不影响当前会话）。运行中锁定的来源 chip，help 为“<标题> · 会话中不可更换”，自动来源运行时补应用名；选了有图标的应用时只画图标加 chevron，全名在 help 与 VoiceOver 值。节点里的语言 chip 一律用短码（中／EN／DE，宽 34），菜单项、help 与 VoiceOver 用语言全名；字幕弹层里的语言 chip 仍写全名。最大宽仍由节点宽和截断隐含，没有单独写“节点宽 − 16”。

### 3.5 StepTrack

取代 `PhoneSettingsView` 的 checklistRow 和 EnrollmentView 的步骤条。

- **作用**：有顺序的用户步骤，画成一条 FlowGrid 泳道。
- **尺寸**：节点图形用 `.step(n, state)`：未开始 `\(n).circle`，进行中 ProgressView `.small`，完成 `checkmark.circle.fill` 绿色。图形 18pt，与节点图标同级，这样同一列里不会出现 18 和 15 混排（评审 1 指出的问题）。未就绪的步骤不透明度 50%。
- **无障碍**：“第 N 步，<标题>，未完成 / 进行中 / 已完成”。
- **SwiftUI**：复用 FlowGrid。只是 `glyph` 不同。
- **实现记录**：没有单独的 StepTrack 类型，它就是用 `.step(n, state)` 图形的 FlowGrid 泳道（`FlowGrid.phoneSteps`、录制视图、引导第 7 步）。还不能做的步骤为 `.dimmed`（50%，不可点）。录制视图按本节用编号步骤图形，没有用 §7.7 写的 mic／checkmark.shield／headphones；两节写法冲突，取本节。

### 3.6 DataBoundary

- **作用**：用一张两栏图说明“什么留在这台 Mac、什么去 OpenAI”。用于模型›文本翻译、隐私›数据与隐私、引导第 5 步。
- **尺寸**：两栏间距 12，每栏是 `.quaternary` 圆角面板，高 56。
  - 左栏：`laptopcomputer` 18pt，下面 label“本机”加 `lock.fill` 11pt 角标；chip 为“声音 · 声音档案 · 录音”。
  - 中间：`arrow.right` 11pt，只在启用云端时出现。
  - 右栏：`network` 18pt，label“OpenAI”；chip 为“文字 · 上下文 · 术语”。
- **状态**：两个方向都不用 OpenAI 时，右栏不透明度 40%，图标换成 `network.slash`，label 换成“未连接”，中间箭头消失。
- **无障碍**：“本机：声音、声音档案、录音；OpenAI：文字、上下文、术语”。未连接时追加“，未连接”。
- 尾部 ⓘ 原样放 `TranslationSettingsText.cloudNotice`。
- **SwiftUI**：`DataBoundary(cloudEnabled: Bool, info: [String]? = nil, link: NodeLink? = nil)`，纯视图。`info` 是尾部 ⓘ（识别与翻译 › 文本翻译和引导第 5 步传 cloudNotice）；`link` 让右栏成为按钮，右下角画 chevron（数据与隐私链接到识别与翻译 › 文本翻译）。
- **实现记录（第 4d 次提交 3def91e）**：左栏 chip 用 `lock.shield`（隐私承诺）图标。`cloudEnabled` 取 `TranslationFlowFacts.cloudConnected`：当前偏好或运行中会话开始时的偏好有方向选 OpenAI，并且存有 key 或 key 状态还没读到。也就是在第一次元数据查询返回之前宁可多报，不显示“未连接”；会话中关掉开关后，本场仍在发送，右栏也不灰显。大字号时两栏上下排、箭头朝下（§3.3）。

### 3.7 SettingsStatus / StatusGlyph / StatusLabel（修整后的统一词汇）

| case | 图形 | 颜色 |
|---|---|---|
| ok | checkmark.circle.fill | 绿 |
| warn | exclamationmark.triangle.fill | 橙 |
| risk | 合成字形 mic.badge.exclamationmark（mic.fill + exclamationmark.circle.fill） | 红 |
| failed | xmark.circle.fill | 红 |
| pending | circle.dashed | secondary |
| waiting | clock | secondary |
| busy | ProgressView().controlSize(.mini) | — |
| recording | record.circle.fill | 红 |

- **删除 `.info`。** `info.circle` 只用于 ⓘ。
- 尺寸只有两种：
  - **inline**：13pt 图形 + 13pt callout 文字，间距 4，用于行尾、问题行、结果。
  - **badge**：11pt 图形放在 15pt 圆底上，用于卡片和节点角标。
- risk 合成字形按固定点径绘制，修正 `SettingsFlowComponents.swift:315` 依赖 `NSFont.systemFontSize` 的问题。
- 以下非令牌写法全部替换：
  - `DiagnosticsView.swift:174` 的空心 `checkmark.circle` / `xmark.circle` / `minus.circle`
  - `EngineComponentsRows.swift:254` 的空心三角
  - `DriverComponentView.swift:167` 用三角表示错误
  - `TranslationSettingsView.swift:203` 和 `OpenAIOnboardingStep.swift:141` 的 `xmark.octagon.fill`。`xmark.octagon` 只留给标题栏的“已中止”。
  - `DriverComponentView.swift:113` 的纯文字“通过 / 没通过 / 跳过”
  - 引导第 8 步的 `hourglass`
- 文字取最短形式，完整原因放 `.help`。
- 无障碍：状态词进 label。
- **实现记录（第 1 次提交 7077444 起）**
  - `.info` 与令牌 `SettingsIcon.statusInfo` 在第 1 次提交就删除了（已没有调用点），没有等到第 5 次。
  - `StatusLabel(_ text:, _ status:, help:)` 的 ok／pending／waiting 文字为次要色，warn 文字用警示令牌的墨色，字号固定 13pt。risk 字形和 busy 转圈都对齐 SF Symbol 的文字基线。
  - 新增 `SettingsProblem(_ status:, _ text:, help:)` 与 `SettingsProblem(_ status:, sentence:)`（第一个分句可见，全句进 help）。`mostSevere` 按 risk > failed > warn > waiting > pending 排序，是各页问题行以及由问题行派生的卡片角标（场景、模型、组件卡）的共同来源；菜单问题区在 TalkTalkSession 里用同样的 风险 > 失败 > 警示 > 待确认 顺序自行排序（`StatusMenu` 的 `Issue.rank`，没有等待一级），因为 TalkTalkSession 不依赖 TalkTalkSettingsUI。
  - 页面级的加载占位（安装与维护页、文本翻译页、引导第 3、5 步）也用 `StatusGlyph(.busy)`，并带说明加载对象的 help 与 VoiceOver 标签。

### 3.8 SectionHeader + `.settingsRow`（SettingsRowLabelStyle）

恢复 34c0724 删掉的分组标题图标。

- **SectionHeader**：HStack(spacing 8)：15pt medium secondary 图标放在 22pt 列；标题 13pt semibold，≤4 字；尾部可选 InfoButton。标题图标 = 锚定该 Section 的节点图标。Section 加 `.id(anchorID)`。
- **行**：HStack(spacing 8)：15pt regular、hierarchical secondary 图标放在 22pt 列（应用图标为 15×15）；标题 13pt body，从 +30 起。
  - 每个 Toggle、Picker、LabeledContent、Button 行都必须有图标。找不到合适图标的行，说明它不该是一行。
  - 破坏性行的图标和文字都是红色。
  - 状态行和 FactRow 缩进到 +30，没有自己的图标列。
- **行尾固定顺序**：值 → StatusGlyph 13 → IconButton（每个 22×22）→ ⓘ。
- **SwiftUI**：`public struct SettingsRowLabelStyle: LabelStyle`，在每个 Form 根部加一次 `.labelStyle(.settingsRow)`。Toggle 写成 `Toggle(isOn:) { Label("…", systemImage: SettingsIcon.x) }`。
- **实现记录**：`SectionHeader(_ title:, symbol:, info: [String]? = nil)`，Section 自己加 `.id(anchorID)`；破坏性行用 `.labelStyle(.settingsRowDestructive)`。术语表的 Form 不加 `.settingsRow`，以免改掉空状态 `ContentUnavailableView` 的样式。

### 3.9 InfoButton（ⓘ）

- **作用**：只用于展开安全事实、法律依据、隐私承诺的完整句子。
- **尺寸**：NSButton，`info.circle`，`NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)`，替换现在的 textStyle `.body`；frame 22×22；`secondaryLabelColor`。
- 弹层：宽 300，callout，最多 2 句，≤60 字，不加标题，最多一个动作按钮。
- **预算**：每个 Section ≤1 个，每页 ≤3 个。必须挂在 FactChip、节点或行尾上。
- **SwiftUI**：保留现有 NSViewRepresentable 和 NSPopover Coordinator（不需要 @State），只改符号配置和 frame。topic 参数只用于 AX：“<topic>说明”。

### 3.10 IconButton / IconMenuButton

- **IconButton**：`.borderless`，13pt regular，点击区 22×22，secondary 颜色。真正删除数据的入口使用系统红色，禁用时灰色；已主动选择删除后的确认弹窗采用 macOS 系统普通确认样式。必须同时设 `.help` 和 `accessibilityLabel`。
- **固定图形**

  | 动作 | 符号 |
  |---|---|
  | 刷新 | arrow.clockwise |
  | 恢复默认 | arrow.counterclockwise |
  | 移除条目 | minus.circle |
  | 添加 | plus |
  | 关闭 / 知道了 | xmark |
  | 复制 | doc.on.doc |
  | Finder | folder |
  | 验证 | checkmark.shield |
  | 删除 | trash |
  | 取消进行中 | xmark.circle |
  | 打开其他 App / 系统设置 | arrow.up.forward.app |

- 统一替换：`TranslationSettingsView.swift:115` 的 bordered 24×24 刷新、`GlossarySettings.swift:79` 的固定 24×24 `minus.circle`、`AudioSettings.swift:339` 的 `minus.circle`。
- **IconMenuButton**：`Menu`，label 为 `ellipsis.circle` 13pt，`.menuStyle(.button)`、`.buttonStyle(.borderless)`、`.menuIndicator(.hidden)`；菜单项都带 13pt 图标；`.help` 为“维护引擎”或“维护”。
- **实现记录（第 1 次提交实测改写）**
  - `IconButton(_ symbol:, help:, accessibilityLabel: String? = nil, isDestructive: Bool = false, action:)`：AX 标签默认等于 help，help 说不出对象时另传。`isDestructive` 明确标记删除入口的语义与红色，其他动作保留 secondary；`IconMenuItem` 同样支持该标记，卸载菜单项使用系统红字。
  - IconMenuButton 不是 SwiftUI `Menu`：macOS 不管 label 或菜单给多大的 frame，都把 SwiftUI `Menu` 画成按自身大小（约 21×15）的弹出按钮，点击区达不到其他纯图标控件的 22×22。它改为 AppKit 下拉按钮（`NSPopUpButton` pull-down，无边框、无箭头）：`IconMenuButton(help:, items: [IconMenuItem])`，菜单项为 `IconMenuItem(_ title:, symbol:, isEnabled:, action:)` 与 `.separator`，遵守 `.disabled`。每次 SwiftUI 更新都重建一份 NSMenu，动作按序号查找，所以菜单项顺序要固定。菜单项没有破坏性样式（AppKit 常规），破坏性动作必须保留确认弹窗。
- 语言互换按钮是 `IconButton`（`SettingsIcon.languageSwap`，13pt，22×22）；`handoff` 令牌只表示 iPhone ⇄ Mac 的交接。

### 3.11 FactChip / FactRow

取代 SettingsNote 和灰色段落。

- **尺寸**：胶囊高 20，内边距 h8，1pt 分隔色描边，`.quaternary` 底；11pt 图标 + 11pt caption。普通 chip ≤8 字；§5.4 列出的安全事实 ≤16 字。
- **语气**：neutral（secondary）；cloud（`network` 图标，accent 字色）；warn（橙）；risk（红色合成字形 + 红字）。
- 每个 chip 都必须有 `.help`（≤20 字）；AX 读完整句。
- **FactRow**：HStack(spacing 6)，最多 4 个。宽度不够时用 `ViewThatFits(in: .horizontal) { HStack; VStack(alignment: .leading) }` 折到两行，不用自写 Layout；大字号（§3.3）下一律竖排。我的声音的事实行把 ⓘ 和 Finder 按钮挂在第一个 chip 后（§7.7），不用 FactRow，但遵守同样的竖排规则。位置是主图正下方，或某个 Section 末行下方，缩进 +30。
- **SwiftUI**：`public struct FactChip: View { symbol, text, tone, help }`，`public struct FactRow: View { chips }`。
- **实现记录（第 1、4d、5 次提交）**：`FactChip(_ text:, symbol:, tone: .neutral | .cloud | .warn | .risk, help:, spoken:)`，`symbol` 必填；另有 `FactChip.cloud(_:help:spoken:)`、`.warn(…)`、`.risk(…)`。VoiceOver 读 `spoken ?? text`，提示为 help。描边按本节用 1pt（示意图为 0.5px）。`FactRow(_ chips:, indented: Bool = false, info: InfoButton? = nil)`：`info` 是这一行唯一的 ⓘ，放在行尾（§3.9）。放不下时 FactRow 改为每个 chip 一行的竖排，ⓘ 留在最后一个 chip 旁，不是折成两行。字幕分析有 6 个 chip，超过 FactRow 的 4 个上限：放得下时一行 HStack，否则是两个各 3 个 chip 的 FactRow。

### 3.12 ThumbnailChoice

- **作用**：本身就是外观的设置用缩略图选择：视频字幕的样式和排列。
- **尺寸**：每个选项是按钮。样式缩略图 72×40，排列缩略图 48×32，圆角 8。下方是 caption2 名称（≤4 字）：贴合玻璃 / 描边 / 实底，原文在上 / 译文在上。选中时 2pt accent 描边。
- 缩略图用 SubtitleTokens 绘制，背景跟随系统外观（浅色白、深色黑，与预览一致），不加载图片。
- **无障碍**：label 为选项名，选中项带 `.isSelected`。
- **SwiftUI**：`public struct ThumbnailChoice<V: Hashable>: View { options: [(V, name, thumbnail: AnyView)], selection: Binding<V> }`。
- **实现记录（第 4a 次提交 6cd04df）**：元组数组改为结构体，才能通过类型检查并带上 help：`ThumbnailChoice(_ label:, options: [ThumbnailChoice<V>.Option], selection: Binding<V>, size: .wide | .compact)`，`Option(_ value:, name:, help: String? = nil, @ViewBuilder thumbnail:)`。`.wide` 为 72×40（样式），`.compact` 为 48×32（排列）；`label`（“样式”“排列”）是 VoiceOver 容器名。深色的黑底上，黑色描边和实底看不出区别，所以缩略图先在底上画一块示意视频画面（令牌 `SubtitleTokens.captionThumbnailPicture`，0x4A6A8A，浅色深色同一中间色），字幕画在它上面。

### 3.13 ReturnPill

由 `ReturnToScenePill` 泛化而来。

- **尺寸**：胶囊高 24，`.quaternary` 底，内边距 h10。内容依次为：`chevron.left` 11pt semibold、来源图标 13pt、来源名 13pt callout（例如“会议同传”“音频”，不写“返回”二字）；之后是 IconButton `xmark`（`.help`“关闭”）。整个胶囊的 `.help` 为“返回<来源名>”。
- **行为**：返回时恢复来源的页面、子页、场景卡和滚动锚点。
- **SwiftUI**：把 `SettingsNavigation.returnTarget` 扩展为 `{section, subpage, scenario, scrollAnchor}`。在 `SettingsWindowController` 的 detail 容器的 Z0 槽统一渲染，不在每个页面里各画一次。删除组件自带的 `.padding(.horizontal, 20)`。
- **实现记录（第 2 次提交 a0b370b）**：`ReturnPill(_ title:, symbol:, back:, dismiss:)`。`SettingsReturnTarget { section, subpage, scenario, scrollOffset, title, symbol }` 存的是滚动偏移（Double），不是锚点，经同一个不受观察的 `ScrollPosition` 恢复。标题用 13pt body。只有跳到其他设置页的流程链接（`SettingsNavigation.open`，目标页与来源页不同）显示它；页内锚点和同一页内的子页链接不显示；菜单修复项用 `reveal` 直达，侧栏、菜单、HUD 打开页面时它消失。

### 3.14 RecordingBanner

- 固定在隐私与诊断三个子页的卡片行之下，高 32，横向铺满。
- 底色：诊断录音时 `red.opacity(0.10)`，字幕分析时 `orange.opacity(0.10)`。
- 内容：
  - 诊断录音中：`record.circle.fill` 红色 13pt，“录音中：我 · 译音 · 对方”。
  - 字幕分析记录中：`record.circle` 橙色，“正在保存字幕文字”。
  - 已预约：“本场将录音”或“下场将录音”。
- 尾部 `chevron.right` 跳到对应子页（`.help`“查看诊断录音”或“查看字幕分析”）；当前已在该子页时不显示。
- **实现记录（第 4e 次提交 0f655a8）**：`RecordingBanner(_ text:, kind: .recording | .analysing | .preparing | .planned, link: NodeLink?)`，高 32；整条横幅是按钮，`link` 为 nil 时不带 chevron。诊断录音和字幕分析同时进行时上下叠两条。字幕分析正在建文件时（`.preparing`）显示转圈。菜单的录音行与横幅同词（§8.7）。
- 横幅链接“查看诊断录音／查看字幕分析”与菜单一样落到对应分组并闪烁一次（`reveal` + `SettingsAnchor`），不再只是切子页。

### 3.15 ScenarioBottomBar

- 高 56，`.bar` 材质，上方一条 Divider，左右各 20。
- **左侧状态**（空闲时为空）
  - 运行中：8pt 语音色圆点 + 场景图标 13pt + “<来源> · 12:03”（等宽数字），整组可点，选中运行中的场景卡。
  - 电话运行中：追加 FactChip `phone`“通话不会挂断”。
  - 字幕隐藏：追加橙色胶囊 `eye.slash`“字幕已隐藏”和 link 按钮“显示”。
- **右侧主按钮**：`borderedProminent`，`.large`，minWidth 140。
  - 空闲：`play.fill`“开始”；电话场景为“准备”。
  - 进行中：ProgressView `.small` + “准备中…”或“结束中…”，按钮禁用。
  - 运行本场景：`stop.fill`“结束”，红色 tint。
  - 正在浏览另一个场景、而别的场景在运行：按钮禁用，`.help`“先结束<运行中场景>”。
- 不显示描述行。
- **SwiftUI**：保留 `ScenarioRunState`；删除描述 caption 和左侧场景名；按钮标题改为短词；删除 runningBanner。
- **实现记录（第 3 次提交 7ab201a）**：开始或结束过程中左侧为空，由按钮的转圈和短词表示状态。会议应用还不知道时，运行来源退回场景名。
- 底栏“开始／准备”与菜单快速开始共用同一个可用条件：引导已完成，且没有自检、说话测试、引擎安装或维护在进行；禁用时 tooltip 写原因，引导未完成为“完成引导后可用”，其余为“请先结束正在运行的自检或说话测试，或等待语音资源维护完成。”

### 3.16 VoiceCapsule / Keycap

复用，不改样式。

- 尺寸：高 `SubtitleTokens.Size.controlHeight` = 20，胶囊图标 `capsuleIconSize` = 10，键帽最小宽 30。
- 出现位置：泳道 gutter、节点附件槽、LoopRow、电话实时发声行。
- 改动：只迁移到 `TalkTalkSettingsUI` 并加 `public`。
- **实现记录（第 5、7 次提交）**：设置里的键帽从不被按下，所以 `Keycap(key:, showsAction: Bool = true)` 只是一张图：底下的 `KeycapActionView` 不是无障碍元素、不设 toolTip、不接收点击，由包住它的行、节点附件或回环说出“右⌥ 开始翻译”并显示 help。`showsAction: false` 只画键，用于大字号下放不下的节点。第 7 次提交加的 `decorative` 参数在第 5 次提交的修正里去掉了，因为所有调用点都是装饰用途。

### 3.17 删除的共享件（用编译器强制执行文字预算）

- `SettingsNote`（GeneralSettings.swift:275-281）：删除后，所有灰段落的调用点会编译失败，逐一迁移。
- `SettingsSubpagePicker`、`SpeechFlow`、`SpeakingLanes`、`FlowNodeCard`、`FlowLink`（改为 NodeTarget）、OpenAI 步私有的 `pathStep`/`pathArrow`、`ScenarioCardHeader` 内部的摘要行、`SettingsStatus.info`。
- 迁移期间可以把 `FlowNodeCard` 保留为薄封装，最后一次页面提交时删除。
- **实现记录**：已全部删除。`SettingsStatus.info` 在第 1 次提交（7077444）删除；`SettingsSubpagePicker`、`SettingsTabButton`、`ReturnToScenePill` 在第 2 次（a0b370b）；运行横幅在第 3 次（7ab201a）；`SettingsNote`、`SpeechFlow`、`SpeakingLanes`、`FlowNodeCard`、`FlowLink`、`FlowArrow`、整个 `SettingsFlowComponents.swift`、OpenAI 步的 `pathStep`、`OnboardingCard`，以及 `DriverComponentSection`、`EngineComponentsRows` 两个引导用封装，在第 7 次（bf2c68f）删除。第 5 次（40bb982）清掉它们留下的字符串检查规则、测试样例和不再使用的直通偏好。`ScenarioCardHeader` 保留为 `CardRow` 的薄封装（§3.1）。

---

## 4. 图标尺寸表

所有 SF Symbol 一律用 `.font(.system(size: N))` 或 `SymbolConfiguration(pointSize:)`。**禁止**：
- `.title2`、`.title3`、`.headline`、`.caption` 这类随字号变化的图标字体；
- `imageScale(.small)` 这类相对缩放；
- 默认 body 尺寸的选中勾。

已知要改的位置：`EngineComponentsRows.swift:158/247`、`DriverComponentView.swift:21/192`、`OpenAIOnboardingStep.swift:32/82`、`OnboardingPracticeSteps.swift:262`。

| 层级 | 用在哪里 | pt | 字重 | 渲染模式 | 对齐列 / 框 |
|---|---|---|---|---|---|
| L0 | 侧栏 | 系统“侧栏图标大小”（不覆盖） | 系统 | 系统 | 系统 |
| **L1** | 场景卡和子页卡、PageHero 方块、引导 StepTitle | **22** | regular | hierarchical | 卡片 28×24；方块 40×40 |
| **L2** | 流程节点图标、应用图标、StepTrack 圆、DataBoundary 面板 | **18** | regular | hierarchical | 24×22 框；节点高 60/82 |
| **L3** | Form 行首、SectionHeader、泳道 gutter 图标 | **15** | 行 regular / 标题 medium | hierarchical secondary | **22pt 宽固定列**，文字起点 +30 |
| **L4** | 行内状态图形、IconButton、ⓘ、ReturnPill 图标、菜单栏菜单 | **13** | regular | 状态色 / secondary | 点击区 22×22，靠行尾 |
| **L5** | 角标（卡片、节点）、FactChip 图标、NodeChip 前置图标*、卫星、箭头、回环 | **11** | 角标 regular；箭头 semibold | 状态色 / tertiary | 角标放在 15pt 圆底；箭头放在 16pt 列 |
| 微件 | 链接 chevron、lock/warn in chip | 9 | semibold | tertiary | 节点右下内缩 6 |
| 微件 | 运行圆点 | 8 | — | 语音色 | 卡片左上内缩 6 |
| 字幕令牌 | VoiceCapsule、Keycap | 控件高 20，图标 10 | — | 令牌 | 不变 |
| 主按钮 | BottomBar 的 play.fill / stop.fill | `.large` 按钮默认 | — | — | 全窗口只此一处 |

\* NodeChip 里的应用图标是 12pt，因为应用图标需要比 11 稍大才看得清。这是唯一的例外，写进令牌 `SettingsIcon.Size.chipAppIcon`。

**每层只有一个尺寸的五级梯子：22 / 18 / 15 / 13 / 11。** 验收时用 grep 检查：`Sources/**/*Settings*.swift` 及各设置相关 view 中 `.font(.system(size:` 的取值，只能是 {22, 18, 15, 13, 11, 9}，加上令牌常量。

**侧栏令牌**：新增 `SubtitleTokens.SettingsIcon.Page.*`，流程和页面中禁止写字面量。

| 页 | 符号 | 变化 |
|---|---|---|
| 通用 | gearshape | — |
| 使用场景 | rectangle.3.group | 原来与会议卡共用 person.2.wave.2 |
| 字幕 | captions.bubble | — |
| 音频 | mic.and.signal.meter | — |
| 我的声音 | waveform.and.person.filled | — |
| 模型 | square.stack.3d.up | 原来与“翻译”共用 character.bubble |
| 组件 | shippingbox | — |
| 术语表 | character.book.closed | — |
| 隐私与诊断 | hand.raised | — |

（`brain` 也存在，但“模型”页同时管识别、翻译、合成，用“层叠”比用“大脑”更贴切；三份设计中有两份选了它。）

**实现记录（第 1–7 次提交）**

- 梯子是令牌 `SubtitleTokens.SettingsIcon.Size`：card 22、node 18、row 15、inline 13、badge 11、micro 9、chipAppIcon 12、runningDot 8，另有 rowColumn 22、rowTextInset 30、hitArea 22、badgeDisc 15、chipHeight 20。第 5 次提交的 grep 验收结果：设置、引导和录制视图里的 `.font(.system(size:` 都取这些令牌。
- 不属于梯子的文字尺寸也写成令牌：录制视图的倒数 `enrollmentCountdown` 72 与稿子 `enrollmentScript` 26（§7.7），引导头部步骤指示 `onboardingStep` 16 与圆 `onboardingStepDisc` 30（§7.17）。
- 电话实时发声行的送达图形用 13pt（梯子上的 inline），不是 §7.2 写的 12pt。
- 规格未列、实现补的令牌：`offlineCommands` = `terminal`（故障检查 › 技术详情 › 离线命令的小标题；示意图画的是 `doc.on.doc`，但它在 §3.10 表示“复制”，四个复制按钮仍用它，小标题不再复用）、`checkValues` = `number`（自检的“数值”折叠）、`callsInPhone` = `phone`（字幕页电话预览的 Phone 热点）。性能小标题用 `performance`（`gauge.with.needle`，与技术详情同形）；第 4e 次提交曾加的 `latency` = `timer` 在评审后删除。性能表里 RTF 用 `cpu`，欠载用 `hifispeaker`。
- 侧栏、卡片、节点、菜单和标题栏用到的令牌都由 `SettingsSymbolTests` 用 `NSImage(systemSymbolName:)` 核对存在；`VoiceIcon.originalRisk` 豁免，改为核对它的两个合成部件。

**一义一形**

| 含义 | 唯一图形 | 替换掉的写法 |
|---|---|---|
| 原声 | mic.fill（只出现在胶囊里） | 驱动、试说、原声音量行的 mic.fill |
| 实体麦克风 | mic | — |
| TalkTalk Mic | mic.circle | DriverComponentView.swift:21 的 mic.fill |
| 识别 | waveform | — |
| 翻译 / 识别与翻译 | character.bubble | — |
| 原文 | text.bubble | — |
| 字幕 | captions.bubble | — |
| 合成译音 / 播放 | speaker.wave.2 | — |
| 我的声音 | waveform.and.person.filled | — |
| 对方 | person.wave.2（电话对方 phone.fill，令牌 ConversationIcon.phoneRemote） | — |
| 我 | person.crop.circle.fill | — |
| 收听 | ear | 字幕分析的 play.rectangle |
| 本机 | laptopcomputer | 所有 desktopcomputer |
| 云端 / OpenAI | network | 所有 cloud |
| 打开其他 App / 系统设置 | arrow.up.forward.app | GeneralSettings:161 的 gearshape、phone.arrow.down.left |
| 打开说明 | info.circle | “关于”行和菜单不再使用 |
| 隐私承诺 / 不上传 | lock.shield | — |
| 会话中锁定 | lock.fill | — |
| 自动 | wand.and.stars | sparkles |
| 引擎 | cpu | — |
| 自检 | checkmark.shield | — |
| 导出 | square.and.arrow.up | — |
| 录音 | record.circle(.fill) | — |
| 变慢 | tortoise | — |
| Fast 模式 | hare | — |
| 性能 / 实时可用 | gauge.with.needle | gauge |
| 费用 | dollarsign.circle | — |

---

## 5. 文字规则与预算

### 5.1 哪里允许出现文字（只有这些）

| 位置 | 上限 |
|---|---|
| 卡片标题 | 4 字 |
| 节点标题 | 6 字（产品名不计） |
| 分组标题 | 4 字 |
| Form 行标签 | 10 字 |
| 按钮 | 图标 + 4 字（+“…”）。破坏性入口、同意入口可写全名：完全卸载… / 删除声音档案… / 录对方的声音… / 同意发送文字 |
| 状态 / 问题短句 | 12 字 + 动态名称或数值 |
| FactChip | 8 字（安全清单项 16 字） |
| `.help` | 20 字，一句 |
| ⓘ 弹层 | 2 句、60 字以内；每 Section ≤1，每页 ≤3 |
| 确认弹窗 | 保留完整后果，但压缩成一行清单式 |
| 无障碍文本 | 不限长度；信息量 ≥ 被删掉的可见文字（AX 对等） |

### 5.2 禁止

- 常显的灰色段落，包括 Section footer、控件下方的 caption、SettingsNote。
- 装说明文字的 DisclosureGroup（例如“××说明”“××如何××”）。
- 页内大标题，以及与卡片、侧栏、节点重名的分组标题。
- 一个 Section 里多于一行附加文字，而且那一行只能来自 §5.4。
- 开发构建专用的提示用纯文字说明。统一改为 `ContentUnavailableView(xmark.circle)`“此构建不可用”，原句放 `.help`。

### 5.3 说明放哪里（按优先级）

画进图（箭头、泳道、虚线备用、角标、灰显、缩略图、预览热点） → 写进控件本身（菜单项、按钮词） → `.help` → AX → ⓘ（只用于安全或法律） → 确认弹窗。

### 5.4 必须常显的安全事实（图标 + 最短文字，永不只放 help）

- **发声**：原声、译音（胶囊）；对方听到原声、对方听到译音、对方能听到原声（risk）；播完回到原声。
- **电话**：已送入 Phone、仅本机 · Phone 未接收、未发送、已中止、本机播放、接通后对方才能听到你；通话不会挂断、结束同传不会挂断电话；Phone 麦克风：使用系统设置、否则对方听到原声。
- **采集范围**：含其他标签页（浏览器来源）、不用麦克风（视频）、共享屏幕不可见、收起后继续、听写、Siri 等也会收到原声或译音、外放时自动停用、不保存录音。
- **云端**：DataBoundary 两栏的 chip、云端翻译时发给 OpenAI、同意发送文字、计费、已存入钥匙串 · 请清空剪贴板、不含 key 与文字。
- **本机与保留期**：仅本机 · 不上传、本机播放、未录制时用系统声音、24 小时、30 天、20 场 · 14 天 · 200 MB、不进诊断包。
- **授权与风险**：需全员同意（§201）、需管理员授权、已卸载 · 会议改用实体麦（对方听到原声）。
- 译音来源：有声音档案但引擎未安装时，我的声音页与场景页的卫星画虚线“系统声音”（help“引擎未安装，声音档案暂不能用”），与菜单“译音：系统声音”一致；页面 ⓘ“暂不可用时不会改用系统声音”描述的是引擎已装但暂不可用的情形。

### 5.5 统一用词

- 会话结束一律叫“结束”，不叫“停止”。录音和分析的停止叫“停止”。
- 开始叫“开始”，电话叫“准备”。
- “对方语言”和“我的译音”是同一个 state 在各处的唯一名称。
- 菜单与设置共用“使用引导…”“设置…”。设置保留“关于 TalkTalk”入口；状态栏菜单直接单行显示双对话框图标、软件名、版本与构建号。

### 5.6 执行方式

- 删除 `SettingsNote` 类型，让编译器暴露所有调用点。
- 新增字符串跑 `scripts/check-strings.sh`。
- 可选（按比例，不强制）：在 check-strings 中加一条规则，标出设置相关 Swift 文件里新增的、超过 16 个中文字符的可见字符串，仅作提醒。
- 审阅时对照 §7 每页的“保留可见中文”清单逐项检查。
- **实现记录**：`SettingsNote` 已删除（第 7 次提交），编译通过即说明没有调用点。可选的 16 字提醒规则没有加，`check-strings.sh` 只对标题栏标签（10）和通知短标签（8）限长；其余预算靠审阅。

---

## 6. 导航规则

### 6.1 决定：所有子页导航都用图标卡片，不用分段控件（不论有无图标）

适用范围：
- 使用场景、字幕：三张场景卡，共享 `requestedScenario`。
- 模型：语音识别 → 文本翻译 → 语音合成，卡间带箭头。
- 组件：引擎与模型、虚拟麦克风。
- 隐私与诊断：数据与隐私、字幕分析、故障检查。
- 引导：场景多选。

理由：

1. `remaining-work.md:29` 已经约定“三场景标签与其他设置页采用相同图标卡片”。卡片本身就是“图标 + 文字”的子标签，用户认可的 icon+text 子标签方案已经包含在内。
2. SwiftUI 的 segmented Picker 在 macOS 上会丢掉 Label 的图片，这正是 34c0724 退化的根因。改用 NSSegmentedControl 只能得到 13pt 小图，等于第三种形态，而且放不下状态。
3. 卡片能承载状态：运行点和计时、需处理角标、OpenAI 角标、录音角标。导航本身因此就在传达状态，这是“图形起到足够作用”的直接体现。
4. 全窗口只有一个组件，键盘、AX 和命中区一致。去掉摘要行后，卡高从 88 降到 64，腾出空间给主图。

### 6.2 规则

- 卡片只回答“这页在编辑或查看什么”。修改一个值（语言、样式、背景）永远不用卡片，用 NodeChip、原生控件或 ThumbnailChoice。
- 卡片行固定在滚动区外，永不收起，永不退化成分段控件。
- 不允许二层导航：子页里面不再出现卡片或分段。
- 场景卡只选择“正在编辑哪个场景”，不启动也不切换会话。在字幕页切卡会同步使用场景页，反之亦然。这条要写进 ARCHITECTURE。
- 每页记住上次的子页（沿用 `SettingsNavigation.modelStage`、`componentsTab`、`diagnosticsTab`）。切换时滚动回顶部。
- 运行中的场景卡带绿点和计时，点击它就是“回到运行中的场景”，因此不需要运行横幅。

### 6.3 页内导航

节点 `.anchor(id)`：调用 `ScrollViewReader.scrollTo(id, anchor: .top)`（AudioSettings 已经这样用），再触发 `FlowInteraction.flashed = id`。Section header 的图标与节点图标相同，看得出两者是对应的。

### 6.4 跨页导航与返回

调用 `SettingsNavigation.open(section, subpage:, returnTo: origin)`，同时选中侧栏页和子页，并显示 ReturnPill。节点到目标页的映射：

| 节点 | 目标 |
|---|---|
| 识别与翻译 | 识别与翻译 › 语音识别（译音泳道上的识别与翻译 → 识别与翻译 › 文本翻译） |
| 双语字幕 | 字幕（同一场景） |
| 麦克风 | 音频 #麦克风 |
| TalkTalk Mic | 安装与维护 › 虚拟麦克风 |
| 会议应用 / Phone（原声泳道） | 音频 #TalkTalk Mic |
| 我的声音 | 我的声音 |
| 术语表卫星 | 术语表 |
| 识别和合成的模型角标 | 安装与维护 › 引擎与模型 |
| OpenAI 节点 | 识别与翻译 › 文本翻译 |
| 字幕分析的“收听” | 使用场景 |
| 菜单问题行 | 对应页的对应 Section，并闪烁 |

**实现记录**：流程链接用 `SettingsNavigation.open(_:_:scenario:anchor:)`，带 ReturnPill；菜单修复项用 `SettingsNavigation.reveal(_:_:anchor:)`，直达但不显示 ReturnPill（§8.7）。两者落到分组时都经 `settingsAnchorTarget` 滚动并闪烁，目标页已打开时同样生效。

---

## 7. 逐页蓝图

记法：`[symbol 标题]` 表示节点或行；`‹chip ▾›` 表示 NodeChip；`(角标)` 表示状态；`→` 表示箭头；“help:”表示 `.help`。

### 7.0 侧栏与窗口框架（SettingsWindowController.swift）

- 侧栏宽 190，原生 `List(.sidebar)` + Label，使用 §4 的 `SettingsIcon.Page.*`。侧栏行不加角标或计数。
- 窗口标题 = 页名。
- detail 容器统一持有三个槽：Z0 ReturnPill、Z1 导航带、Z1b 横幅。
- 翻译占位页（:308/:321）改为 `ContentUnavailableView(xmark.circle)`“此构建不可用”，原句放 `.help`。
- **删除**：页内标题“翻译”；“这个构建没有 bundle id（直接运行的二进制），翻译设置只在 TalkTalk.app / TalkTalk-Dev.app 里可用。”（改放 `.help`）；ReturnPill 里的“返回”二字。

**实现记录（第 2 次提交 a0b370b 起）**：窗口内容默认 880×640，最小 820×600（`contentMinSize`，窗口尺寸由 AppKit 决定，不由 SwiftUI 回推），侧栏固定宽 190。翻译占位页的图标是 `SettingsIcon.unavailable` 令牌，原因放 `.help`；读取中不放文字，而是 `StatusGlyph(.busy)`，help 与 VoiceOver 为“正在读取翻译设置”。

- 侧栏总有一个选中页，点击取消选中会被忽略。

### 7.1 使用场景 · 会议同传

**Z1** CardRow：`[person.2.wave.2 会议同传]` `[phone 电话同传]` `[play.rectangle 视频字幕]`。运行中的卡显示“● 12:03”；来源缺失时显示 warn 角标。

**Z2** FlowGrid（3 条泳道 + 回环，节点高 82）：

| 泳道 | 列 1 | 列 2 | 列 3 | 列 4 |
|---|---|---|---|---|
| gutter `ear`（AX 听对方） | `[person.wave.2 对方]` ‹应用图标 Zoom ▾ \| 自动 ▾› ‹EN ▾›（会话中显示 lock.fill；应用未开时 warn） | `[character.bubble 识别与翻译]` ›模型·语音识别；Qwen 未装时 pending | `[captions.bubble 双语字幕]` ›字幕；字幕隐藏时 off | — |
| gutter 胶囊 **原声** + “默认” | `[mic 麦克风]` ›音频#麦克风；没有麦克风时 failed | `[mic.circle TalkTalk Mic]` ›组件·虚拟麦克风；未装时 pending | `[<会议应用图标> Zoom]`（未知时为 app.dashed“会议应用”）›音频#TalkTalk Mic；角标 = 会议检查 ok/pending/warn/risk（会话中无应用读取为 warn，与问题行、菜单一致）；help:“静音请用会议应用的按钮” | `[person.wave.2 对方听到原声]`；会话中原声生效时为 live；risk 时红描边 + “对方能听到原声” |
| LoopRow（横跨列 2–4） | | `arrow.uturn.backward` Keycap“右⌥” `stop.fill` “播完回到原声” | | |
| gutter 胶囊 **译音** | `[person.crop.circle.fill 说中文]` 附件 Keycap“右⌥ 开始翻译”；help:“可夹英语” | `[character.bubble 识别与翻译]` ›模型·文本翻译 | `[waveform.and.person.filled 我的声音]` ›我的声音；未录制时 pending，卫星虚线 `[speaker.wave.2 系统声音]` | `[person.wave.2 对方听到译音]` ‹EN ▾›（我的译音） |

- 问题行（同一时刻只显示最高的一个）：risk“对方能听到原声”（help:“在 Zoom 的音频设置里选 TalkTalk Mic”）> warn“Zoom 未打开”（help:“不会自动换用其他来源”）> failed“无可用麦克风”。
- FactRow（满足条件才出现）：`[rectangle.on.rectangle 含其他标签页]`（来源是浏览器时）。

没有 Z3 Section，也没有 ⓘ。

**Z5** 底栏：
- 空闲：`[play.fill 开始]`
- 运行中：左侧“● [person.2.wave.2] Zoom · 12:03”，右侧 `[stop.fill 结束]`（红色）
- 进行中：“准备中…”或“结束中…”
- 字幕隐藏：`[eye.slash 字幕已隐藏]` `显示`

**保留可见中文**：会议同传 电话同传 视频字幕 / 12:03 / 对方 自动 EN DE 刷新列表（菜单项）/ <App> 未打开 / 识别与翻译 / 双语字幕 / 原声 默认 麦克风 TalkTalk Mic <会议应用名>|会议应用 对方听到原声 对方能听到原声 / 右⌥ 播完回到原声 / 译音 说中文 开始翻译 我的声音 系统声音 对方听到译音 / 含其他标签页 / 开始 结束 准备中… 结束中… / 字幕已隐藏 显示 / 无可用麦克风。

**删除**：
- 分组标题“会议同传”“工作方式”。
- 两个 InfoButton（“在会议应用里选 TalkTalk Mic；需要静音时…”“点按右⌥开始翻译，说中文，可夹英语；再点按结束…”）。
- 卡片摘要“电脑会议 · 双向同传”（改放 help）。
- “听对方、看双语字幕；点按右⌥把中文译给对方”。
- 小标题“听对方”“我说话”。
- “对方说英语／德语”“原文＋中文字幕”。
- 链接文字“模型设置 / 字幕设置 / 麦克风设置 / 翻译设置 / 声音与试听”（改为 chevron + help）。
- “默认 · 原声”（只留“默认”）、“点按 右⌥ · 翻译”、“再点按 右⌥ 结束 · 译音播完后回到原声”、“说中文，可夹英语”、“对方听英语／德语”。
- 来源 Picker 行“会议应用”、“自动选择”及其 InfoButton 三行。
- “这里只选择本场景要听的应用声音，与你说话用的麦克风分开。”
- “来源在本次会话中保持不变。请先结束当前同传或视频字幕，再更换应用。”（改为 lock + help）
- “请先打开 <应用>，或重新选择应用；不会自动改用其他声音来源。”
- “选择浏览器会包含它的其他标签页。”（改为 chip）
- “听译语言” + InfoButton、“原文语言”、“字幕翻译为 · 中文”。
- 运行横幅“<运行中>正在运行，结束后才能开始<浏览中> / 回到<场景>”。
- 底栏场景名、“按本场景的应用与语言设置开始双向同传。”、“正在准备识别、翻译与音频，请稍候。”、“正在结束翻译并还原麦克风。”、“开始会议同传 / 停止会议同传”。

**实现记录（第 3 次提交 7ab201a）**

- 回环不横跨列 2–4，见 §3.3 的实现裁决。两个 chip 的节点里，自动来源只写“自动 ▾”（§3.4）。
- 会议检查 nobodyReads 是橙色 warn“会议尚未使用 TalkTalk Mic”，不是 pending。§9.1 第 3 行要求节点、问题行和菜单一致，而菜单本来就把它画成橙色；音频页和引导第 7 步因此也是橙色。needsAction 描边只用于 nobodyReads（`MeetingMicCheck.nodeState`，引导第 7 步同用）。
- TalkTalk Mic 节点在驱动未安装时为灰色 pending 角标（与 §7.12 一致），不是橙色；对方能听到原声的后果仍由会议应用节点和风险行承担。
- 底栏的进行中与运行来源见 §3.15 实现记录。
- 会议应用节点的角标原因：空闲时写“未检查”，会议运行中才写“会议麦克风待确认”。
- 场景流程图（§7.1–§7.3）节点里的语言 chip 一律用短码（中／EN／DE，宽 34），菜单项、help 与 VoiceOver 用语言全名；字幕弹层里的语言 chip 仍写全名。

### 7.2 使用场景 · 电话同传

**Z1** CardRow，选中电话同传；有 phoneProblem 时 warn 角标。

**Z2** 主图 Section：
1. **实时发声行**（只在准备好或会话中出现，作为首行）：VoiceCapsule + 12pt 送达图形（`phone.arrow.up.right` / `laptopcomputer` / `speaker.slash`）+ 最短后果，取其一：“已送入 Phone” / “仅本机 · Phone 未接收” / “未发送” / “接通后对方才能听到你”。尾部 22pt 状态按钮：平时是 ⓘ，warn 时是三角，risk 时是风险字形。点开弹出 320pt 弹层，无标题：胶囊、voice.detail 全句、按钮 `[mic.and.signal.meter 音频设置…]`。
2. **FlowGrid**（与会议同构，列对齐）：
   - 听泳道：`[phone.fill 对方]` ‹EN ▾›（对方语言）→ `[识别与翻译]` → `[双语字幕]`
   - 原声泳道：`[麦克风]` → `[TalkTalk Mic]` → `[Phone 应用图标 Phone]`（角标 = Phone 检查：读 TalkTalk Mic 为 ok；读实体麦为 risk；通话前为 pending“通话前检查”；通话中无应用读取为 warn，问题行同源）→ `[phone.fill 对方听到原声]`
   - LoopRow
   - 译音泳道：`[说中文 Keycap]` → `[识别与翻译]` → `[我的声音]` → `[phone.fill 对方听到译音]` ‹EN ▾›
3. **StepTrack**（第二张小图，单泳道，无 gutter，节点高 60）：`[①准备]`（有问题时 warn 角标，问题行显示 phoneProblem 短句）→ `[②在 Phone 中拨号或接听]`（①未完成时 50%，点按滚到拨号行）→ `[③挂断后结束]`。下方 FactRow：`[stop.circle 结束同传不会挂断电话]`。

**Z3**
- Section（无 header，锚定②）：普通 `[phone] 在 Phone 中拨号或接听` 标签，右侧 `[arrow.up.forward.app 打开 Phone]` 按钮；准备前也可打开 Phone。无号码输入、拨打按钮或号码校验，只打开系统应用，拨号、接听和挂断在 Phone 内完成。
- Section `[iphone] 首次连接`（DisclosureGroup，**从未成功准备过时默认展开**，之后默认收起）。内容是一张小图：
  - `[iphone iPhone]` ⇄ `[laptopcomputer Mac]`，卫星 `[person.crop.circle 同一账户]` 和 `[wifi 同一网络]`；iPhone 节点 help:“在其他设备上通话”。
  - `[Phone 应用图标 Phone]`，附件 caption2“麦克风：使用系统设置”，下方 FactRow：`[mic.circle Phone 麦克风：使用系统设置]` 和 risk `[否则对方听到原声]`。
  - FactRow `[headphones 用耳机]`（help“避免回声”）。
  - 行 `[mic.and.signal.meter 音频设置…]`。

**Z5** 底栏：`[play.fill 准备]` / `[stop.fill 结束]`（help“结束同传，不会挂断电话”）；运行中左侧“● [phone] Phone · 12:03”加 chip `[phone 通话不会挂断]`。

**保留可见中文**：已送入 Phone / 仅本机 · Phone 未接收 / 未发送 / 接通后对方才能听到你 / 音频设置… / 对方 EN DE 识别与翻译 双语字幕 麦克风 TalkTalk Mic Phone 对方听到原声 播完回到原声 右⌥ 说中文 开始翻译 我的声音 对方听到译音 / 准备 拨号／接听 挂断后结束 结束同传不会挂断电话 / 在 Phone 中拨号或接听 打开 Phone / 首次连接 iPhone Mac 同一账户 同一网络 麦克风：使用系统设置 Phone 麦克风：使用系统设置 否则对方听到原声 用耳机 / 准备 结束 准备中… 结束中… 通话不会挂断。

**删除**：
- 分组标题“电话同传”及 InfoButton 两句（“TalkTalk 专门收听 Phone…”“准备好后即可收音…”）。
- “用 iPhone 号码在 Mac 上通话，双向同传”。
- 状态行“正在准备 / 结束电话同传…”。
- voice.consequence 的长句形式。
- 弹层标题“状态与提示”。
- “请先结束当前同传或视频字幕，再准备电话同传。”
- “通话语言 / 对方语言 / 我的译音”Picker 行（改为 chip）、“电话对方说英语／德语”。
- “通话步骤”；“准备电话同传 / 拨号或接听 / 挂断后结束同传”（改为短标题）。
- 清单①里重复的主按钮“准备电话同传”。
- “已就绪，可拨号”“准备完成后可拨号”“电话号码（可选，含国家区号）”“拨打此号码”“打开 Phone 接听来电”。
- “在 Phone 中静音或挂断。挂断后点“结束电话同传”…结束同传不会替你挂断电话。”（只留 chip）
- “首次使用：连接 iPhone 与麦克风”；三段指引（同一 Apple 账户…、音频 › 麦克风…、建议使用耳机…）改为图。
- “结束同传会还原麦克风；挂断请使用 Phone。”“先准备同传，再到 Phone 拨号或接听。”“打开音频设置”。
- 底栏“准备电话同传 / 结束电话同传”。

**实现记录（第 3 次提交 7ab201a，582176e）**

- 送达图形为 13pt（§4 实现记录）。对方能听到原声时只画红色风险胶囊，不配送达文字：`PhoneDelivery(_:)` 对这一状态返回 nil，避免同一句出现两次。
- Phone 节点的角标与电话问题行同源 `ScenarioFacts.phoneCheck`：通话前 pending“通话前检查”，读 TalkTalk Mic 为 ok，读实体麦为 risk，通话音频接入后仍无人读取才是 warn“Phone 尚未使用 TalkTalk Mic”。菜单的 Phone 一行读同一来源。
- 电话问题在卡片角标、步骤 ① 和问题行都显示第一个分句，全句放 help（`SettingsProblem(_:sentence:)`，首句以“. ”“; ”、句末“.”和换行为分界），代替笼统的“电话需要检查”。
- ③ 在 ① 未完成且不在进行中时为 50%；结束进行中不灰显。
- 首次连接里的 Phone 节点不再放 caption2“麦克风：使用系统设置”：正下方的 FactChip 已经写了同一事实。首次连接的标题用 SectionHeader 样式。默认展开在每次进入电话页时取定（`SettingsNavigation.phoneSetupDefault`），页面显示期间准备成功不会当场收起；经 ReturnPill 返回算新的一次进入。
- 号码框已撤销（构建 33）：拨号行现在只有“打开 Phone”，号码输入、拨打按钮与拨号进度都已移除（Z3 的拨号行）。
- 语言 chip 不随别的场景运行而锁定（§3.4）：语言偏好按场景独立，非活动场景也可编辑，会议页、电话页和视频页都一样。
- 步骤 ① 在本场已就绪过、或通话音频已接入时保持完成；未开“同传时设为系统默认输入”时，问题行和步骤 ① 的 warn 角标显示“请开启‘同传时设为系统默认输入’，或在 Phone 的‘音频 › 麦克风’选择 TalkTalk Mic。”
- 松开确认在 Phone 未读 TalkTalk Mic 时的送达为“仅本机 · Phone 未接收”。
- 电话场景 Phone 读实体麦时，芯片为“Phone 在用实体麦”，详情为“请在 Phone 的‘音频 › 麦克风’选择‘使用系统设置’或 TalkTalk Mic。”，状态带后果为“Phone 没有使用 TalkTalk Mic”。

### 7.3 使用场景 · 视频字幕

**Z1** CardRow，选中视频字幕。

**Z2** FlowGrid（单泳道，gutter `ear`，节点高 82，与会议的列对齐）：`[<所选应用图标>，未选时为 speaker.wave.2，标题“应用声音”]` ‹Chrome ▾ | 自动 ▾› ‹EN ▾›（lock 和 warn 与会议页相同）→ `[character.bubble 识别与翻译]` ›模型·语音识别（改正原来的“识别原文”，这一步也包括翻译）→ `[captions.bubble 双语字幕]` ›字幕 → —。

- 问题行：warn“Chrome 未打开”。
- FactRow：`[mic.slash 不用麦克风]`（始终显示；help“不启用按键说话，不改默认麦克风”）；浏览器来源时加 `[rectangle.on.rectangle 含其他标签页]`。

没有 Section，也没有 ⓘ。

**Z5** 底栏：`[play.fill 开始]` / `[stop.fill 结束]`；运行中左侧“● [play.rectangle] Chrome · 12:03”。

**保留可见中文**：应用声音 自动 EN DE 刷新列表 / <App> 未打开 / 识别与翻译 双语字幕 / 不用麦克风 含其他标签页 / 开始 结束 准备中… 结束中…。

**删除**：分组标题“视频字幕”及 InfoButton；“看视频时只收听应用声音，显示双语字幕”；“视频声音 / 识别原文 / 中文字幕”；“识别设置 / 字幕设置”；“视频声音来源”；“自动选择正在播放声音的应用；有多个候选时会请你选择。”；“听译语言 / 原文语言 / 字幕翻译为 · 中文”；“收听所选应用并显示字幕，不启用麦克风。”；“正在停止字幕与声音采集。”；“开始视频字幕 / 停止视频字幕”；卡片摘要（改放 help）。

### 7.4 字幕

**Z1a** GlobalRow（固定，在卡片上方，高 28，左对齐，横排）：
- `[captions.bubble] 显示字幕`（switch）。
- **只在 VoiceOver 运行时显示**：`[voiceover] 用 VoiceOver 读出新字幕`（switch；help“只读定稿”）。

**它在卡片上方，这个位置本身就表示“所有场景”**，所以不写“所有场景”或“（所有场景）”。显示条件为 `NSWorkspace.shared.isVoiceOverEnabled`，用 KVO 观察（与 SubtitlePanel.swift:304 相同的写法）。回调切到 MainActor 后写入 `@Observable SubtitleSettingsModel.voiceOverRunning`。VoiceOver 关闭时行隐藏，已存的偏好保留。

**Z1b** CardRow 场景卡（与使用场景页是同一实例和同一 selection）。

**Z2** 主图 Section：`SubtitleLayoutPreview`（会议、电话 760:480，视频 960:150；圆角 12，带阴影）。
- 背景浅色为 #FFFFFF、深色为 #000000，跟随系统外观（HEAD 已实现），**不提供背景选择器**。
- 左上角 caption2“示例”胶囊（`.thinMaterial`）。
- **标题栏热点**：在胶囊、右⌥键帽、结束按钮上各放一个 11pt 编号圆点（①②③，16pt `.thinMaterial` 圆底），help 依次为“发声状态：点开看说明”“右⌥：开始翻译或完成发言”“结束同传”；电话预览的③ help 为“结束同传，不挂断电话”。它们取代被删的标题栏说明句。
- 视频预览：悬停条旁加 `cursorarrow` 11pt 热点，help“悬停时显示”。

**Z3**
- Section `[textformat.size] 字号`：一行，左右 `textformat.size.smaller` / `.larger` 13pt，中间 Slider；值“18 磅”；IconButton `arrow.counterclockwise`（help“恢复默认字号”）。
- Section `[circle.lefthalf.filled] 背景`：一行，左右 `circle.dotted` / `circle.fill`，中间 Slider，在 85% 处画刻度；值“85%”；IconButton 恢复默认（新增，help“恢复默认 85%”）。
  - 系统开启“降低透明度”时禁用，行尾加 `accessibility` 13pt，help“系统已开启降低透明度”。
  - 描边样式时禁用，help“描边样式没有背景”。
- 只在视频场景：Section `[captions.bubble] 样式`：
  - ThumbnailChoice 三个：贴合玻璃 / 描边 / 实底。
  - 行 `[arrow.up.arrow.down] 排列`：ThumbnailChoice 两个：原文在上 / 译文在上。
  - Toggle `[moon.zzz] 静默变暗`（help“8 秒无新内容时变暗”）。
- Section `[macwindow] 窗口`（无行，只有 FactRow）：
  - `[arrow.up.and.down.and.arrow.left.and.right 可拖动]`（help“拖标题栏或文字；视频可在菜单锁定”）
  - `[keyboard 不抢焦点]`
  - `[minus.circle 收起后继续]`（单色，不再用黄色）
  - `[rectangle.on.rectangle.slash 共享屏幕不可见]`
  - ⓘ“最小化后从菜单栏选“恢复字幕窗口”。”

**保留可见中文**：显示字幕 / 用 VoiceOver 读出新字幕 / 会议同传 电话同传 视频字幕 / 示例 / 预览内的示例内容 / 字号 N 磅 / 背景 N% / 样式 贴合玻璃 描边 实底 / 排列 原文在上 译文在上 / 静默变暗 / 窗口 可拖动 不抢焦点 收起后继续 共享屏幕不可见 / ⓘ 一句。

**删除**：
- “显示字幕（所有场景）”改为“显示字幕”；“朗读新译文（VoiceOver）”改为“用 VoiceOver 读出新字幕”，且只在 VoiceOver 运行时显示；“用 VoiceOver 朗读每条定稿译文，不读草稿”改为 help“只读定稿”。
- “字号、背景和窗口位置按场景分别保存；朗读新译文对所有场景生效…不会启动或切换正在进行的会话。”
- 卡片摘要“双方发言 · 原文与译文分栏 / 电话对话 · 原文与译文分栏 / 扁宽字幕条 · 原文与中文”。
- “布局预览”。
- 三段预览说明（会议、电话、视频，含“预览显示鼠标悬停时的标题栏”）。
- “字幕大小”分组标题 + InfoButton；“基础字号”改为“字号”。
- 两段长 footer：“每次显示同一句的原文与中文…中文下方的圆点表示还有下一页。”“对方和自己的发言按句对排列，保留最近约一分钟…”
- “视频字幕”分组标题；“字幕样式”标签；三段样式说明“贴合玻璃：… / 描边：… / 实底：…”。
- “长静默时变暗”改为“静默变暗”；它的说明句改放 help。
- “窗口背景”分组标题；“背景不透明度”改为“背景”。
- 两句“系统已开启“降低透明度”…”（改放 help）；静态行“描边样式不使用背景”。
- 两句“使用 macOS 原生毛玻璃…低于 75% 时文字加阴影。”
- “移动与隐私”改为“窗口”；“拖动标题栏或文字区域移动；视频可在菜单中锁定位置。”（改放 help）。
- “窗口左上角的最小化按钮收起字幕，同传继续…”（改为 chip + ⓘ）；“不出现在屏幕共享中”改为“共享屏幕不可见”。
- “标题栏右侧显示发声状态、右⌥ 和结束操作；点状态查看说明。”“电话窗口标题栏有“Phone”和“结束同传”按钮…”（改为预览热点）。

**实现记录（第 4a 次提交 6cd04df）**

- 预览放在第一个分组的卡片里（§2 Z2），与场景页一致。VoiceOver 不再把它读成一张图，而是名为“字幕窗口布局预览”的分组，内含各热点（图像角色，标签为热点说明）。
- 热点圆点是 AppKit 的 `NSVisualEffectView`（hudWindow、darkAqua、within-window，白 22% 着色、细描边、11pt 白色数字或图形），不是 SwiftUI `.thinMaterial`：圆点要按 AppKit 标题栏控件的 frame 定位，而且落在始终是深色的字幕窗口上。每个圆点在其控件右上角。
- 电话预览多一个 Phone 图形热点，不改 ①②③ 的编号，help 为“打开 Phone：拨号、接听或挂断”。依据是上面删除清单里 Phone 按钮的说明“改为预览热点”。
- 视频的指针热点放在悬停条右上角，与 ①②③ 一样是角标位置，help“悬停时显示”，VoiceOver 标签“标题栏：鼠标悬停时显示”。
- 热点的 tooltip 用 rect tooltip（`addToolTip` + `NSViewToolTipOwner`），不用 `toolTip`：设了 `toolTip` 的 NSView 会把同一句作为 AXHelp，VoiceOver 读两遍（离屏探针实测）。
- 两个滑块都在默认值处画刻度，用 macOS 26 原生的 `Slider(…, tick:)` 与 `SliderTick`，不是自绘。背景滑块的 VoiceOver 标签保留“背景不透明度”。描边样式时只灰显并写 help，不加行尾图形；只有“降低透明度”加 `accessibility` 图形。
- 规格没给 help 的 chip：不抢焦点为“键盘输入留在当前 App”；收起后继续沿用原来的可见句（视频为“最小化后收听和翻译继续，可从菜单栏恢复”）。共享屏幕不可见的 help 第 8 次提交改为“部分共享方式下可能不显示，不作保证”：Apple 文档把 `NSWindow.SharingType.none` 写作 macOS 不再使用的旧常量，只说它会让内容在部分共享方式下不可用，并说明不要用它隐藏或防止截取内容，所以 help 不能承诺屏幕共享或录屏一定看不到。可见的“共享屏幕不可见”四字暂按 §5.4 保留，但它比 Apple 文档承诺的范围更绝对，是否改词待用户决定；实际会议共享和录屏工具的表现要由用户安排实测。
- 样式缩略图那一行缩进到 +30，没有自己的行图标，由“样式”分组标题的图标说明；排列是带图标的 LabeledContent 行。
- 删掉的 ⓘ 事实（按场景分别保存、向上滚动暂停跟随、长句分页的圆点）不另找去处；按场景保存只由滑块上方的场景卡暗示。
- Z1a 的 GlobalRow 开关是 mini（`controlSize`），与页面其他开关一致。
- 视频“实底”样式的“背景”滑块置灰，help 为“实底样式背景固定”，与描边同一做法；实底固定 0.62（降低透明度时 0.85）。
- 系统“减少透明度”开启时，“样式”缩略图置灰并带 accessibility 图标与“系统已开启降低透明度”，已存样式不变；样式行与排列行都是带行标签、缩略图在行尾的行；预览的视频控制条用 `Radius.videoGlass`、增强对比度描边，红黄圆心对齐真实位置，右侧留白 16。
- “排列”的第二个选项为“译文在上”（六方向互译后译文不一定是中文）。

### 7.5 通用

**Z2** PageHero：方块 `gearshape`；状态为本页最高优先级的问题，例如 warn“建议开启登录时启动”、waiting“待系统允许”、warn“需允许通知”；全部正常时为 ok“已就绪”。help“启动、通知与应用管理”。

**Z3** Section（无 header）：
- Toggle `[power] 登录时启动`。行尾按状态显示其一：
  - warn“建议开启” + ⓘ“异常退出后，默认输入可能停在 TalkTalk Mic，直到下次启动才还原。”
  - waiting“待系统允许” + 按钮 `[arrow.up.forward.app 登录项…]`
  - 尚未登记的主应用 `.notFound` 与 `.notRegistered` 都是正常关闭、可开启；不显示目录错误或“不可用”。真正的注册／注销失败由下方错误状态显示。
  - failed“未能更改”（help 放 error）
  - 未签名构建时禁用，help“未签名构建不可用”
- Toggle `[bell] 会议结束通知`（help“会议似乎结束时提醒你”）。行尾：
  - 检查授权中：busy（AX“检查中”）
  - warn“需允许通知” + 按钮 `[bell.badge 允许…]`
  - failed“系统已拒绝” + 按钮 `[arrow.up.forward.app 系统设置…]`
  - 不支持时禁用，help“当前运行方式不支持通知”
- Toggle `[megaphone] 首次翻译前播放告知语`（help“告诉对方你在用机器同传与合成声音”）。

Section（无 header）：
- 按钮行 `[arrow.clockwise.circle] 使用引导…`。引导未完成时行尾 caption 显示“第 N 步，共 M 步”。help“保留已装模型与声音档案”。
- 按钮行 `[App 图标 15pt] 关于 TalkTalk`，行尾 secondary 版本号“1.0 (29)”，可选中复制。

**Z4** 破坏性 Section：普通 `[trash] TalkTalk 与本机数据` 标签，右侧原生小按钮“完全卸载…”（红字），不再整行可点击。
- 进行中：行尾显示进度和步骤名。
- 引擎安装中：行禁用，行尾 waiting“引擎安装中” + 链接“安装与维护 ›”。
- 确认弹窗：标题“完全卸载 TalkTalk？”；正文“将删除：虚拟麦克风 · 引擎与识别与翻译 · 我的声音 · 术语表 · 日志缓存 · 设置与登录项 · 钥匙串中的 OpenAI key。需管理员密码，声音中断约 1 秒；通话中不可卸载。完成后退出并移到废纸篓。”；按钮“全部删除”“取消”。
- 结果：“已删除 N 项”；“未删除：”后每项加 `xmark.circle.fill`。

整节删除“会议与电话发言方式”（与场景页的泳道重复；列入 §9.6 待确认）。本页只有 1 个 ⓘ。

**保留可见中文**：已就绪 / 登录时启动 建议开启 待系统允许 登录项… 未能更改 / 会议结束通知 需允许通知 允许… 系统已拒绝 系统设置… / 首次翻译前播放告知语 / 使用引导… 第 N 步，共 M 步 / 关于 TalkTalk 1.0 (29) / 完全卸载… 引擎安装中 安装与维护 › / 弹窗与结果文字。

**删除**：
- 节标题“启动 / 会议与电话发言方式 / 通知 / 告知对方 / 首次引导 / 关于 / 应用管理”。
- “登录时启动 TalkTalk”。
- 橙字“强烈建议开启：TalkTalk 异常退出后…”。
- “这个构建没有签名，不能注册登录启动。”“等你在“系统设置 › 通用 › 登录项与扩展”里允许 TalkTalk。”“系统没找到这个 App 的登录项；把 TalkTalk 放进“应用程序”文件夹后再试。”
- “打开登录项设置”“登录启动没有改成：<error>”。
- 整节发言方式：胶囊图示、ⓘ、“点按一次右⌥开始翻译…”、“需要静音时，请使用会议应用或 Phone 的静音按钮。”
- “会议自动结束通知”“正在检查系统通知授权… / 权限…”“系统通知权限：已允许”“通知尚未生效：…”两句、“当前运行方式不支持系统通知。”“允许系统通知…”“打开系统通知设置”（gearshape）、“关闭通知不会改变自动结束会议的规则；视频字幕同样适用。”“提醒你会议似乎已结束。”
- “第一次按键翻译时播放告知语”“向对方说明你正在使用机器同传和合成声音。”“也可以从菜单选择“现在播放告知语”。”
- “重新运行引导…”“重新检查权限、组件和声音设置…”。
- 单独的“版本”行；“关于 TalkTalk…”去掉“…”。
- “正在检查组件…”；headline“完全卸载 TalkTalk”；“移除组件及本机的声音档案、设置和数据。”；约 230 字的卸载长文；“没有删除或没有做成的： / 已删除的（N 项）”。

**实现记录（第 4b 次提交 f8a6be2，第 6 次 14b8145）**

- 使用引导… 在引导未完成时从当前一步继续（原来总是重新开始），行尾“第 N 步，共 M 步”取 `OnboardingState.progress`，与菜单状态 A 和引导头部同源；已完成时重新开始，重跑不收回已完成状态（`completedOnce` 持久化）。Apple 语音或翻译资源缺失时，这一行行尾与头图显示 warn“Apple 资源待配置”，菜单同名问题行的“通用设置…”落到这一行并闪烁（第 6 次提交）。
- 会议结束通知的 warn／failed 状态和“允许…”“系统设置…”只在开关开启时显示。
- 登录时启动的开关只在本页；ⓘ 跟着“建议开启”出现。音频页只在 .recommended 时显示状态行（§7.6，`LaunchAtLogin.recommendedProblem`）。
- 完全卸载的结果只显示一行短句（如“已删除 N 项”），标题与原因放 help；只列未删除的项，以及提前停止前已完成的步骤。确认文字加了“并重置隐私权限”，对应已有的 tccutil 步骤。`FullUninstallSection` 移到 TalkTalkDriverSupport 自己的文件，接受可选模型（为 nil 时是带说明 help 的禁用行）和“安装与维护 ›”链接。
- Z3 在“登录时启动”之前有行 `[globe 界面语言]`（`SettingsIcon.interfaceLanguage`），头图 help 可以加上语言。
- Apple 资源检查不只在启动时跑一次：引导下载或完成、开始时下载语音资源成功、应用回到前台、切换界面语言时都会重跑，菜单的“Apple 资源待配置”和通用页同时更新。
- 完全卸载：会话、录音或试听进行中按钮预先禁用并在行尾显示 waiting“先结束会话”；一次完整卸载后按钮保持禁用；运行结束后通用页刷新登录时启动状态；英文首句切分认半角句读加空格或句尾。

### 7.6 音频

**Z2** FlowGrid（2 条泳道，节点高 82；以图开头，不加 PageHero）：

| 泳道 | 列 1 | 列 2 | 列 3 |
|---|---|---|---|
| gutter：胶囊 原声 / 译音 竖排 | `[mic 麦克风]` caption2 当前设备名；角标：蓝牙或接续互通时 warn，没有麦克风时 failed；anchor #麦克风 | `[mic.circle TalkTalk Mic]`；“同传时设为默认输入”开时 ok，关时 off；anchor #TalkTalk Mic | `[person.2.wave.2 会议 · Phone]`；角标 = 会议/Phone 检查 ok/pending/risk（risk 时红描边 + “对方能听到原声”）；anchor #TalkTalk Mic |
| gutter `headphones` | `[speaker.wave.2 会议声音]` | 穿过；耳机译音开时箭头上叠 10pt 译音胶囊 | `[headphones 耳机]` 附件 mini switch（耳机译音）；当前为外放时 warn + hifispeaker；anchor #耳机 |

问题行：只显示 1 个最高的问题，规则同 §2。

**Z3**
- Section `[mic] 麦克风`：
  - Picker 行 `[mic] 麦克风`，选项“自动 · <当前设备>”及各设备（带图标）。行尾状态：warn“通话音质”（help“耳机会切到通话音质，识别也会变差”）；waiting“延迟约 125 ms”；failed“无可用麦克风”；warn“所选设备不在 · 暂用自动”“所选设备不可用 · 暂用自动”“<原因>不可用 · 暂用自动”。
  - 行 `[dial.medium] 原声音量`：值“+2.1 dB”或 pending“未校准”；按钮“校准…”（会中禁用，help“会中不可校准”）。
  - 校准中这一行展开：电平条 + “按平常音量读一句（约 6 秒）” + FactChip `[lock.shield 不保存录音]` + 按钮“取消”。结果：ok“+x.x dB” / warn“未测到清晰语音或削波 · 重试” / warn“麦克风已变 · 已取消” / warn“需麦克风权限” / failed“未完成”（help 放 error）/ “已取消”。
  - Section ⓘ：“换麦后可单独校准，不必重录声音档案。”
  - 蓝牙确认弹窗：“用“<设备>”的麦克风？”，正文为 pickNotice 短句，按钮“仍然使用”“取消”。
- Section `[mic.circle] TalkTalk Mic`：
  - Toggle `[mic.circle] 同传时设为系统默认输入` + ⓘ“停止同传或退出时自动还原；你手动改过的输入会保留。”
  - FactRow `[mic.circle 听写、Siri 等也会收到原声或译音]`。
  - 状态行（会议检查）：ok“Zoom 正在用 TalkTalk Mic” / pending“未检查” / warn“会议尚未使用 TalkTalk Mic”（与节点、问题行、菜单一致；第 3 次提交裁决） / risk“对方能听到原声 · 在 Zoom 选 TalkTalk Mic”。
  - 条件行（只在强烈建议时）：`[power] 登录时启动` + warn“建议开启”，链接“通用 ›”。
- Section `[headphones] 耳机`：
  - Toggle `[headphones] 耳机译音`（与节点开关同步）。
  - FactRow `[hifispeaker 外放时自动停用]`（help“停用耳机译音与原声通路，避免回声”）。
  - 已记住的设备（没有设备时不显示这些行，也不写标题）：每台一行 `[headphones|hifispeaker] <设备名>`，行尾是类型 Picker（耳机 / 扬声器，带图标）+ IconButton `minus.circle`（help“忘记此设备”）。
  - 首次连接弹窗：““<设备>”是耳机吗？”，正文“外放时停用耳机译音和会议原声，避免回声。”，按钮“是耳机”“是扬声器”。

**保留可见中文**：原声 译音 麦克风 TalkTalk Mic 会议 · Phone 对方能听到原声 会议声音 耳机 / 麦克风 自动 · <设备> 通话音质 延迟约 125 ms 无可用麦克风 所选设备不在 · 暂用自动 / 原声音量 未校准 校准… 按平常音量读一句（约 6 秒） 不保存录音 取消 + 结果短句 / 同传时设为系统默认输入 听写、Siri 等也会收到原声或译音 <app> 正在用 TalkTalk Mic 未检查 会议尚未使用 TalkTalk Mic 登录时启动 建议开启 / 耳机译音 外放时自动停用 耳机 扬声器 / 弹窗文字。

**删除**：
- “声音如何流动”及其 footer“耳机负责播放…视频字幕只收听应用声音，不使用麦克风。”
- 节点旧标签“实体麦克风 / 原声／按键翻译 / 会议应用 / 会议声音与可选译音 / 耳机播放”；链接文字“选择采音设备 / 设置会议输入 / 设置耳机播放”；“TalkTalk 选实体麦收音；会议应用选 TalkTalk Mic 接收声音。”
- “实体麦克风 · 采集你的声音”“采音设备”“已选采音设备”“自动（内建麦克风优先）”。
- 三句长回退说明（“你选的麦克风现在不在…暂时改用上面这一个。”等）；“采音设备如何选择”及其说明。
- “会议与电话收音”整节，“收音方式 = 按场景启用麦克风”“需要静音时…”，86 字 footer。
- “校准增益 / 校准状态 = 尚未校准 · 0 dB”“读一句话校准音量”“请按平常音量读一句话，测量约 6 秒；只测电平，不保存录音。”“只测电平，不保存录音。请先停止会议同传或视频字幕再校准。”
- “TalkTalk Mic · 通话输入”“会议或电话同传时将系统默认输入设为 TalkTalk Mic”“在会议应用或 Phone 中选择 = TalkTalk Mic…”“默认输入如何恢复”及其说明、“视频字幕不更改默认输入。”
- “会议与电话应用检查”及其 footer、“尚未检查。准备会议或电话同传后，可在会议应用中测试麦克风…”、“会议绕过 TalkTalk 使用实体麦克风，按键翻译已停用…”（改为 risk 短句，detail 放 help）。
- “耳机 · 播放声音”“在耳机中听到译音”“开启后，你也能听到译音。外放时停用…”。
- “已记住的耳机与扬声器”“还没有已确认的设备”“设备分类说明”及其说明、“这里的设备分类不表示当前正在使用的输出。”
- 外放弹窗长正文（缩短）。

**实现记录（第 4c 次提交 0b878a1）**

- 接续互通麦克风：节点角标与行尾用同一个问题，所以是 waiting“延迟约 125 ms”，不是 warn。
- TalkTalk Mic 节点先显示驱动问题（未安装、需重启音频服务等，与场景页同源），没有驱动问题时才按“同传时设为默认输入”显示 ok 或 off。
- 会议 · Phone 检查：没有发声会话时（视频字幕会话也算）为 pending“未检查”；发声会话中尚未确认时用场景的词（会议麦克风待确认，Phone 为通话前检查）；Phone 的风险为“对方能听到原声 · Phone 选“使用系统设置””，通话音频接入后无人读取为 warn“Phone 尚未使用 TalkTalk Mic”。nobodyReads 为 warn（§7.1 实现记录）。
- 问题行多一个外放候选 warn“正在外放 · 耳机译音已停用”（help“停用耳机译音与原声通路，避免回声”），与耳机节点一致；外放时连线上不叠译音胶囊。驱动问题只在节点上，与场景页相同。
- “听写、Siri 等也会收到原声或译音”只在“同传时设为系统默认输入”开启时显示，因为它是这个开关的后果。默认输入的 ⓘ 按 §5.5 写“结束同传或退出时自动还原”，不用本节引文里的“停止”。
- 闪烁描分组标题（§3.3 实现记录）。有待处理的锚点时页面不滚回顶部，音频页在下一个主队列轮次取锚点。
- 校准结果只属于当次访问：离开页面、换麦或开始会话时清掉旧结果；只有取消正在运行的校准才显示“已取消”。
- 音频页可见期间跟随设备列表变化（`DeviceWatcher.devicesChanged`）；校准点击时先重读设备，所选麦克风已变则行尾显示“麦克风已变 · 已取消”；“需麦克风权限”行尾带“系统设置…”。
- TalkTalk Mic 分组的“同传时设为系统默认输入”：发声会话中，安全 chip 与流程图节点读本场实际（进入会议模式时的快照），空闲时读开关；会中改动在开关行尾显示 waiting“下次开始生效”（help“本次仍按开始时的设置”）。
- headphone 询问弹窗的两个按钮都不设默认键，回车不能作答。
- 问题行的候选在会议检查、micProblem、外放之外，加上系统默认输入通知、空闲时有应用读 TalkTalk Mic、播放设备未确认，用词与菜单相同。

### 7.7 我的声音（含 EnrollmentView）

**Z2** FlowGrid（两条泳道，第一条 gutter `person.crop.circle.fill`，节点高 82；第二条沿用 §7.10 的译音路径）：
- `[mic 录中文]`：附件按钮 `[mic.badge.plus 录制]`，有档案时为“重录”（borderedProminent small；这是本页唯一的主操作）；自检中禁用。
- `[waveform.and.person.filled 声音档案]`：已保存时 ok，未创建时 pending，“无法读取”或“引擎已切换 · 请重录”时 warn；附件 caption2 日期“11-06”；未创建时卫星为虚线 `[speaker.wave.2 系统声音]`。
- `[headphones 试听]`：附件 `[play.fill EN]` `[play.fill DE]`，播放时变为 `stop.fill`（AX“试听英语 / 德语”）；角标：通过为 ok（help“音色相似度 0.98”），未通过为 failed（help“建议重录”），待引擎为 waiting。

问题行：取 waiting“自检中” / waiting“引擎就绪后可试听” / waiting“组件安装中” / warn“自听输出不可用” / warn“试听失败”（help 放 error）中优先级最高的一个。

FactRow：
- `[lock.shield 仅本机 · 不上传]` + ⓘ“声音档案只保存在这台 Mac，不进备份与 Spotlight 索引。” + IconButton `folder`（help“在 Finder 中显示”）。
- `[laptopcomputer 本机播放]`（help“试听不发送到会议”）。
- 没有档案时加 `[speaker.wave.2 未录制时用系统声音]`。

**Z4**（有档案时）：普通“声音档案”标签，行尾为原生 small push“删除…”按钮（`SettingsDestructiveButton`，启用时系统红字、禁用时系统灰字），不再将整行画为红色点击区。点按打开系统 alert“删除声音档案？”，正文“参考音、稿子和声音缓存从这台 Mac 删除；之后译音用系统声音。”，按钮为“取消”和“删除声音档案”。后者是对用户主动删除请求的普通确认按钮，遵循 macOS 系统样式，不手工染红或指定默认快捷键；删除模型逻辑不变。

档案详情（参考音、语速、自动检查、声音缓存）**移到** 隐私与诊断 › 故障检查 › 技术详情 › 声音档案。

**EnrollmentView（TalkTalkVoice）**
- 去掉标题和副标题。
- 顶部 StepTrack：`[mic 录中文]` → `[checkmark.shield 检查]` → `[headphones 试听保存]`，图标与主图一致。
- 准备区：行 `[mic]` 麦克风 Picker + IconButton `arrow.clockwise`（help“刷新”）；FactRow `[clock 约 10–20 秒]` `[ear 安静 · 离麦一拳]` `[lock.shield 仅本机 · 不上传]`；重录时加 `[checkmark.shield 旧档案保留到保存]`。
- 稿子：26pt，无 GroupBox 标题。
- 录制：“请先保持安静” → 72pt 倒数 → “请自然朗读” + 计时“x.x 秒”；电平条前有 `mic` 15pt（AX“输入音量”）。
- 处理：“检查中…”“生成试听…”“保存中…”。
- 结果：ok“可以用”；每项检查一行，只显示状态图形 + 检查名，message 放 help；failed“未通过：<原因> · 建议重录”；waiting“引擎就绪后生成试听”；`[headphones 戴耳机试听]`；EN / DE 两行，状态图形 + play/stop IconButton；warn“无法播放”；`[laptopcomputer 本机播放]`；“已保存” + `[lock.shield 仅本机]`；“第 N 遍”。
- 按钮：关闭 / 开始录制 / 取消 / 完成录制 / 放弃 / 重录 / 保存 / 完成 / 再试一次（“生成试听”和“保存声音档案”合并为“保存”）。

**保留可见中文**：录中文 录制 重录 声音档案 <日期> 系统声音 试听 EN DE / 自检中 引擎就绪后可试听 组件安装中 自听输出不可用 试听失败 / 仅本机 · 不上传 本机播放 未录制时用系统声音 / 删除声音档案… 及对话框 / 录制窗口里的上述短词。

**实现记录（第 4c 次提交 0b878a1，第 5 次 40bb982）**

- 没有档案时进入本页先显示概览，点“录制”才进入录制视图，不自动打开也不自动开始（`MyVoiceModel.autoBegan` 已删除；2026-11-07 的并页决定取代了先前“每次进入先打开录制视图”）。
- 问题行比上面多两个候选：warn“声音档案无法读取 · 请重录”和“引擎已切换 · 请重录”。“自听输出不可用”只在读到不可用原因后出现，不会在读取前闪一下。
- 档案存在但读取失败时，不显示“未录制时用系统声音”，也不挂系统声音卫星：这时合成等待恢复，不改用系统声音。
- 事实行是本页自己的 ViewThatFits：ⓘ 和 Finder 按钮挂在第一个 chip 后，因为 §3.9 要求 ⓘ 挂在它说明的 chip 上；大字号下同样竖排（§3.11）。
- 试听生成中按停止，按钮立即换回不可用的播放，生成完也不播放。
- 录制视图的步骤条用编号步骤（§3.5 实现记录）；倒数与稿子字号为令牌（§4 实现记录）。

**删除**：
- “用你的声音朗读英语或德语译文。”
- “录一段中文 / 保存声音档案 / 听英语／德语”；节标题“声音档案 / 听听效果”。
- “尚未创建声音档案”“读一遍固定的中文稿子即可创建…”“声音档案已保存”“录制时间”“试听检查”“通过（音色相似度 x.xx）”。
- 档案详情折叠里的全部内容（已移走）。
- “试听英语 / 试听德语”（改为 EN/DE + AX）。
- “自检正在运行，完成后可录制或试听。”“引擎装好并就绪后可试听（经自听输出播到耳机，绝不进 TalkTalk Mic）。”“引擎组件正在安装或修复，完成后再试听。”“试听在耳机或当前播放设备中响起，不发送到会议。”“重新录制时，旧档案会一直保留到新档案保存成功。”
- “存储与隐私”折叠及路径（改为 ⓘ + Finder 按钮）；删除确认长正文（缩短）。
- 录制窗口：“创建我的声音 / 重新录制我的声音”“录一段中文，用你的声音说英语和德语。”“录制准备 / 朗读这段中文”“找个安静的地方…离麦克风一拳左右。”“约 10–20 秒 · 按平时说话的语速读完全文”“开始后先测量环境噪声，再倒数 3 秒…”“测量环境噪声后，会倒数 3 秒再开始录制。”“自然读完全文…或点“完成录制”。”“正在检查录音质量… / 正在准备你的声音并生成英语、德语试听…”“录音检查”及每项 message、“语速约 x.x 字/秒（用于估计说话节奏）”“引擎尚未就绪：可以先保存录音…”“试听已生成。戴上耳机听一听，满意就保存。”“回读错误率 / 第 N 次生成”“参考音 x.x 秒，语速 x.x 字/秒。”“存储位置 + 路径”。
- 录制视图“生成试听…”阶段页脚有“取消”（恢复原声音）；准备页没有合格麦克风时选择器行尾显示 failed“无可用麦克风”，“开始录制”禁用并带同一句 help；设备类失败（断开、采样率变化、打不开、无设备）的“再试一次”回到准备区重新选麦；试听保存一步自听输出不可用时 EN／DE 置灰并显示 warn“自听输出不可用”取代“戴耳机试听”；电平条过载时尾部加 warn 图形，VoiceOver 值为“削波”。
- “已保存”即刷新档案节点与场景页（不等“完成”）；引擎维护与音频自检只把录音中、检查、试听生成、保存（含 review）算进行中，idle、saved、failed 不算；概览生成试听时问题行显示 waiting“生成试听…”；试听失败只属于当次访问（进入概览、删除档案、被删除取消时清除）；设置与引导两个窗口的档案互相刷新；合成译音节点右侧只读显示合成模型短名。
- 译音来源：有档案但引擎未安装时，我的声音页与场景页的卫星画虚线“系统声音”（help“引擎未安装，声音档案暂不能用”），与菜单“译音：系统声音”一致；页面 ⓘ“暂不可用时不会改用系统声音”描述的是引擎已装但暂不可用的情形，保持不变。语音合成子页（`ModelSettingsView.synthesis`）的卫星尚未同步。
- 录音步骤的标题统一为“录音／Record”（2026-11-07 并页决定），上文设计稿里的“录中文”按此更新解释；删除声音档案是“声音档案”行尾的“删除…”。

### 7.8 识别与翻译 · 语音识别

**Z1** CardRow（arrows）：`[waveform 语音识别]` → `[character.bubble 文本翻译]` → `[speaker.wave.2 语音合成]`。
- 语音识别卡：Qwen 未装时 pending；已转 Apple 备用时 warn。
- 文本翻译卡：启用 OpenAI 时显示 `network`；key 无效或模型下线时 warn。
- 语音合成卡：TTS 未装时 pending。

**Z2** FlowGrid（2 条泳道，节点高 82）：
- gutter `ear`：`[person.wave.2 应用声音]` → `[waveform 识别]`，附件 ‹Qwen3-ASR ▾›（选项 Qwen3-ASR / Apple Speech，立即生效）；Qwen 模型未装时 pending + chevron 到组件·引擎与模型；运行中且已回退时 warn；卫星为虚线 `[laptopcomputer 备用 Apple]`，Apple 生效时变实线 → `[text.bubble 原文]`。
- gutter 胶囊 译音：`[person.crop.circle.fill 说中文]`，附件 Keycap“右⌥” → `[waveform 识别]`，附件 caption2“Qwen3-ASR”（固定），卫星为链接 `[character.book.closed 术语表 ›]` → `[text.bubble 原文]`。

FactRow：`[laptopcomputer 本机识别]`（help“声音在这台 Mac 上转成原文”）。

**没有 Section**。“本地识别模型”一行已删除，节点角标和 chevron 已经表达它。本页没有 ⓘ。

**保留可见中文**：语音识别 文本翻译 语音合成 / 应用声音 识别 原文 说中文 右⌥ / Qwen3-ASR Apple Speech / 备用 Apple 术语表 / 本机识别。

**实现记录（第 4d 次提交 3def91e）**：听泳道识别节点的“备用 Apple”卫星只在选 Qwen3-ASR 时出现（选 Apple Speech 时没有备用），会话中转到 Apple 之前为虚线。我说话泳道的识别节点在 ASR 模型缺失时为 pending，并与听泳道一样链接到安装与维护 › 引擎与模型；组件链接只在模型缺失或有问题时出现。图下加了问题行（与场景页同一写法），上文没有。

**删除**：卡片下 caption“声音 → 原文 / 原文 → 译文 / 译文 → 声音”（改为卡间箭头 + help）；“听对方／看视频 · 应用声音 → 原文”；“首选识别引擎”；“Qwen3-ASR（默认）”的“（默认）”；“当前运行 / 尚未开始收听”；“选择立即生效；Qwen 不可用时由 Apple Speech 接管。”；“按键翻译的识别引擎 / Qwen3-ASR，Apple Speech 备用”；“支持中文夹英语，统一生成选定的英语或德语译音。”；“我说话 · 点按右⌥开始，再点按结束”；“本地识别模型”整节（含 InfoButton，模型 id 改放 help）；“管理本地模型安装”；“识别与翻译的分工”折叠及两段说明。

- 识别图在 asr 角色存在但引擎不可启动（缺文件、需更新运行时、记录损坏）时，带出与语音资源卡同一问题，并出现“安装与维护 · 语音资源”链接。
- 会中 OpenAI 因 key 或额度暂停（paused）时，文本翻译卡角标为 warn“OpenAI key 或额度异常 · 已用 Apple”。

### 7.9 识别与翻译 · 文本翻译（TalkTalkCloudUI）

**Z1** CardRow（同上，选中文本翻译）。

**Z2** 主图 Section：
1. FlowGrid（2 条泳道，节点高 82）：
   - gutter 胶囊 译音：`[mic 我说的话]` caption2“中” → 翻译节点（启用 OpenAI 时为 `network`“OpenAI”，否则为 `laptopcomputer`“Apple”；附件 mini switch，AX“用 OpenAI 翻译我说的话”；未同意或没有 key 时禁用；角标：没有 key 时 warn，help“无 key → Apple”；会话中改动时 waiting，help“下次开始生效”；启用 OpenAI 时卫星为虚线 `[laptopcomputer 备用 Apple]`）→ `[character.bubble 译文]` ‹EN/DE›。
   - gutter `ear`：`[person.wave.2 听到的话]` ‹EN/DE› → 翻译节点（同上，AX“用 OpenAI 翻译听到的话”）→ `[captions.bubble 中文字幕]`。
2. **DataBoundary**，尾部 ⓘ 原样放 cloudNotice。
3. 问题行：warn“无 key → Apple” 或 waiting“下次开始生效”，取其一。

**Z3**
- Section `[key] API key`（同意与输入都留在行里，不进弹层）：
  - 未同意：按钮 `borderedProminent`“同意发送文字”，下方输入框禁用。
  - 已有 key：行 `[key] sk-…•••` + IconButton `checkmark.shield`（help“验证”）+ IconButton `trash`（help“删除 key”）。
  - 输入行：SecureField 占位“sk-…” + 按钮“保存”（保存后自动验证）。
  - 结果：ok“已存入钥匙串 · 请清空剪贴板”；failed“key 无效 · 401”“被拒绝 · 403”“模型不存在 · 404”“额度用完 → Apple”“请求太频繁”“OpenAI 出错”“连不上”，原句放 help。
  - 行：Link `[arrow.up.forward.app OpenAI]` + ⓘ“建议单独建一个 project 并设硬性预算上限，再在其中建 key。”
- Section `[network] OpenAI`（任一方向开启或已有 key 时显示）：
  - Picker 行 `[square.stack.3d.up] 模型`，选项后缀只留“默认”；菜单图：`tortoise` 表示会变慢，`clock.badge.exclamationmark` 表示即将下线。行尾 IconButton `arrow.clockwise`（help“重新读取模型列表”）。
  - Toggle 行 `[hare] Fast 模式`：行尾 chip `[dollarsign.circle 2× 费用]` → 等待状态（help“下次开始生效”）→ 开关；打开后费用行按两倍估算。
  - Toggle `[pin] 显示固定快照`。
  - 下线通知：warn“X 已下线 → Y”或“Y 即将下线” + IconButton `xmark`（help“知道了”）。
  - 行 `[gauge.with.needle] 实时可用`：状态图形 + “首字 N ms · 共 N ms”（help“一次测量”）；变慢时加 chip `[tortoise 变慢]`；失败时 failed“无响应”“仍有推理 token”“响应不完整”；IconButton `arrow.clockwise`（help“再测一次”）。
  - 行 `[dollarsign.circle] 费用`：“≈ $0.42/小时（估）”。
  - Toggle `[bell] 开始时提醒：文字发给 OpenAI`。
- 慢模型弹窗：“<model> 会明显变慢”，正文“更慢、推理另计费；超时的句子改用 Apple。”，按钮“仍然使用”“取消”。
- 开发构建：`ContentUnavailableView`“此构建不可用”。
- 本页 ⓘ：cloudNotice + key 建议，共 2 个。

**保留可见中文**：我说的话 听到的话 中 EN/DE OpenAI Apple 译文 中文字幕 备用 Apple / DataBoundary：本机 声音 · 声音档案 · 录音 OpenAI 文字 · 上下文 · 术语 未连接 / 无 key → Apple 下次开始生效 / Fast 模式 2× 费用 / API key 同意发送文字 sk-… 保存 已存入钥匙串 · 请清空剪贴板 + 错误短句 OpenAI / 模型 默认 显示固定快照 X 已下线 → Y Y 即将下线 实时可用 首字 N ms · 共 N ms 变慢 费用 ≈ $X/小时（估） 开始时提醒：文字发给 OpenAI / 弹窗。

**删除**：
- “原文 → 译文”；“把识别出来的原文翻译成目标语言。OpenAI 和 Apple 翻译都只处理文字…”；“这里的翻译引擎与 OpenAI 模型选择在下次开始同传或字幕时生效。”
- “两个翻译方向”；可见开关标签“用 OpenAI 翻译我说的话 / 听到的话”（改放 AX）；“中文（可夹英语）→ 英语 / 德语译音”“英语 / 德语 → 中文字幕”。
- “提醒你：对方的话会以文字发给 OpenAI 翻译。”；“关闭某个方向的 OpenAI 后，该方向使用 Apple 本地文本翻译…”；“两个方向都关：全部走 Apple 翻译，不保温，也不连接 OpenAI。”；“没有 key 时，开着的方向也走 Apple 翻译。”
- “OpenAI · 云端文本翻译”；“OpenAI 文本翻译模型”；后缀“（即将下线）（会明显变慢）”；“实时翻译可用性检查”“再测一次”文字按钮、“首个 delta … （参考，一次测量）”；探针长失败句（改放 help）。
- “更多模型选项”及“固定快照用于选择特定版本…”。
- “OpenAI API key”标题；“第一次填 key 前，请确认你同意上面的说明。”；“同意”（改为“同意发送文字”）；“验证 / 删除”文字按钮；“粘贴新的 key 以替换 / 粘贴 OpenAI API key（sk-…）”；“替换并验证 / 保存并验证”；“已保存。请清空剪贴板：通用剪贴板和剪贴板管理器会留副本。”（缩短）；“建议在 OpenAI 网站单独建一个 project…”（改为 ⓘ）；“OpenAI key 页面”。
- cloudNotice 作为可见段落（改为 DataBoundary + ⓘ）。
- “知道了”文字按钮；慢模型弹窗长正文（缩短）。
- TranslationSettingsView 的 4 个带图标节标题。

**实现记录（第 4d 次提交 3def91e，第 7 次 bf2c68f）**

- 开关只拦“关 → 开”：同意并存有 key 之前不能打开 OpenAI，已经打开的随时可以关回 Apple（`TranslationFlowFacts.switchEnabled`）。否则同意后不存 key 的用户无法关掉默认开启的方向。
- 会话中改动的比较基准是会话开始时的偏好，由 App 按 `AppState.meetingStartedAt` 传入 `session`（CloudUI 拿不到 AppState）。会话中换模型同样显示等待“下次开始生效”（`modelWaits`）；不论是否显示，模型 Picker 的 VoiceOver 提示都带这句。
- DataBoundary 的连接判断见 §3.6 实现记录。
- 已有 key 时仍显示粘贴行，用来替换。已存 key 的掩码是固定的 `sk-…•••`，不读取 key 的字符；只有刚粘贴的 key 显示后四位。
- “同意发送文字”旁有 FactChip“按用量计费”（`dollarsign.circle`），让计费作为安全事实可见。
- 删除 key 先弹“删除 key？”确认。设置和引导第 5 步同时打开时，只在点按的那个窗口确认（`TranslationSettingsModel.keyDeletionAskedBy`）。验证和成功删除都会清掉上一次粘贴的问题。
- 模型菜单项的乌龟、时钟图形有 VoiceOver 文字（`choiceSpoken`）。模型行顺序为 Picker → 状态 → 刷新（§3.8）；只有一个状态槽，列表既不在读取也没失败时才显示等待图形。“N 个可选模型”的计数行不显示。
- “开始时提醒：文字发给 OpenAI”在听的方向不用 OpenAI 时禁用，因为它只对这个方向生效。
- 语言 chip 复用场景页的 LanguageChip 及其锁定规则。
- 文本翻译卡的 warn 只在验证失败属于 key 或模型本身（无 key、401／403／404）时点亮，文字与页内 key 行同词（如“key 无效 · 401 · 已启用 OpenAI”）；连不上、429、5xx 只留在页内。会中 OpenAI 因 key 或额度暂停（paused）时，角标为 warn“OpenAI key 或额度异常 · 已用 Apple”。
- 模型行的状态槽（Picker → 状态 → 刷新）也显示被拒候选模型的探针失败，“实时可用”只表示当前所选模型，未测时显示“未检查”；验证被新的列表刷新取代时等待最新结果，无结论则回到空闲。

### 7.10 我的声音 · 语音合成说明（原模型子页）

**Z1** CardRow（选中语音合成）。

**Z2** FlowGrid（单泳道，gutter 胶囊 译音，节点高 60）：`[character.bubble EN/DE 译文]` → `[speaker.wave.2 合成译音]`（TTS 模型缺失时 pending + chevron 到组件·引擎与模型；help 放模型名）→ `[mic.circle TalkTalk Mic]` ›组件·虚拟麦克风 → `[person.wave.2 对方听到译音]`。
- 合成节点的卫星：有档案时为实线链接 `[waveform.and.person.filled 我的声音 ›]`（ok）；没有档案时为虚线 `[speaker.wave.2 系统声音]`（与 §3.3、场景页和我的声音页同形：系统声音是备用路径），同样链接到我的声音以便录制。安全 ⓘ（对方听到什么）：“已有声音档案但克隆引擎暂不可用时，会等待恢复或不发送该段（未发送），不会改用系统声音。”
- FactRow：`[person.2.wave.2 会议·电话生成译音]` `[speaker.slash 视频不生成]`。

**没有 Section**。“Qwen3-TTS / 声音档案”两行已删，节点角标和卫星已表达。

**实现记录（第 4d 次提交 3def91e）**：只有一个卫星，由是否有档案决定画哪一种。系统声音原写实线，与 §3.3 和另外两页冲突，按一义一形改为虚线（上文已改）。安全 ⓘ 挂在 FactRow 末尾（`FactRow(info:)`，§3.9），不挂在卫星上。TalkTalk Mic 节点带驱动角标，所以 `ModelSettingsView` 接收 `driver`。译文节点固定写“EN/DE 译文”，不随“我的译音”变化。

**保留可见中文**：EN/DE 译文 合成译音 TalkTalk Mic 对方听到译音 我的声音 系统声音 / ⓘ 一句 / 会议·电话生成译音 视频不生成。

**删除**：“译文 → 会议里的声音”；“英语／德语译文”；“声音与试听”；“会议同传会生成译音；视频字幕只显示文字。”；节标题“我的声音 / 系统声音”及 InfoButton；“Qwen3-TTS 模型 / <模型名>／未安装”；“声音档案 / 已创建／尚未创建”；“macOS 系统声音 / 无需创建声音档案”；“没有声音档案时，译音使用系统声音。”；“声音档案与恢复说明”折叠及说明。

- 语音合成子页的“译音”泳道标签为译音胶囊，与我的声音页一致。

### 7.11 安装与维护 · 语音资源

**2026-11-07 档位修正（按后续反馈更新）**：本地资源只提供 Max（TTS 1.7B＋ASR 1.7B，5.6 GB）、标准（1.7B＋0.6B，4.1 GB，默认）、轻量（0.6B＋0.6B，3.0 GB）。Apple Speech 移到“识别与翻译”的独立识别选择，两路各自保存；选择 Apple 不下载 Qwen、不换 TTS。旧 compact16 仍可读取和维护，显示“仅语音合成”，不再作为新用户的第四个资源选项。

名称、容量与组成由同一 catalog 给出。档位行下面并排展示识别、合成两张需求卡，复用 FlowNode 的圆角、底色、字号、SF Symbols 和状态徽标，不加顺序箭头。只显示用途、模型规格与大小：就绪为勾号，缺少资源为下载图标；状态含 help 与 VoiceOver，不能只靠颜色。选择档位立即更新卡片，安装仍须另行确认。容量是模型文件量，不是运行内存档。

实际档位按 active roles 判断，旧 Max 的标准组合不下载、不换角色，直接按标准显示；未知组合诚实显示自定义。健康且所选档位等于已安装档位时，不再独占一行重复“已安装”；就绪图保留状态标记。待换档明确实际→目标，不能把选中选项误报成已安装。模型列表尾部重复的“识别与翻译”链接删除。当前模型的红色删除入口在空闲时可用，原生确认说明将影响识别或合成；确认后停止引擎再删除，不自动选另一个已下载模型。会话或试听使用中保留禁用与对应帮助。

**Z1** CardRow：`[cpu 引擎与模型]` `[mic.circle 虚拟麦克风]`；需要安装、更新或修复时显示 warn 或 failed 角标。

**Z2** FlowGrid（单泳道，无 gutter，节点高 82，表示安装生命周期）：
- `[arrow.down.circle 下载]`：下载中附件为进度环 + “x/y GB”。
- `[shippingbox 安装]`
- `[checkmark.shield 校验]`：缺文件或记录损坏时 warn。
- `[cpu 就绪]`：附件 ‹max ▾›（档位 chip）；角标 ok，或 warn“可更新”“需更新运行时”“未完成”。

每个节点 `.anchor` 到下方 Section。安装中，当前节点上放 IconButton `xmark.circle`（help“取消”）。

**Z3**
- Section `[cpu] 引擎`（锚定“就绪”节点）：
  - 行 `[cpu] 档位` Picker（max · 4.9 GB / standard · 4.9 GB / compact-24 · 3.8 GB / compact-16 · 2.8 GB，与节点 chip 同步）+ 按钮 `[arrow.down.circle 下载]` 或“换档”；需要时加 `[wrench.and.screwdriver 修复]`；IconMenuButton `ellipsis.circle`（help“维护引擎”），菜单项 `[checkmark.shield 校验安装]` `[power 重启引擎]` `[doc.text.magnifyingglass 查看日志]` `[trash 卸载引擎…]`。
  - 状态行：已安装 · max / 可更新 / 需更新运行时 / 缺 N 个文件 · X GB / 未完成 / 记录损坏 / 完成 / 未完成：… / 已取消 / 引擎已重启 / waiting 完全卸载中。
  - 进度行：ProgressView + “2/5 · 1.2/4.9 GB”（模型名放 help）。
- Section `[square.stack.3d.up] 模型`：每个模型一行，`[waveform | speaker.wave.2]` 等宽 key + secondary“X GB · rev” + 状态图形 13（ok / warn，help“已安装 / 待校验”）+ IconButton `trash` 或 `arrow.down.circle`（help“删除 / 下载 <key>”）。另有一行链接 `[square.stack.3d.up 模型设置 ›]`，跳到识别与翻译页。
- 弹窗（缩短）：
  - “安装引擎（max）？”“从 Hugging Face 等下载约 X GB（另加运行时），可随时取消。”[下载并安装][取消]
  - “下载模型 k？”“约 X GB。”[下载]
  - “删除模型 k？”“以后要用时需要重新下载。”[删除]
  - “卸载引擎？”“删除运行时和全部模型；我的声音、术语表和设置保留。”[卸载]
- 开发构建：“此构建不可用”。

**保留可见中文**：引擎与模型 虚拟麦克风 / 下载 安装 校验 就绪 max x/y GB / 引擎 档位 换档 修复 校验安装 重启引擎 查看日志 卸载引擎… / 状态短句 / 模型 X GB · rev 模型设置 / 弹窗。

**实现记录（第 4e 次提交 0f655a8）**

- 取消按钮在当前节点和“引擎”进度行都有：引导复用这些行，但没有这张流程图。
- 记录损坏在“校验”节点为 failed（与卡片角标一致，上文写 warn）；未安装为 warn；未完成落在“就绪”。
- 流程图下没有单独的问题行，由分组的状态行承担（同一来源 `EngineComponentsModel.status`／`problem`）。结果行可用 `xmark`“知道了”关闭。
- “修复”重装已记录的档位（help“重新安装 <档位>”）；所选档位与已装不同时另加“换档”（help“安装 <档位>”），不会因需要修复而丢掉换档。
- 页面加载占位为 `StatusGlyph(.busy)`，help 与 VoiceOver 为“正在读取组件”。

**删除**：卡片摘要“语音识别 · 语音合成 / TalkTalk Mic · 连接会议应用”；“本页管理本地安装；模型选择在“模型”中设置。”（改为“模型设置 ›”）；“正在检查组件…”（改为 busy）；页内 headline“引擎与模型”及 `.title2` cpu 头；stateText 长句；“这个构建里没有安装器…”；“准备中 d/c · model · x/y GB”里的模型名；“取消”文字；“完全卸载正在进行：引擎的操作要等它结束。”；“换档并安装 / 下载并安装”“修复安装”“维护引擎”文字；“下载与安装说明”及其说明；“Qwen3-ASR · 把听到的声音转成原文 / Qwen3-TTS · 用你的声音朗读译文”角色行；“已安装／待修复／未安装”文字；“模型、版本与单独下载”；模型行用途说明；“已安装／待校验”文字；“删除 / 下载”文字按钮；安装弹窗长正文（缩短）。

- 换档或首次安装被取消／失败后保留所选档位（pending），换档按钮可重试；无记录的未完成状态点修复不带 `--profile`，安装器按 `install.json.prev` 的组合重装，确认标题为“修复 引擎？”。
- 状态行：结果行的失败短句按操作区分——校验安装为 warn“校验未通过”，安装类为“磁盘空间不足”／“下载失败”／“未完成”，安装器原文在 help；运行中状态行让位给进度行，失败后未完成的状态行让位给结果行；流程图运行时只有当前步骤带角标。
- 自定义组合：除“选择组合以修复引擎”外，增加可更新状态的 warn“选择组合以更新”（同一 help 句式）。

### 7.12 安装与维护 · TalkTalk Mic（TalkTalkDriverSupport）

**Z1** CardRow（选中虚拟麦克风）。

**Z2** FlowGrid（`FlowGrid.driver`，与引导第 3 步共用；单泳道，gutter `person.crop.circle.fill`，节点高 82）：
- `[mic 麦克风]`：附件为两个胶囊 原声 / 译音。
- `[mic.circle TalkTalk Mic]`：角标 ok（help“已安装 0.2.3”）/ pending 未安装 / warn 需重启音频服务、可更新、自检未通过 / failed 有问题。
- `[person.2.wave.2 会议应用]`：附件为最多 3 个真实应用图标（13pt）+ “+N”，名字放 help，AX“使用中：A、B”；没有应用使用时为“—”。

FactRow：`[lock.fill 需管理员授权]` + ⓘ“TalkTalk Mic 仅在 TalkTalk 运行时出现；安装或维护时系统声音会短暂中断。”

**Z3** Section `[mic.circle] 驱动`（锚定 TalkTalk Mic 节点）：
- 状态行：已安装 0.2.3 / 未安装 / 需重启音频服务 / 可更新 0.2.2 → 0.2.3 / 自检未通过 / 有问题：… / 此版本未带驱动（详情放 help）。
- 主按钮，按状态取其一：“安装”/“更新”/“重新安装”（按钮里加 lock.fill 9pt，help“需管理员授权”），或“重启音频服务”。
- 按钮 `[checkmark.shield 自检]`；IconMenuButton（help“维护”），菜单项 `[arrow.clockwise 刷新]` `[arrow.down.circle 重新安装]` `[trash 卸载…]`。
- 进度：校验驱动… / `[lock.fill]` 等待授权… / `[arrow.triangle.2.circlepath]` 音频服务重启中 n/30 / 自检中 ~20 秒。
- 结果：ok 已安装 v / ok 音频服务已重启 / 已取消 / failed 未成功：… / warn 需注销或重启 Mac 后生效 / **risk“已卸载 · 会议改用实体麦（对方听到原声）”**。每条带 IconButton `xmark`（help“知道了”）。
- DisclosureGroup“详情”（数据）：每项一行，状态图形 13 + 检查名：设备属性 / 回环（第 2 声道 → Test Mic）/ 隔离（TalkTalk Mic 全零）/ 防重放；最后一行是状态图形 + 日期。
- 弹窗保持原文：“要输入一次管理员密码，系统音频会重启（声音中断约 1 秒）。”“卸载后，会议 App 会切回实体麦克风。”“要输入一次管理员密码。”
- 引导第 3 步复用同一组行（`DriverComponentRows`，放在无标题 Section 里），没有 header 和 footnote。
- 开发构建：“此构建不可用”。

**保留可见中文**：麦克风 原声 译音 TalkTalk Mic 会议应用 / 需管理员授权 + ⓘ / 驱动 状态短句 安装 更新 重新安装 重启音频服务 自检 刷新 卸载… / 进度、结果短句 / 详情及检查名 / 弹窗原文。

**实现记录（第 4e 次提交 0f655a8，第 5 次 40bb982）**

- 原来的 `DriverComponentSection` 已删除（第 7 次提交）。安装与维护页和引导都把 `DriverComponentRows` 直接放进 Section，生命周期与刷新由 `.driverComponentLifecycle(model)` 挂在容器上。
- “重启音频服务”同样要管理员密码，所以也带锁。
- `DriverComponentModel.users` 为 `[DriverUser]`（名字 + bundle id），会议应用节点画真实图标。被占用而不能安装或卸载时写应用名（“TalkTalk Mic 正被使用（Zoom）”），已知会议应用用 MeetingApp 的名字。
- 自检检查名有长短两种：句子里用短名（“上次自检没通过（回环、隔离）”“跳过：门禁没有跑（…）”），详情行用长名。
- 路径、退出码和设备属性这类诊断原文保留英文，作为数据显示在 help 里。

**删除**：区块 headline“TalkTalk Mic · 虚拟麦克风”（`mic.fill` `.title2`）；“把原声或译音送进会议，请在会议 App 中选择 TalkTalk Mic。”；statusText 长句；“正在使用：A、B”；“正在校验随 App 带的驱动…”；“安装虚拟麦克风 / 更新虚拟麦克风”；“运行自检”；“维护”文字；“刷新状态”“卸载虚拟麦克风…”；结果长句；“好”；“自检详情”；“跳过 / 通过 / 没通过”文字；“上次自检：通过 / 没通过 · 日期”；footnote“TalkTalk Mic 仅在 TalkTalk 运行时出现。安装或维护需要管理员授权…”（改为 chip + ⓘ）；“这个构建没有 bundle id… / 这次运行没有接系统默认输入（冒烟运行）…”（改放 help）。

- 手动自检通过后结果行显示 ok“自检通过”（安装结果仍在时不覆盖）；安装、卸载、重启音频的确认只在发起的窗口（设置或引导第 3 步）弹出。

### 7.13 术语表

改为 `Form(.grouped)`，修正现在 padding 20 与其他页不对齐的问题。

**Z2** PageHero：方块 `character.book.closed`；状态“12 / 30”；状态旁的 FactChip：任一方向用 OpenAI 时为 cloud 语气 `[network 云端翻译时发给 OpenAI]`，否则为 `[lock.shield 仅本机]`；右侧 IconButton `plus`（help“添加术语”）+ 按钮“保存”（`.bordered`，有未保存修改时变 `borderedProminent`）。方块 help“也帮助识别中英混说”。

**Z3** Section（无 header）：
- 首行列头“中文 | EN | DE | 备注”（caption secondary，左边留 22pt 图标列以对齐）。
- 每条一行：4 个 TextField（只有备注有占位“备注”）+ IconButton `minus.circle`（help“删除这条术语”）。缺必填项的输入框加红描边。
- 保存结果显示在 Hero 状态位：ok“已保存” / warn“需中文 + 至少一种译法” / failed“读取失败”或“保存失败”（help 放 error）。

空状态（取代 Section）：`ContentUnavailableView(character.book.closed)`，标题“还没有术语”，描述“产品名 · 人名 · 专业词”，按钮 `[plus 添加]`。

本页没有 ⓘ。

**保留可见中文**：12 / 30 云端翻译时发给 OpenAI 仅本机 保存 / 中文 EN DE 备注 / 已保存 需中文 + 至少一种译法 读取失败 保存失败 / 还没有术语 产品名 · 人名 · 专业词 添加。

**实现记录（第 4b 次提交 f8a6be2）**：头图状态槽同时放计数、仍然成立的上次结果和隐私 chip：改动后不再显示“已保存”，补齐缺项后不再显示警示（`GlossarySettingsModel.currentResult`）。云端 chip 的条件是已同意云端且有方向开启，不检查是否存有 key（key 从不读取）；它读共享的翻译偏好，在识别与翻译页或引导第 5 步改动时立即更新（`GlossarySettingsView(model:translation:)`）。红色描边只在因缺项被拒保存后出现，到下次成功保存或读取时清除。列头对齐输入框边缘。Form 不加 `.settingsRow`（§3.8 实现记录）。

**删除**：“填写中文及至少一种外语译法；保存后，下次翻译请求生效。”；“术语使用说明”及“为产品名、人名和专业词指定译法…”；“添加产品名、人名或专业词，填写中文及至少一种外语译法。”；列名“English / Deutsch”（改为 EN / DE）；占位“中文 / English / Deutsch”；“备注（可选）”；“已保存，下次翻译请求生效。”；“每条填写中文，以及至少一种外语译法。”；“术语表读取失败 / 保存失败”前缀；“启用云端翻译时，术语随文字发送给 OpenAI；关闭时不发送。”（改为条件 chip）。

- 头图状态位在有未保存修改时显示 waiting“未保存”；无修改时“保存”禁用；空列表只保留空状态卡内的“添加”；保存时丢弃全空行。
- 云端 chip 与数据边界同源（`TranslationFlowFacts.cloudConnected`）：“任一方向用 OpenAI 时”改为同一口径——有 key 且当前或本场会话有 OpenAI 方向。

### 7.14 隐私与诊断 · 数据与隐私

**Z1** CardRow：`[hand.raised 数据与隐私]` `[captions.bubble 字幕分析]` `[stethoscope 故障检查]`；字幕分析卡记录中显示 `record.circle` 橙色角标，故障检查卡诊断录音中显示 `record.circle.fill` 红色角标。

**Z1b** RecordingBanner（规则见 §3.14，在三个子页都显示）。

**Z2** 主图 = **DataBoundary**，就是本页唯一的图，不再另画“本机 → 文字 → OpenAI”流程。右栏可点击跳到模型·文本翻译（chevron）。尾部 ⓘ 为 cloudNotice。

**Z3**
- Section `[text.document] 文字记录`：
  - Toggle `[text.document] 保存文字记录`（默认关）+ IconButton `folder`（help“在 Finder 中显示”）+ ⓘ“文件仅当前用户可读，不进入备份。”
  - FactRow `[laptopcomputer 本机]` `[clock 30 天]` `[shippingbox 不进诊断包]`。
- Section `[key] 密钥与日志`（无 header 也可以，按 §2 规则，只有 2 行时省略）：
  - 行 `[key] Key：仅钥匙串`（help“不进日志、不进诊断包”）。
  - 行 `[doc.text] 日志：不含文字和音频`（help“只记 id、长度、耗时和错误码”）。
- Section `[clock.arrow.circlepath] 自动清理` + ⓘ“启动时及之后每小时检查一次。”：
  - 行 `[record.circle] 诊断录音 · 字幕分析`，值“24 小时”。
  - 行 `[text.document] 文字记录`，值“30 天”。
  - 行 `[gauge.with.needle] 延迟事件`，值“20 场 · 14 天 · 200 MB”。
  - 普通 `[trash] 过期数据` 标签、secondary“09:12 · 删除 3”与右侧红字“清理过期数据…”按钮；原生 alert 说明仅按现有期限／数量／容量规则清理，不清空全部数据，取消不做删除。自动定时清理不新增弹窗、不改保留规则。

本页 ⓘ：cloudNotice + 文字记录 + 自动清理，共 3 个，正好是上限。

**保留可见中文**：数据与隐私 字幕分析 故障检查 / 录音中：我 · 译音 · 对方 正在保存字幕文字 本场将录音 下场将录音 / DataBoundary 文字 / 保存文字记录 本机 30 天 不进诊断包 / Key：仅钥匙串 日志：不含文字和音频 / 自动清理 诊断录音 · 字幕分析 24 小时 文字记录 30 天 延迟事件 20 场 · 14 天 · 200 MB 清理过期数据… HH:mm · 删除 N。

**实现记录（第 4e 次提交 0f655a8）**：DataBoundary 右栏用 `link` 链接到识别与翻译 › 文本翻译（§3.6）。保存文字记录开启时 Finder 按钮总是可用，文件夹还不存在时先按 TranscriptWriter 的同样权限建好再显示；关闭且没有文件夹时禁用。

**删除**：卡片摘要“存储与清理 / 检查本次字幕 / 自检与导出”；横幅长句“字幕分析正在准备 / 正在保存本次字幕文字”、“查看字幕分析 / 查看诊断录音”可见按钮、“正在录音：麦克风、合成语音、对方”（改为“我 · 译音 · 对方”）、“已启用本场 / 下场诊断录音”；“声音与文字的去向”；“声音留在本机 / 识别为文字 / 可选云端翻译 / 翻译设置”；“语音识别与合成在本机完成，音频和声音档案不上传…”；“密钥与常规日志”折叠；“OpenAI key 只在登录钥匙串里…”；“常规日志只记 id、长度、耗时和错误码…”；“文字记录”节说明“默认关闭。开启后保存会议原文和译文，仅在本机保留 30 天，不进入诊断包。”；“文字记录的存放方式”折叠及说明；“启动时及之后每小时检查一次，按以上期限自动清理。”（改为 ⓘ）；“上次：HH:mm，删除 N 项”。

### 7.15 隐私与诊断 · 字幕分析

**Z1** CardRow + RecordingBanner。

**Z2** FlowGrid（单泳道，无 gutter，节点高 82）：
- `[ear 收听]`：会话运行中为 live；空闲时为 off，chevron 到使用场景，help“先开始会话”。
- `[record.circle 分析]`：附件按钮“开始分析（含文字）”或“停止”，没有会话时禁用；角标为 pending 未开启 / recording 记录中 / ok 已停止 / warn 达上限 / failed 写入失败（原因放 help）。
- `[doc.text.magnifyingglass 记录]`：附件为 secondary“N 行” + IconButton `doc.on.doc`（help“复制分析文件路径”，路径也在 help 里）+ IconButton `folder`（help“在 Finder 中显示”）；ⓘ“记录原文、译文和各阶段耗时，用于检查漏句与积压；8 MiB 或 1 万行自动停止。”

FactRow：`[text.quote 仅文字]` `[mic.slash 不录音]` `[1.circle 仅本次]` `[laptopcomputer 本机]` `[clock 24 小时]` `[shippingbox 不进诊断包]`，用 ViewThatFits 折成两行。（实现：FactRow 最多 4 个 chip，所以放得下时是一行 HStack，否则是两个各 3 个 chip 的 FactRow，§3.11 实现记录。）

没有 Section。

**保留可见中文**：收听 分析 开始分析（含文字） 停止 记录 N 行 / 仅文字 不录音 仅本次 本机 24 小时 不进诊断包 / ⓘ 一句。

**删除**：“开始收听 / 选择使用场景 / 开启本次分析 / 查看本地记录”（play.rectangle 改为 ear）；“检查本次原文、译文和字幕节奏。只在你开启后记录文字…”；“本次分析”节标题；“收听状态 / 会话进行中／尚未开始收听”；recorder 长状态句；“分析文件包含本次原文和译文，仅保存在这台 Mac；24 小时后清理，不进入诊断包。”；“停止字幕分析”；“开启本次字幕分析（包含文字）”；“请先开始会议同传或视频字幕，再开启本次分析。”；“已接收 N 行”；“复制分析文件路径 / 在 Finder 中显示分析文件”文字；“分析文件位置”折叠及路径；“分析内容与保留方式”折叠及两段说明。

### 7.16 隐私与诊断 · 故障检查

**Z1** CardRow + RecordingBanner。

**Z2** FlowGrid（单泳道，无 gutter，节点高 60；这是 34c0724 前就有的图，现在恢复）：`[checkmark.shield 自检]`（角标 = 上次结果）→ `[list.bullet.rectangle 结果]` → `[square.and.arrow.up 导出]`，各自 `.anchor` 到下方 Section。

**Z3**
- Section `[checkmark.shield] 自检`：
  - 按钮 `[cpu 本地引擎]`：help“会先停止引擎”；会中禁用，help“先结束会话”。
  - 按钮 `[network 云端翻译]` + chip `[dollarsign.circle 计费]`（help“发送少量测试文字，产生费用”）；没有 key 或未同意时禁用，help 说明原因。
  - 运行中按钮内显示 spinner。
  - 结果：汇总 StatusLabel“通过 / 未通过”；每项一行，实心状态图形 + 检查名 + secondary 详情；DisclosureGroup“数值”（数据）。
- Section `[square.and.arrow.up] 导出` + ⓘ“包含日志、延迟事件、版本、install.json 和设备名；发现疑似 key 时停止导出。”：
  - FactChip `[lock.shield 不含 key 与文字]`，help 列出“声音档案、文字记录、字幕分析、诊断录音、术语表、key”。
  - 按钮“导出诊断包…”。
  - 结果：ok“已导出 N 个文件 · 已确认无 key 和文字”（过滤和跳过的数字放 help）/ failed“导出失败”。
- Section `[record.circle] 诊断录音`：
  - Toggle `[mic] 录我这边（麦克风＋译音）` + chip“仅本场”或“仅下一场”。
  - 按钮行 `[person.wave.2] 录对方的声音…` + chip `[checkmark.seal 需全员同意（§201）]`；录音中改为 `[record.circle.fill]`“正在录对方的声音” + 按钮“停止”。
  - 行：IconButton `folder`（help“在 Finder 中显示”）+ 按钮 `[trash 删除本场录音…]`。
  - FactRow `[laptopcomputer 本机]` `[clock 24 小时]` `[shippingbox 不进诊断包]`。
  - ⓘ“录音存在本机 diagnostics 文件夹，只有你能读，不进备份。”
  - failed“诊断录音无法开始：…”。
  - 同意、删除、“会议没有在进行”三种弹窗保持原文。音轨标签改为“我 / 译音 / 对方”。
- DisclosureGroup `[gauge.with.needle] 技术详情`（数据，默认收起；里面每块用 SectionHeader 样式的小标题）：
  - **性能**：表头“p50 | p90”只写一次；行用图标对：`[mic→speaker.wave.2]` 提交 → 首声、`[ear→captions.bubble]` 定稿 → 译文、`[stop.fill→speaker.wave.2]` 结束 → 首声、RTF、欠载；最近各段列表用 mic / ear 图标 + 段 N + ms + RTF；warn“仅末尾”（help 说明）；`[clock]` HH:mm + IconButton `arrow.clockwise`（help“重新读取延迟记录”）；没有数据时“无记录”。指标口径不是安全事实，不用 ⓘ，放在“性能”小标题的 `.help`：“最近 3 场日志末尾；原始时延”。本页 ⓘ 共 3 个（导出、诊断录音、离线命令），正好是上限。
  - **离线命令**：四个按钮 `[doc.on.doc 驱动]` `[doc.on.doc 声音]` `[doc.on.doc 回环]` `[doc.on.doc 直通]`；小标题 ⓘ“先退出 TalkTalk，再在终端执行复制的命令。”；直通 help 为“仅离线独占；会中检查在“组件”页”；复制后 ok“已复制”。
  - **声音档案**（从“我的声音”移来）：“参考音 x.x 秒 · x.x 字/秒”+ 自动检查状态图形 + 缓存状态图形（help 放原文）。

**实现记录（第 4e 次提交 0f655a8）**

- 小标题图标：性能为 `gauge.with.needle`（与技术详情同形），离线命令为 `terminal`，数值为 `number`（§4 实现记录）。
- 本地引擎、云端翻译和导出进行中的转圈放在行尾（`StatusGlyph(.busy)`，带说明对象的 VoiceOver 标签），不在按钮里；性能小标题的转圈占刷新按钮的 22pt 位置。
- 结果节点在有报告之前为 dimmed，help“先运行自检”；结果锚点是自检分组里的汇总行，它没有自己的分组。
- 云端翻译自检在两个方向都不用 OpenAI 时也禁用，help“先开启 OpenAI 翻译”。
- “不含 key 与文字”与“导出诊断包…”在同一行；chip 的 help 保留原来的排除清单，包括 OpenAI key 和请求头。
- “录对方的声音…”没有会议时禁用，§201 全句放在同意 chip 的 help 里，“会议没有在进行”弹窗只在竞态时出现。
- 性能表的数值格 VoiceOver 读“p50 …”“p90 …”，时间行是一个元素“上次读取 <时间>”。

**保留可见中文**：自检 结果 导出 / 本地引擎 云端翻译 计费 通过 未通过 数值 / 不含 key 与文字 导出诊断包… 已导出 N 个文件 · 已确认无 key 和文字 导出失败 / 诊断录音 录我这边（麦克风＋译音） 仅本场 仅下一场 录对方的声音… 需全员同意（§201） 正在录对方的声音 停止 删除本场录音… 本机 24 小时 不进诊断包 / 技术详情 性能 p50 p90 提交 → 首声 定稿 → 译文 结束 → 首声 RTF 欠载 仅末尾 无记录 / 离线命令 驱动 声音 回环 直通 已复制 / 声音档案 参考音 … / 弹窗原文。

**删除**：
- “下面的检查与导出都由你手动开始。打开此页不会启动录音或发送测试请求。”
- 节标题“运行自检 / 检查结果 / 导出诊断包 / 详细性能记录 / 离线音频自检命令 / 按需记录音频”。
- “自检只在点击后运行。引擎自检先停止当前引擎…”（改放 help）；“检查本地引擎 / 检查云端翻译”；“云端自检需已同意云翻译并配置 key，会发送少量合成测试文字并产生 API 费用。”；“正在检查…”。
- “命令已复制。先退出 TalkTalk…”；“自检通过／自检未通过或未完成”；“原始检查数值”；“尚未运行自检。请在上方选择检查项目。／检查完成后，结果会显示在这里。”
- “用于排查运行问题。不含声音档案、文字记录…”（改为 chip + help）；“诊断包包含什么”折叠（改为 ⓘ）；“过滤掉 M 行，跳过 K 个过大的文件”可见部分。
- SPEAK / LISTEN 长标签及重复的 p50 / p90；EVS 行及其说明；“时延是原始记录…”“缺少记录的指标显示 —…”“还没有可显示的延迟记录。”“较大的日志只读取末尾，统计不代表全场。”“上次读取：HH:mm”。
- “先退出 TalkTalk，再在终端执行复制的命令…”；“复制驱动 / 声音 / 回环 / 直通自检命令”；“直通自检仅适用于离线独占…”；“共载自检：已跳过（按你的决定，不做负载测试）。”
- “本场会议正在进行。选择只对这一场有效… / 现在没有会议。…”（改为 chip）；“录麦克风和合成语音（我这边）”；“对方的声音只在会议进行时、你当场确认…（德国《刑法典》§201）。”（改为 chip，全文留在同意弹窗）；“正在录：…”（与横幅重复）；“在 Finder 中显示”文字；“停止并删除本场录音…”；“录音存在本机 diagnostics 文件夹…24 小时后自动删除，不进诊断包。”（改为 chip + ⓘ）；音轨标签“麦克风 / 合成语音 / 对方”。
- 视频字幕没有发言链路，不录、也不清掉“录我这边（麦克风＋译音）”的预约，横幅、chip、菜单在此期间显示“下场将录音／仅下一场”；对方的声音仍可在当场确认后录。
- 单轨写满 512 MiB 后该轨停止、不再显示“录音中”，诊断录音分组显示 warn“达上限”；本场麦克风与译音两轨都封顶，或文件打不开时，本场预约结束，开关回到关闭，错误行在会议结束或关闭开关时清除。
- “录对方的声音？”同意框在未勾选“所有参与者都已同意录音”时“开始录音”不可用。
- 录音横幅的链接“查看诊断录音／查看字幕分析”与菜单一样落到对应分组并闪烁一次（`reveal` + `SettingsAnchor`），不再只是切子页。
- 自检分组的两行为静态行加行尾验证图标按钮（`SettingsIcon.verify`），运行中在同一位置显示忙碌标记；本地引擎的禁用原因按“先结束会话／引擎安装中／自检中／先结束说话测试、录音和试听”区分。
- 离线命令的“已复制”约 3 秒后自动消失，再次复制重新计时。

### 7.17 首次引导（OnboardingFlow / OnboardingPracticeSteps / OnboardingUIComponents / OpenAIOnboardingStep）

沿用同一套组件和尺寸。

- **头部步骤指示**：保持 16pt 图形放在 30pt 圆里（这是引导专用的已有组件，只此一处）。AX 和菜单项共用同一个字符串“第 N 步，共 M 步”。
- **StepTitle**：图标改为 L1 22pt + `title2.bold`。OpenAI 步也改用 StepTitle，不再有私有头部。
- **场景选择**：CardRow(multiSelect)，不显示摘要；可见文字只有“你会用 TalkTalk 做什么？”和“可多选”。
- **第 1 步（权限）**：GrantRow 改用 `.settingsRow`（15/22），只留标题：应用声音 / Apple 语音识别 / 麦克风 / Keycap 右⌥；状态只用图形；说明进 ⓘ，最多 3 个（例如“快捷键只监听、不修改按键”）。失败短句：failed“系统录音被拒绝” + `[arrow.up.forward.app 打开“隐私与安全性”]`；warn“未确认 · 开始时再查”。
- **第 2 步（语言资源）**：语言徽章 48pt 保持，角落加状态角标（11 放在 15 圆底）；按钮 `[arrow.down.circle 下载]`。
- **第 3 步（虚拟麦）**：`FlowGrid.driver` + FactChip `[lock.fill 需管理员授权 · 声音中断约 1 秒]`；其下是安装与维护页同一组 `DriverComponentRows`，放在无标题 Section 里。
- **第 4 步（引擎）**：FlowGrid `[waveform 声音]`（卫星 Qwen3-ASR）→ `[text.bubble 原文]`；`[character.bubble 译文]` → `[waveform.and.person.filled 我的声音]`（卫星 Qwen3-TTS）；FactChip `[laptopcomputer 本机]`；下面是引擎区块。
- **第 5 步（文本翻译）**：DataBoundary + 与模型·文本翻译相同的 API key Section 组件 + FactChip `[laptopcomputer 不配也能用 Apple]`。
- **第 6 步**：嵌入“我的声音”的主图。
- **第 7 步（连接会议）**：StepTrack `[①输入选 TalkTalk Mic]` → `[②打开麦克风测试]` + risk chip `[实体麦克风 → 对方听到原声]` + 结果状态行；下面是 `FlowGrid.meeting`（去掉 chip 的只读版）。
- **第 8 步（试一试）**：
  - 听：FlowGrid `[英语示例]` → `[识别与翻译]` → `[双语字幕]`；按钮“播放示例 / 停止示例”；状态“准备中… / 播放中 · 看字幕面板 / 未收到译文 / 已收到字幕”。
  - 说：FlowGrid `[Keycap 说中文]` → `[翻译与合成]` → `[headphones 耳机听译音]`；按钮 `[mic 试说]`（`mic.fill` 改为 `mic`）；FactChip `[headphones 戴耳机 · 先结束其他麦克风测试]`；状态“不可用 / 准备中… / 就绪 / 已播放译音 / 未完成：<原因>”。
- **完成页**：一张小图“菜单栏图标 → 开始上次场景 / 选其他场景”；三行场景各配一个 chip：`[mic.circle 输入选 TalkTalk Mic]` / `[phone 先准备，再拨号或接听]` / `[mic.slash 不用麦克风]`。
- **页脚按钮**保持：稍后设置 / 继续 / 上一步 / 跳过 / 稍后核验 / 完成 / 关闭 / 打开使用场景。

**删除**：
- “可以多选。只看视频时，引导只准备应用声音、语音识别和语音资源。”（只留“可多选”）
- 权限说明（“收听选中的会议应用或浏览器…”“在本机识别声音，作为 Qwen 的备用。”）
- “只看视频时不需要麦克风和输入监控…”；“只想看视频，或想了解权限用途？”及两段说明
- “这些资源用在哪里？”及说明
- 卡片标题“把你的声音送进会议 / 安装状态 / 安装与管理 / 在会议应用中完成两步 / 当前检查结果 / 会议里的两个方向 / 开会、打电话与看视频”
- “TalkTalk 用实体麦收音；会议应用用 TalkTalk Mic 接收原声或译音。”
- “Qwen3-ASR 识别声音，Qwen3-TTS 合成译音。”；“文本翻译与下载说明”及正文
- “可选的云端翻译服务，也可以稍后设置。”；“未配置 OpenAI key 时，两个方向都使用 Apple 本地文本翻译…”
- “打开会议应用的麦克风测试后，这里会自动更新。”
- “本页汇总示例原文和已收到的中文译文…”
- “点按后说中文，可夹英语；说完再点按右⌥结束发言…”
- “正式会议的发言方式”及说明
- “需要重新检查时，可从 设置 › 通用 重新运行引导。”

**实现记录（第 7 次提交 bf2c68f）**

- 每一步是固定的 StepTitle 加一个 grouped Form，去掉原来外层的 ScrollView，因为 `OpenAIKeySection` 本身是 Form 的 Section。场景选择页仍是带内边距的 VStack。
- 第 1 步：“打开‘隐私与安全性’”只出现在被拒的行上（应用声音另在“检查”旁）。全步只有右⌥ 行一个 ⓘ，用途说明进各行 help；探针进行中在应用声音行尾显示 `StatusGlyph(.busy)`。右⌥ 行的标题是键帽图（§3.16 实现记录），悬停显示输入监控的说明。
- 第 2 步：各语言的失败合并为一行“下载失败”（全部原因在 help），语言代码也在 help。
- 第 3 步：FactChip 为 warn 语气（原来的提醒是橙色）；引导里的驱动图不带 TalkTalk Mic 链接。
- 第 4 步：用私有的 `FlowGrid.localEngine` 画本节写的两条泳道，不用安装与维护页的安装生命周期图 `FlowGrid.engine`；模型未安装的角标在带卫星的“声音”“我的声音”节点上。其下是安装与维护页的 `EngineControlRows`、`EngineModelRows` 两个分组（原 `EngineComponentsRows` 封装已删除）。
- 第 5 步：`OpenAIOnboardingStep(model:)` 加 `static canContinue(_:)`，按钮移到窗口页脚；key 分组是 `OpenAIKeySection(model:, host: .onboarding)`，与识别与翻译 › 文本翻译同一组件；设置与引导同时打开时，删除 key 只在点按的那个窗口确认（§7.9 实现记录）。
- 第 6 步：嵌入整个我的声音页（概览与录制），不只是主图，这样自动开始录制和录制流程只有一个容器。
- 第 7 步：顺序为 StepTrack → 检查状态行 → 风险 chip（§2 的页面顺序：图、问题、事实）。只读会议流程图只在安装与维护页模型可用时显示。① 的 needsAction 描边只用于 nobodyReads（§7.1 实现记录）。
- 第 8 步：收听空闲时不显示状态，可用的“播放示例”已说明；“试说／停止”合成一个开关按钮。
- 完成页：“需要重新检查时…”的说明改为“关闭”的 help。
- 只选电话或“电话＋视频”时走 7 步，不含第 7 步“确认会议麦克风”（电话麦克风跟随系统默认输入）；含会议则 8 步，只选视频仍为 3 步。重跑引导（restart）后在场景选择页退出，重开仍回到场景选择页。
- 第 5、7 步页脚：“继续”在检查通过（key 验证／会议麦克风变绿）后才可用并成为默认键；第 7 步“稍后核验”仅在未通过时显示，第 5 步“稍后设置”始终显示，先刷新再前进，key 已存在时不记为已略过；窗口回到前台（成为 key window）时引导刷新一次状态。
- 第 1 步和场景页的“稍后设置”是关窗，悬停提示为“关闭引导，可从菜单“视频字幕…”开始”；第 5 步的“稍后设置”是前进。第 8 步示例节点 help 为“示例仅用 Apple 翻译”。

---

## 8. 菜单栏菜单（StatusItemController.swift）

### 8.1 通用规则

- **没有“更多”子菜单**，也没有 340pt 的说明子菜单（detailItem）。只保留两个语言子菜单。
- 问题行的写法：一行不可点的着色状态行，紧跟一行缩进 1 级（`indentationLevel = 1`）的操作项。完整说明放在状态行的 `toolTip`。
- 所有可操作项都配 13pt 模板图（`NSFont.menuFont(ofSize: 0).pointSize`，现状正确，不改）。状态行着色。应用信息行使用与其它菜单项相同的 13pt 模板 SF Symbol `bubble.left.and.bubble.right`，软件名与 `AppVersion.current.displayString` 合为单行标题，无副标题；点击仍打开标准 About 面板。“退出”不配图（§0.2 #13）。现在缺图的项要补上：切回 TalkTalk Mic 用 `mic.circle`，收听所有应用用 `ear`，会中标题用场景图标，phoneStatus 用送达图形。
- 问题行点击后进入设置的精确 Section，并闪烁（复用 §6.3 的锚点）。

### 8.2 状态 A：引导未完成（放在所有其他状态之前）

```
[arrow.clockwise.circle] **继续使用引导 · 第 3 步，共 8 步**      ← 粗体；打开引导到该步
─────────
（下接 B / C / D 的其余内容）
```

- N 和 M 来自 `OnboardingState.progress`（规格原写 `position`；`position(of:)` 只给某一步的序号，N 与 M 一起由 `progress` 给出），与引导头部的 AX 和 通用 › 使用引导… 的行尾共用同一个字符串。
- 这一项吞掉原来的“Apple 资源待配置 › 打开使用引导…”和状态行“语音组件尚未就绪”。
- 场景的“开始”项在所需组件就绪前禁用，`toolTip`“完成引导后可用”。
- 首次启动自动打开引导（已实现，保持）。
- 引导完成后，入口只在 设置 › 通用 › 使用引导…。“引导未完成”只指从未完成过引导；已完成者通过 通用 › 使用引导… 重跑期间，菜单快速开始与启动／Dock 打开行为不变，进度只在 通用 行尾显示。
- 菜单快速开始与场景页底栏“开始／准备”共用同一个可用条件（引导已完成，且没有自检、说话测试、引擎安装或维护在进行）；禁用时两处 tooltip 都写原因：引导未完成为“完成引导后可用”，其余为“请先结束正在运行的自检或说话测试，或等待语音资源维护完成。”

### 8.3 状态 B：空闲

```
[play.fill] **开始会议同传 · Zoom**            subtitle: 英语 → 中文     （电话：准备电话同传；视频：开始视频字幕 · Chrome；自动来源：· 自动）
[person.2.wave.2] 会议同传…
[phone] 电话同传…
[play.rectangle] 视频字幕…
─────────
（问题块，仅当有问题时，见 D）
[captions.bubble] 字幕：英语 → 中文 ›        （英语 / 德语）
[person.crop.circle.fill] 我说话：中文 → 英语 ›（英语 / 德语）
[captions.bubble] 显示字幕 ✓
[headphones] 耳机译音 ✓
─────────
[gearshape] 设置…   ⌘,
关于 TalkTalk
退出 TalkTalk   ⌘Q
```

- 需要选来源时打开对应场景页：场景页显示 pending 问题行“选择要收听的应用”，空闲菜单显示“确认应用…”，选定来源或下次开始时消失；用户在权限弹窗里选了“打开系统设置”时不再打开场景页。

### 8.4 状态 C：运行中（以会议为例）

```
[person.2.wave.2] 会议同传 · Zoom · 12:03      ← 禁用标题行
[发声字形，语音色] 原声 · 对方可听到             ← 与标题栏胶囊同字形、同颜色、同短词
（问题块 D，按严重度排序，若有）
[stop.circle] 结束会议同传
[macwindow] 恢复字幕窗口                        ← 仅字幕窗口收起时
─────────
[rectangle.3.group] 查看当前场景…
字幕 / 我说话 语言子菜单
[captions.bubble] 显示字幕  ·  [headphones] 耳机译音  ·  [megaphone] 播放告知语（会议 / 电话）
[lock.fill] 锁定字幕位置（仅视频；toolTip：鼠标穿透）
[network] 字幕翻译：OpenAI                      ← 禁用信息行，仅在有方向用 OpenAI 时出现（文字发往云端）
[ear] 收听所有应用（备用）                       ← 仅 allowsGlobalFallback；已在用时为“收听：所有应用（备用）✓”
─────────
设置… / 关于 TalkTalk / 退出 TalkTalk
```

- **电话的差异**：发声行之后插入 phoneStatus 行：`[phone.arrow.up.right]` 已送入 Phone，或 `[laptopcomputer]` 仅本机 · Phone 未接收。另加 `[arrow.up.forward.app] 打开 Phone`。结束项为“结束电话同传”，`toolTip`“通话不会挂断”。删除“电话同传设置…”，它与“查看当前场景…”重复。
- **准备 / 结束中**：禁用的 `[hourglass]`“正在准备会议同传…”或“正在结束会议同传…”，取代开始或结束项。其余同 B 或 C。
- “结束<场景>”只在会话运行中才结束（与标题栏同一段判断）；菜单打开期间会话阶段变化（开始、运行、结束中、空闲）时菜单当场重建。会中“退出 TalkTalk”行的 tooltip 写结束后果；退出会先调用 `MeetingSession.stop(.user)` 再关闭 SPEAK 和引擎。

### 8.5 状态 D：有问题（插在标题行之后、“结束”或“开始”之前，最严重的在上）

| 状态行（着色） | ⤷ 缩进操作 |
|---|---|
| [risk 红] 对方能听到原声 | [mic.circle] 检查麦克风… |
| [exclamationmark.circle 橙] 会议尚未使用 TalkTalk Mic | [mic.circle] 检查麦克风… |
| [mic.circle 橙] <systemInputNotice 短句> | [mic.circle] 切回 TalkTalk Mic ／ [arrow.uturn.backward.circle] 还原默认输入 ／ [mic.and.signal.meter] 查看音频设置… |
| [arrow.uturn.backward.circle] 恢复输入记录（subtitle） | 开始会议同传 |
| [exclamationmark.triangle 橙] 识别：Apple 备用 | [square.stack.3d.up] 识别与翻译… |
| [exclamationmark.triangle 橙] 字幕翻译：Apple 备用 | [square.stack.3d.up] 识别与翻译… |
| [captions.bubble] <会议似乎已结束提示> | [ear] 继续收听 |
| [questionmark.bubble] 确认应用… | （点击即选择） |

- 有问题时，菜单栏图标显示该问题自己的形状（`MenuBarIcon`，原声风险为红色合成字形），不统一换成 `exclamationmark.bubble`（2026-11-07 用户确认，见 §8.7）。
- 状态栏 `toolTip` 和菜单中的短状态词：组件未就绪 / 准备中 / 识别/播放译音 / 音频未就绪 / 使用备用 / 检查音频设备 / 原声中 / 对方能听到原声。
- “权限设置…”（字幕窗口详情与菜单）：系统录音未确认时，引导未完成且停在权限步骤时打开引导，否则直接打开系统设置的“录屏与系统录音”面板；说话链路未能启动、按键监听或音频尚未就绪（输入监控）时打开“输入监控”面板；字幕窗口详情里的“音频设置…”与菜单一样落到 音频 › TalkTalk Mic 分组并闪烁。
- 会议或电话场次中 TalkTalk Mic 驱动未加载时，会议检查行和系统输入行的修复项是“安装与维护…”（安装与维护 › TalkTalk Mic），不再是“检查麦克风…”“查看音频设置…”。
- 收听提示行：行标题用标题栏芯片的短词（会议“会议似乎已结束”、电话“长时间无通话音频”、视频“长时间没有声音”等），tooltip 用芯片 detail；会议与电话的 `.meetingSeemsOver` 详情与视频一致，写明即将自动结束，以及要继续请在菜单栏选“继续收听”。“没能确认系统录音权限”这一行带缩进修复项“权限设置…”（打开使用引导）。
- 问题行另有：“字幕已隐藏”（视频字幕会中且字幕关闭，warn，修复项“显示字幕”），以及空闲时中性色的“<场景>已自动结束”（10 分钟无音频或解锁、唤醒时应用无音频，修复项打开该场景页，下次开始时清除）。
- 图标：会话准备中和结束中（`meetingStarting`／`meetingStopping`）为 `hourglass`（`.warming`），不再只限 SPEAK 预热；识别 Apple 备用、字幕识别出错、空闲时上次因错误结束，图标都是 `.degraded` 三角，后两者的 tooltip 用该菜单行自己的词（“字幕识别出错”“<场景>因错误已结束”），不用“使用备用”。

### 8.6 从菜单删除

- “更多 ›”整组（我的声音… / 使用引导… / 通知设置…）、“隐私与诊断…”。删除“隐私与诊断…”和“我的声音…”**需要用户确认**，见 §9.6。
- “电话同传设置…”。
- 正常状态下的“语音识别 / <asr 详情> / 识别与模型设置…”。
- 只用 Apple 时的“字幕翻译：Apple”。
- 两个“…与模型设置…”合并为一个修复项，现名“识别与翻译…”（与侧栏页名一致）。
- 绿色的“会议麦克风：TalkTalk Mic”行（没有新信息）。
- 我说话语言的 toolTip“中文可夹英语，译音统一为所选语言”。
- 文案改短：“在耳机中听到译音”→“耳机译音”；“现在播放告知语”→“播放告知语”；“打开 Phone 拨号或接听”→“打开 Phone”；“现在还原默认输入”→“还原默认输入”；“继续收听，不自动停止”→“继续收听”；“上次：<场景> · 英语 → 中文”→ subtitle“英语 → 中文”。
- 字幕翻译 Apple 备用行的 tooltip 按原因只给一句（key 或额度、超时、离线、暂不可用）；系统输入行的 tooltip 不带 ⚠︎／⛔︎。
- 系统默认输入被改为“系统麦克风已改变”，切回失败为“未能切回 TalkTalk Mic”，字幕条芯片与菜单用同一词。

### 8.7 实现裁决（第 6 次提交）

- 行由 `StatusMenu.rows`（TalkTalkSession）给出，有单元测试；菜单的会议检查与场景页、音频页同读 `ScenarioFacts.sessionCheck`。
- **已确认**（2026-11-07 用户选择“保留各问题的图标”）：图标保留各问题自己的形状（`MenuBarIcon`，含红色风险字形），不统一换成 `exclamationmark.bubble`；§8.5 已随之改写。
- 图标的其余原因（外放、播放设备未确认、我说话翻译备用、系统声音、空闲时有应用读 TalkTalk Mic）各占一行并带修复项；仍无行能说明图标时，问题区显示同一短词，tooltip 为一句说明，音频类下接“检查麦克风…”。
- 空闲时问题区放在场景项之后、语言之前（与 §8.3 示意一致）；会中放在标题、发声与 Phone 行之后。
- 标题行不加粗。发声行是风险胶囊时由“对方能听到原声”行代替，不重复。风险行用固定短句，检查说明放在 tooltip。
- 收听提示沿用标题栏芯片的字形和颜色；“保持”类提示不占行，待确认类为灰色。
- 状态 A 中，开始与“开始会议同传（恢复输入记录）”都禁用；“Apple 资源待配置”在引导完成后指向“通用设置…”，落到 通用 › 使用引导… 并闪烁，该行与头图同显“Apple 资源待配置”（§9.6 #3：引导完成后菜单不再列“使用引导…”）；另加“组件未就绪”→“安装与维护…”。
- 修复项用不带 ReturnPill 的直达（`SettingsNavigation.reveal`）加分组锚点：音频 #TalkTalk Mic／#耳机、识别与翻译 › 语音识别／文本翻译的主图、安装与维护 › 引擎与模型 #引擎、通用 #使用引导、故障检查 #诊断录音、字幕分析的主图；各页用同一个 `settingsAnchorTarget` 滚动并闪烁，目标页已打开时同样生效。
- 云端信息行覆盖两个方向：“字幕翻译：OpenAI”“我说话翻译：OpenAI”“翻译：OpenAI”；字幕翻译转 Apple 备用但本场仍把句子交给 OpenAI 时照常显示，离线或已暂停时不显示。
- 识别未能恢复或切换失败时为橙色“字幕识别出错”（与图标的 `.degraded` 同色）（原因在 tooltip）→“识别与翻译…”；只有正常状态的“语音识别”行删除（§8.6）。
- 录音事实（§5.4）在问题之前，与录音横幅同词：“录音中：…”“本场将录音／下场将录音”→“查看诊断录音…”，“正在保存字幕文字”→“查看字幕分析…”。
- 状态 A 的行为粗体“继续使用引导 · 第 N 步，共 M 步”（`arrow.clockwise.circle`），数字取 `OnboardingState.progress`（§8.2）。
- 第 8 次提交复核时的图标偏离，已由 2026-11-07 用户确认保留各问题的形状，代码与 ARCHITECTURE 不变。
- “组件未就绪”在引擎维护期间不出现，引导路径不含引擎步骤（只选视频）时也不出现；引擎装好或卸掉后图标立即刷新。
- 兜底短词行在 `.warming` 时也带一句 help“正在准备音频”。
- Apple 资源检查在启动、引导下载或完成、开始时下载语音资源成功、应用回到前台、切换界面语言时都会重跑，菜单与通用页同时更新。

---

## 9. 实施顺序

### 9.0 前提

- 之前并行的工作流已在 e36b0b3 落地，本计划直接在 main 上接着提交。保留 `ScenarioCardHeader` 的选择语义（`requestedScenario` 由使用场景和字幕共用），以及 95cdf11 的系统外观背景。
- 只用 `scripts/build-app.sh release` 构建、安装、启动，不打包 DEV 应用。需要权限的流程用 `open -a` 启动。
- 每次提交至少跑一次聚焦检查；页面类提交跑 `scripts/check.sh --skip-stress`。改了 `Localizable.xcstrings` 时跑 `scripts/check-strings.sh`。**不跑负载或浸泡测试。**
- 界面验收：每次页面提交后，在 release 应用中按 深色 / 浅色 × 880×640 / 820×600（最小）逐页截图。同时开 VoiceOver 抽查读序，用“减少动态效果”“降低透明度”“增强对比度”各检查一次。

### 9.1 提交序列

| # | 提交 | 改哪些文件 | 依赖 | 验收点 | 状态 |
|---|---|---|---|---|---|
| 1 | **共享 target + 令牌 + 状态词汇** | `Package.swift`（新增 `TalkTalkSettingsUI`；App、CloudUI、DriverSupport、Voice 依赖它）；新目录 `Sources/TalkTalkSettingsUI/`（迁入 VoiceCapsule、Keycap、InfoButton、SettingsStatus、风险字形绘制，并新增 StatusGlyph、StatusLabel、IconButton、IconMenuButton、FactChip、FactRow、SectionHeader、SettingsRowLabelStyle）；`SubtitleTokens.swift`（`SettingsIcon.Page.*`、§4 一义一形的令牌、Size 常量）；`SettingsFlowComponents.swift`（改为 import 新 target）；新测试 `TalkTalkCoreTests/SettingsSymbolTests.swift`（遍历 SettingsIcon、MenuIcon、VoiceIcon、SceneIcon 令牌，`NSImage(systemSymbolName:)` 非 nil；豁免 `VoiceIcon.originalRisk`，断言它的回退合成存在） | 无 | 构建通过；`check.sh --skip-stress`；侧栏图标更新；状态图形全窗口统一为 13pt；InfoButton 为 13pt，22×22 | 已完成 `7077444` |
| 2 | **导航统一** | 新增 `SettingsCard`/`CardRow`（SettingsUI）；`SettingsTabButton.swift` 删除或改为薄封装；`ModelSettingsView.swift`（删 `SettingsSubpagePicker`）、`ComponentsSettings.swift`、`DiagnosticsView.swift`、`ScenarioSettingsView.swift`（ScenarioCardHeader 改走 CardRow）、`SubtitleSettingsView.swift`（加 GlobalRow 和 VoiceOver KVO 模型）；`SettingsWindowController.swift`（Z0 ReturnPill 槽、Z1 导航带槽、`returnTarget` 扩展、`FlowInteraction`） | 1 | 五个页面都有卡片行，固定、不收起、不随滚动；识别与翻译页卡间有箭头；角标显示正确；字幕页 GlobalRow 在卡片上方；VoiceOver 关闭时不显示朗读开关；ReturnPill 返回时恢复子页和滚动位置 | 已完成 `a0b370b` |
| 3 | **流程组件 + 场景三页** | SettingsUI 新增 `FlowGrid`/`FlowNode`/`NodeChip`/`FlowSatellite`/`LoopRow`/`StepTrack`；`ScenarioSettingsView.swift`、`PhoneSettingsView.swift`（FlowGrid.meeting/phone/video 工厂、ScenarioBottomBar 改写、删除 runningBanner 与描述）；`SettingsFlowComponents.swift`（SpeechFlow/SpeakingLanes 先原样保留，不改成薄封装：引导、音频、我的声音、模型、诊断各在 4c/4d/4e/7 迁到 FlowGrid，第 5 次提交删除它们） | 2 | 820 宽下节点不截断安全词；滚动和切卡不卡死（8c87ba7 回归）；chip 和开关可点，chevron 不误触；VoiceOver 读序为节点 → 控件 → 链接；会议检查 notChecked / green / physicalMic / nobodyReads 四种状态下，节点、问题行、菜单三处一致；电话“首次连接”在从未准备成功前自动展开 | 已完成 `7ab201a`，协调修正 `582176e` |
| 4a | **字幕页** | `SubtitleSettingsView.swift`、`SubtitleLayoutPreview.swift`（热点）、新增 `ThumbnailChoice` | 3（并行于 4b–4d） | 深色黑、浅色白；没有背景选择器；热点有 help 和 AX；视频的样式和排列为缩略图 | 已完成 `6cd04df` |
| 4b | **通用 + 术语表** | `GeneralSettings.swift`（PageHero、删除发言方式节，**先获用户确认**）、`GlossarySettings.swift`（改为 Form）；新增 `PageHero` | 1–2 | 每页 ⓘ 不超过上限；术语表边距与其他页一致 | 已完成 `f8a6be2` |
| 4c | **音频 + 我的声音** | `AudioSettings.swift`（FlowGrid.audio，节点 anchor 复用现有 scrollTo）、`MyVoiceSettings.swift`、`Sources/TalkTalkVoice/EnrollmentView.swift`（StepTrack） | 3 | anchor 滚动和闪烁正常，减少动态效果下不闪；档案详情已移走（与 4e 协调） | 已完成 `0b878a1` |
| 4d | **模型三子页** | `ModelSettingsView.swift`、`Sources/TalkTalkCloudUI/TranslationSettingsView.swift`（+ `TranslationSettingsText.swift`）；新增 `DataBoundary` | 3 | OpenAI 开关在同意和 key 之前禁用；同意按钮文字为“同意发送文字”；DataBoundary 在未连接状态灰显 | 已完成 `3def91e` |
| 4e | **组件 + 隐私与诊断** | `EngineComponentsRows.swift`、`DriverComponentPage.swift`、`Sources/TalkTalkDriverSupport/DriverComponentView.swift`、`PrivacySettings.swift`、`DiagnosticsView.swift`（RecordingBanner、技术详情 › 声音档案） | 3、4d（DataBoundary） | 录音横幅在三个子页都显示，卡片角标正确；risk“已卸载 · 会议改用实体麦（对方听到原声）”出现 | 已完成 `0f655a8` |
| 5 | **清理** | 删除 `SettingsNote`、`SpeechFlow`、`SpeakingLanes`、`FlowNodeCard`、`FlowLink`、`SettingsStatus.info`、OpenAI 步 `pathStep`；清理孤立的 `Localizable.xcstrings` 键 | 4a–4e | 编译通过即证明没有灰段落；`check-strings.sh` 通过；grep 检查 `.font(.system(size:` 取值只在 {22, 18, 15, 13, 11, 9} 内 | 已完成 `40bb982`（旧组件已随 `bf2c68f` 删除，本次做清理扫描与大字号回退；`SettingsStatus.info` 在 `7077444` 删除） |
| 6 | **菜单** | `StatusItemController.swift`（及其菜单模型和测试） | 2（深链锚点） | A/B/C/D 四态截图；没有“更多”；引导项为粗体且排第一；问题行深链能落到正确 Section | 已完成 `14b8145` |
| 7 | **引导** | `OnboardingFlow.swift`、`OnboardingPracticeSteps.swift`、`OnboardingUIComponents.swift`、`Sources/TalkTalkCloudUI/OpenAIOnboardingStep.swift` | 3、4d、4e | 第 3 步与安装与维护页是同一张图；第 5 步与文本翻译用同一个 DataBoundary 和 key 组件；“第 N 步，共 M 步”与菜单同源 | 已完成 `bf2c68f`（在第 5 次之前落地） |
| 8 | **文档** | `docs/ARCHITECTURE.md`（设置视觉系统、TalkTalkSettingsUI、场景卡语义、VoiceOver 开关显示规则、菜单四态）；`docs/decisions/2026-11-06-subtitle-ui-redesign.md` 新增 §9.4“图示优先设置系统”，并在 §9.1 注明“HIG pass 去图标部分被本节推翻”；`docs/remaining-work.md:29` 补“卡片导航覆盖全部子页” | 全部 | 文档与行为一致 | 已完成（本提交；新节编号为 §9.3，因为该文档只有 §9.1、§9.2） |

### 9.2 可以并行的部分

- 1 → 2 → 3 必须串行：它们是共享地基。
- 4a、4b、4c、4d 文件互不重叠，可以在独立 worktree 并行。4e 依赖 4d 的 DataBoundary，可以先做组件部分。
- 6（菜单）在 2 之后就能与 3、4 并行。
- 7 要等 3、4d、4e。
- 5 和 8 放在最后。

### 9.3 风险与缓解

1. **宽度。** 最小窗口下每列约 113pt。“Microsoft Teams”这类长名会截断为“图标 + 截断名”，全名放 help。节点标题允许缩放到 0.85，但永不换行，永不截断安全词。大字号（环境值 `dynamicTypeSize ≥ .xxLarge`；macOS 用户改不了它，所以 Mac 上平时不出现）下 gutter 收进首节点，胶囊永不被挤掉（§3.3）。必须在 820 宽下截图验收。
2. **布局循环。** Grid、固定高度和常量列都不做几何回传；卡片行、横幅、底栏放在 Form 滚动区外；TimelineView 只包住计时 Text。每次页面提交后，在 release 应用里反复滚动、切卡、切子页。
3. **嵌套点击和 AX。** 严格执行 §3.3 的命中规则：有控件的节点只有 chevron 是链接。逐节点用 VoiceOver 验证。
4. **可发现性。** 只有非安全信息才降级为 help。安全信息保留可见 chip，AX 写完整句。缩略图保留名称。建议请用户做一次“只看图能不能说出对方此刻听到什么”的实测。
5. **安全回退。** “在会议应用选 TalkTalk Mic”的可见句被删后，这条信息由三处承载：risk 节点（红描边 + 风险字形 + 红字）、问题行、音频页的状态行。验收时按 §9.1 第 3 条的四种会议检查状态逐一核对。
6. **跨模块迁移。** 把 VoiceCapsule、Keycap 迁进 SettingsUI 会牵动字幕窗口的令牌，只移动、不改样式。迁完后跑 `TalkTalkCoreTests` 里的令牌断言，例如 `VideoWindowChromeTests`、`SubtitleWindowPresenceTests`。
7. **VoiceOver KVO。** 回调不在主线程，要先切到 MainActor 再写 @Observable 模型。VoiceOver 关闭只隐藏行，不清偏好。实现前再查一次 Apple 文档，确认 `isVoiceOverEnabled` 支持 KVO；仓库内 SubtitlePanel.swift:304 已经在用，可以作为第二个来源。
8. **字符串大量删改。** 涉及 `Localizable.xcstrings` 的大量删除，需要在另一个工作流落地后再动手，避免冲突。
9. **验收边界。** 以上检查只覆盖构建和界面。会议检查、Phone 接收状态、驱动安装的真实行为，要由用户自行安排麦克风、Phone 和会议环境验收。驱动安装和音频服务重启需要先与用户约定。

### 9.4 每次提交的通用验收清单

- [ ] 页面上没有常显的灰段落、footer 或说明折叠。
- [ ] 每页 ⓘ ≤3、每个 Section ≤1。
- [ ] 行首图标都在 22pt 列，大小为 15pt。
- [ ] 状态图形 13，角标 11。
- [ ] §5.4 的安全事实都可见（图标 + 短文字）。
- [ ] 每个纯图标控件都有 `.help` 和 `accessibilityLabel`。
- [ ] AX 信息量 ≥ 被删掉的可见文字。
- [ ] 深色和浅色、880 和 820 两种宽度截图无截断、无重叠。
- [ ] `scripts/check.sh --skip-stress` 的输出贴进提交说明或回报。

### 9.5 文档同步要点（第 8 次提交已同步到 ARCHITECTURE）

- 设置“文字预算”规则（§5）。
- 子页导航统一为图标卡片（§6）。
- 尺寸梯子 22/18/15/13/11（§4）。
- `SettingsStatus.info` 删除。
- 新 target `TalkTalkSettingsUI`。
- 字幕页卡片只编辑设置，不启动会话。
- VoiceOver 朗读开关的显示规则。
- 菜单四态、删除“更多”。
- 另同步：`SettingsStatus.info` 在第 1 次提交删除；`IconMenuButton` 是 AppKit `NSPopUpButton` 下拉（SwiftUI `Menu` 在 macOS 上实测只画约 21×15，§3.10）；`SettingsNote` 删除；`共享屏幕不可见` 的 help 按 `NSWindow.SharingType.none` 的文档缩短；菜单栏图标保留各问题的形状（待用户确认，§8.7）。

### 9.6 动手前需要用户确认的行为删除（2026-11-06 已全部确认）

1. 删除使用场景页的**运行横幅**。之后由运行中场景卡的绿点和计时，加底栏左侧的“● 场景 · 来源 · 12:03”承担。
2. 删除通用页的**“会议与电话发言方式”整节**。场景页的泳道和回环已经完整表达同样内容。
3. 菜单删除 **“隐私与诊断…”和“我的声音…”**，改为经“设置…”进入；引导完成后，“使用引导…”只保留在 设置 › 通用。
4. 电话清单 ① 不再单独放“准备”按钮，只用底栏的“准备”。
5. “我的声音”的档案详情移到 故障检查 › 技术详情。
6. **术语表**继续保留手动“保存”按钮；是否改为自动保存另行讨论，本规格不改。

落实位置：#1 第 3 次提交（7ab201a）；#2 第 4b 次（f8a6be2）；#3 第 6 次（14b8145）；#4 第 3 次；#5 第 4c、4e 次（0b878a1、0f655a8）；#6 第 4b 次保持手动保存。
