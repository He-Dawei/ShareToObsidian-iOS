# ShareToObsidian iOS

目标：替代旧的“凌晨自动读取抖音收藏夹”方案，改成主动分享触发。

核心流程：

1. 在抖音、哔哩哔哩、小红书、网页等平台点“分享”。
2. 选择 iOS 分享扩展 `ShareToObsidian`。
3. App 保存链接，识别平台，生成 Obsidian Markdown 草稿。
4. 用户在 App 内查看、切换不同文案版本、编辑、删除。
5. 电脑在线时实时 POST 到 Windows 桥接器写入 Obsidian。
6. 电脑离线时保留本地队列；启用 iCloud 中转后，Windows 开机即可主动消费队列，不依赖再次唤醒 App。

当前已落地内容：

- iOS App SwiftUI 源码骨架
- iOS Share Extension 源码骨架
- App Group 队列模型
- Markdown 草稿生成器
- 多平台链接识别
- Windows Obsidian bridge
- 桥接器自动补元数据：抖音/B站等视频优先走 yt-dlp，普通网页/微信文章优先走 Defuddle 提取干净 Markdown 正文，失败不阻塞入库
- yt-dlp 使用稳定安装目录并可读取登录 cookie，不再依赖会被清理的 Codex runtime 缓存
- 同一链接会去掉 `utm_*`、`spm_id_from`、`vd_source` 等追踪参数后查重，避免重复入库
- App 启动和回到前台时自动检查桥接器并补同步待处理队列
- App 进入后台时注册 iOS Background App Refresh，同步失败队列会在系统允许的后台唤醒中继续重试
- App 支持保存 Bridge URL / Token，并可手动检查连接
- Windows 可生成 `sharetoobsidian://pair?...` 深链和 `pairing.iphone.json`，App 可点链接或粘贴导入，避免手填局域网 IP
- App 设置页可发送一条固定验收收藏，用于验证 iPhone 到 Windows Obsidian Bridge 的同步链路
- App 详情页可调用 Bridge `/metadata` 刷新视频信息，并展示作者、简介、时长、播放/点赞、封面链接
- App 可调用桥接器 `/drafts` 重新生成 3 种 Obsidian 文案版本
- Share Extension 保存分享后会用 fast 模式立即尝试同步；Bridge 快速确认入库后在后台继续提取正文/字幕、生成 AI 文案并原路径更新
- App 回到前台会从 Bridge 拉取后台完成的最新条目，避免本地占位稿覆盖已精炼笔记
- 可选择 `iCloud Drive/ShareToObsidian` 作为离线中转目录；电脑关机期间的分享会写入 `Queue/`，Windows Bridge 登录启动后自动处理并把结果写入 `Processed/`
- App 删除已同步内容时会调用 Bridge 把 Obsidian 笔记和原始 JSON 移入 `80_Trash`
- 桥接器支持 OpenAI/Anthropic 兼容的 AI 文案生成；DeepSeek 可直接读取 `ANTHROPIC_BASE_URL`、`ANTHROPIC_MODEL`、`ANTHROPIC_AUTH_TOKEN`，失败时自动回退本地模板
- AI 生成标签时优先复用 Vault 已有标签，减少知识分类不断分叉
- Obsidian 自动维护 `收藏知识框架.md`、`平台索引.md`、`标签索引.md`
- Obsidian 自动生成 `收藏主题地图.md`、`收藏复习问题.md`、`收藏行动池.md`
- 收藏目录自动维护 `AGENTS.md` 与 `CLAUDE.md`，让 Codex/Claude 使用同一个 `AI学习上下文.md` 入口
- XcodeGen `project.yml`

当前没有保留旧凌晨任务；旧任务 `DouyinFavoritesToObsidian` 已注销。

## Mac 上生成工程

先在 Windows 导出干净的 Mac 构建包：

```powershell
cd C:\Users\44527\Documents\Codex\2026-07-24\codex-reconnecting-codex-env-3\outputs\share-to-obsidian-ios
powershell -ExecutionPolicy Bypass -File .\Scripts\export_mac_build_package.ps1
```

该包默认输出到 `E:\claude code生成文件\`，只包含 iOS 源码、XcodeGen 配置、Mac 验证脚本和文档，不包含 Bridge token、pairing 文件、Python 缓存或本机数据。

把 zip 解压到 Mac 后：

```bash
cd share-to-obsidian-ios
brew install xcodegen
chmod +x Scripts/verify_mac_ios_project.sh
./Scripts/verify_mac_ios_project.sh
```

需要在 Xcode 中设置：

- Team / Signing
- App Group: `group.com.hdwei.ShareToObsidian`
- 主 App 和 Share Extension 都启用同一个 App Group

## Windows 桥接器

桥接器负责把 iOS 发来的 JSON 写入本机 Obsidian vault。

```powershell
cd C:\Users\44527\Documents\Codex\2026-07-24\codex-reconnecting-codex-env-3\outputs\share-to-obsidian-ios\Bridge
python .\obsidian_bridge.py --config .\bridge.config.json
```

`Bridge\bridge.config.json`、`Bridge\pairing.*` 都包含本机路径或 Bridge Token，只保留在本机，不提交到 Git。新环境先复制示例配置：

```powershell
copy .\Bridge\bridge.config.example.json .\Bridge\bridge.config.json
cd .\Bridge
.\write_pairing_config.ps1 -RotateToken
.\export_pairing_for_iphone.ps1
```

正文提取依赖：

```powershell
npm install -g defuddle
```

Windows 版 yt-dlp 建议放到稳定路径，例如：

```text
C:\Users\44527\tools\yt-dlp\yt-dlp.exe
```

处理顺序保持轻量优先：平台原生元数据/字幕 → Defuddle 网页正文 → 本地模板；只有没有字幕且确实需要口播全文时，再启用本地语音转写。

## 当前手机配对方式

Windows Bridge 运行后，iPhone 和电脑在同一局域网时，直接在 iPhone Safari 打开：

```text
http://192.168.1.104:8765/pair
```

页面会显示 ShareToObsidian 配对按钮。点击后 App 会导入 Bridge URL 和 Token。
如果电脑 IP 变化，先在 Windows 执行：

```powershell
cd C:\Users\44527\ios-project\Bridge
.\export_pairing_for_iphone.ps1
```

然后用输出的 `Bridge URL`，把末尾改成 `/pair`。该页面包含 Bridge Token，只在自己的 iPhone 上打开。

## 分享扩展验收

`ShareToObsidian-standalone.ipa` 只用于验证主 App 内同步，不包含系统分享入口。
要验证“抖音/哔哩哔哩/Safari 分享面板 -> Save to Obsidian”，安装 full IPA：

```text
E:\claude code生成文件\ShareToObsidian-full-runXX.ipa
```

安装 full IPA 后，在 Windows 运行：

```powershell
cd C:\Users\44527\ios-project
powershell -ExecutionPolicy Bypass -File .\Scripts\wait_for_share_extension_verification.ps1
```

脚本开始等待后，在 iPhone Safari 打开或输入：

```text
https://example.com/share-to-obsidian-share-extension-verify
```

点系统分享按钮，选择 `Save to Obsidian`。Windows 端出现 `SHARE_EXTENSION_VERIFICATION_OK` 即表示分享扩展链路已通过。

## SideStore 安装 standalone

当前 Windows 路线：

1. Codex 改代码并推送到 GitHub。
2. GitHub Actions 的 macOS runner 构建 `ShareToObsidian-standalone.ipa`。
3. 下载 latest standalone：

```powershell
cd C:\Users\44527\ios-project
powershell -ExecutionPolicy Bypass -File .\Scripts\download_latest_standalone.ps1
```

4. 把 `E:\claude code生成文件\ShareToObsidian-standalone-latest.ipa` 传到 iPhone。
5. 用 SideStore 安装。免费签名 7 天有效，iPhone 和电脑同 WiFi 时由 SideStore 自动续签。

说明：Windows 不支持 AirDrop。可用 iCloud Drive、微信文件传输、LocalSend、数据线文件共享等方式把 IPA 传到 iPhone。

standalone 版本不包含原生系统分享扩展，但内置 App Intent 和 URL Scheme，可以配合 iOS 快捷指令从分享面板保存链接。

推荐用内置 App Intent：

1. 打开 ShareToObsidian 的“同步”页，点“快捷指令”。
2. 在快捷指令中使用 `保存到 Obsidian` 动作。
3. 把动作的“链接或分享文本”设为“快捷指令输入”。
4. 打开快捷指令详情，启用“在共享表单中显示”，接收 URL 和文本。

之后在抖音、哔哩哔哩、Safari 等平台点分享，选择这个快捷指令即可。动作会提取分享内容里的第一个 http/https 链接，写入离线队列，并立即尝试同步。

URL Scheme：

```text
sharetoobsidian://capture?url=https%3A%2F%2Fexample.com%2Fvideo&title=%E6%A0%87%E9%A2%98
```

也支持：

```text
sharetoobsidian://add?url=...
sharetoobsidian://share?text=...
```

URL Scheme 备用快捷指令：

1. 新建快捷指令，开启“在共享表单中显示”。
2. 接收“URL”和“文本”。
3. 对分享输入执行“URL 编码”。
4. 打开 URL：`sharetoobsidian://capture?url=编码后的输入`。

触发后 App 会把链接加入待同步队列，并立即尝试同步到 Windows Bridge。电脑离线时保留队列，之后打开 App 会继续同步。

默认 Obsidian 输出目录：

`E:\44527\Documents\claude仓库\移动收藏`

桥接器已注册为 Windows 登录启动任务：

```text
ShareToObsidianBridge
```

放行 Windows 防火墙，让 iPhone 可访问局域网 Bridge：

```powershell
cd C:\Users\44527\Documents\Codex\2026-07-24\codex-reconnecting-codex-env-3\outputs\share-to-obsidian-ios\Bridge
.\ensure_firewall_rule.ps1
```

健康检查：

```text
http://127.0.0.1:8765/health
```

## iCloud 离线中转

Windows 已使用以下目录作为电脑离线兜底：

```text
C:\Users\44527\iCloudDrive\ShareToObsidian
```

iPhone 安装新版后，在“同步设置”→“电脑离线中转”中选择 iCloud Drive 里的 `ShareToObsidian` 文件夹一次。之后：

1. 局域网 Bridge 在线时仍直接实时同步。
2. Bridge 不在线时，App/分享入口把 JSON 写入 iCloud `Queue/`。
3. Windows 开机登录后，`ShareToObsidianBridge` 自动消费队列并生成完整 Obsidian 笔记。
4. App 下次打开时读取 `Processed/`，显示远端元数据、AI 文案和同步状态。

Windows 端一键验收：

```powershell
cd C:\Users\44527\Documents\Codex\2026-07-24\codex-reconnecting-codex-env-3\outputs\share-to-obsidian-ios
powershell -ExecutionPolicy Bypass -File .\Scripts\verify_windows_bridge.ps1
```

该脚本会检查旧定时任务已取消、新 Bridge 任务正在运行、认证生效、fast 入库/删除链路可用，并做 iOS 项目静态结构检查。

iPhone 真机同步验收：

```powershell
cd C:\Users\44527\ios-project
powershell -ExecutionPolicy Bypass -File .\Scripts\wait_for_iphone_verification.ps1
```

脚本开始等待后，在 iPhone App 的“同步设置”点“发送验收收藏”。电脑端看到 `IPHONE_VERIFICATION_OK` 即表示 iPhone 已通过 Windows Bridge 写入 Obsidian。

生成手机配对配置：

```powershell
cd C:\Users\44527\Documents\Codex\2026-07-24\codex-reconnecting-codex-env-3\outputs\share-to-obsidian-ios\Bridge
.\export_pairing_for_iphone.ps1
```

脚本会写入：

```text
Bridge\pairing.iphone.json
Bridge\pairing.iphone.url.txt
Bridge\pairing.iphone.html
E:\44527\Documents\claude仓库\移动收藏\pairing.iphone.json
E:\44527\Documents\claude仓库\移动收藏\pairing.iphone.html
```

它还会把 `sharetoobsidian://pair?...` 配对深链复制到 Windows 剪贴板。把这个链接发到自己的 iPhone 并打开，App 会自动导入 Bridge URL / Token 并检查连接。也可以打开 `pairing.iphone.html`，点击里面的配对按钮。

如果不方便打开深链，也可以把 `pairing.iphone.json` 粘贴到 iPhone App 的“同步设置”→“快速配对”，点“导入配对配置”，再点“检查连接”。

`pairing.iphone.json`、`pairing.iphone.url.txt` 和 `pairing.iphone.html` 都包含 Bridge Token，只发给自己的 iPhone，不要公开分享。需要更换 token 时：

```powershell
.\write_pairing_config.ps1 -RotateToken
.\export_pairing_for_iphone.ps1
```
