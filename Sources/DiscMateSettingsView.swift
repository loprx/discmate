import AppKit
import SwiftUI

struct DiscMateSettingsView: View {
    @ObservedObject var shortcuts: DiscMateShortcuts
    @StateObject private var updates = SoftwareUpdateModel()

    var body: some View {
        TabView {
            Form {
                Section("当前安装") {
                    LabeledContent("版本", value: updates.version)
                        .floatingScrollbars()
                    LabeledContent("构建号", value: updates.build)
                }

                Section("正式版本") {
                    HStack(spacing: 12) {
                        if updates.state == .checking {
                            ProgressView().controlSize(.small)
                        }
                        Text(status).foregroundStyle(.secondary)
                        Spacer()
                        Button("检查更新") {
                            Task { await updates.check() }
                        }
                        .disabled(updates.state == .checking)
                    }

                    if case .finished(.available(_, let page)) = updates.state {
                        Link("查看新版与下载", destination: page)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("软件更新", systemImage: "arrow.down.circle") }

            ShortcutSettingsView(shortcuts: shortcuts)
                .tabItem { Label("快捷键", systemImage: "keyboard") }
        }
        .padding(12)
        .frame(width: 530, height: 520)
        .onExitCommand {
            guard let window = NSApp.keyWindow, !window.isSheet,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            window.performClose(nil)
        }
    }

    private var status: String {
        switch updates.state {
        case .idle: "从 GitHub Releases 检查正式版本。"
        case .checking: "正在检查更新…"
        case .finished(.current): "没有可用更新。"
        case .finished(.available(let version, _)): "发现新版本 \(version)。"
        case .failed: "检查失败。请确认网络连接后重试。"
        }
    }
}

