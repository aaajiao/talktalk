# TalkTalk 架构

本文是当前设计依据。改变模块边界、音频路径或隐私约束时，先在这里记录理由并同步实现。
功能与验收状态见 [remaining-work.md](remaining-work.md)；构建和使用入口见 [README](../README.md)。

## 平台与模块

TalkTalk 是面向 Apple Silicon 的菜单栏应用，部署目标为 macOS 26；Apple 本地翻译要求 macOS 26.4 及以上并安装对应语言资源，因此使用说明采用 26.4+ 作为完整功能要求。SwiftPM 使用 Swift 6.2 工具链、Swift 6 语言模式；界面采用 AppKit 与 SwiftUI，应用本身不链接 MLX。

| 模块 | 职责 |
|---|---|
| `TalkTalkApp` | 应用装配、菜单、设置、引导、字幕与发言 HUD |
| `TalkTalkCore` | 协议、策略、时间、文本检查、状态机与配置 |
| `TalkTalkSession` | LISTEN/SPEAK 流水线、会议生命周期、按键与原声门控 |
| `TalkTalkAudio` / `CAudioCore` | HAL 采集与输出、重采样、环形缓冲、实时 C 回调 |
| `TalkTalkApple` | Apple Speech、Translation、系统声音适配 |
| `TalkTalkCloud` / `TalkTalkCloudUI` | OpenAI 文本翻译、熔断、连接保温、云端设置 |
| `TalkTalkEngineHost` / `engine/` | 私有 Python 进程、安装器、MLX ASR/TTS、流式协议 |
| `TalkTalkVoice` | 声音录入、校准、校验、存储与试听 |
| `TalkTalkDriverSupport` / `Driver/` | 虚拟麦驱动、安装卸载、状态检查与隔离自检 |

`TalkTalkSession` 通过 Core 协议接收云端和本地引擎，不直接依赖 Cloud、EngineHost 或 Voice。App 层负责把具体实现装配起来。

## 两种使用场景

- **会议同传**：听英语或德语，显示原文与中文；自己说中文（可夹英语），翻译为英语或德语并送入会议。
- **视频字幕**：只收听所选应用并显示双语字幕，不开启麦克风、SPEAK 或默认输入切换。
- “要听的应用”选择应用音频。浏览器来源包含该浏览器的其他标签页，不保证只捕获一个标签页；全局采集仅作明确选择的备用方式。

## LISTEN：对方音频到双语字幕

```text
所选应用 → Core Audio process tap → AudioIngest / TimeMap
        → Qwen ASR（默认）或 Apple Speech → 句子定稿
        → Apple 草稿 / OpenAI 定稿（不可用时 Apple 兜底）
        → 数字检查 → SubtitleBoard → SubtitlePanel
```

Qwen 在共享引擎中以较低优先级运行，冷启动先等待 ASR 就绪；不可用或识别失败时接管到 Apple，界面显示实际引擎状态。
原文语言与 ASR 选择可在会话中切换；配置代际隔离旧回调，切换清空旧字幕和待显队列，不重启 SPEAK 或默认输入管理。
最终字幕按句配对保留原文和译文；草稿单独显示。面板最多保留两组，按阅读节奏推进，支持字号、拖动与位置保存，不抢键盘焦点并从屏幕共享中排除。

## SPEAK：实体麦到会议输入

```text
实体麦 → MicCapture → MicIngest / VAD / clip cutter
原声：PassthroughGate → PassthroughStage → ringP → Feed → TalkTalk Mic → 会议应用
翻译：ASR → MT → 文本检查 → TTS → ClauseQueue
                                  ├─ ringO → 同一个 Feed
                                  └─ ringO2 → Monitor → 耳机自听
```

会议默认发送实体麦原声。物理右 Option 按下立即关原声，持键期间允许分段翻译与播放；松开后等待采集尾段、识别、翻译、合成及待播译音全部排空，才自动恢复原声。拒绝翻译的持键期间也不能漏出原声。
原声与译音互斥；恢复依据真实 gate、流水线 busy 和播放边界，不能只按 UI 状态或 key-up 判断。会议静音使用会议应用的按钮。
稳定文本负责切句，完整可修订假设负责预览。当前音频片段上限为 4.5 秒；短尾未提交时显示为未发送草稿，不能冒充成功翻译。
自己的本次发言原文与译文独立显示，完成处理和播放后短时保留；新一轮按键替换，不建立发言历史。
Feed 的第 1 声道送会议 Mic，第 2 声道只送 Test Mic；自检不能借第 2 声道向真实会议发声。

## 实时音频与生命周期约束

- 实时回调在 C 中运行，不分配内存、不持锁、不做文件、网络或日志 I/O；通过有界环和原子状态与 worker 交换数据。
- 采集时间戳来自音频回调，必须与实际写入帧配对；丢帧和溢出不能造成时间错位。跨线程保留原 host time，不能用 worker 到达时间代替。
- 预录 floor 是实际采集时间的硬下限；按键前已发送的原声不能再次作为翻译预录。ring 的容量不等于允许读取的历史范围。
- 原声只能经过 typed gate → PassthroughStage → ringP → Feed；短租约、设备事实、安全输入和按键组合共同守门，过期或未知状态不放行。没有控制 socket 遥控原声入口。
- 外放模式保留远端 VAD 重叠与回声检查；覆盖不足返回未知，不能记为“无远端语音”或“无回声”。
- HAL listener 注册和移除使用独立 control queue，不在其投递回调队列上等待移除。
- `SpeakOutput`、环、Feed、Monitor 和输出 worker 属于应用；`ClauseQueue`、任务账本和翻译上下文属于一次会话。停止时先取消生产者并拆除输出，再复位缓冲。
- 音频服务重启按关门、detach Feed、suspend Monitor、复位本场队列、恢复 Monitor、按需挂回 Feed 的顺序处理；挂起时延后恢复，不重播旧尾巴。
- 会议模式管理默认输入并保留恢复记录与守护路径；正常结束、异常退出和仍有会议读者的情况分别处理。应用永不更改系统默认输出。
- 引导试说复用正式 Feed，不启用默认原声；必须有确认的可听耳机且没有 Mic 读者或活动会议。读者出现、锁屏、睡眠或路由失效即停止。

## 引擎、翻译与播放

Python/MLX 在独立进程中运行，通过仅本机 HTTP 与每次启动的认证 token 通信；模型、私有 Python 和 venv 位于 bundle 外。一个 GPU worker 按 TTS、SPEAK ASR、LISTEN ASR、后台工作的优先级调度。
默认配置使用 Qwen3-ASR-0.6B 与 Qwen3-TTS-1.7B-Base；较小配置可采用更小 TTS 或 Apple 识别。具体 revision、文件散列、依赖与配置以 `scripts/lib/versions.sh` 和 lock 文件为准。
同场 LISTEN/SPEAK 复用一个 OpenAI 后端及其熔断和连接状态，各方向保留独立开关；语言热切换不能新建后端割裂这些状态。模型设置在下一场生效，术语表按请求读取，最多 30 条生效。
云端只接收待翻译文本、短上下文和术语；未同意或关闭时走 Apple。超时、网络及服务错误按既有预算兜底；翻译结果仍须经过目标文本与数字检查。
有可用声音档案时使用“我的声音”，否则按当前策略使用系统声音或停止发声；界面必须说明实际选择与不可用原因。
`firstSampleEnqueued` 只界定重试边界；已说历史、播放状态和首声指标以 `firstSamplePlayed` 为准。GPU RTF 使用计算时间，不把 HTTP 等待算作 GPU 工作。
告知语在内存中准备，与用户处理并行；失败或超时不能无限阻塞用户句。未验证的码本缩减和自动热备不启用。

## 数据与隐私

- API key 存于 macOS Keychain，不进入命令行、日志、诊断包或引擎；正常音频处理不上传录音或声音档案。
- 常规事件日志默认不含原文和译文。转写、诊断录音和字幕分析分别显式开启，不能以诊断为由默认录制全部会话。
- “本次字幕分析”含原译文和阶段时间，不含音频；不持久化开启偏好，会话结束自动停止。目录 0700、文件 0600，上限 8 MiB / 10,000 行，达到上限在 UI 显示停止。
- 字幕显示时间是 AppKit 提交更新时刻，不是光学显示时刻；缺 voice-end 或参考转写时，不计算伪 EVS、准确率或主观质量分数。
- 诊断导出使用白名单，私有记录按留存策略清理；声音资料与分析文本不进入仓库。合成测试音频同样不提交。

## 构建与验证边界

版本和组件 pins 从 `scripts/lib/versions.sh` 生成；更改后运行 `scripts/gen-pins.sh`，不手改生成文件。安装器验证 revision、大小与 SHA-256，最后写入安装记录。
正式包与开发包使用独立身份；开发 bench 入口只在 `TALKTALK_DEV` 下编译。状态栏使用跨版本稳定 autosaveName，由系统保存布局，不使用未公开排序偏好。
常规检查与 fake 测试不应申请权限或改真实设备。真实驱动、麦克风、云端费用和设备恢复检查必须单独安排；CLI passthrough 是退出应用后的离线独占自检，无法取得独占时明确 skip。
自检默认不运行 cloud 或 corun；cloud 需要显式选择，corun 当前明确 skip。构建、签名、mock 回归或一次本地播放不等于完成真人会议、质量或兼容性验收。
