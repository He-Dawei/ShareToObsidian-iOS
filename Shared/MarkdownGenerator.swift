import Foundation

struct MarkdownDraft: Codable, Hashable {
    var summary: String
    var markdown: String
    var alternatives: [String]
    var tags: [String]
}

enum MarkdownGenerator {
    static func generate(url: URL, title: String, platform: CapturePlatform) -> MarkdownDraft {
        let tags = defaultTags(for: platform)
        let summary = "待提炼：已捕获来自\(platform.displayName)的分享链接，等待补充视频内容、口播转写和个人判断。"
        let markdown = makeMarkdown(
            title: title,
            url: url,
            platform: platform,
            summary: summary,
            tags: tags,
            style: "结构化重点"
        )

        return MarkdownDraft(
            summary: summary,
            markdown: markdown,
            alternatives: [
                makeMarkdown(title: title, url: url, platform: platform, summary: summary, tags: tags, style: "行动清单"),
                makeMarkdown(title: title, url: url, platform: platform, summary: summary, tags: tags, style: "知识卡片"),
                makeMarkdown(title: title, url: url, platform: platform, summary: summary, tags: tags, style: "问题驱动")
            ],
            tags: tags
        )
    }

    private static func makeMarkdown(
        title: String,
        url: URL,
        platform: CapturePlatform,
        summary: String,
        tags: [String],
        style: String
    ) -> String {
        let tagText = tags.map { "#\($0)" }.joined(separator: " ")
        let yamlTags = tags.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        ---
        title: "\(escape(title))"
        source: "\(platform.rawValue)"
        url: "\(url.absoluteString)"
        status: draft
        note_style: "\(style)"
        tags: [\(yamlTags)]
        ---

        # \(title)

        ## 核心内容

        \(summary)

        ## 视频介绍

        暂无自动简介。Windows 桥接器在线时会尝试补充标题、作者、简介、封面等元数据。

        ## 关键观点

        - 这条内容解决了什么问题：
        - 值得保留的观点：
        - 可迁移到学习、求职或项目的一点：

        ## 我的判断

        - 是否值得长期保存：
        - 和我当前目标的关系：
        - 需要二次验证的信息：

        ## 后续行动

        - [ ] 补充 3 句摘要
        - [ ] 标出可执行动作
        - [ ] 判断是否加入长期知识框架

        ## 自动标签

        \(tagText)

        ## 原始链接

        \(url.absoluteString)
        """
    }

    private static func defaultTags(for platform: CapturePlatform) -> [String] {
        var tags = ["移动收藏", "待提炼", platform.rawValue]
        if platform == .douyin || platform == .bilibili {
            tags.append("视频")
        }
        return tags
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
