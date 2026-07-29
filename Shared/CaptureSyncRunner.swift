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
        let originalItems = (try? CaptureFileStore.reconcileCloudRelay()) ?? CaptureFileStore.load()
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
                try? CloudRelayStore.enqueue(items[index])
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
                    let itemID = items[index].id
                    if let remoteNotePath = items[index].remoteNotePath, !remoteNotePath.isEmpty {
                        try await client.deleteRemoteNote(path: remoteNotePath)
                    }
                    items.remove(at: index)
                    try? CloudRelayStore.removeQueuedItem(id: itemID)
                    syncedCount += 1
                    continue
                } else if items[index].status == .synced {
                    guard let remoteNotePath = items[index].remoteNotePath else {
                        throw URLError(.fileDoesNotExist)
                    }
                    let remote = try await client.fetchRemoteCapture(path: remoteNotePath)
                    if remote.metadata != nil {
                        items[index] = remote
                        items[index].status = .synced
                        items[index].remoteNotePath = remoteNotePath
                        items[index].syncError = nil
                        items[index].lastMetadataRefreshAttemptAt = attemptedAt
                        items[index].lastSyncedAt = Date()
                        items[index].updatedAt = items[index].lastSyncedAt ?? attemptedAt
                        try? CloudRelayStore.removeQueuedItem(id: items[index].id)
                        syncedCount += 1
                    } else {
                        items[index].syncError = "电脑正在后台提炼内容"
                    }
                } else {
                    let result = try await client.push(items[index], fast: fast)
                    items[index] = result.item ?? items[index]
                    items[index].status = .synced
                    items[index].remoteNotePath = result.relativePath ?? result.path
                    items[index].lastSyncedAt = Date()
                    items[index].updatedAt = items[index].lastSyncedAt ?? attemptedAt
                    try? CloudRelayStore.removeQueuedItem(id: items[index].id)
                    syncedCount += 1
                }
            } catch {
                if items[index].status != .deleted {
                    items[index].status = .queued
                }
                items[index].syncError = error.localizedDescription
                items[index].updatedAt = Date()
                try? CloudRelayStore.enqueue(items[index])
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
              let remoteNotePath = item.remoteNotePath,
              !remoteNotePath.isEmpty else {
            return false
        }
        let needsInitialEnrichment = item.metadata == nil || item.backgroundEnrichedAt == nil
        let needsVideoTranscript = [.douyin, .bilibili].contains(item.platform)
            && item.metadata?.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && item.backgroundTranscribedAt == nil
            && item.backgroundTranscriptionFailedAt == nil
        guard needsInitialEnrichment || needsVideoTranscript else {
            return false
        }
        if let lastAttempt = item.lastMetadataRefreshAttemptAt {
            return Date().timeIntervalSince(lastAttempt) > 30
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
