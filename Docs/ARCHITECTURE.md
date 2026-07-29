# 架构设计

## 为什么取消旧方案

旧方案依赖定时打开抖音收藏页、滚动读取、下载视频、转写，再写入 Obsidian。缺陷：

- 不实时；
- 页面懒加载和登录状态不稳定；
- 平台反爬会影响成功率；
- 只能覆盖抖音收藏夹；
- 用户无法在入库前修改笔记质量。

## 新方案

新方案以“分享动作为入口”：

```mermaid
flowchart LR
    A["抖音/B站/网页分享"] --> B["iOS Share Extension"]
    B --> C["App Group 本地队列"]
    C --> D["ShareToObsidian App"]
    D --> E["预生成 Markdown 草稿"]
    E --> F["用户编辑/切换文案/删除"]
    F --> G{"电脑在线?"}
    G -->|"是"| H["Windows Obsidian Bridge"]
    G -->|"否"| I["App 本地队列"]
    I --> L["iCloud Drive 中转"]
    L --> H
    H --> J["Obsidian/移动收藏"]
    J --> K["知识框架索引"]
```

## 模块职责

- Share Extension：接收外部分享链接，尽快入队，不做重处理。
- iOS App：展示队列、编辑草稿、删除、手动同步。
- MarkdownGenerator：生成 Obsidian 初稿和多个版本。
- SyncEngine：向电脑桥接器同步，失败则保留队列。
- Windows Bridge：接收局域网请求或消费 iCloud 队列；后台补充网页/视频元数据和 AI 文案，写入 Obsidian，并更新知识框架、平台、标签索引。

## 同步策略

优先级：

1. 局域网实时同步：App POST 到 `http://电脑IP:8765/captures`。
2. iCloud 离线中转：电脑不在线时，App 保留 `queued` 状态并写入用户选择的 iCloud 文件夹。
3. 开机补同步：Windows 桥接器登录启动后主动消费 iCloud `Queue/`，无需等待 iOS 再次后台唤醒。
4. 本地兜底：未配置 iCloud 时，App 前台、后台刷新或手动同步继续重试。

后续可增强：

- CloudKit 私有数据库；
- Tailscale/ZeroTier 内网穿透；
- 更深层的本地 LLM 主题聚类和跨笔记关系推理。
