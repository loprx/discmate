import SwiftUI
import Foundation

@main struct DiagnosticsPreviewApp: App {
    var body: some Scene { WindowGroup("DiscMate 无硬件诊断测试") { FixtureView() } }
}
private struct FixtureView: View {
    private let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("fixture-data")
    @State private var store: DiagnosticReportStore?
    @State private var presented = false
    @State private var status = "准备合成报告…"
    var body: some View {
        VStack(spacing: 16) {
            Text("无硬件测试：仅合成诊断报告").font(.headline)
            Text(status)
            Button("打开诊断预览") { presented = true }.disabled(store == nil)
        }.padding(30).frame(minWidth: 440, minHeight: 180)
        .task {
            do {
                let created = DiagnosticReportStore(directory: root.appendingPathComponent("history"), appVersion: "0.3.8", appBuild: "1")
                let ids = try await DiagnosticPreviewFixture.seed(created)
                try await created.exportData(taskID: ids.large).write(to: root.appendingPathComponent("expected-large.json"), options: .atomic)
                try await created.exportData(taskID: ids.small).write(to: root.appendingPathComponent("expected-small.json"), options: .atomic)
                store = created; status = "首次数据刻录／需要恢复检查 + 准备追加摘要／已完成"; presented = true
            } catch { status = "Fixture failed: \(error)" }
        }
        .sheet(isPresented: $presented) { if let store { DiagnosticsView(store: store) } }
    }
}
