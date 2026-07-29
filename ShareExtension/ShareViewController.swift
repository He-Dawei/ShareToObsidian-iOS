import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupStatusView()
        updateStatus("正在读取分享内容", detail: "请稍候")
        captureSharedContent()
    }

    private func setupStatusView() {
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [activityIndicator, statusLabel, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func updateStatus(_ title: String, detail: String) {
        statusLabel.text = title
        detailLabel.text = detail
    }

    private func captureSharedContent() {
        let extensionItems = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            ?? []
        let providers = extensionItems.flatMap { $0.attachments ?? [] }

        let group = DispatchGroup()
        let lock = NSLock()
        var capturedURLs: [URL] = []
        var capturedTitles: [String] = Self.extensionItemTitles(from: extensionItems)
        var savedIDs: [UUID] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        lock.lock()
                        capturedURLs.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    if let text = item as? String {
                        let urls = Self.urls(in: text)
                        if !urls.isEmpty {
                            lock.lock()
                            capturedURLs.append(contentsOf: urls)
                            lock.unlock()
                        }
                        if let title = Self.titleCandidate(in: text) {
                            lock.lock()
                            capturedTitles.append(title)
                            lock.unlock()
                        }
                    }
                    group.leave()
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, _ in
                    let extracted = Self.extractPropertyListContent(from: item)
                    if !extracted.urls.isEmpty || !extracted.titles.isEmpty {
                        lock.lock()
                        capturedURLs.append(contentsOf: extracted.urls)
                        capturedTitles.append(contentsOf: extracted.titles)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            do {
                let uniqueURLs = Self.uniqueURLs(capturedURLs)
                guard !uniqueURLs.isEmpty else {
                    self.finish(error: Self.noURLFoundError())
                    return
                }
                for (index, url) in uniqueURLs.enumerated() {
                    let title = capturedTitles.indices.contains(index) ? capturedTitles[index] : (capturedTitles.first ?? "")
                    var item = CaptureItem(url: url, title: title, sourceApp: "Share Extension")
                    item.status = .queued
                    let savedItem = try CaptureFileStore.append(item)
                    try? CloudRelayStore.enqueue(savedItem)
                    savedIDs.append(savedItem.id)
                }
                self.updateStatus("已保存到队列", detail: "正在尝试同步到电脑 Obsidian")
                self.syncAndFinish(prioritizedIDs: savedIDs)
            } catch {
                self.finish(error: error)
            }
        }
    }

    private static func extensionItemTitles(from items: [NSExtensionItem]) -> [String] {
        items.flatMap { item in
            [
                item.attributedTitle?.string,
                item.attributedContentText?.string
            ].compactMap { cleanTitle($0) }
        }
    }

    private static func noURLFoundError() -> NSError {
        NSError(
            domain: "ShareToObsidian.ShareExtension",
            code: 1001,
            userInfo: [
                NSLocalizedDescriptionKey: "没有在分享内容里找到可保存的链接。请确认分享文本包含 http/https 链接。"
            ]
        )
    }

    private func syncAndFinish(prioritizedIDs: [UUID]) {
        Task {
            let maxItemsToSync = max(3, prioritizedIDs.count)
            let summary = await CaptureSyncRunner.syncQueued(
                bridgeAddress: CaptureSettingsStore.bridgeAddress,
                bearerToken: CaptureSettingsStore.bridgeToken,
                maxItems: maxItemsToSync,
                fast: true,
                prioritizedIDs: prioritizedIDs
            )
            await MainActor.run {
                if summary.lastError == nil {
                    self.updateStatus("已同步到 Obsidian", detail: "可以关闭分享面板")
                } else {
                    self.updateStatus("已保存，等待补同步", detail: "电脑桥接器恢复后，打开 App 会继续同步")
                }
                self.finishAfterStatusDelay()
            }
        }
    }

    private func finishAfterStatusDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.finish()
        }
    }

    private func finish(error: Error? = nil) {
        if let error {
            let alert = UIAlertController(title: "保存失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "关闭", style: .default) { _ in
                self.extensionContext?.cancelRequest(withError: error)
            })
            present(alert, animated: true)
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private static func firstURL(in text: String) -> URL? {
        urls(in: text).first
    }

    private static func urls(in text: String) -> [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?
            .matches(in: text, range: range)
            .compactMap(\.url)
            .filter { SupportedShareURL.isSupported($0) } ?? []
    }

    private static func titleCandidate(in text: String) -> String? {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { cleanTitle($0) }
            .first
    }

    private static func cleanTitle(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, firstURL(in: title) == nil else {
            return nil
        }
        return title
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            guard SupportedShareURL.isSupported(url) else {
                continue
            }
            let key = url.absoluteString
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }

    private static func extractPropertyListContent(from item: Any?) -> (urls: [URL], titles: [String]) {
        var urls: [URL] = []
        var titles: [String] = []

        func collect(_ value: Any?) {
            switch value {
            case let url as URL:
                urls.append(url)
            case let string as String:
                let detectedURLs = Self.urls(in: string)
                if !detectedURLs.isEmpty {
                    urls.append(contentsOf: detectedURLs)
                }
                if let title = titleCandidate(in: string) ?? (detectedURLs.isEmpty ? cleanTitle(string) : nil) {
                    titles.append(title)
                }
            case let dictionary as [AnyHashable: Any]:
                let urlKeys = ["URL", "url", "documentURL", "webpageURL"]
                for key in urlKeys {
                    collect(dictionary[key])
                }
                if let title = dictionary["title"] as? String {
                    titles.append(title.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                collect(dictionary["NSExtensionJavaScriptPreprocessingResultsKey"])
            case let dictionary as NSDictionary:
                collect(dictionary as? [AnyHashable: Any])
            case let array as [Any]:
                array.forEach { collect($0) }
            default:
                break
            }
        }

        collect(item)
        return (
            urls: Array(NSOrderedSet(array: urls).compactMap { $0 as? URL }),
            titles: Array(NSOrderedSet(array: titles.filter { !$0.isEmpty }).compactMap { $0 as? String })
        )
    }
}
