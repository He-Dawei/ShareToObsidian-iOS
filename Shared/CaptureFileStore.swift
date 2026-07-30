import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum CaptureFileStore {
    static let appGroupIdentifier = "group.com.hdwei.ShareToObsidian"

    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static var hasSharedAppGroup: Bool {
        sharedContainerURL != nil
    }

    static var containerURL: URL {
        if let url = sharedContainerURL {
            return url
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var queueURL: URL {
        containerURL.appending(path: "captures.json")
    }

    private static var lockURL: URL {
        containerURL.appending(path: "captures.lock")
    }

    static func load() -> [CaptureItem] {
        do {
            return try withFileLock {
                loadUnlocked()
            }
        } catch {
            return []
        }
    }

    static func save(_ items: [CaptureItem]) throws {
        try withFileLock {
            try saveUnlocked(items)
        }
    }

    static func update(_ operation: ([CaptureItem]) throws -> [CaptureItem]) throws {
        try withFileLock {
            let updated = try operation(loadUnlocked())
            try saveUnlocked(updated)
        }
    }

    static func reconcileCloudRelay() throws -> [CaptureItem] {
        try withFileLock {
            let current = loadUnlocked()
            guard CloudRelayStore.isConfigured else {
                return current
            }
            let reconciled = try CloudRelayStore.reconcile(current)
            if reconciled != current {
                try saveUnlocked(reconciled)
            }
            return reconciled
        }
    }

    @discardableResult
    static func append(_ item: CaptureItem) throws -> CaptureItem {
        try withFileLock {
            var items = loadUnlocked()
            var item = item
            item.url = canonicalURL(item.url)
            let itemKey = normalizedURLKey(item.url)
            if let existingIndex = items.firstIndex(where: { normalizedURLKey($0.url) == itemKey }) {
                var existing = items.remove(at: existingIndex)
                existing.url = item.url
                if existing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPlaceholderTitle(existing) {
                    existing.title = item.title
                }
                if existing.sourceApp == nil {
                    existing.sourceApp = item.sourceApp
                }
                if item.status == .queued {
                    existing.status = .queued
                    existing.syncError = nil
                }
                existing.updatedAt = Date()
                items.insert(existing, at: 0)
                try saveUnlocked(items)
                return existing
            }
            items.insert(item, at: 0)
            try saveUnlocked(items)
            return item
        }
    }

    private static func loadUnlocked() -> [CaptureItem] {
        guard FileManager.default.fileExists(atPath: queueURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: queueURL)
            return try JSONDecoder.captureDecoder.decode([CaptureItem].self, from: data)
        } catch {
            return []
        }
    }

    private static func saveUnlocked(_ items: [CaptureItem]) throws {
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.captureEncoder.encode(items)
        try data.write(to: queueURL, options: [.atomic])
    }

    private static func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: lockURL)
        defer {
            try? handle.close()
        }

        #if canImport(Darwin)
        flock(handle.fileDescriptor, LOCK_EX)
        defer {
            flock(handle.fileDescriptor, LOCK_UN)
        }
        #endif

        return try operation()
    }

    private static func normalizedURLKey(_ url: URL) -> String {
        let canonical = canonicalURL(url)
        guard var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if let host = components.host, host.hasPrefix("www.") {
            components.host = String(host.dropFirst(4))
        }
        components.fragment = nil
        if components.path.count > 1 {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + components.path
        }
        let trackingNames: Set<String> = [
            "from",
            "share_app_name",
            "share_medium",
            "share_plat",
            "share_session_id",
            "share_source",
            "share_tag",
            "social_share_type",
            "spm_id_from",
            "timestamp",
            "unique_k",
            "utm_campaign",
            "utm_content",
            "utm_medium",
            "utm_source",
            "utm_term",
            "vd_source"
        ]
        components.queryItems = components.queryItems?
            .filter { item in
                let name = item.name.lowercased()
                return !trackingNames.contains(name) && !name.hasPrefix("utm_")
            }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name {
                    return (lhs.value ?? "") < (rhs.value ?? "")
                }
                return lhs.name < rhs.name
            }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        return components.string ?? url.absoluteString
    }

    private static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              ["v.douyin.com", "b23.tv"].contains(host),
              let shortCode = components.path.split(separator: "/").first else {
            return url
        }
        components.path = "/\(shortCode)/"
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private static func isPlaceholderTitle(_ item: CaptureItem) -> Bool {
        item.title == item.platform.displayName + "收藏内容" || item.title == "移动收藏"
    }
}

extension JSONEncoder {
    static var captureEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var captureDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date: \(value)"
            )
        }
        return decoder
    }
}
