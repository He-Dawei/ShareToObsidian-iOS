import SwiftUI
import UIKit
import AppIntents
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: CaptureListModel
    @State private var pairingText = ""
    @State private var isChoosingCloudRelayFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section("电脑桥接器") {
                    TextField("Bridge URL", text: $model.bridgeAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Bridge Token（可选）", text: $model.bridgeToken)
                        .textInputAutocapitalization(.never)
                    Button("检查连接") {
                        Task { await model.refreshHealth() }
                    }
                    Button("同步所有待处理") {
                        Task { await model.syncQueued() }
                    }
                    Button {
                        Task { await model.refreshRemoteLibrary() }
                    } label: {
                        Label("回读电脑收藏", systemImage: "icloud.and.arrow.down")
                    }
                    Button {
                        UIPasteboard.general.string = CaptureSettingsStore.pairingText
                    } label: {
                        Label("复制扩展配对配置", systemImage: "doc.on.doc")
                    }
                    .disabled(!CaptureSettingsStore.isConfiguredForDevice)
                    Button("发送验收收藏") {
                        Task { await model.createVerificationCapture() }
                    }
                }

                Section("快速配对") {
                    TextEditor(text: $pairingText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                    Button {
                        pairingText = UIPasteboard.general.string ?? ""
                    } label: {
                        Label("从剪贴板读取", systemImage: "doc.on.clipboard")
                    }
                    Button("导入配对配置") {
                        Task {
                            await model.importPairing(text: pairingText)
                            if model.lastError == nil {
                                pairingText = ""
                            }
                        }
                    }
                    .disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("快捷指令") {
                    ShortcutsLink()
                }

                Section("电脑离线中转") {
                    if let folderName = model.cloudRelayFolderName {
                        LabeledContent("iCloud 文件夹", value: folderName)
                    } else {
                        LabeledContent("iCloud 文件夹", value: "未选择")
                    }
                    Button {
                        isChoosingCloudRelayFolder = true
                    } label: {
                        Label("选择 iCloud 中转文件夹", systemImage: "folder.badge.plus")
                    }
                    if model.cloudRelayFolderName != nil {
                        Button {
                            model.createCloudRelayVerificationCapture()
                        } label: {
                            Label("发送离线中转验收", systemImage: "checkmark.icloud")
                        }
                        Button(role: .destructive) {
                            model.clearCloudRelay()
                        } label: {
                            Label("关闭离线中转", systemImage: "xmark.icloud")
                        }
                    }
                    if let relayError = model.cloudRelayError {
                        Text(relayError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("状态") {
                    LabeledContent("总数", value: "\(model.items.count)")
                    LabeledContent("待同步", value: "\(model.items.filter { $0.status != .synced }.count)")
                    if let health = model.lastHealth {
                        LabeledContent("桥接器", value: health.ok ? "在线" : "异常")
                        if health.aiEnabled == true {
                            let aiState = health.aiConfigured == true ? "已连接" : "缺少配置"
                            LabeledContent("AI 草稿", value: aiState)
                        }
                        if let notesRoot = health.notesRoot {
                            Text(notesRoot)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    if let statusMessage = model.lastStatusMessage {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("同步设置")
            .fileImporter(
                isPresented: $isChoosingCloudRelayFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let folderURL = try result.get().first else {
                        return
                    }
                    model.configureCloudRelay(folderURL: folderURL)
                } catch {
                    model.cloudRelayError = error.localizedDescription
                }
            }
        }
    }
}
