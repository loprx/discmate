import Foundation

/// Immutable, already-sanitized export plus bounded pages. Pagination never
/// drops retained events or changes the bytes saved by the user.
struct DiagnosticPreview: Sendable {
    static let maximumPageBytes = 8_192
    let taskID: UUID
    let exportData: Data
    let pages: [String]
    let omittedEventCount: Int

    init(data: Data, taskID: UUID) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReport.self, from: data)
        guard report.id == taskID, let text = String(data: data, encoding: .utf8) else {
            throw DiagnosticExportError.taskUnavailable
        }
        self.taskID = taskID
        exportData = data
        omittedEventCount = report.omittedEventCount
        var chunks: [String] = [], page = "", bytes = 0
        // Scalar boundaries preserve UTF-8 exactly, including non-ASCII text.
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            if bytes + size > Self.maximumPageBytes {
                chunks.append(page); page = ""; bytes = 0
            }
            page.unicodeScalars.append(scalar)
            bytes += size
        }
        if !page.isEmpty { chunks.append(page) }
        pages = chunks
    }

    static func load(store: DiagnosticReportStore, taskID: UUID) async throws -> Self {
        let data = try await store.exportData(taskID: taskID)
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try Self(data: data, taskID: taskID)
        }.value
    }

    var omissionExplanation: String {
        "已省略事件数（omittedEventCount）：\(omittedEventCount)。这是日志保留上限导致未保存的历史事件数量，不是配置，也不是其他预览页的数量。已省略事件无法从这份报告恢复。"
    }
}

/// A request generation protects even a refresh of the same task ID. Selection
/// equality alone cannot distinguish an older snapshot from the new request.
struct DiagnosticPreviewRequest {
    private(set) var token = UUID()
    private(set) var taskID: UUID?

    @discardableResult mutating func begin(taskID: UUID?) -> UUID {
        token = UUID()
        self.taskID = taskID
        return token
    }

    func accepts(_ token: UUID, taskID: UUID) -> Bool {
        self.token == token && self.taskID == taskID
    }
}
