import AppIntents
import Foundation

struct SaveToObsidianIntent: AppIntent {
    static let title: LocalizedStringResource = "保存到 Obsidian"
    static let description = IntentDescription("把分享链接保存到 ShareToObsidian，并同步到电脑 Obsidian。")

    @Parameter(
        title: "链接或分享文本",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var sharedText: String

    @Parameter(title: "标题")
    var noteTitle: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = Self.firstSupportedURL(in: sharedText) else {
            throw SaveToObsidianIntentError.noSupportedURL
        }

        let cleanedTitle = noteTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var item = CaptureItem(url: url, title: cleanedTitle, sourceApp: "App Intent")
        item.status = .queued
        let savedItem = try CaptureFileStore.append(item)

        let summary = await CaptureSyncRunner.syncQueued(
            bridgeAddress: CaptureSettingsStore.bridgeAddress,
            bearerToken: CaptureSettingsStore.bridgeToken,
            maxItems: 1,
            fast: true,
            prioritizedIDs: [savedItem.id]
        )

        if summary.syncedCount > 0 {
            return .result(dialog: "已同步到 Obsidian。")
        }
        return .result(dialog: "已保存到待同步队列。电脑恢复连接后会自动同步。")
    }

    private static func firstSupportedURL(in text: String) -> URL? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directURL = URL(string: cleaned),
           SupportedShareURL.isSupported(directURL) {
            return directURL
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        return detector?
            .matches(in: cleaned, range: range)
            .compactMap(\.url)
            .first(where: { SupportedShareURL.isSupported($0) })
    }
}

private enum SaveToObsidianIntentError: LocalizedError {
    case noSupportedURL

    var errorDescription: String? {
        "分享内容中没有可保存的 http/https 链接。"
    }
}

struct ShareToObsidianShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveToObsidianIntent(),
            phrases: [
                "用 \(.applicationName) 保存链接",
                "保存到 \(.applicationName)"
            ],
            shortTitle: "保存到 Obsidian",
            systemImageName: "square.and.arrow.down"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .blue
    }
}
