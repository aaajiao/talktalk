# 维护与诊断

在 **设置 › 隐私与诊断 › 字幕分析** 主动开始记录，可查看实际识别、翻译及显示节奏。记录包含原文和译文，不含音频；不要将会议转写或诊断记录直接提交到公开 issue。

本地分析：

```bash
python3 -I -B tools/subtitle_report.py "/完整路径/trace.jsonl"
```

需要逐句原译对照时加 `--include-text`。报告不能自动判断翻译准确率，仍需对照原声或参考字幕。

模型和专用 Python 位于 `~/Library/Application Support/TalkTalk/engine`，由组件页管理。仅替换 App 不会删除它们。

## 卸载

推荐先离开会议，在 **设置 › 通用 › 应用管理 › 完全卸载 TalkTalk** 操作。它会核验并还原系统默认输入、卸载驱动与引擎、清理私有数据和本构建的钥匙串条目，逐项报告未删除的内容。最后把 app 拖进废纸篓。

仅恢复驱动时，bundle 内的 `Contents/Resources/uninstall.sh` 可复用已有校验脚本：

```bash
/bin/bash /Applications/TalkTalk.app/Contents/Resources/uninstall.sh --driver-only --confirm-no-meeting
```

执行前先退出所有通话和 TalkTalk，在 **系统设置 › 声音 › 输入** 确认选中实体麦克风。驱动卸载会请求管理员密码并重启音频服务，声音短暂中断；可加 `--no-restart`，之后自行注销或重启。此入口只删驱动，不删声音档案、模型或 key；如果还原记录仍在，会拒绝执行。

## App 已被删掉时

保留或重新取得本仓库后，在仓库根目录操作：

1. 退出所有会议程序；在系统设置把默认输入从 TalkTalk Mic 改回实体麦。退出仍在运行的 TalkTalk/开发版。
2. 用校验 bundle identifier 的脚本卸载驱动：

   ```bash
   sudo /bin/bash scripts/driver/uninstall-driver.sh
   ```

   它只操作 `/Library/Audio/Plug-Ins/HAL/TalkTalkAudio.driver` 及确认属于 TalkTalk 的安装残留，并重启音频服务；失败时按输出提示注销或重启。
3. 用 `/bin/bash scripts/install-engine.sh --uninstall` 删除已登记的引擎与模型。脚本保留不认识的文件，检查它报告的残留。
4. 确认不需要保留声音档案、术语表、转写和诊断录音后，在 Finder 删除 `~/Library/Application Support/TalkTalk`、`~/Library/Logs/TalkTalk`、`~/Library/Caches/TalkTalk`。还原记录也在第一个文件夹里，只有确认默认输入已是实体麦、TalkTalk 已退出后才删除。
5. 在“钥匙串访问”中删除服务名 `com.aaajiao.talktalk.openai` 或 `com.aaajiao.talktalk.dev.openai`、账户名 **api-key** 的 app 条目。仅删除明确属于此应用的条目。
6. 在系统设置的登录项中移除 TalkTalk；按需运行 `defaults delete com.aaajiao.talktalk`、`defaults delete com.aaajiao.talktalk.dev` 清理偏好，以及 `tccutil reset All com.aaajiao.talktalk` / `tccutil reset All com.aaajiao.talktalk.dev` 清理授权。不存在的条目报错可忽略。

手动步骤不能替代 app 的会议状态核验；先完成第 1 步，再删除驱动和还原记录。
