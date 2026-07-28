import Foundation

enum CapturePlatform: String, Codable, CaseIterable, Identifiable {
    case douyin
    case bilibili
    case xiaohongshu
    case wechat
    case web
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .douyin: "抖音"
        case .bilibili: "哔哩哔哩"
        case .xiaohongshu: "小红书"
        case .wechat: "微信"
        case .web: "网页"
        case .unknown: "未知"
        }
    }
}

enum CaptureStatus: String, Codable {
    case draft
    case queued
    case synced
    case failed
    case deleted

    var displayName: String {
        switch self {
        case .draft: "草稿"
        case .queued: "待同步"
        case .synced: "已同步"
        case .failed: "同步失败"
        case .deleted: "待删除"
        }
    }
}

struct CaptureItem: Identifiable, Codable, Hashable {
    var id: UUID
    var url: URL
    var platform: CapturePlatform
    var title: String
    var summary: String
    var draftMarkdown: String
    var alternativeDrafts: [String]
    var tags: [String]
    var status: CaptureStatus
    var isUserEdited: Bool?
    var remoteNotePath: String?
    var metadata: CaptureMetadata?
    var syncError: String?
    var lastSyncAttemptAt: Date?
    var lastSyncedAt: Date?
    var lastMetadataRefreshAttemptAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var sourceApp: String?

    init(url: URL, title: String = "", sourceApp: String? = nil) {
        let platform = PlatformDetector.detect(url: url)
        let baseTitle = title.isEmpty ? platform.displayName + "收藏内容" : title
        let generated = MarkdownGenerator.generate(url: url, title: baseTitle, platform: platform)

        self.id = UUID()
        self.url = url
        self.platform = platform
        self.title = baseTitle
        self.summary = generated.summary
        self.draftMarkdown = generated.markdown
        self.alternativeDrafts = generated.alternatives
        self.tags = generated.tags
        self.status = .draft
        self.isUserEdited = false
        self.remoteNotePath = nil
        self.metadata = nil
        self.syncError = nil
        self.lastSyncAttemptAt = nil
        self.lastSyncedAt = nil
        self.lastMetadataRefreshAttemptAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.sourceApp = sourceApp
    }
}
