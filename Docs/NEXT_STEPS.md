# 下一步

## 需要在 Mac 上完成

1. 安装 Xcode。
2. 安装 XcodeGen。
3. 在 `outputs/share-to-obsidian-ios` 执行：

```bash
chmod +x Scripts/verify_mac_ios_project.sh
./Scripts/verify_mac_ios_project.sh
```

4. 打开工程并配置签名：

```bash
open ShareToObsidian.xcodeproj
```

   - 主 App Bundle ID: `com.hdwei.ShareToObsidian`
   - Share Extension Bundle ID: `com.hdwei.ShareToObsidian.ShareExtension`
   - App Group: `group.com.hdwei.ShareToObsidian`

5. 真机安装后，在抖音/B站/网页分享面板选择 `Save to Obsidian`。

完整验收清单见 `Docs/MAC_VALIDATION.md`。

## 需要确认的配置

- iPhone 和电脑在同一局域网时，把 App 的 Bridge URL 改成：

```text
http://电脑局域网IP:8765
```

- 或者在 Windows 执行：

```powershell
cd C:\Users\44527\Documents\Codex\2026-07-24\codex-reconnecting-codex-env-3\outputs\share-to-obsidian-ios\Bridge
.\write_pairing_config.ps1
```

然后把 `pairing.local.json` 内容粘贴到 App 设置页的“快速配对”里导入。
`pairing.local.json` 包含 Bridge Token，只用于自己的 iPhone；如需换 token，执行 `.\write_pairing_config.ps1 -RotateToken` 后重新导入。

- Windows 防火墙可能需要允许 Python 入站访问 `8765`。

## 已完成的 Windows 端

- 旧任务 `DouyinFavoritesToObsidian` 已取消。
- 新任务 `ShareToObsidianBridge` 已注册为登录启动。
- 桥接器当前健康检查通过：
- 桥接器会写入 `10_Notes/`、保留 `00_Inbox/` 原始 JSON，并维护 `90_Knowledge/收藏知识框架.md`、`平台索引.md`、`标签索引.md`。
- 桥接器会自动生成 `90_Knowledge/收藏主题地图.md`、`收藏复习问题.md`、`收藏行动池.md`，供 Codex/Claude 后续读取。
- 桥接器会调用本机 `yt-dlp` 尝试补标题、作者/频道、简介、封面等元数据；失败不阻塞笔记创建。
- App 已支持自动补同步、后台刷新重试、桥接器健康检查、Bridge Token、重新生成 3 种文案版本。
- Share Extension 保存分享后会用 fast 模式立即尝试同步最多 3 条待处理队列；fast 模式跳过耗时元数据提取，详情页仍可手动刷新视频信息。
- App 已支持粘贴导入 Windows 生成的 `pairing.local.json`。
- App 详情页已支持刷新并查看结构化视频信息。
- App 删除已同步收藏时，Bridge 会把 Obsidian 笔记和原始 JSON 移入 `80_Trash`，并刷新知识框架。
- `/drafts` 支持可选 AI 生成：设置环境变量 `OPENAI_API_KEY` 并把 `bridge.config.json` 里的 `ai.enabled` 改为 `true` 后启用；未启用时使用本地模板兜底。
- Bridge POST 接口已启用 Bearer Token；App 通过 `pairing.local.json` 导入 token 后同步。

```text
http://127.0.0.1:8765/health
```

## 后续增强

- 在 Mac/Xcode 上真机编译验证 Share Extension。
- 在真机设置里确认 `Background App Refresh` 已开启；iOS 后台同步由系统调度，不能保证电脑一开机立即触发，但 App 前台、回到前台和后台唤醒都会补同步。
- 增加 iCloud/CloudKit 队列，电脑离线时不依赖局域网。
- 加一个定时复盘任务，让 Codex/Claude 定期读取 `移动收藏` 文件夹并继续细化知识图谱。
