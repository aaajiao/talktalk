# GitHub 发布与应用内更新

TalkTalk 的更新包、校验文件和签名更新源都放在 `aaajiao/talktalk` 的 GitHub Release。应用只读取公开更新源，不保存 GitHub Token，也不需要用户登录 GitHub。用户在 App 内检查更新、下载，并确认安装重启；不会静默安装。会议、录音和维护尚未结束时不重启。

固定更新源：

```
https://github.com/aaajiao/talktalk/releases/latest/download/appcast.xml
```

GitHub 的 Latest Release 必须包含以下三个文件。不要用 GitHub 自动生成的源码 ZIP 替代应用 ZIP：

| 文件 | 用途 |
|---|---|
| `TalkTalk-<版本>-macOS-arm64.zip` | 含 `TalkTalk.app` 的已签名更新归档 |
| `appcast.xml` | Sparkle 版本、构建号、系统／硬件要求、版本说明与归档签名；文件本身也有签名 |
| `SHA256SUMS.txt` | 应用 ZIP 和签名 appcast 的 SHA-256，方便人工核对 |

Sparkle 按 `CFBundleVersion` 比较新旧。`CFBundleShortVersionString` 是用户看到的版本号。`scripts/build-app.sh` 自动保留递增的构建号；失败的构建也不回退号码。更新源要求 Apple Silicon 与 macOS 26.4 或更高版本，沿用项目对外公布的支持范围。

## 每次发布

发布者在配有签名钥匙串及 GitHub CLI 登录状态的 Mac 上执行：

1. 在 `scripts/lib/versions.sh` 修改 `TT_APP_VERSION`，例如 `1.0.18`。不要手改生成的 pins。运行 `scripts/gen-pins.sh`。
2. 完成改动和版本说明。把发布说明写到 Git 忽略的本地文件，例如 `build/release-notes-v1.0.18.md`；只包含面向用户的变更、验证与已知限制。
3. 运行 `scripts/build-app.sh release`。它生成正式 `build/TalkTalk.app`、递增构建号、嵌入固定版本的 Sparkle、公钥和更新源，并执行签名与双语 smoke 检查。构建前后核对输入指纹，在签名前将 `build-source.json` 放入应用；编译期间源文件变化会让构建失败。
4. 运行 `scripts/check.sh --skip-stress`。新增发布工具使用隔离的离线 fixtures，不访问钥匙串、GitHub 或真实音频。
5. 核对 `git diff`，更新 README 下载链接和实际验证记录，提交并推送到 `origin/main`。不要在提交后修改应用源代码而继续发布旧构建；源代码变化必须重新构建、检查并提交。
6. 运行唯一的正式发布入口：

   ```bash
   .venv/bin/python3 -I -B scripts/publish-release.py \
     --notes-file build/release-notes-v1.0.18.md
   ```

默认从 `build/TalkTalk.app` 打包到新的 `build/releases/v<版本>/`。可用 `--app`、`--out`、`--tools-dir` 指定其他本地路径；发布仓库、正式分支、更新源和应用身份不能通过这些参数更改。

发布入口按顺序执行：

- 验证工作区干净、当前分支为 `main`、本地 HEAD 与 GitHub 的 `origin/main` 一致、源版本与构建包身份一致、当前构建输入指纹与已签名应用内的收据一致，且这个版本的 tag 和 Release 尚不存在。
- 调用 `scripts/package-update.py` 验证并快照应用，用钥匙串内的既有密钥签署 ZIP 与 appcast，验证签名，再生成校验文件。只有公钥与应用内嵌公钥完全一致才继续。
- 为同一个提交创建并推送 `v<版本>` 标签，创建 GitHub **草稿** Release 并上传三个文件。
- 从 GitHub 重新读取每个文件的上传状态、字节数和 SHA-256，与本地逐一比较；再次确认 `origin/main` 后，才把草稿发布并设为 Latest。
- 回读已发布 Release，检查文件和发布状态，输出版本链接。

输入指纹涵盖 Swift／C／引擎源码、依赖锁、资源、驱动及打包安装脚本。收据只存 SHA-256 和文件数，不存源码正文、绝对路径或密钥。README、版本文档与不随应用分发的测试不计入指纹；更新下载链接或补充验证记录可以在构建后提交，改动应用输入则必须重建。

不会覆盖已有本地归档、标签或 Release，也不使用 `--clobber`。不要在正式发布时另行手写 `gh release create/upload`，否则可能遗漏 appcast 或绕过远端文件校验。

## 签名密钥

公开配置在 `scripts/lib/updates.sh`：

- `TT_SPARKLE_VERSION`：固定的 Sparkle 版本；`Package.swift` 与 `Package.resolved` 同步固定依赖。
- `TT_UPDATE_FEED_URL`：固定 GitHub Latest appcast 地址。
- `TT_UPDATE_PUBLIC_KEY`：可以提交到仓库、内嵌到应用的 Ed25519 公钥。
- `TT_UPDATE_KEYCHAIN_ACCOUNT`：`com.aaajiao.talktalk.updates`。

私钥存放在发布者的 macOS 登录钥匙串，Sparkle 服务为 `https://sparkle-project.org`，标签为 `Private key for signing Sparkle updates`。打包和发布脚本不导出私钥、不将其放进仓库、环境变量或 GitHub Release。公钥核对调用 `generate_keys --account com.aaajiao.talktalk.updates -p`，只查找既有密钥；缺少密钥时发布失败，不自动创建替代密钥。

请保留此登录钥匙串的安全备份。当前应用为 ad-hoc 签名，不能依靠 Developer ID 证书轮换来救回丢失的更新密钥；失去原私钥后，新包不能继续被已安装应用信任，必须另行人工迁移。不要为了让发布通过而更换仓库中的公钥。

应用要求在解压前验证更新包签名，也要求 appcast 签名；签名失败不会到期后自动放行。SHA-256 供人工与 GitHub 上传校验使用，不能代替 Ed25519 的更新来源验证。

## 失败与恢复

构建或检查失败时不发布。签名失败不会留下最终输出目录；私钥缺失或公钥不匹配时先恢复正确钥匙串，不重新生成公钥。网络／鉴权错误不会被当作“版本不存在”。

标签推送或 GitHub 上传途中失败，脚本保留已创建的标签、草稿和本地文件用于检查，不删除它们，也不会把未验证的草稿设为 Latest。先查看草稿和日志，确认失败发生在哪一步。当前工具不自动恢复或覆盖半成品；发布者确认清理本次未发布的草稿／标签后，使用新的输出目录重新运行。已经公开的版本及文件保持不可变，修正另发新版本。

发布后若需要撤回有问题的新版本，保留已公开文件，明确说明问题，并发布构建号更高的修复版本。不得通过改低构建号、修改旧 appcast 或替换同名 ZIP 让应用降级。

## 首次启用与验证边界

没有内置 Sparkle 的旧版（包括 1.0.17）需要先人工安装一次带更新器的版本。此后，新的 GitHub Release 通过上述入口发布，App 才能从 Latest appcast 找到并安装它。

正常发布需要编译、签名、双语与完整离线检查。首次启用更新器或变更更新协议，还应在隔离应用上验证实际下载、签名拒绝、替换与重启；使用独立应用身份与临时目录，避免操作正在参会的正式应用。普通离线 fixtures 和签名工具验证不能代替真实安装重启测试。
