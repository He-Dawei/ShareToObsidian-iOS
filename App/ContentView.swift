import SwiftUI

struct ContentView: View {
    @Bindable var model: CaptureListModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var pastedURL = ""
    @State private var searchText = ""

    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        HStack {
                            TextField("粘贴分享链接", text: $pastedURL)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                            Button {
                                if model.add(urlText: pastedURL) {
                                    pastedURL = ""
                                    Task { await model.syncQueued() }
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .accessibilityLabel("添加链接")
                        }
                    }

                    if let error = model.lastError {
                        Section {
                            HStack(alignment: .top, spacing: 8) {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button {
                                    model.clearLastError()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("清除错误")
                            }
                        }
                    }

                    Section {
                        ForEach(visibleItems) { item in
                            NavigationLink(value: item.id) {
                                CaptureRow(item: item)
                            }
                        }
                        .onDelete { offsets in
                            deleteVisibleItems(offsets)
                        }
                    }
                }
                .navigationTitle("移动收藏")
                .searchable(text: $searchText, prompt: "搜索标题、摘要、平台、标签")
                .navigationDestination(for: UUID.self) { id in
                    if let item = model.items.first(where: { $0.id == id }) {
                        CaptureEditorView(item: item) { updated in
                            model.save(updated)
                            Task { await model.syncQueued() }
                        } onRegenerate: { item in
                            let updated = await model.regenerateDrafts(for: item)
                            await model.syncQueued()
                            return updated
                        } onRefreshMetadata: { item in
                            let updated = await model.refreshMetadata(for: item)
                            await model.syncQueued()
                            return updated
                        }
                    }
                }
                .toolbar {
                    Button {
                        Task { await model.syncQueued() }
                    } label: {
                        Image(systemName: model.isSyncing ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.up")
                    }
                    .accessibilityLabel("同步到 Obsidian")
                }
            }
            .tabItem {
                Label("收藏", systemImage: "tray.full")
            }

            SettingsView(model: model)
                .tabItem {
                    Label("同步", systemImage: "desktopcomputer")
                }
        }
        .task {
            await model.runForegroundSyncLoop()
        }
        .onOpenURL { url in
            Task {
                await model.importPairing(url: url)
                await model.syncIfPossible()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task {
                    model.reload()
                    await model.refreshHealth()
                    await model.syncIfPossible()
                }
            case .background:
                BackgroundSyncScheduler.schedule()
            default:
                break
            }
        }
    }

    private var visibleItems: [CaptureItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return model.items
        }
        return model.items.filter { item in
            searchableText(for: item).range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    private func searchableText(for item: CaptureItem) -> String {
        [
            item.title,
            item.summary,
            item.url.absoluteString,
            item.platform.displayName,
            item.tags.joined(separator: " "),
            item.metadata?.description ?? "",
            item.metadata?.transcriptText ?? ""
        ].joined(separator: " ")
    }

    private func deleteVisibleItems(_ offsets: IndexSet) {
        let displayedItems = visibleItems
        let ids = offsets.compactMap { index in
            displayedItems.indices.contains(index) ? displayedItems[index].id : nil
        }
        Task { await model.delete(ids: ids) }
    }
}

private struct CaptureRow: View {
    let item: CaptureItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let thumbnail = item.metadata?.thumbnail {
                CaptureThumbnailView(url: thumbnail)
                    .frame(width: 82, height: 46)
            }

            VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(item.status.displayName)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Text(item.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(item.platform.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let syncError = item.syncError, item.status != .synced {
                Label(syncError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let lastSyncedAt = item.lastSyncedAt {
                Label("最近同步 \(lastSyncedAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let lastSyncAttemptAt = item.lastSyncAttemptAt {
                Label("最近尝试 \(lastSyncAttemptAt.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch item.status {
        case .synced: .green
        case .failed: .red
        case .deleted: .orange
        case .queued: .orange
        case .draft: .secondary
        }
    }
}

#Preview {
    ContentView(model: CaptureListModel())
}
