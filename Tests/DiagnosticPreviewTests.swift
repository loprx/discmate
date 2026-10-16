import Foundation

enum DiagnosticPreviewTests {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-preview-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticReportStore(directory: root, appVersion: "0.3.8", appBuild: "1")
        let ids = try await DiagnosticPreviewFixture.seed(store)
        let data = try await store.exportData(taskID: ids.large), started = Date()
        let preview = try await DiagnosticPreview.load(store: store, taskID: ids.large)
        precondition(preview.pages.count > 10 && preview.omittedEventCount > 0)
        precondition(preview.pages.allSatisfy { !$0.isEmpty && $0.utf8.count <= 8192 })
        precondition(Data(preview.pages.joined().utf8) == data && preview.exportData == data)
        let text = String(decoding: data, as: UTF8.self)
        precondition(text.contains("needsRecovery") && text.contains("dataBurn"))
        for secret in ["private-owner", "私人文件.txt", "private-secret", "/Users/"] { precondition(!text.contains(secret)) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReport.self, from: data)
        precondition(report.events.count == 256 && report.events.last?.kind == .recoveryRequired)
        var request = DiagnosticPreviewRequest()
        let old = request.begin(taskID: ids.large)
        let other = request.begin(taskID: ids.small)
        precondition(!request.accepts(old, taskID: ids.large) && request.accepts(other, taskID: ids.small))
        let refresh = request.begin(taskID: ids.small)
        precondition(!request.accepts(other, taskID: ids.small) && request.accepts(refresh, taskID: ids.small))
        request.begin(taskID: nil)
        precondition(!request.accepts(refresh, taskID: ids.small))
        let small = try await DiagnosticPreview.load(store: store, taskID: ids.small)
        precondition(small.taskID == ids.small && small.exportData != data)
        do { _ = try DiagnosticPreview(data: data, taskID: ids.small); fatalError("Expected mismatched task rejection") }
        catch DiagnosticExportError.taskUnavailable { }
        let saved = root.appendingPathComponent("full-export.json")
        try preview.exportData.write(to: saved, options: .atomic)
        let savedData = try Data(contentsOf: saved)
        precondition(savedData == data)
        print("PASS large recovery preview: bytes=\(data.count), pages=\(preview.pages.count), omitted=\(preview.omittedEventCount), seconds=\(Date().timeIntervalSince(started)); exact export, privacy, task switch/refresh/close tokens")
    }
}
