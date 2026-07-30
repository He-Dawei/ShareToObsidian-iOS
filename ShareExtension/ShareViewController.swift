import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController, UIDocumentPickerDelegate {
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let pairingButton = UIButton(type: .system)
    private let cloudRelayButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var pendingIDs: [UUID] = []

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

        configureButton(
            pairingButton,
            title: "从剪贴板导入配对",
            systemImage: "doc.on.clipboard",
            action: #selector(importPairingFromClipboard)
        )
        configureButton(
            cloudRelayButton,
            title: "选择 iCloud 离线文件夹",
            systemImage: "folder.badge.plus",
            action: #selector(chooseCloudRelayFolder)
        )
        configureButton(
            retryButton,
            title: "重试同步",
            systemImage: "arrow.clockwise",
            action: #selector(retrySync)
        )
        configureButton(
            closeButton,
            title: "稍后处理",
            systemImage: "xmark",
            action: #selector(closeExtension)
        )

        let stack = UIStackView(
            arrangedSubviews: [
                activityIndicator,
                statusLabel,
                detailLabel,
                pairingButton,
                cloudRelayButton,
                retryButton,
                closeButton
            ]
        )
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

    private func configureButton(
        _ button: UIButton,
        title: String,
        systemImage: String,
        action: Selector
    ) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 8
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
        button.isHidden = true
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
                self.pendingIDs = savedIDs
                guard CaptureSettingsStore.isConfiguredForDevice else {
                    self.showRecoveryActions(
                        title: "链接已保存在手机",
                        detail: "爱思助手安装需要给分享扩展单独导入一次配对。请先在 App 设置复制扩展配对配置。"
                    )
                    return
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
        guard CaptureSettingsStore.isConfiguredForDevice else {
            showRecoveryActions(
                title: "尚未配置分享扩展",
                detail: "请从剪贴板导入配对后重试。"
            )
            return
        }
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
                    self.finishAfterStatusDelay()
                } else if CloudRelayStore.isConfigured {
                    self.updateStatus("已保存到 iCloud", detail: "电脑开机后会自动同步到 Obsidian")
                    self.finishAfterStatusDelay()
                } else {
                    self.showRecoveryActions(
                        title: "暂时无法连接电脑",
                        detail: "\(summary.lastError ?? "连接失败")。可重试或选择 iCloud 离线文件夹。"
                    )
                }
            }
        }
    }

    private func showRecoveryActions(title: String, detail: String) {
        activityIndicator.stopAnimating()
        updateStatus(title, detail: detail)
        pairingButton.isHidden = false
        cloudRelayButton.isHidden = false
        retryButton.isHidden = !CaptureSettingsStore.isConfiguredForDevice
        closeButton.isHidden = false
    }

    private func hideRecoveryActions() {
        pairingButton.isHidden = true
        cloudRelayButton.isHidden = true
        retryButton.isHidden = true
        closeButton.isHidden = true
        activityIndicator.startAnimating()
    }

    @objc private func importPairingFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            showRecoveryActions(title: "剪贴板为空", detail: "请先在主 App 的同步设置中复制扩展配对配置。")
            return
        }
        do {
            _ = try CaptureSettingsStore.applyPairingInput(text)
            UIPasteboard.general.items = []
            hideRecoveryActions()
            updateStatus("配对已导入", detail: "正在同步刚才的分享")
            syncAndFinish(prioritizedIDs: pendingIDs)
        } catch {
            showRecoveryActions(title: "配对配置无效", detail: error.localizedDescription)
        }
    }

    @objc private func chooseCloudRelayFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc private func retrySync() {
        hideRecoveryActions()
        updateStatus("正在重试同步", detail: "请稍候")
        syncAndFinish(prioritizedIDs: pendingIDs)
    }

    @objc private func closeExtension() {
        finish()
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let folderURL = urls.first else {
            return
        }
        do {
            try CloudRelayStore.configure(folderURL: folderURL)
            for item in CaptureFileStore.load() where item.status != .synced {
                try CloudRelayStore.enqueue(item)
            }
            if CaptureSettingsStore.isConfiguredForDevice {
                hideRecoveryActions()
                updateStatus("iCloud 离线中转已启用", detail: "正在重试电脑直连")
                syncAndFinish(prioritizedIDs: pendingIDs)
            } else {
                showRecoveryActions(
                    title: "iCloud 离线中转已启用",
                    detail: "链接已保存。导入配对后还可立即同步到电脑。"
                )
            }
        } catch {
            showRecoveryActions(title: "无法使用该文件夹", detail: error.localizedDescription)
        }
    }

    private func finishAfterStatusDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
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
