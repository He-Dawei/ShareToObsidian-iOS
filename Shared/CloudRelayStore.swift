import Foundation

enum CloudRelayStore {
    private static let bookmarkKey = "cloudRelayFolderBookmark"
    private static let folderNameKey = "cloudRelayFolderName"

    private static var defaults: UserDefaults {
        if CaptureFileStore.hasSharedAppGroup,
           let sharedDefaults = UserDefaults(suiteName: CaptureFileStore.appGroupIdentifier) {
            return sharedDefaults
        }
        return .standard
    }

    static var isConfigured: Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    static var folderName: String? {
        defaults.string(forKey: folderNameKey)
    }

    static func configure(folderURL: URL) throws {
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let bookmark = try folderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.nameKey],
            relativeTo: nil
        )
        try ensureLayout(at: folderURL)
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(folderURL.lastPathComponent, forKey: folderNameKey)
    }

    static func clear() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: folderNameKey)
    }

    static func enqueue(_ item: CaptureItem) throws {
        guard item.status != .synced else {
            try? removeQueuedItem(id: item.id)
            return
        }
        try withFolder { folder in
            try ensureLayout(at: folder)
            let fileURL = folder
                .appending(path: "Queue", directoryHint: .isDirectory)
                .appending(path: fileName(for: item.id))
            let data = try JSONEncoder.captureEncoder.encode(item)
            try coordinatedWrite(data, to: fileURL)
        }
    }

    static func removeQueuedItem(id: UUID) throws {
        try withFolder { folder in
            let fileURL = folder
                .appending(path: "Queue", directoryHint: .isDirectory)
                .appending(path: fileName(for: id))
            try coordinatedRemove(fileURL)
        }
    }

    static func reconcile(_ items: [CaptureItem]) throws -> [CaptureItem] {
        try withFolder { folder in
            try ensureLayout(at: folder)
            let processedURL = folder.appending(path: "Processed", directoryHint: .isDirectory)
            let files = try FileManager.default.contentsOfDirectory(
                at: processedURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "json" }

            var result = items
            for fileURL in files {
                let data = try coordinatedRead(fileURL)
                let remote = try JSONDecoder.captureDecoder.decode(CaptureItem.self, from: data)
                if remote.status == .deleted {
                    result.removeAll { $0.id == remote.id }
                } else if let index = result.firstIndex(where: { $0.id == remote.id }) {
                    let local = result[index]
                    if local.status != .synced && local.updatedAt > remote.updatedAt {
                        try enqueue(local)
                    } else {
                        result[index] = remote
                    }
                } else {
                    result.append(remote)
                }
                try coordinatedRemove(fileURL)
            }
            return result
        }
    }

    private static func withFolder<T>(_ operation: (URL) throws -> T) throws -> T {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else {
            throw CloudRelayError.notConfigured
        }
        var isStale = false
        let folderURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else {
            throw CloudRelayError.staleBookmark
        }

        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        return try operation(folderURL)
    }

    private static func ensureLayout(at folderURL: URL) throws {
        for subdirectory in ["Queue", "Processed", "Failed"] {
            try FileManager.default.createDirectory(
                at: folderURL.appending(path: subdirectory, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
    }

    private static func coordinatedRead(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationResult: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            operationResult = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let operationResult else {
            throw CloudRelayError.coordinationFailed
        }
        return try operationResult.get()
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: [.atomic])
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let operationError {
            throw operationError
        }
    }

    private static func coordinatedRemove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let operationError {
            throw operationError
        }
    }

    private static func fileName(for id: UUID) -> String {
        id.uuidString.lowercased() + ".json"
    }
}

private enum CloudRelayError: LocalizedError {
    case notConfigured
    case staleBookmark
    case coordinationFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "尚未选择 iCloud 中转文件夹"
        case .staleBookmark:
            "iCloud 中转文件夹权限已失效，请重新选择"
        case .coordinationFailed:
            "iCloud 文件协调失败"
        }
    }
}
