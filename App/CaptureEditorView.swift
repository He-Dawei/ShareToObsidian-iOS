import SwiftUI

private enum DraftDisplayMode: String, CaseIterable, Identifiable {
    case preview
    case edit

    var id: String { rawValue }
}

struct CaptureEditorView: View {
    @State private var item: CaptureItem
    @State private var originalMarkdown: String
    @State private var originalSummary: String
    @State private var draftDisplayMode: DraftDisplayMode = .preview
    @State private var isGenerating = false
    @State private var isRefreshingMetadata = false
    let onSave: (CaptureItem) -> Void
    let onRegenerate: (CaptureItem) async -> CaptureItem
    let onRefreshMetadata: (CaptureItem) async -> CaptureItem

    init(
        item: CaptureItem,
        onSave: @escaping (CaptureItem) -> Void,
        onRegenerate: @escaping (CaptureItem) async -> CaptureItem,
        onRefreshMetadata: @escaping (CaptureItem) async -> CaptureItem
    ) {
        _item = State(initialValue: item)
        _originalMarkdown = State(initialValue: item.draftMarkdown)
        _originalSummary = State(initialValue: item.summary)
        self.onSave = onSave
        self.onRegenerate = onRegenerate
        self.onRefreshMetadata = onRefreshMetadata
    }

    var body: some View {
        Form {
            Section("基础信息") {
                TextField("标题", text: $item.title)
                Text("摘要")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $item.summary)
                    .frame(minHeight: 80)
                Text(item.url.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link(destination: item.metadata?.webpageURL ?? item.url) {
                    Label("打开原链接", systemImage: "safari")
                }
            }

            Section("同步状态") {
                LabeledContent("状态", value: item.status.displayName)
                if let lastSyncAttemptAt = item.lastSyncAttemptAt {
                    LabeledContent("最近尝试", value: lastSyncAttemptAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let lastSyncedAt = item.lastSyncedAt {
                    LabeledContent("最近成功", value: lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let remoteNotePath = item.remoteNotePath, !remoteNotePath.isEmpty {
                    Text(remoteNotePath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let syncError = item.syncError, !syncError.isEmpty {
                    Text(syncError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if let metadata = item.metadata {
                Section("视频信息") {
                    if let author = metadata.authorText {
                        LabeledContent("作者/频道", value: author)
                    }
                    if let duration = metadata.duration {
                        LabeledContent("时长", value: "\(Int(duration)) 秒")
                    }
                    if let viewCount = metadata.viewCount {
                        LabeledContent("播放/阅读", value: "\(viewCount)")
                    }
                    if let likeCount = metadata.likeCount {
                        LabeledContent("点赞", value: "\(likeCount)")
                    }
                    if let description = metadata.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let thumbnail = metadata.thumbnail {
                        CaptureThumbnailView(url: thumbnail)
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                        Link("打开封面", destination: thumbnail)
                    }
                    if let metadataError = metadata.metadataError {
                        Text(metadataError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("视频内容/口播转写") {
                TextEditor(text: transcriptBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                Text("没有自动转写时，可以先手动补入口播、字幕或自己概括的视频内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("预生成效果") {
                Picker("显示方式", selection: $draftDisplayMode) {
                    Text("预览").tag(DraftDisplayMode.preview)
                    Text("编辑").tag(DraftDisplayMode.edit)
                }
                .pickerStyle(.segmented)

                if draftDisplayMode == .preview {
                    MarkdownPreviewView(markdown: item.draftMarkdown)
                } else {
                    TextEditor(text: $item.draftMarkdown)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 300)
                }
            }

            if !item.alternativeDrafts.isEmpty {
                Section("其他文案") {
                    ForEach(item.alternativeDrafts.indices, id: \.self) { index in
                        Button("使用版本 \(index + 1)") {
                            item.draftMarkdown = item.alternativeDrafts[index]
                        }
                    }
                }
            }

            Section("标签") {
                Text(item.tags.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("编辑笔记")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        Task {
                            isRefreshingMetadata = true
                            item = await onRefreshMetadata(item)
                            isRefreshingMetadata = false
                        }
                    } label: {
                        Label("刷新视频信息", systemImage: "info.circle")
                    }

                    Button {
                        Task {
                            isGenerating = true
                            item = await onRegenerate(item)
                            originalMarkdown = item.draftMarkdown
                            originalSummary = item.summary
                            isGenerating = false
                        }
                    } label: {
                        Label("重新生成文案", systemImage: "sparkles")
                    }
                } label: {
                    if isGenerating || isRefreshingMetadata {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .disabled(isGenerating || isRefreshingMetadata)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    item.status = .queued
                    item.syncError = nil
                    item.isUserEdited = item.draftMarkdown != originalMarkdown || item.summary != originalSummary
                    onSave(item)
                    originalMarkdown = item.draftMarkdown
                    originalSummary = item.summary
                }
            }
        }
    }

    private var transcriptBinding: Binding<String> {
        Binding(get: {
            item.metadata?.transcriptText ?? ""
        }, set: { value in
            var metadata = item.metadata ?? CaptureMetadata()
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            metadata.transcript = cleaned.isEmpty ? nil : value
            metadata.contentText = nil
            item.metadata = metadata
            item.draftMarkdown = markdownReplacingTranscript(in: item.draftMarkdown, with: cleaned)
        })
    }

    private func markdownReplacingTranscript(in markdown: String, with transcript: String) -> String {
        let heading = "## 视频内容/口播转写"
        let nextAnchor = "\n## "
        let fallback = "暂无口播转写。后续可接入字幕/语音转写后自动补全。"
        let body = transcript.isEmpty ? fallback : transcript
        let section = "\(heading)\n\n\(body)\n"

        if let headingRange = markdown.range(of: heading) {
            if let nextRange = markdown[headingRange.upperBound...].range(of: nextAnchor) {
                var updated = markdown
                updated.replaceSubrange(headingRange.lowerBound..<nextRange.lowerBound, with: section)
                return updated
            }
            var updated = markdown
            updated.replaceSubrange(headingRange.lowerBound..<markdown.endIndex, with: section)
            return updated
        }

        if let keyPointsRange = markdown.range(of: "## 关键观点") {
            var updated = markdown
            updated.insert(contentsOf: "\(section)\n", at: keyPointsRange.lowerBound)
            return updated
        }

        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed)\n\n\(section)"
    }
}

private struct MarkdownPreviewView: View {
    let markdown: String

    private var lines: [MarkdownPreviewLine] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { MarkdownPreviewLine(rawValue: String($0)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    MarkdownPreviewLineView(line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .frame(minHeight: 300)
        .textSelection(.enabled)
    }
}

private struct MarkdownPreviewLine {
    enum Kind {
        case heading(Int)
        case bullet
        case quote
        case body
        case empty
    }

    let kind: Kind
    let text: String

    init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            kind = .empty
            text = ""
        } else if trimmed.hasPrefix("### ") {
            kind = .heading(3)
            text = String(trimmed.dropFirst(4))
        } else if trimmed.hasPrefix("## ") {
            kind = .heading(2)
            text = String(trimmed.dropFirst(3))
        } else if trimmed.hasPrefix("# ") {
            kind = .heading(1)
            text = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("- ") {
            kind = .bullet
            text = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("> ") {
            kind = .quote
            text = String(trimmed.dropFirst(2))
        } else {
            kind = .body
            text = rawValue
        }
    }
}

private struct MarkdownPreviewLineView: View {
    let line: MarkdownPreviewLine

    var body: some View {
        switch line.kind {
        case .empty:
            Color.clear.frame(height: 4)
        case .heading(let level):
            Text(line.text)
                .font(headingFont(level))
                .fontWeight(.semibold)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(line.text)
            }
            .font(.body)
        case .quote:
            Text(line.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 3)
                }
        case .body:
            Text(line.text)
                .font(.body)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            return .title3
        case 2:
            return .headline
        default:
            return .subheadline
        }
    }
}
