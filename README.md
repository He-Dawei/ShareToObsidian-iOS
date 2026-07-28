# ShareToObsidian iOS

目标：替代旧的“凌晨自动读取抖音收藏夹”方案，改成主动分享触发。

核心流程：

1. 在抖音、哔哩哔哩、小红书、网页等平台点“分享”。
2. 选择 iOS 分享扩展 `ShareToObsidian`。
3. App 保存链接，识别平台，生成 Obsidian Markdown 草稿。
4. 用户在 App 内查看、切换不同文案版本、编辑、删除。
5. 电脑在线时实时 POST 到 Windows 桥接器写入 Obsidian。
6. 电脑离线时保留在 App 待同步队列，之后再次打开 App 或电脑桥接器恢复时补同步。

当前已落地内容：

- iOS App SwiftUI 源码骨架
- iOS Share Extension 源码骨架
- App Group 队列模型
- Markdown 草稿生成器
- 多平台链接识别
- Windows Obsidian bridge
- 桥接器自动补元数据：标题、作者/频道、简介、封面、播放量等，失败不阻塞入库
- App 启动和回到前台时自动检查桥接器并补同步待处理队列
- App 进入后台时注册 iOS Background App Refresh，同步失败队列会在系统允许的后台唤醒中继续重试
- App 支持保存 Bridge URL / Token，并可手动检查连接
- Windows 可生成 `sharetoobsidian://pair?...` 深链和 `pairing.iphone.json`，App 可点链接或粘贴导入，避免手填局域网 IP
- App 设置页可发送一条固定验收收藏，用于验证 iPhone 到 Windows Obsidian Bridge 的同步链路
- App 详情页可调用 Bridge `/metadata` 刷新视频信息，并展示作者、简介、时长、播放/点赞、封面链接
- App 可调用桥接器 `/drafts` 重新生成 3 种 Obsidian 文案版本
- Share Extension 保存分享后会用 fast 模式立即尝试同步最多 3 条待处理队列；fast 模式跳过耗时元数据提取，电脑不在线时保留队列，之后由 App 补同步
- App 删除已同步内容时会调用 Bridge 把 Obsidian 笔记和原始 JSON 移入 `80_Trash`
- 桥接器支持可选 AI 文案生成：配置 `OPENAI_API_KEY` 并开启 `ai.enabled` 后使用 AI；未配置时自动回退本地模板
- Obsidian 自动维护 `收藏知识框架.md`、`平台索引.md`、`标签索引.md`
- Obsidian 自动生成 `收藏主题地图.md`、`收藏复习问题.md`、`收藏行动池.md`
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

Windows 端一键验收：

```powershell
cd C:\Users\44527\Documents\Codex\2026-07-24\codex-reconnecting-codex-env-3\outputs\share-to-obsidian-ios
powershell -ExecutionPolicy Bypass -File .\Scripts\verify_windows_bridge.ps1
```

该脚本会检查旧定时任务已取消、新 Bridge 任务正在运行、认证生效、fast 入库/删除链路可用，并做 iOS 项目静态结构检查。

生成手机配对配置：

```powershell
cd C:\Users\44527\Documents\Codex\2026-07-24\codex-reconnecting-codex-env-3\outputs\share-to-obsidian-ios\Bridge
.\export_pairing_for_iphone.ps1
```

脚本会写入：

```text
Bridge\pairing.iphone.json
Bridge\pairing.iphone.url.txt
E:\44527\Documents\claude仓库\移动收藏\pairing.iphone.json
```

它还会把 `sharetoobsidian://pair?...` 配对深链复制到 Windows 剪贴板。把这个链接发到自己的 iPhone 并打开，App 会自动导入 Bridge URL / Token 并检查连接。

如果不方便打开深链，也可以把 `pairing.iphone.json` 粘贴到 iPhone App 的“同步设置”→“快速配对”，点“导入配对配置”，再点“检查连接”。

`pairing.iphone.json` 和 `pairing.iphone.url.txt` 都包含 Bridge Token，只发给自己的 iPhone，不要公开分享。需要更换 token 时：

```powershell
.\write_pairing_config.ps1 -RotateToken
.\export_pairing_for_iphone.ps1
```
