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
    var lastHealth: BridgeHealth?

    init() {
        bridgeAddress = CaptureSettingsStore.bridgeAddress
        bridgeToken = CaptureSettingsStore.bridgeToken
        reload()
    }

    func reload() {
        items = CaptureFileStore.load()
    }

    func clearLastError() {
        lastError = nil
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
            return true
        } catch {
            lastError = error.localizedDescription
            return false
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
                } catch {
                    var pendingDelete = item
                    pendingDelete.status = .deleted
                    pendingDelete.syncError = error.localizedDescription
                    pendingDelete.lastSyncAttemptAt = Date()
                    pendingDelete.updatedAt = pendingDelete.lastSyncAttemptAt ?? Date()
                    items[offset] = pendingDelete
                    lastError = "已加入待删除队列：\(error.localizedDescription)"
                }
            } else if item.status == .deleted {
                lastError = "该条目正在等待删除远端笔记"
            } else {
                items.remove(at: offset)
                deletedIDs.insert(item.id)
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
                enrichSyncedMissingMetadata: true
            )
            reload()
            lastError = summary.lastError
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
            await refreshHealth()
        } catch {
            lastError = "配对链接无效：\(error.localizedDescription)"
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
            return updated
        } catch {
            lastError = error.localizedDescription
            return item
        }
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
}
