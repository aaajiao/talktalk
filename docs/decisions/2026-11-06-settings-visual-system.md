# TalkTalk 设置：图示优先的视觉系统（定稿规格）

> 状态：2026-11-06 用户审阅示意页后批准（“全部同意，开始”），§9.6 六项删除同时确认；按 §9.1 实施。基线是 HEAD e36b0b3（含 95cdf11：共享固定场景头、字幕预览背景跟随系统外观；4849095：一步退出）。
> 来源：三份候选设计和两位评审。评审 1 选“图示优先（Diagram-First）”，评审 2 选“图即界面（Diagram-as-Interface）”。本规格的取舍是：以 Diagram-First 的页面骨架、命中规则和 Grid 实现为底；场景页采用 Diagram-as-Interface 的“图即控件”写法；共享 target 和“无角标即就绪”两条规则取自 State Board。两位评审意见冲突的地方，统一在 §0.2 裁决。
> 已核实的事实：
> - 设置窗口可调整大小，内容区默认 880×640，最小 820×600（`SettingsWindowController.swift:189-208`）。所以内容列默认约 690pt，最小约 630pt。
> - `TranslationSettingsView` 位于 TalkTalkCloudUI，`DriverComponentView` 位于 TalkTalkDriverSupport，`EnrollmentView` 位于 TalkTalkVoice。三者都不能 import TalkTalkApp。
> - `ScrollViewReader.scrollTo` 已在 `AudioSettings.swift:177-212` 中可用。
> - `SubtitlePanel.swift:304` 已用 KVO 观察 `isVoiceOverEnabled`。
> - 本机用 `NSImage(systemSymbolName:)` 检查了本文用到的 88 个符号，只有 `mic.badge.exclamationmark` 返回 nil。它是合成字形，已有回退方案（`SubtitleTokens.swift:186`）。

---

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
| 13 | 菜单中“关于”是否配 info.circle | **“关于 TalkTalk”和“退出”都不配图** | 一义一形：info.circle 只表示“打开说明” |
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

### 3.1 SettingsCard + CardRow

取代 `SettingsTabButton`、`SettingsSubpagePicker`（ModelSettingsView.swift:122-152）以及 `ScenarioCardHeader` 的内部实现。

- **作用**：全窗口唯一的子页和场景导航，用于使用场景、字幕（同一组场景卡）、模型（卡间有箭头）、组件、隐私与诊断，以及引导的场景多选。
- **尺寸**
  - 卡高固定 64，行内等宽，间距 12。
  - 模型页卡间插 FlowArrow（`arrow.right` 11pt semibold tertiary），间距加宽到 24。
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
  - 内容列在最小宽 630 下仍能放下（4×113）。如果用户把系统字号调到最大导致放不下，用 `ViewThatFits` 退化：gutter 收进节点的附件槽，宽度降为 0。
  - 模型定义：`FlowNodeModel { id, glyph: .symbol(String) | .appIcon(bundleID) | .step(n, StepState), title, state: NodeState, badge: SettingsStatus?, target: NodeTarget?, accessory: NodeAccessory?, satellite: FlowSatellite?, help, axValue }`。
  - 悬停和闪烁状态放在 `@Observable FlowInteraction { flashed: String? }`，由 SettingsNavigation 持有；0.8s 后用 Task 清空。

### 3.4 NodeChip

- **作用**：把来源应用、对方语言、我的译音、识别引擎、翻译引擎、档位等选择器并进节点，删掉独立的 Picker 行。
- **尺寸**
  - 高 20，胶囊，`.quinary` 底，11pt medium 文字。
  - 前置 12pt 应用图标或符号；后置 `chevron.down` 8pt（`SubtitleTokens.Size.capsuleChevronSize`）。
  - 最大宽 = 节点宽 − 16，文字中间截断，全名放 `.help`。
  - 一个节点放两个 chip 时，应用 chip 只显示图标加截断名，语言 chip 固定 34pt 宽（“EN ▾”）。
- **状态**
  - 会话中锁定：`lock.fill` 9pt 替换 chevron，禁用，`.help`“会话中不可更换”。
  - 来源缺失：前置 `exclamationmark.triangle.fill` 9pt 橙色，节点问题行显示“<App> 未打开”。
- **菜单项**（13pt 图）：`wand.and.stars` 自动 / 各应用（真实图标）/ 未就绪的应用（三角 + 名称）/ 分隔线 / `arrow.clockwise` 刷新列表。
- **无障碍**：label 依次为“声音来源”“对方语言”“我的译音”“识别引擎”“翻译方式”“档位”。
- **SwiftUI**：`Menu { … } label: { chipLabel }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()`。如果 macOS 丢掉了菜单项图片，退回 `NSPopUpButton`（NSViewRepresentable，`.inline` bezel，controlSize `.small`）。绑定沿用现有 state：`state.remoteLanguage`（会议、电话、视频共用，即“对方语言”）、`state.speakLanguage`（“我的译音”）、来源选择、ASR 偏好。

### 3.5 StepTrack

取代 `PhoneSettingsView` 的 checklistRow 和 EnrollmentView 的步骤条。

- **作用**：有顺序的用户步骤，画成一条 FlowGrid 泳道。
- **尺寸**：节点图形用 `.step(n, state)`：未开始 `\(n).circle`，进行中 ProgressView `.small`，完成 `checkmark.circle.fill` 绿色。图形 18pt，与节点图标同级，这样同一列里不会出现 18 和 15 混排（评审 1 指出的问题）。未就绪的步骤不透明度 50%。
- **无障碍**：“第 N 步，<标题>，未完成 / 进行中 / 已完成”。
- **SwiftUI**：复用 FlowGrid。只是 `glyph` 不同。

### 3.6 DataBoundary

- **作用**：用一张两栏图说明“什么留在这台 Mac、什么去 OpenAI”。用于模型›文本翻译、隐私›数据与隐私、引导第 5 步。
- **尺寸**：两栏间距 12，每栏是 `.quaternary` 圆角面板，高 56。
  - 左栏：`laptopcomputer` 18pt，下面 label“本机”加 `lock.fill` 11pt 角标；chip 为“声音 · 声音档案 · 录音”。
  - 中间：`arrow.right` 11pt，只在启用云端时出现。
  - 右栏：`network` 18pt，label“OpenAI”；chip 为“文字 · 上下文 · 术语”。
- **状态**：两个方向都不用 OpenAI 时，右栏不透明度 40%，图标换成 `network.slash`，label 换成“未连接”，中间箭头消失。
- **无障碍**：“本机：声音、声音档案、录音；OpenAI：文字、上下文、术语”。未连接时追加“，未连接”。
- 尾部 ⓘ 原样放 `TranslationSettingsText.cloudNotice`。
- **SwiftUI**：`public struct DataBoundary: View { let cloudEnabled: Bool }`，纯视图。

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

### 3.8 SectionHeader + `.settingsRow`（SettingsRowLabelStyle）

恢复 34c0724 删掉的分组标题图标。

- **SectionHeader**：HStack(spacing 8)：15pt medium secondary 图标放在 22pt 列；标题 13pt semibold，≤4 字；尾部可选 InfoButton。标题图标 = 锚定该 Section 的节点图标。Section 加 `.id(anchorID)`。
- **行**：HStack(spacing 8)：15pt regular、hierarchical secondary 图标放在 22pt 列（应用图标为 15×15）；标题 13pt body，从 +30 起。
  - 每个 Toggle、Picker、LabeledContent、Button 行都必须有图标。找不到合适图标的行，说明它不该是一行。
  - 破坏性行的图标和文字都是红色。
  - 状态行和 FactRow 缩进到 +30，没有自己的图标列。
- **行尾固定顺序**：值 → StatusGlyph 13 → IconButton（每个 22×22）→ ⓘ。
- **SwiftUI**：`public struct SettingsRowLabelStyle: LabelStyle`，在每个 Form 根部加一次 `.labelStyle(.settingsRow)`。Toggle 写成 `Toggle(isOn:) { Label("…", systemImage: SettingsIcon.x) }`。

### 3.9 InfoButton（ⓘ）

- **作用**：只用于展开安全事实、法律依据、隐私承诺的完整句子。
- **尺寸**：NSButton，`info.circle`，`NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)`，替换现在的 textStyle `.body`；frame 22×22；`secondaryLabelColor`。
- 弹层：宽 300，callout，最多 2 句，≤60 字，不加标题，最多一个动作按钮。
- **预算**：每个 Section ≤1 个，每页 ≤3 个。必须挂在 FactChip、节点或行尾上。
- **SwiftUI**：保留现有 NSViewRepresentable 和 NSPopover Coordinator（不需要 @State），只改符号配置和 frame。topic 参数只用于 AX：“<topic>说明”。

### 3.10 IconButton / IconMenuButton

- **IconButton**：`.borderless`，13pt regular，点击区 22×22，secondary 颜色。破坏性动作只在确认弹窗里用红色。必须同时设 `.help` 和 `accessibilityLabel`。
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

### 3.11 FactChip / FactRow

取代 SettingsNote 和灰色段落。

- **尺寸**：胶囊高 20，内边距 h8，1pt 分隔色描边，`.quaternary` 底；11pt 图标 + 11pt caption。普通 chip ≤8 字；§5.4 列出的安全事实 ≤16 字。
- **语气**：neutral（secondary）；cloud（`network` 图标，accent 字色）；warn（橙）；risk（红色合成字形 + 红字）。
- 每个 chip 都必须有 `.help`（≤20 字）；AX 读完整句。
- **FactRow**：HStack(spacing 6)，最多 4 个。宽度不够时用 `ViewThatFits(in: .horizontal) { HStack; VStack(alignment: .leading) }` 折到两行，不用自写 Layout。位置是主图正下方，或某个 Section 末行下方，缩进 +30。
- **SwiftUI**：`public struct FactChip: View { symbol, text, tone, help }`，`public struct FactRow: View { chips }`。

### 3.12 ThumbnailChoice

- **作用**：本身就是外观的设置用缩略图选择：视频字幕的样式和排列。
- **尺寸**：每个选项是按钮。样式缩略图 72×40，排列缩略图 48×32，圆角 8。下方是 caption2 名称（≤4 字）：贴合玻璃 / 描边 / 实底，原文在上 / 中文在上。选中时 2pt accent 描边。
- 缩略图用 SubtitleTokens 绘制，背景跟随系统外观（浅色白、深色黑，与预览一致），不加载图片。
- **无障碍**：label 为选项名，选中项带 `.isSelected`。
- **SwiftUI**：`public struct ThumbnailChoice<V: Hashable>: View { options: [(V, name, thumbnail: AnyView)], selection: Binding<V> }`。

### 3.13 ReturnPill

由 `ReturnToScenePill` 泛化而来。

- **尺寸**：胶囊高 24，`.quaternary` 底，内边距 h10。内容依次为：`chevron.left` 11pt semibold、来源图标 13pt、来源名 13pt callout（例如“会议同传”“音频”，不写“返回”二字）；之后是 IconButton `xmark`（`.help`“关闭”）。整个胶囊的 `.help` 为“返回<来源名>”。
- **行为**：返回时恢复来源的页面、子页、场景卡和滚动锚点。
- **SwiftUI**：把 `SettingsNavigation.returnTarget` 扩展为 `{section, subpage, scenario, scrollAnchor}`。在 `SettingsWindowController` 的 detail 容器的 Z0 槽统一渲染，不在每个页面里各画一次。删除组件自带的 `.padding(.horizontal, 20)`。

### 3.14 RecordingBanner

- 固定在隐私与诊断三个子页的卡片行之下，高 32，横向铺满。
- 底色：诊断录音时 `red.opacity(0.10)`，字幕分析时 `orange.opacity(0.10)`。
- 内容：
  - 诊断录音中：`record.circle.fill` 红色 13pt，“录音中：我 · 译音 · 对方”。
  - 字幕分析记录中：`record.circle` 橙色，“正在保存字幕文字”。
  - 已预约：“本场将录音”或“下场将录音”。
- 尾部 `chevron.right` 跳到对应子页（`.help`“查看诊断录音”或“查看字幕分析”）；当前已在该子页时不显示。

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

### 3.16 VoiceCapsule / Keycap

复用，不改样式。

- 尺寸：高 `SubtitleTokens.Size.controlHeight` = 20，胶囊图标 `capsuleIconSize` = 10，键帽最小宽 30。
- 出现位置：泳道 gutter、节点附件槽、LoopRow、电话实时发声行。
- 改动：只迁移到 `TalkTalkSettingsUI` 并加 `public`。

### 3.17 删除的共享件（用编译器强制执行文字预算）

- `SettingsNote`（GeneralSettings.swift:275-281）：删除后，所有灰段落的调用点会编译失败，逐一迁移。
- `SettingsSubpagePicker`、`SpeechFlow`、`SpeakingLanes`、`FlowNodeCard`、`FlowLink`（改为 NodeTarget）、OpenAI 步私有的 `pathStep`/`pathArrow`、`ScenarioCardHeader` 内部的摘要行、`SettingsStatus.info`。
- 迁移期间可以把 `FlowNodeCard` 保留为薄封装，最后一次页面提交时删除。

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

### 5.5 统一用词

- 会话结束一律叫“结束”，不叫“停止”。录音和分析的停止叫“停止”。
- 开始叫“开始”，电话叫“准备”。
- “对方语言”和“我的译音”是同一个 state 在各处的唯一名称。
- 菜单与设置共用的写法：“使用引导…”“关于 TalkTalk”“设置…”。

### 5.6 执行方式

- 删除 `SettingsNote` 类型，让编译器暴露所有调用点。
- 新增字符串跑 `scripts/check-strings.sh`。
- 可选（按比例，不强制）：在 check-strings 中加一条规则，标出设置相关 Swift 文件里新增的、超过 16 个中文字符的可见字符串，仅作提醒。
- 审阅时对照 §7 每页的“保留可见中文”清单逐项检查。

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
| 识别与翻译 | 模型 › 语音识别（译音泳道上的识别与翻译 → 模型 › 文本翻译） |
| 双语字幕 | 字幕（同一场景） |
| 麦克风 | 音频 #麦克风 |
| TalkTalk Mic | 组件 › 虚拟麦克风 |
| 会议应用 / Phone（原声泳道） | 音频 #TalkTalk Mic |
| 我的声音 | 我的声音 |
| 术语表卫星 | 术语表 |
| 识别和合成的模型角标 | 组件 › 引擎与模型 |
| OpenAI 节点 | 模型 › 文本翻译 |
| 字幕分析的“收听” | 使用场景 |
| 菜单问题行 | 对应页的对应 Section，并闪烁 |

---

## 7. 逐页蓝图

记法：`[symbol 标题]` 表示节点或行；`‹chip ▾›` 表示 NodeChip；`(角标)` 表示状态；`→` 表示箭头；“help:”表示 `.help`。

### 7.0 侧栏与窗口框架（SettingsWindowController.swift）

- 侧栏宽 190，原生 `List(.sidebar)` + Label，使用 §4 的 `SettingsIcon.Page.*`。侧栏行不加角标或计数。
- 窗口标题 = 页名。
- detail 容器统一持有三个槽：Z0 ReturnPill、Z1 导航带、Z1b 横幅。
- 翻译占位页（:308/:321）改为 `ContentUnavailableView(xmark.circle)`“此构建不可用”，原句放 `.help`。
- **删除**：页内标题“翻译”；“这个构建没有 bundle id（直接运行的二进制），翻译设置只在 TalkTalk.app / TalkTalk-Dev.app 里可用。”（改放 `.help`）；ReturnPill 里的“返回”二字。

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

### 7.2 使用场景 · 电话同传

**Z1** CardRow，选中电话同传；有 phoneProblem 时 warn 角标。

**Z2** 主图 Section：
1. **实时发声行**（只在准备好或会话中出现，作为首行）：VoiceCapsule + 12pt 送达图形（`phone.arrow.up.right` / `laptopcomputer` / `speaker.slash`）+ 最短后果，取其一：“已送入 Phone” / “仅本机 · Phone 未接收” / “未发送” / “接通后对方才能听到你”。尾部 22pt 状态按钮：平时是 ⓘ，warn 时是三角，risk 时是风险字形。点开弹出 320pt 弹层，无标题：胶囊、voice.detail 全句、按钮 `[mic.and.signal.meter 音频设置…]`。
2. **FlowGrid**（与会议同构，列对齐）：
   - 听泳道：`[phone.fill 对方]` ‹EN ▾›（对方语言）→ `[识别与翻译]` → `[双语字幕]`
   - 原声泳道：`[麦克风]` → `[TalkTalk Mic]` → `[Phone 应用图标 Phone]`（角标 = Phone 检查：读 TalkTalk Mic 为 ok；读实体麦为 risk；通话前为 pending“通话前检查”；通话中无应用读取为 warn，问题行同源）→ `[phone.fill 对方听到原声]`
   - LoopRow
   - 译音泳道：`[说中文 Keycap]` → `[识别与翻译]` → `[我的声音]` → `[phone.fill 对方听到译音]` ‹EN ▾›
3. **StepTrack**（第二张小图，单泳道，无 gutter，节点高 60）：`[①准备]`（有问题时 warn 角标，问题行显示 phoneProblem 短句）→ `[②拨号／接听]`（①未完成时 50%）→ `[③挂断后结束]`。下方 FactRow：`[stop.circle 结束同传不会挂断电话]`。

**Z3**
- Section（无 header，锚定②）：一行 `[phone]` TextField，占位“+49 …（可选）”（AX“电话号码”），宽 160；IconButton `phone.arrow.up.right`（help“拨打”）；按钮 `[arrow.up.forward.app 打开 Phone]`。①未完成时整行禁用。
- Section `[iphone] 首次连接`（DisclosureGroup，**从未成功准备过时默认展开**，之后默认收起）。内容是一张小图：
  - `[iphone iPhone]` ⇄ `[laptopcomputer Mac]`，卫星 `[person.crop.circle 同一账户]` 和 `[wifi 同一网络]`；iPhone 节点 help:“在其他设备上通话”。
  - `[Phone 应用图标 Phone]`，附件 caption2“麦克风：使用系统设置”，下方 FactRow：`[mic.circle Phone 麦克风：使用系统设置]` 和 risk `[否则对方听到原声]`。
  - FactRow `[headphones 用耳机]`（help“避免回声”）。
  - 行 `[mic.and.signal.meter 音频设置…]`。

**Z5** 底栏：`[play.fill 准备]` / `[stop.fill 结束]`（help“结束同传，不会挂断电话”）；运行中左侧“● [phone] Phone · 12:03”加 chip `[phone 通话不会挂断]`。

**保留可见中文**：已送入 Phone / 仅本机 · Phone 未接收 / 未发送 / 接通后对方才能听到你 / 音频设置… / 对方 EN DE 识别与翻译 双语字幕 麦克风 TalkTalk Mic Phone 对方听到原声 播完回到原声 右⌥ 说中文 开始翻译 我的声音 对方听到译音 / 准备 拨号／接听 挂断后结束 结束同传不会挂断电话 / +49 …（可选） 打开 Phone / 首次连接 iPhone Mac 同一账户 同一网络 麦克风：使用系统设置 Phone 麦克风：使用系统设置 否则对方听到原声 用耳机 / 准备 结束 准备中… 结束中… 通话不会挂断。

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
- **标题栏热点**：在胶囊、右⌥键帽、结束按钮上各放一个 11pt 编号圆点（①②③，16pt `.thinMaterial` 圆底），help 依次为“发声状态：点开看说明”“右⌥：开始或结束翻译”“结束同传”；电话预览的③ help 为“结束同传，不挂断电话”。它们取代被删的标题栏说明句。
- 视频预览：悬停条旁加 `cursorarrow` 11pt 热点，help“悬停时显示”。

**Z3**
- Section `[textformat.size] 字号`：一行，左右 `textformat.size.smaller` / `.larger` 13pt，中间 Slider；值“18 磅”；IconButton `arrow.counterclockwise`（help“恢复默认字号”）。
- Section `[circle.lefthalf.filled] 背景`：一行，左右 `circle.dotted` / `circle.fill`，中间 Slider，在 85% 处画刻度；值“85%”；IconButton 恢复默认（新增，help“恢复默认 85%”）。
  - 系统开启“降低透明度”时禁用，行尾加 `accessibility` 13pt，help“系统已开启降低透明度”。
  - 描边样式时禁用，help“描边样式没有背景”。
- 只在视频场景：Section `[captions.bubble] 样式`：
  - ThumbnailChoice 三个：贴合玻璃 / 描边 / 实底。
  - 行 `[arrow.up.arrow.down] 排列`：ThumbnailChoice 两个：原文在上 / 中文在上。
  - Toggle `[moon.zzz] 静默变暗`（help“8 秒无新内容时变暗”）。
- Section `[macwindow] 窗口`（无行，只有 FactRow）：
  - `[arrow.up.and.down.and.arrow.left.and.right 可拖动]`（help“拖标题栏或文字；视频可在菜单锁定”）
  - `[keyboard 不抢焦点]`
  - `[minus.circle 收起后继续]`（单色，不再用黄色）
  - `[rectangle.on.rectangle.slash 共享屏幕不可见]`
  - ⓘ“最小化后从菜单栏选“恢复字幕窗口”。”

**保留可见中文**：显示字幕 / 用 VoiceOver 读出新字幕 / 会议同传 电话同传 视频字幕 / 示例 / 预览内的示例内容 / 字号 N 磅 / 背景 N% / 样式 贴合玻璃 描边 实底 / 排列 原文在上 中文在上 / 静默变暗 / 窗口 可拖动 不抢焦点 收起后继续 共享屏幕不可见 / ⓘ 一句。

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

### 7.5 通用

**Z2** PageHero：方块 `gearshape`；状态为本页最高优先级的问题，例如 warn“建议开启登录时启动”、waiting“待系统允许”、warn“需允许通知”；全部正常时为 ok“已就绪”。help“启动、通知与应用管理”。

**Z3** Section（无 header）：
- Toggle `[power] 登录时启动`。行尾按状态显示其一：
  - warn“建议开启” + ⓘ“异常退出后，默认输入可能停在 TalkTalk Mic，直到下次启动才还原。”
  - waiting“待系统允许” + 按钮 `[arrow.up.forward.app 登录项…]`
  - warn“请移到“应用程序”文件夹”
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

**Z4** 破坏性 Section：行 `[trash] 完全卸载…`（红色）。
- 进行中：行尾显示进度和步骤名。
- 引擎安装中：行禁用，行尾 waiting“引擎安装中” + 链接“组件 ›”。
- 确认弹窗：标题“完全卸载 TalkTalk？”；正文“将删除：虚拟麦克风 · 引擎与模型 · 我的声音 · 术语表 · 日志缓存 · 设置与登录项 · 钥匙串中的 OpenAI key。需管理员密码，声音中断约 1 秒；通话中不可卸载。完成后退出并移到废纸篓。”；按钮“全部删除”“取消”。
- 结果：“已删除 N 项”；“未删除：”后每项加 `xmark.circle.fill`。

整节删除“会议与电话发言方式”（与场景页的泳道重复；列入 §9.6 待确认）。本页只有 1 个 ⓘ。

**保留可见中文**：已就绪 / 登录时启动 建议开启 待系统允许 登录项… 请移到“应用程序”文件夹 未能更改 / 会议结束通知 需允许通知 允许… 系统已拒绝 系统设置… / 首次翻译前播放告知语 / 使用引导… 第 N 步，共 M 步 / 关于 TalkTalk 1.0 (29) / 完全卸载… 引擎安装中 组件 › / 弹窗与结果文字。

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

### 7.7 我的声音（含 EnrollmentView）

**Z2** FlowGrid（单泳道，gutter `person.crop.circle.fill`，节点高 82）：
- `[mic 录中文]`：附件按钮 `[mic.badge.plus 录制]`，有档案时为“重录”（borderedProminent small；这是本页唯一的主操作）；自检中禁用。
- `[waveform.and.person.filled 声音档案]`：已保存时 ok，未创建时 pending，“无法读取”或“引擎已切换 · 请重录”时 warn；附件 caption2 日期“11-06”；未创建时卫星为虚线 `[speaker.wave.2 系统声音]`。
- `[headphones 试听]`：附件 `[play.fill EN]` `[play.fill DE]`，播放时变为 `stop.fill`（AX“试听英语 / 德语”）；角标：通过为 ok（help“音色相似度 0.98”），未通过为 failed（help“建议重录”），待引擎为 waiting。

问题行：取 waiting“自检中” / waiting“引擎就绪后可试听” / waiting“组件安装中” / warn“自听输出不可用” / warn“试听失败”（help 放 error）中优先级最高的一个。

FactRow：
- `[lock.shield 仅本机 · 不上传]` + ⓘ“声音档案只保存在这台 Mac，不进备份与 Spotlight 索引。” + IconButton `folder`（help“在 Finder 中显示”）。
- `[laptopcomputer 本机播放]`（help“试听不发送到会议”）。
- 没有档案时加 `[speaker.wave.2 未录制时用系统声音]`。

**Z4**（有档案时）：行 `[trash] 删除声音档案…`。确认对话框：“删除我的声音？”，正文“参考音、稿子和声音缓存从这台 Mac 删除；之后译音用系统声音。”，按钮“删除”“取消”。

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

**删除**：
- “用你的声音朗读英语或德语译文。”
- “录一段中文 / 保存声音档案 / 听英语／德语”；节标题“声音档案 / 听听效果”。
- “尚未创建声音档案”“读一遍固定的中文稿子即可创建…”“声音档案已保存”“录制时间”“试听检查”“通过（音色相似度 x.xx）”。
- 档案详情折叠里的全部内容（已移走）。
- “试听英语 / 试听德语”（改为 EN/DE + AX）。
- “自检正在运行，完成后可录制或试听。”“引擎装好并就绪后可试听（经自听输出播到耳机，绝不进 TalkTalk Mic）。”“引擎组件正在安装或修复，完成后再试听。”“试听在耳机或当前播放设备中响起，不发送到会议。”“重新录制时，旧档案会一直保留到新档案保存成功。”
- “存储与隐私”折叠及路径（改为 ⓘ + Finder 按钮）；删除确认长正文（缩短）。
- 录制窗口：“创建我的声音 / 重新录制我的声音”“录一段中文，用你的声音说英语和德语。”“录制准备 / 朗读这段中文”“找个安静的地方…离麦克风一拳左右。”“约 10–20 秒 · 按平时说话的语速读完全文”“开始后先测量环境噪声，再倒数 3 秒…”“测量环境噪声后，会倒数 3 秒再开始录制。”“自然读完全文…或点“完成录制”。”“正在检查录音质量… / 正在准备你的声音并生成英语、德语试听…”“录音检查”及每项 message、“语速约 x.x 字/秒（用于估计说话节奏）”“引擎尚未就绪：可以先保存录音…”“试听已生成。戴上耳机听一听，满意就保存。”“回读错误率 / 第 N 次生成”“参考音 x.x 秒，语速 x.x 字/秒。”“存储位置 + 路径”。

### 7.8 模型 · 语音识别

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

**删除**：卡片下 caption“声音 → 原文 / 原文 → 译文 / 译文 → 声音”（改为卡间箭头 + help）；“听对方／看视频 · 应用声音 → 原文”；“首选识别引擎”；“Qwen3-ASR（默认）”的“（默认）”；“当前运行 / 尚未开始收听”；“选择立即生效；Qwen 不可用时由 Apple Speech 接管。”；“按键翻译的识别引擎 / Qwen3-ASR，Apple Speech 备用”；“支持中文夹英语，统一生成选定的英语或德语译音。”；“我说话 · 点按右⌥开始，再点按结束”；“本地识别模型”整节（含 InfoButton，模型 id 改放 help）；“管理本地模型安装”；“识别与翻译的分工”折叠及两段说明。

### 7.9 模型 · 文本翻译（TalkTalkCloudUI）

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
  - Toggle `[pin] 显示固定快照`。
  - 下线通知：warn“X 已下线 → Y”或“Y 即将下线” + IconButton `xmark`（help“知道了”）。
  - 行 `[gauge.with.needle] 实时可用`：状态图形 + “首字 N ms · 共 N ms”（help“一次测量”）；变慢时加 chip `[tortoise 变慢]`；失败时 failed“无响应”“仍有推理 token”“响应不完整”；IconButton `arrow.clockwise`（help“再测一次”）。
  - 行 `[dollarsign.circle] 费用`：“≈ $0.42/小时（估）”。
  - Toggle `[bell] 开始时提醒：文字发给 OpenAI`。
- 慢模型弹窗：“<model> 会明显变慢”，正文“更慢、推理另计费；超时的句子改用 Apple。”，按钮“仍然使用”“取消”。
- 开发构建：`ContentUnavailableView`“此构建不可用”。
- 本页 ⓘ：cloudNotice + key 建议，共 2 个。

**保留可见中文**：我说的话 听到的话 中 EN/DE OpenAI Apple 译文 中文字幕 备用 Apple / DataBoundary：本机 声音 · 声音档案 · 录音 OpenAI 文字 · 上下文 · 术语 未连接 / 无 key → Apple 下次开始生效 / API key 同意发送文字 sk-… 保存 已存入钥匙串 · 请清空剪贴板 + 错误短句 OpenAI / 模型 默认 显示固定快照 X 已下线 → Y Y 即将下线 实时可用 首字 N ms · 共 N ms 变慢 费用 ≈ $X/小时（估） 开始时提醒：文字发给 OpenAI / 弹窗。

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

### 7.10 模型 · 语音合成

**Z1** CardRow（选中语音合成）。

**Z2** FlowGrid（单泳道，gutter 胶囊 译音，节点高 60）：`[character.bubble EN/DE 译文]` → `[speaker.wave.2 合成译音]`（TTS 模型缺失时 pending + chevron 到组件·引擎与模型；help 放模型名）→ `[mic.circle TalkTalk Mic]` ›组件·虚拟麦克风 → `[person.wave.2 对方听到译音]`。
- 合成节点的卫星：有档案时为实线链接 `[waveform.and.person.filled 我的声音 ›]`（ok）；没有档案时为实线 `[speaker.wave.2 系统声音]`（生效中），我的声音链接改为虚线。卫星的 ⓘ（安全：对方听到什么）：“已有声音档案但克隆引擎暂不可用时，会等待恢复或不发送该段（未发送），不会改用系统声音。”
- FactRow：`[person.2.wave.2 会议·电话生成译音]` `[speaker.slash 视频不生成]`。

**没有 Section**。“Qwen3-TTS / 声音档案”两行已删，节点角标和卫星已表达。

**保留可见中文**：EN/DE 译文 合成译音 TalkTalk Mic 对方听到译音 我的声音 系统声音 / ⓘ 一句 / 会议·电话生成译音 视频不生成。

**删除**：“译文 → 会议里的声音”；“英语／德语译文”；“声音与试听”；“会议同传会生成译音；视频字幕只显示文字。”；节标题“我的声音 / 系统声音”及 InfoButton；“Qwen3-TTS 模型 / <模型名>／未安装”；“声音档案 / 已创建／尚未创建”；“macOS 系统声音 / 无需创建声音档案”；“没有声音档案时，译音使用系统声音。”；“声音档案与恢复说明”折叠及说明。

### 7.11 组件 · 引擎与模型

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
- Section `[square.stack.3d.up] 模型`：每个模型一行，`[waveform | speaker.wave.2]` 等宽 key + secondary“X GB · rev” + 状态图形 13（ok / warn，help“已安装 / 待校验”）+ IconButton `trash` 或 `arrow.down.circle`（help“删除 / 下载 <key>”）。另有一行链接 `[square.stack.3d.up 模型设置 ›]`，跳到模型页。
- 弹窗（缩短）：
  - “安装引擎（max）？”“从 Hugging Face 等下载约 X GB（另加运行时），可随时取消。”[下载并安装][取消]
  - “下载模型 k？”“约 X GB。”[下载]
  - “删除模型 k？”“以后要用时需要重新下载。”[删除]
  - “卸载引擎？”“删除运行时和全部模型；我的声音、术语表和设置保留。”[卸载]
- 开发构建：“此构建不可用”。

**保留可见中文**：引擎与模型 虚拟麦克风 / 下载 安装 校验 就绪 max x/y GB / 引擎 档位 换档 修复 校验安装 重启引擎 查看日志 卸载引擎… / 状态短句 / 模型 X GB · rev 模型设置 / 弹窗。

**删除**：卡片摘要“语音识别 · 语音合成 / TalkTalk Mic · 连接会议应用”；“本页管理本地安装；模型选择在“模型”中设置。”（改为“模型设置 ›”）；“正在检查组件…”（改为 busy）；页内 headline“引擎与模型”及 `.title2` cpu 头；stateText 长句；“这个构建里没有安装器…”；“准备中 d/c · model · x/y GB”里的模型名；“取消”文字；“完全卸载正在进行：引擎的操作要等它结束。”；“换档并安装 / 下载并安装”“修复安装”“维护引擎”文字；“下载与安装说明”及其说明；“Qwen3-ASR · 把听到的声音转成原文 / Qwen3-TTS · 用你的声音朗读译文”角色行；“已安装／待修复／未安装”文字；“模型、版本与单独下载”；模型行用途说明；“已安装／待校验”文字；“删除 / 下载”文字按钮；安装弹窗长正文（缩短）。

### 7.12 组件 · 虚拟麦克风（TalkTalkDriverSupport）

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
- 引导嵌入这一区块时，不显示它自己的 header 和 footnote。
- 开发构建：“此构建不可用”。

**保留可见中文**：麦克风 原声 译音 TalkTalk Mic 会议应用 / 需管理员授权 + ⓘ / 驱动 状态短句 安装 更新 重新安装 重启音频服务 自检 刷新 卸载… / 进度、结果短句 / 详情及检查名 / 弹窗原文。

**删除**：区块 headline“TalkTalk Mic · 虚拟麦克风”（`mic.fill` `.title2`）；“把原声或译音送进会议，请在会议 App 中选择 TalkTalk Mic。”；statusText 长句；“正在使用：A、B”；“正在校验随 App 带的驱动…”；“安装虚拟麦克风 / 更新虚拟麦克风”；“运行自检”；“维护”文字；“刷新状态”“卸载虚拟麦克风…”；结果长句；“好”；“自检详情”；“跳过 / 通过 / 没通过”文字；“上次自检：通过 / 没通过 · 日期”；footnote“TalkTalk Mic 仅在 TalkTalk 运行时出现。安装或维护需要管理员授权…”（改为 chip + ⓘ）；“这个构建没有 bundle id… / 这次运行没有接系统默认输入（冒烟运行）…”（改放 help）。

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

**删除**：“填写中文及至少一种外语译法；保存后，下次翻译请求生效。”；“术语使用说明”及“为产品名、人名和专业词指定译法…”；“添加产品名、人名或专业词，填写中文及至少一种外语译法。”；列名“English / Deutsch”（改为 EN / DE）；占位“中文 / English / Deutsch”；“备注（可选）”；“已保存，下次翻译请求生效。”；“每条填写中文，以及至少一种外语译法。”；“术语表读取失败 / 保存失败”前缀；“启用云端翻译时，术语随文字发送给 OpenAI；关闭时不发送。”（改为条件 chip）。

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
  - 按钮行 `[trash] 立即清理` + secondary“09:12 · 删除 3”。

本页 ⓘ：cloudNotice + 文字记录 + 自动清理，共 3 个，正好是上限。

**保留可见中文**：数据与隐私 字幕分析 故障检查 / 录音中：我 · 译音 · 对方 正在保存字幕文字 本场将录音 下场将录音 / DataBoundary 文字 / 保存文字记录 本机 30 天 不进诊断包 / Key：仅钥匙串 日志：不含文字和音频 / 自动清理 诊断录音 · 字幕分析 24 小时 文字记录 30 天 延迟事件 20 场 · 14 天 · 200 MB 立即清理 HH:mm · 删除 N。

**删除**：卡片摘要“存储与清理 / 检查本次字幕 / 自检与导出”；横幅长句“字幕分析正在准备 / 正在保存本次字幕文字”、“查看字幕分析 / 查看诊断录音”可见按钮、“正在录音：麦克风、合成语音、对方”（改为“我 · 译音 · 对方”）、“已启用本场 / 下场诊断录音”；“声音与文字的去向”；“声音留在本机 / 识别为文字 / 可选云端翻译 / 翻译设置”；“语音识别与合成在本机完成，音频和声音档案不上传…”；“密钥与常规日志”折叠；“OpenAI key 只在登录钥匙串里…”；“常规日志只记 id、长度、耗时和错误码…”；“文字记录”节说明“默认关闭。开启后保存会议原文和译文，仅在本机保留 30 天，不进入诊断包。”；“文字记录的存放方式”折叠及说明；“启动时及之后每小时检查一次，按以上期限自动清理。”（改为 ⓘ）；“上次：HH:mm，删除 N 项”。

### 7.15 隐私与诊断 · 字幕分析

**Z1** CardRow + RecordingBanner。

**Z2** FlowGrid（单泳道，无 gutter，节点高 82）：
- `[ear 收听]`：会话运行中为 live；空闲时为 off，chevron 到使用场景，help“先开始会话”。
- `[record.circle 分析]`：附件按钮“开始分析（含文字）”或“停止”，没有会话时禁用；角标为 pending 未开启 / recording 记录中 / ok 已停止 / warn 达上限 / failed 写入失败（原因放 help）。
- `[doc.text.magnifyingglass 记录]`：附件为 secondary“N 行” + IconButton `doc.on.doc`（help“复制分析文件路径”，路径也在 help 里）+ IconButton `folder`（help“在 Finder 中显示”）；ⓘ“记录原文、译文和各阶段耗时，用于检查漏句与积压；8 MiB 或 1 万行自动停止。”

FactRow：`[text.quote 仅文字]` `[mic.slash 不录音]` `[1.circle 仅本次]` `[laptopcomputer 本机]` `[clock 24 小时]` `[shippingbox 不进诊断包]`，用 ViewThatFits 折成两行。

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

### 7.17 首次引导（OnboardingFlow / OnboardingPracticeSteps / OnboardingUIComponents / OpenAIOnboardingStep）

沿用同一套组件和尺寸。

- **头部步骤指示**：保持 16pt 图形放在 30pt 圆里（这是引导专用的已有组件，只此一处）。AX 和菜单项共用同一个字符串“第 N 步，共 M 步”。
- **StepTitle**：图标改为 L1 22pt + `title2.bold`。OpenAI 步也改用 StepTitle，不再有私有头部。
- **场景选择**：CardRow(multiSelect)，不显示摘要；可见文字只有“你会用 TalkTalk 做什么？”和“可多选”。
- **第 1 步（权限）**：GrantRow 改用 `.settingsRow`（15/22），只留标题：应用声音 / Apple 语音识别 / 麦克风 / Keycap 右⌥；状态只用图形；说明进 ⓘ，最多 3 个（例如“快捷键只监听、不修改按键”）。失败短句：failed“系统录音被拒绝” + `[arrow.up.forward.app 打开“隐私与安全性”]`；warn“未确认 · 开始时再查”。
- **第 2 步（语言资源）**：语言徽章 48pt 保持，角落加状态角标（11 放在 15 圆底）；按钮 `[arrow.down.circle 下载]`。
- **第 3 步（虚拟麦）**：`FlowGrid.driver` + FactChip `[lock.fill 需管理员授权 · 声音中断约 1 秒]`；嵌入的 DriverComponentSection 不显示 header 和 footnote。
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

---

## 8. 菜单栏菜单（StatusItemController.swift）

### 8.1 通用规则

- **没有“更多”子菜单**，也没有 340pt 的说明子菜单（detailItem）。只保留两个语言子菜单。
- 问题行的写法：一行不可点的着色状态行，紧跟一行缩进 1 级（`indentationLevel = 1`）的操作项。完整说明放在状态行的 `toolTip`。
- 所有可操作项都配 13pt 模板图（`NSFont.menuFont(ofSize: 0).pointSize`，现状正确，不改）。状态行着色。“关于 TalkTalk”和“退出”不配图（§0.2 #13）。现在缺图的项要补上：切回 TalkTalk Mic 用 `mic.circle`，收听所有应用用 `ear`，会中标题用场景图标，phoneStatus 用送达图形。
- 问题行点击后进入设置的精确 Section，并闪烁（复用 §6.3 的锚点）。

### 8.2 状态 A：引导未完成（放在所有其他状态之前）

```
[arrow.clockwise.circle] **继续使用引导 · 第 3 步，共 8 步**      ← 粗体；打开引导到该步
─────────
（下接 B / C / D 的其余内容）
```

- N 和 M 来自 `OnboardingState.position`，与引导头部的 AX 共用同一个字符串。
- 这一项吞掉原来的“Apple 资源待配置 › 打开使用引导…”和状态行“语音组件尚未就绪”。
- 场景的“开始”项在所需组件就绪前禁用，`toolTip`“完成引导后可用”。
- 首次启动自动打开引导（已实现，保持）。
- 引导完成后，入口只在 设置 › 通用 › 使用引导…。

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

### 8.5 状态 D：有问题（插在标题行之后、“结束”或“开始”之前，最严重的在上）

| 状态行（着色） | ⤷ 缩进操作 |
|---|---|
| [risk 红] 对方能听到原声 | [mic.circle] 检查麦克风… |
| [exclamationmark.circle 橙] 会议尚未使用 TalkTalk Mic | [mic.circle] 检查麦克风… |
| [mic.circle 橙] <systemInputNotice 短句> | [mic.circle] 切回 TalkTalk Mic ／ [arrow.uturn.backward.circle] 还原默认输入 ／ [mic.and.signal.meter] 查看音频设置… |
| [arrow.uturn.backward.circle] 恢复输入记录（subtitle） | 开始会议同传 |
| [exclamationmark.triangle 橙] 识别：Apple 备用 | [square.stack.3d.up] 模型设置… |
| [exclamationmark.triangle 橙] 字幕翻译：Apple 备用 | [square.stack.3d.up] 模型设置… |
| [captions.bubble] <会议似乎已结束提示> | [ear] 继续收听 |
| [questionmark.bubble] 确认应用… | （点击即选择） |

- 有问题时，菜单栏图标换为 `exclamationmark.bubble`。
- 状态栏 `toolTip` 和菜单中的短状态词：组件未就绪 / 准备中 / 识别/播放译音 / 音频未就绪 / 使用备用 / 检查音频设备 / 原声中 / 对方能听到原声。

### 8.6 从菜单删除

- “更多 ›”整组（我的声音… / 使用引导… / 通知设置…）、“隐私与诊断…”。删除“隐私与诊断…”和“我的声音…”**需要用户确认**，见 §9.6。
- “电话同传设置…”。
- 正常状态下的“语音识别 / <asr 详情> / 识别与模型设置…”。
- 只用 Apple 时的“字幕翻译：Apple”。
- 两个“…与模型设置…”合并为“模型设置…”。
- 绿色的“会议麦克风：TalkTalk Mic”行（没有新信息）。
- 我说话语言的 toolTip“中文可夹英语，译音统一为所选语言”。
- 文案改短：“在耳机中听到译音”→“耳机译音”；“现在播放告知语”→“播放告知语”；“打开 Phone 拨号或接听”→“打开 Phone”；“现在还原默认输入”→“还原默认输入”；“继续收听，不自动停止”→“继续收听”；“上次：<场景> · 英语 → 中文”→ subtitle“英语 → 中文”。

---

## 9. 实施顺序

### 9.0 前提

- 之前并行的工作流已在 e36b0b3 落地，本计划直接在 main 上接着提交。保留 `ScenarioCardHeader` 的选择语义（`requestedScenario` 由使用场景和字幕共用），以及 95cdf11 的系统外观背景。
- 只用 `scripts/build-app.sh release` 构建、安装、启动，不打包 DEV 应用。需要权限的流程用 `open -a` 启动。
- 每次提交至少跑一次聚焦检查；页面类提交跑 `scripts/check.sh --skip-stress`。改了 `Localizable.xcstrings` 时跑 `scripts/check-strings.sh`。**不跑负载或浸泡测试。**
- 界面验收：每次页面提交后，在 release 应用中按 深色 / 浅色 × 880×640 / 820×600（最小）逐页截图。同时开 VoiceOver 抽查读序，用“减少动态效果”“降低透明度”“增强对比度”各检查一次。

### 9.1 提交序列

| # | 提交 | 改哪些文件 | 依赖 | 验收点 |
|---|---|---|---|---|
| 1 | **共享 target + 令牌 + 状态词汇** | `Package.swift`（新增 `TalkTalkSettingsUI`；App、CloudUI、DriverSupport、Voice 依赖它）；新目录 `Sources/TalkTalkSettingsUI/`（迁入 VoiceCapsule、Keycap、InfoButton、SettingsStatus、风险字形绘制，并新增 StatusGlyph、StatusLabel、IconButton、IconMenuButton、FactChip、FactRow、SectionHeader、SettingsRowLabelStyle）；`SubtitleTokens.swift`（`SettingsIcon.Page.*`、§4 一义一形的令牌、Size 常量）；`SettingsFlowComponents.swift`（改为 import 新 target）；新测试 `TalkTalkCoreTests/SettingsSymbolTests.swift`（遍历 SettingsIcon、MenuIcon、VoiceIcon、SceneIcon 令牌，`NSImage(systemSymbolName:)` 非 nil；豁免 `VoiceIcon.originalRisk`，断言它的回退合成存在） | 无 | 构建通过；`check.sh --skip-stress`；侧栏图标更新；状态图形全窗口统一为 13pt；InfoButton 为 13pt，22×22 |
| 2 | **导航统一** | 新增 `SettingsCard`/`CardRow`（SettingsUI）；`SettingsTabButton.swift` 删除或改为薄封装；`ModelSettingsView.swift`（删 `SettingsSubpagePicker`）、`ComponentsSettings.swift`、`DiagnosticsView.swift`、`ScenarioSettingsView.swift`（ScenarioCardHeader 改走 CardRow）、`SubtitleSettingsView.swift`（加 GlobalRow 和 VoiceOver KVO 模型）；`SettingsWindowController.swift`（Z0 ReturnPill 槽、Z1 导航带槽、`returnTarget` 扩展、`FlowInteraction`） | 1 | 五个页面都有卡片行，固定、不收起、不随滚动；模型页卡间有箭头；角标显示正确；字幕页 GlobalRow 在卡片上方；VoiceOver 关闭时不显示朗读开关；ReturnPill 返回时恢复子页和滚动位置 |
| 3 | **流程组件 + 场景三页** | SettingsUI 新增 `FlowGrid`/`FlowNode`/`NodeChip`/`FlowSatellite`/`LoopRow`/`StepTrack`；`ScenarioSettingsView.swift`、`PhoneSettingsView.swift`（FlowGrid.meeting/phone/video 工厂、ScenarioBottomBar 改写、删除 runningBanner 与描述）；`SettingsFlowComponents.swift`（SpeechFlow/SpeakingLanes 先原样保留，不改成薄封装：引导、音频、我的声音、模型、诊断各在 4c/4d/4e/7 迁到 FlowGrid，第 5 次提交删除它们） | 2 | 820 宽下节点不截断安全词；滚动和切卡不卡死（8c87ba7 回归）；chip 和开关可点，chevron 不误触；VoiceOver 读序为节点 → 控件 → 链接；会议检查 notChecked / green / physicalMic / nobodyReads 四种状态下，节点、问题行、菜单三处一致；电话“首次连接”在从未准备成功前自动展开 |
| 4a | **字幕页** | `SubtitleSettingsView.swift`、`SubtitleLayoutPreview.swift`（热点）、新增 `ThumbnailChoice` | 3（并行于 4b–4d） | 深色黑、浅色白；没有背景选择器；热点有 help 和 AX；视频的样式和排列为缩略图 |
| 4b | **通用 + 术语表** | `GeneralSettings.swift`（PageHero、删除发言方式节，**先获用户确认**）、`GlossarySettings.swift`（改为 Form）；新增 `PageHero` | 1–2 | 每页 ⓘ 不超过上限；术语表边距与其他页一致 |
| 4c | **音频 + 我的声音** | `AudioSettings.swift`（FlowGrid.audio，节点 anchor 复用现有 scrollTo）、`MyVoiceSettings.swift`、`Sources/TalkTalkVoice/EnrollmentView.swift`（StepTrack） | 3 | anchor 滚动和闪烁正常，减少动态效果下不闪；档案详情已移走（与 4e 协调） |
| 4d | **模型三子页** | `ModelSettingsView.swift`、`Sources/TalkTalkCloudUI/TranslationSettingsView.swift`（+ `TranslationSettingsText.swift`）；新增 `DataBoundary` | 3 | OpenAI 开关在同意和 key 之前禁用；同意按钮文字为“同意发送文字”；DataBoundary 在未连接状态灰显 |
| 4e | **组件 + 隐私与诊断** | `EngineComponentsRows.swift`、`DriverComponentPage.swift`、`Sources/TalkTalkDriverSupport/DriverComponentView.swift`、`PrivacySettings.swift`、`DiagnosticsView.swift`（RecordingBanner、技术详情 › 声音档案） | 3、4d（DataBoundary） | 录音横幅在三个子页都显示，卡片角标正确；risk“已卸载 · 会议改用实体麦（对方听到原声）”出现 |
| 5 | **清理** | 删除 `SettingsNote`、`SpeechFlow`、`SpeakingLanes`、`FlowNodeCard`、`FlowLink`、`SettingsStatus.info`、OpenAI 步 `pathStep`；清理孤立的 `Localizable.xcstrings` 键 | 4a–4e | 编译通过即证明没有灰段落；`check-strings.sh` 通过；grep 检查 `.font(.system(size:` 取值只在 {22, 18, 15, 13, 11, 9} 内 |
| 6 | **菜单** | `StatusItemController.swift`（及其菜单模型和测试） | 2（深链锚点） | A/B/C/D 四态截图；没有“更多”；引导项为粗体且排第一；问题行深链能落到正确 Section |
| 7 | **引导** | `OnboardingFlow.swift`、`OnboardingPracticeSteps.swift`、`OnboardingUIComponents.swift`、`Sources/TalkTalkCloudUI/OpenAIOnboardingStep.swift` | 3、4d、4e | 第 3 步与组件页是同一张图；第 5 步与文本翻译用同一个 DataBoundary 和 key 组件；“第 N 步，共 M 步”与菜单同源 |
| 8 | **文档** | `docs/ARCHITECTURE.md`（设置视觉系统、TalkTalkSettingsUI、场景卡语义、VoiceOver 开关显示规则、菜单四态）；`docs/decisions/2026-11-06-subtitle-ui-redesign.md` 新增 §9.4“图示优先设置系统”，并在 §9.1 注明“HIG pass 去图标部分被本节推翻”；`docs/remaining-work.md:29` 补“卡片导航覆盖全部子页” | 全部 | 文档与行为一致 |

### 9.2 可以并行的部分

- 1 → 2 → 3 必须串行：它们是共享地基。
- 4a、4b、4c、4d 文件互不重叠，可以在独立 worktree 并行。4e 依赖 4d 的 DataBoundary，可以先做组件部分。
- 6（菜单）在 2 之后就能与 3、4 并行。
- 7 要等 3、4d、4e。
- 5 和 8 放在最后。

### 9.3 风险与缓解

1. **宽度。** 最小窗口下每列约 113pt。“Microsoft Teams”这类长名会截断为“图标 + 截断名”，全名放 help。节点标题允许缩放到 0.85，但永不换行，永不截断安全词。最大系统字号下用 ViewThatFits 收起 gutter。必须在 820 宽下截图验收。
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

### 9.5 文档同步要点

- 设置“文字预算”规则（§5）。
- 子页导航统一为图标卡片（§6）。
- 尺寸梯子 22/18/15/13/11（§4）。
- `SettingsStatus.info` 删除。
- 新 target `TalkTalkSettingsUI`。
- 字幕页卡片只编辑设置，不启动会话。
- VoiceOver 朗读开关的显示规则。
- 菜单四态、删除“更多”。

### 9.6 动手前需要用户确认的行为删除（2026-11-06 已全部确认）

1. 删除使用场景页的**运行横幅**。之后由运行中场景卡的绿点和计时，加底栏左侧的“● 场景 · 来源 · 12:03”承担。
2. 删除通用页的**“会议与电话发言方式”整节**。场景页的泳道和回环已经完整表达同样内容。
3. 菜单删除 **“隐私与诊断…”和“我的声音…”**，改为经“设置…”进入；引导完成后，“使用引导…”只保留在 设置 › 通用。
4. 电话清单 ① 不再单独放“准备”按钮，只用底栏的“准备”。
5. “我的声音”的档案详情移到 故障检查 › 技术详情。
6. **术语表**继续保留手动“保存”按钮；是否改为自动保存另行讨论，本规格不改。
