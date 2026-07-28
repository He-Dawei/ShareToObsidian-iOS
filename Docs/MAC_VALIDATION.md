# Mac 验证清单

## 编译

```bash
cd outputs/share-to-obsidian-ios
chmod +x Scripts/verify_mac_ios_project.sh
./Scripts/verify_mac_ios_project.sh
```

该脚本会检查：

- App 与 Share Extension 都启用同一个 App Group。
- App 声明 Background fetch 与 BGTask identifier。
- App 注册 `sharetoobsidian://pair` 配对 URL Scheme。
- App 与 Share Extension 都声明 Local Network 权限说明。
- Share Extension 类型为 `com.apple.share-services`。
- XcodeGen 能生成工程。
- iOS Simulator Debug 构建成功。
- 构建产物内嵌 Share Extension。
- 主 App 和 Share Extension Bundle ID 正确。

## 真机 Build 验证

如果 Mac 已登录 Apple Developer Team，并且 Xcode 签名配置可用，执行：

```bash
cd outputs/share-to-obsidian-ios
DEVELOPMENT_TEAM=你的TeamID VERIFY_DEVICE=1 ./Scripts/verify_mac_ios_project.sh
```

指定具体设备：

```bash
DEVELOPMENT_TEAM=你的TeamID VERIFY_DEVICE=1 DEVICE_DESTINATION='platform=iOS,id=设备UDID' ./Scripts/verify_mac_ios_project.sh
```

真机 build 通过后，再做下面的手工分享链路验收。

## 真机配置

- 主 App Bundle ID: `com.hdwei.ShareToObsidian`
- Share Extension Bundle ID: `com.hdwei.ShareToObsidian.ShareExtension`
- App Group: `group.com.hdwei.ShareToObsidian`
- 主 App Capability:
  - App Groups
  - Background Modes: Background fetch
- Share Extension Capability:
  - App Groups

## 真机验收

1. 在 Windows 执行 `Bridge/export_pairing_for_iphone.ps1`，把剪贴板里的 `sharetoobsidian://pair?...` 深链发到自己的 iPhone 并打开。
2. App 应自动导入 Windows Bridge URL / Token，并显示桥接器在线。
3. 备用方式：在 App 设置页填入 Windows Bridge URL，或粘贴 `pairing.iphone.json` 到“快速配对”并导入。
4. 在 Windows 仓库目录运行 `Scripts/wait_for_iphone_verification.ps1`，然后在 App “同步设置”点“发送验收收藏”。
5. Windows 脚本应输出 `IPHONE_VERIFICATION_OK`，Obsidian 应出现 `ShareToObsidian iPhone 验收` 笔记。
6. 从抖音/B站/网页分享链接到 `ShareToObsidian`。
7. 如果 Windows Bridge 在线，分享扩展应直接用 fast 模式尝试同步；Obsidian 可在不手动打开 App 的情况下出现新笔记。
8. 回到 App，列表应出现新收藏，并显示同步状态。
9. 进入详情页，刷新视频信息，应看到作者/频道、简介、时长、播放/点赞、封面链接等可用字段。
10. 确认可以编辑 Markdown，并可重新生成 3 种文案。
11. 点同步，Windows Obsidian 应出现新笔记。
12. 删除已同步收藏，Obsidian 对应笔记和原始 JSON 应移动到 `移动收藏/80_Trash/`。
13. 关闭 Windows Bridge 后再分享一条，App 应保留为待同步。
14. 恢复 Windows Bridge，App 前台/回前台/后台刷新触发后应补同步。

## 注意

iOS Background App Refresh 由系统调度，不能保证电脑开机瞬间触发。可靠路径是：App 前台、回到前台、手动同步；后台刷新是额外补偿机制。
