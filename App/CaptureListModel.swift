import Foundation
import Observation

@MainActor
@Observable
final class CaptureListModel {
    var items: [CaptureItem] = []
    var bridgeAddress: String {
        didSet { CaptureSettingsStore.bridgeAddress = bridgeAddress }
    }
    var bridgeToken: String {
        didSet { CaptureSettingsStore.bridgeToken = bridgeToken }
    }
    var isSyncing = false
    private var syncAgainAfterCurrent = false
    var lastError: String?
    var lastStatusMessage: String?
    var lastHealth: BridgeHealth?
    var cloudRelayFolderName: String? = CloudRelayStore.folderName
    var cloudRelayError: String?

    init() {
        bridgeAddress = CaptureSettingsStore.bridgeAddress
        bridgeToken = CaptureSettingsStore.bridgeToken
        reload()
    }

    func reload() {
        guard CloudRelayStore.isConfigured else {
            items = CaptureFileStore.load()
            cloudRelayFolderName = nil
            return
        }
        do {
            items = try CaptureFileStore.reconcileCloudRelay()
            cloudRelayFolderName = CloudRelayStore.folderName
            cloudRelayError = nil
        } catch {
            items = CaptureFileStore.load()
            cloudRelayError = error.localizedDescription
        }
    }

    func clearLastError() {
        lastError = nil
        lastStatusMessage = nil
    }

    func add(urlText: String) -> Bool {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              SupportedShareURL.isSupported(url) else {
            lastError = "链接格式不正确"
            return false
        }
        do {
            var item = CaptureItem(url: url)
            item.status = .queued
            try CaptureFileStore.append(item)
            reload()
            lastStatusMessage = "已加入待同步队列"
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func handleDeepLink(_ url: URL) async {
        guard url.scheme?.lowercased() == "sharetoobsidian" else {
            lastError = "不支持的 App 链接"
            return
        }

        switch url.host?.lowercased() {
        case "pair":
            await importPairing(url: url)
            await syncIfPossible()
        case "capture", "add", "share":
            guard let payload = Self.capturePayload(from: url) else {
                lastError = "分享链接里没有可保存的 http/https 链接"
                return
            }
            do {
                let savedItem = try enqueue(url: payload.url, title: payload.title, sourceApp: "URL Scheme")
                reload()
                lastError = nil
                lastStatusMessage = "已从外部链接加入队列，正在同步"
                await syncQueued(prioritizedIDs: [savedItem.id])
            } catch {
                lastError = error.localizedDescription
            }
        default:
            lastError = "不支持的 App 链接"
        }
    }

    func createVerificationCapture() async {
        guard let url = URL(string: "https://example.com/share-to-obsidian-ios-verify"),
              SupportedShareURL.isSupported(url) else {
            lastError = "验收链接格式不正确"
            return
        }
        do {
            var item = CaptureItem(url: url, title: "ShareToObsidian iPhone 验收", sourceApp: "ShareToObsidian")
            item.summary = "用于验证 iPhone App 到 Windows Obsidian Bridge 的实时同步链路。"
            item.tags = ["iPhone验收", "ShareToObsidian"]
            item.status = .queued
            item.draftMarkdown = """
            # ShareToObsidian iPhone 验收

            ## 核心内容

            这是一条从 iPhone App 主程序发起的验收收藏，用于确认 App 可以把队列内容同步到 Windows Obsidian Bridge。

            ## 验收点

            - App 可以创建收藏
            - App 可以连接电脑桥接器
            - Obsidian `移动收藏` 文件夹可以收到笔记

            ## 原始链接

            https://example.com/share-to-obsidian-ios-verify
            """
            let savedItem = try CaptureFileStore.append(item)
            reload()
            lastStatusMessage = "已创建验收收藏，正在同步"
            await syncQueued(prioritizedIDs: [savedItem.id])
        } catch {
            lastError = error.localizedDescription
        }
    }

    func save(_ item: CaptureItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        var updated = item
        updated.updatedAt = Date()
        items[index] = updated
        persist()
    }

    func delete(_ offsets: IndexSet) async {
        let client = URL(string: bridgeAddress).map { SyncClient(bridgeBaseURL: $0, bearerToken: bridgeToken) }
        var deletedIDs = Set<UUID>()
        for offset in offsets.sorted(by: >) {
            let item = items[offset]
            if (item.status == .synced || item.status == .deleted),
               let remoteNotePath = item.remoteNotePath,
               !remoteNotePath.isEmpty {
                do {
                    guard let client else {
                        throw URLError(.badURL)
                    }
                    try await client.deleteRemoteNote(path: remoteNotePath)
                    items.remove(at: offset)
                    deletedIDs.insert(item.id)
                    try? CloudRelayStore.removeQueuedItem(id: item.id)
                } catch {
                    var pendingDelete = item
                    pendingDelete.status = .deleted
                    pendingDelete.syncError = error.localizedDescription
                    pendingDelete.lastSyncAttemptAt = Date()
                    pendingDelete.updatedAt = pendingDelete.lastSyncAttemptAt ?? Date()
                    items[offset] = pendingDelete
                    try? CloudRelayStore.enqueue(pendingDelete)
                    lastError = "已加入待删除队列：\(error.localizedDescription)"
                }
            } else if item.status == .deleted {
                lastError = "该条目正在等待删除远端笔记"
            } else {
                items.remove(at: offset)
                deletedIDs.insert(item.id)
                try? CloudRelayStore.removeQueuedItem(id: item.id)
            }
        }
        persist(deletedIDs: deletedIDs)
    }

    func delete(ids: [UUID]) async {
        let offsets = IndexSet(ids.compactMap { id in
            items.firstIndex { $0.id == id }
        })
        await delete(offsets)
    }

    func syncQueued() async {
        await syncQueued(prioritizedIDs: [])
    }

    func syncQueued(prioritizedIDs: [UUID]) async {
        if isSyncing {
            syncAgainAfterCurrent = true
            return
        }

        repeat {
            syncAgainAfterCurrent = false
            isSyncing = true

            let summary = await CaptureSyncRunner.syncQueued(
                bridgeAddress: bridgeAddress,
                bearerToken: bridgeToken,
                enrichSyncedMissingMetadata: true,
                prioritizedIDs: prioritizedIDs
            )
            reload()
            lastError = summary.lastError
            lastStatusMessage = syncStatusMessage(for: summary)
            isSyncing = false
        } while syncAgainAfterCurrent
    }

    func syncIfPossible() async {
        guard items.contains(where: { $0.status != .synced || shouldEnrichSyncedItem($0) }) else {
            return
        }
        await syncQueued()
    }

    func runForegroundSyncLoop() async {
        while !Task.isCancelled {
            reload()
            await refreshHealth()
            await syncIfPossible()

            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }

    func refreshHealth() async {
        guard let baseURL = URL(string: bridgeAddress) else {
            lastError = "电脑桥接地址无效"
            return
        }
        do {
            let client = SyncClient(bridgeBaseURL: baseURL, bearerToken: bridgeToken)
            lastHealth = try await client.health()
            lastError = nil
            lastStatusMessage = "桥接器在线"
        } catch {
            lastHealth = nil
            lastError = error.localizedDescription
        }
    }

    func importPairing(text: String) async {
        do {
            _ = try CaptureSettingsStore.applyPairingText(text)
            bridgeAddress = CaptureSettingsStore.bridgeAddress
            bridgeToken = CaptureSettingsStore.bridgeToken
            lastError = nil
            lastStatusMessage = "配对配置已导入"
            await refreshHealth()
        } catch {
            lastError = "配对配置无效：\(error.localizedDescription)"
        }
    }

    func importPairing(url: URL) async {
        do {
            _ = try CaptureSettingsStore.applyPairingURL(url)
            bridgeAddress = CaptureSettingsStore.bridgeAddress
            bridgeToken = CaptureSettingsStore.bridgeToken
            lastError = nil
            lastStatusMessage = "配对链接已导入"
            await refreshHealth()
        } catch {
            lastError = "配对链接无效：\(error.localizedDescription)"
        }
    }

    func configureCloudRelay(folderURL: URL) {
        do {
            try CloudRelayStore.configure(folderURL: folderURL)
            cloudRelayFolderName = CloudRelayStore.folderName
            cloudRelayError = nil
            for item in items where item.status != .synced {
                try CloudRelayStore.enqueue(item)
            }
            lastStatusMessage = "iCloud 离线中转已启用"
        } catch {
            cloudRelayError = error.localizedDescription
        }
    }

    func clearCloudRelay() {
        CloudRelayStore.clear()
        cloudRelayFolderName = nil
        cloudRelayError = nil
        lastStatusMessage = "iCloud 离线中转已关闭"
    }

    func createCloudRelayVerificationCapture() {
        guard CloudRelayStore.isConfigured,
              let url = URL(string: "https://example.com/share-to-obsidian-icloud-relay-verify") else {
            cloudRelayError = "请先选择 iCloud 中转文件夹"
            return
        }
        do {
            var item = CaptureItem(url: url, title: "ShareToObsidian iCloud 离线验收", sourceApp: "iCloud Relay Verification")
            item.summary = "验证电脑关机期间由 iCloud 保存，Windows 开机后自动写入 Obsidian。"
            item.tags = ["iCloud验收", "ShareToObsidian"]
            item.status = .queued
            item.isUserEdited = true
            item.draftMarkdown = """
            # ShareToObsidian iCloud 离线验收

            ## 核心内容

            该条目只写入 iCloud 中转队列，不通过局域网直连，用于验证 Windows Bridge 开机主动消费离线收藏。

            ## 原始链接

            https://example.com/share-to-obsidian-icloud-relay-verify
            """
            let savedItem = try CaptureFileStore.append(item)
            try CloudRelayStore.enqueue(savedItem)
            reload()
            cloudRelayError = nil
            lastStatusMessage = "iCloud 离线验收已发送"
        } catch {
            cloudRelayError = error.localizedDescription
        }
    }

    func regenerateDrafts(for item: CaptureItem) async -> CaptureItem {
        guard let baseURL = URL(string: bridgeAddress) else {
            lastError = "电脑桥接地址无效"
            return item
        }
        do {
            let client = SyncClient(bridgeBaseURL: baseURL, bearerToken: bridgeToken)
            let draft = try await client.generateDrafts(for: item)
            var updated = item
            updated.summary = draft.summary
            updated.draftMarkdown = draft.markdown
            updated.alternativeDrafts = draft.alternatives
            updated.tags = draft.tags
            updated.status = .queued
            updated.isUserEdited = false
            updated.updatedAt = Date()
            save(updated)
            lastError = nil
            lastStatusMessage = "已生成新文案，等待同步"
            return updated
        } catch {
            lastError = error.localizedDescription
            return item
        }
    }

    func refreshMetadata(for item: CaptureItem) async -> CaptureItem {
        guard let baseURL = URL(string: bridgeAddress) else {
            lastError = "电脑桥接地址无效"
            return item
        }
        do {
            let client = SyncClient(bridgeBaseURL: baseURL, bearerToken: bridgeToken)
            var updated = try await client.refreshMetadata(for: item)
            updated.status = .queued
            updated.syncError = nil
            updated.lastMetadataRefreshAttemptAt = Date()
            updated.updatedAt = Date()
            save(updated)
            lastError = nil
            lastStatusMessage = "视频信息已刷新，等待同步"
            return updated
        } catch {
            lastError = error.localizedDescription
            return item
        }
    }

    @discardableResult
    private func enqueue(url: URL, title: String, sourceApp: String?) throws -> CaptureItem {
        var item = CaptureItem(url: url, title: title, sourceApp: sourceApp)
        item.status = .queued
        item.syncError = nil
        return try CaptureFileStore.append(item)
    }

    private func persist(deletedIDs: Set<UUID> = []) {
        do {
            let snapshot = items
            try CaptureFileStore.update { latestItems in
                mergeCurrentSnapshot(snapshot, into: latestItems, deletedIDs: deletedIDs)
            }
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func mergeCurrentSnapshot(
        _ snapshot: [CaptureItem],
        into latestItems: [CaptureItem],
        deletedIDs: Set<UUID>
    ) -> [CaptureItem] {
        let snapshotByID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        var emittedIDs = Set<UUID>()

        var merged = latestItems.compactMap { latestItem -> CaptureItem? in
            if deletedIDs.contains(latestItem.id) {
                emittedIDs.insert(latestItem.id)
                return nil
            }
            if let snapshotItem = snapshotByID[latestItem.id] {
                emittedIDs.insert(latestItem.id)
                return snapshotItem.updatedAt >= latestItem.updatedAt ? snapshotItem : latestItem
            }
            emittedIDs.insert(latestItem.id)
            return latestItem
        }

        for snapshotItem in snapshot where !emittedIDs.contains(snapshotItem.id) {
            merged.append(snapshotItem)
        }
        return merged
    }

    private func shouldEnrichSyncedItem(_ item: CaptureItem) -> Bool {
        guard item.status == .synced,
              item.metadata == nil,
              let remoteNotePath = item.remoteNotePath,
              !remoteNotePath.isEmpty else {
            return false
        }
        return true
    }

    private func syncStatusMessage(for summary: CaptureSyncSummary) -> String? {
        if summary.syncedCount > 0 {
            return "已同步 \(summary.syncedCount) 条，待同步 \(summary.queuedCount) 条"
        }
        if summary.queuedCount > 0 {
            return "还有 \(summary.queuedCount) 条等待同步"
        }
        return "没有待同步内容"
    }

    private static func capturePayload(from url: URL) -> (url: URL, title: String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let queryItems = components.queryItems ?? []
        let title = firstQueryValue(named: "title", in: queryItems) ?? ""

        for name in ["url", "link"] {
            if let value = firstQueryValue(named: name, in: queryItems),
               let capturedURL = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
               SupportedShareURL.isSupported(capturedURL) {
                return (capturedURL, title)
            }
        }

        if let text = firstQueryValue(named: "text", in: queryItems),
           let capturedURL = firstSupportedURL(in: text) {
            let fallbackTitle = title.isEmpty ? firstNonURLLine(in: text) : title
            return (capturedURL, fallbackTitle)
        }

        return nil
    }

    private static func firstQueryValue(named name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func firstSupportedURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?
            .matches(in: text, range: range)
            .compactMap(\.url)
            .first(where: { SupportedShareURL.isSupported($0) })
    }

    private static func firstNonURLLine(in text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && firstSupportedURL(in: $0) == nil } ?? ""
    }
}
