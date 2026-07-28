import SwiftUI
import UIKit

struct SettingsView: View {
    @Bindable var model: CaptureListModel
    @State private var pairingText = ""

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

                Section("状态") {
                    LabeledContent("总数", value: "\(model.items.count)")
                    LabeledContent("待同步", value: "\(model.items.filter { $0.status != .synced }.count)")
                    if let health = model.lastHealth {
                        LabeledContent("桥接器", value: health.ok ? "在线" : "异常")
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
        }
    }
}
