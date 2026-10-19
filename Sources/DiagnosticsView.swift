import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Reads only the app's structured diagnostics store, never the optical device
/// or raw task logs. Preview and export share the exact same immutable snapshot.
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reports: [DiagnosticReport] = []
    @State private var selectedID: UUID?
    @State private var preview: DiagnosticPreview?
    @State private var pageIndex = 0
    @State private var previewLoading = false
    @State private var request = DiagnosticPreviewRequest()
    @State private var revision = UUID()
    @State private var status = "正在载入本机诊断记录…"
    @State private var loading = false
    @State private var saving = false
    private let store: DiagnosticReportStore

    init(store: DiagnosticReportStore = .shared) { self.store = store }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出诊断日志").font(.title2.bold())
            Text("选择一次任务，预览后保存 JSON 文件。包含任务阶段、时间、进度、错误码、软件与系统版本、已知型号和介质类型；后端提供时还包含速度、设备状态及 SCSI 数值错误原因。刷新任务还会只读记录已知 Lenovo 光驱的 USB、光盘驱动和 DVD 介质节点数量，用于区分识别停在哪一层。未知信息会省略或标为 unknown。不会包含文件名、路径、文件内容、序列号、原始设备响应或凭据。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("仅收集此版本开始记录的任务，旧版原始日志不导入。最近保留 30 次任务，每次最多 256 条事件；省略数量记录在 omittedEventCount（已省略事件数）。导出不会访问光驱或自动上传。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("任务", selection: $selectedID) {
                    Text("选择任务").tag(nil as UUID?)
                    ForEach(reports) { report in
                        Text("\(report.startedAt.formatted(date: .numeric, time: .standard)) · \(taskLabel(report.task)) · \(outcomeLabel(report.outcome))")
                            .tag(Optional(report.id))
                    }
                }.disabled(loading || saving || reports.isEmpty)
                Button("刷新记录") { Task { await reload() } }
                    .disabled(loading || saving)
                    .help("仅刷新应用已保存的脱敏记录，不检查光驱；通常立即完成。")
            }
            if previewLoading || loading {
                ProgressView("正在准备诊断预览…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let preview, preview.taskID == selectedID {
                HStack {
                    Button("上一页") { pageIndex -= 1 }.disabled(pageIndex == 0)
                    Text("第 \(pageIndex + 1) / \(preview.pages.count) 页 · 完整报告 \(preview.exportData.count) 字节")
                        .font(.caption).monospacedDigit()
                    Button("下一页") { pageIndex += 1 }.disabled(pageIndex + 1 >= preview.pages.count)
                    Spacer()
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(preview.pages[pageIndex]).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.id(pageIndex).background(Color.secondary.opacity(0.08)).cornerRadius(8)
                Text("预览按页显示；保存包含全部已保留事件，不受当前页影响。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(preview.omissionExplanation)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(reports.isEmpty ? "尚无可导出的任务记录。" : "选择任务后显示实际导出内容。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("inProgress 表示尚未记录终态，不能证明任务仍在运行；backendDone 仅表示后端完成。读回结果会区分新增文件源哈希匹配、全盘可读且已知源匹配，以及仅完成可读性检查。未出现的步骤不视为已完成。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? "正在保存…" : "保存诊断文件…") { save() }
                    .disabled(preview == nil || preview?.taskID != selectedID || previewLoading || loading || saving)
                    .help("保存选中任务的完整诊断报告到你选择的位置，不会上传；通常不到几秒。")
            }
        }
        .padding(24).frame(minWidth: 660, idealWidth: 740, minHeight: 560, idealHeight: 660)
        .task { await reload() }
        .task(id: PreviewKey(id: selectedID, revision: revision)) { await updatePreview() }
        .onDisappear { request.begin(taskID: nil) }
    }

    private struct PreviewKey: Equatable { let id: UUID?; let revision: UUID }

    @MainActor private func reload() async {
        request.begin(taskID: nil)
        preview = nil
        loading = true
        reports = await store.reports()
        if !reports.contains(where: { $0.id == selectedID }) { selectedID = reports.first?.id }
        let failed = await store.persistenceIssue()
        status = failed ? "部分本机记录无法保存或读取；当前预览仍可导出。错误详情不包含在报告中。" : "保存后由你自行检查和分享；应用不会自动上传。"
        loading = false
        revision = UUID()
    }

    @MainActor private func updatePreview() async {
        let id = selectedID
        let token = request.begin(taskID: id)
        preview = nil
        pageIndex = 0
        previewLoading = false
        guard let id, !loading else { return }
        previewLoading = true
        do {
            let prepared = try await DiagnosticPreview.load(store: store, taskID: id)
            guard !Task.isCancelled, selectedID == id, request.accepts(token, taskID: id) else { return }
            preview = prepared
            previewLoading = false
        } catch {
            guard !Task.isCancelled, selectedID == id, request.accepts(token, taskID: id) else { return }
            previewLoading = false
            status = "此任务记录暂不可用，请刷新记录。"
        }
    }

    @MainActor private func save() {
        guard let preview, preview.taskID == selectedID, !previewLoading, !loading else { return }
        let data = preview.exportData
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "DiscMate-diagnostics.json"
        panel.canCreateDirectories = true
        panel.title = "保存脱敏诊断日志"
        saving = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { saving = false; return }
            Task {
                // Only the exported file path is used for this write. It never
                // enters the diagnostic model or a subsequent error report.
                let success = await Task.detached(priority: .utility) {
                    do { try data.write(to: url, options: .atomic); return true }
                    catch { return false }
                }.value
                status = success ? "诊断文件已保存。分享前可再次检查文件内容。" : "保存失败，请选择可写入的位置后重试。"
                saving = false
            }
        }
    }

    private func taskLabel(_ kind: DiagnosticTaskKind) -> String {
        switch kind {
        case .dataBurn: return "首次数据刻录"
        case .append: return "追加刻录"
        case .appendPreparation: return "准备追加摘要"
        case .audioBurn: return "音频刻录"
        case .imageBurn: return "镜像刻录"
        case .videoBurn: return "视频刻录"
        case .erase: return "擦除"
        case .readback: return "读回校验"
        case .openLatest: return "打开最新会话"
        case .eject: return "推出"
        case .deviceRefresh: return "刷新设备"
        case .clipboardImport: return "从剪贴板添加"
        }
    }

    private func outcomeLabel(_ outcome: DiagnosticOutcome) -> String {
        switch outcome {
        case .inProgress: return "尚未记录终态"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .needsRecovery: return "需要恢复检查"
        }
    }
}
