import Foundation

struct CaptureSyncSummary: Hashable {
    var syncedCount: Int
    var queuedCount: Int
    var lastError: String?
}

enum CaptureSyncRunner {
    static func syncQueued(
        bridgeAddress: String,
        bearerToken: String,
        maxItems: Int? = nil,
        fast: Bool = false,
        enrichSyncedMissingMetadata: Bool = false,
        prioritizedIDs: [UUID] = []
    ) async -> CaptureSyncSummary {
        let originalItems = CaptureFileStore.load()
        var items = prioritize(originalItems, ids: prioritizedIDs)
        guard let baseURL = URL(string: bridgeAddress) else {
            let errorMessage = "电脑桥接地址无效"
            let attemptedAt = Date()
            for index in items.indices where items[index].status != .synced {
                if items[index].status != .deleted {
                    items[index].status = .queued
                }
                items[index].lastSyncAttemptAt = attemptedAt
                items[index].syncError = errorMessage
                items[index].updatedAt = attemptedAt
            }
            var finalItems = items
            try? CaptureFileStore.update { latestItems in
                let merged = reconcileWithLatestStore(originalItems: originalItems, workingItems: items, latestItems: latestItems)
                finalItems = merged
                return merged
            }
            let queuedCount = finalItems.filter { $0.status != .synced }.count
            return CaptureSyncSummary(syncedCount: 0, queuedCount: queuedCount, lastError: errorMessage)
        }

        guard items.contains(where: { $0.status != .synced || shouldEnrichSyncedItem($0, enabled: enrichSyncedMissingMetadata) }) else {
            return CaptureSyncSummary(syncedCount: 0, queuedCount: 0, lastError: nil)
        }

        let client = SyncClient(bridgeBaseURL: baseURL, bearerToken: bearerToken)
        var syncedCount = 0
        var lastError: String?

        var attemptedCount = 0
        var index = items.startIndex
        while index < items.endIndex {
            if Task.isCancelled {
                lastError = "同步已取消"
                break
            }
            if items[index].status == .synced && !shouldEnrichSyncedItem(items[index], enabled: enrichSyncedMissingMetadata) {
                index += 1
                continue
            }
            if let maxItems, attemptedCount >= maxItems {
                break
            }
            attemptedCount += 1
            let attemptedAt = Date()
            items[index].lastSyncAttemptAt = attemptedAt
            items[index].syncError = nil
            do {
                if items[index].status == .deleted {
                    if let remoteNotePath = items[index].remoteNotePath, !remoteNotePath.isEmpty {
                        try await client.deleteRemoteNote(path: remoteNotePath)
                    }
                    items.remove(at: index)
                    syncedCount += 1
                    continue
                } else if items[index].status == .synced {
                    items[index].lastMetadataRefreshAttemptAt = attemptedAt
                    let enriched = try await client.refreshMetadata(for: items[index])
                    let result = try await client.push(enriched, fast: false)
                    items[index] = result.item ?? enriched
                    items[index].status = .synced
                    items[index].remoteNotePath = result.relativePath ?? result.path
                    items[index].lastSyncedAt = Date()
                    items[index].updatedAt = items[index].lastSyncedAt ?? attemptedAt
                    syncedCount += 1
                } else {
                    let result = try await client.push(items[index], fast: fast)
                    items[index] = result.item ?? items[index]
                    items[index].status = .synced
                    items[index].remoteNotePath = result.relativePath ?? result.path
                    items[index].lastSyncedAt = Date()
                    items[index].updatedAt = items[index].lastSyncedAt ?? attemptedAt
                    syncedCount += 1
                }
            } catch {
                if items[index].status != .deleted {
                    items[index].status = .queued
                }
                items[index].syncError = error.localizedDescription
                items[index].updatedAt = Date()
                lastError = error.localizedDescription
            }
            index += 1
        }

        var finalItems = items
        do {
            try CaptureFileStore.update { latestItems in
                let merged = reconcileWithLatestStore(originalItems: originalItems, workingItems: items, latestItems: latestItems)
                finalItems = merged
                return merged
            }
        } catch {
            lastError = error.localizedDescription
        }

        let queuedCount = finalItems.filter { $0.status != .synced }.count
        return CaptureSyncSummary(syncedCount: syncedCount, queuedCount: queuedCount, lastError: lastError)
    }

    private static func prioritize(_ items: [CaptureItem], ids: [UUID]) -> [CaptureItem] {
        guard !ids.isEmpty else {
            return items
        }
        var seenIDs = Set<UUID>()
        let uniqueIDs = ids.filter { seenIDs.insert($0).inserted }
        let idSet = Set(uniqueIDs)
        let prioritized = uniqueIDs.compactMap { id in
            items.first { $0.id == id }
        }
        let remaining = items.filter { !idSet.contains($0.id) }
        return prioritized + remaining
    }

    private static func shouldEnrichSyncedItem(_ item: CaptureItem, enabled: Bool) -> Bool {
        guard enabled,
              item.status == .synced,
              item.metadata == nil,
              let remoteNotePath = item.remoteNotePath,
              !remoteNotePath.isEmpty else {
            return false
        }
        if let lastAttempt = item.lastMetadataRefreshAttemptAt {
            return Date().timeIntervalSince(lastAttempt) > 24 * 60 * 60
        }
        return true
    }

    private static func reconcileWithLatestStore(
        originalItems: [CaptureItem],
        workingItems: [CaptureItem],
        latestItems: [CaptureItem]
    ) -> [CaptureItem] {
        let originalByID = Dictionary(uniqueKeysWithValues: originalItems.map { ($0.id, $0) })
        let workingByID = Dictionary(uniqueKeysWithValues: workingItems.map { ($0.id, $0) })
        let deletedIDs = Set(originalByID.keys).subtracting(workingByID.keys)
        var emittedIDs = Set<UUID>()

        var merged: [CaptureItem] = latestItems.compactMap { latest in
            if deletedIDs.contains(latest.id),
               let original = originalByID[latest.id],
               latest.updatedAt <= original.updatedAt {
                emittedIDs.insert(latest.id)
                return nil
            }

            guard let working = workingByID[latest.id],
                  let original = originalByID[latest.id] else {
                emittedIDs.insert(latest.id)
                return latest
            }

            emittedIDs.insert(latest.id)
            if latest.updatedAt > original.updatedAt {
                return latest
            }
            return working
        }

        for working in workingItems where !emittedIDs.contains(working.id) {
            merged.append(working)
        }

        return merged
    }
}
