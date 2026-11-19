import Foundation

enum SoftwareUpdateTests {
    @MainActor
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticReportStore(directory: root, appVersion: "0.3.9", appBuild: "123")
        let model = SoftwareUpdateModel(version: "0.3.9", build: "123")
        let secret = "/Users/private/私人文件?token=secret-token"
        let latest = Data(#"{"tag_name":"v0.3.14"}"#.utf8)
        let page = SoftwareUpdate.releases.appendingPathComponent("tag/v0.3.14")
        let ok = response(200)

        let equal = try SoftwareUpdate.compare(latest, response: ok, installed: "0.3.14")
        let ahead = try SoftwareUpdate.compare(latest, response: ok, installed: "0.4.0")
        precondition(equal == .current && ahead == .current)

        await model.check(reports: store) { (latest, ok) }
        precondition(model.state == .finished(.available(version: "0.3.14", page: page)))
        await model.check(reports: store) { (Data(#"{"tag_name":"v0.3.9"}"#.utf8), ok) }
        precondition(model.state == .finished(.current))
        await model.check(reports: store) { (latest, response(403)) }
        precondition(model.state == .failed)
        await model.check(reports: store) { (Data(secret.utf8), ok) }
        precondition(model.state == .failed)
        await model.check(reports: store) {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                          userInfo: [NSLocalizedDescriptionKey: secret])
        }
        precondition(model.state == .failed)

        let reports = await store.reports()
        let expected: [(DiagnosticEventKind, DiagnosticErrorCode?)] = [
            (.updateCheckFailed, .init(source: .url, code: Int64(NSURLErrorTimedOut))),
            (.updateCheckFailed, .init(source: .updateVersion, code: 1)),
            (.updateCheckFailed, .init(source: .updateHTTP, code: 403)),
            (.updateCurrent, nil),
            (.updateAvailable, nil)
        ]
        precondition(reports.count == expected.count && Set(reports.map(\.id)).count == expected.count)
        for (report, (event, code)) in zip(reports, expected) {
            let data = try await store.exportData(taskID: report.id)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(DiagnosticReport.self, from: data)
            precondition(decoded.task == .softwareUpdate && decoded.appVersion == "0.3.9")
            precondition(decoded.events.first?.kind == .started)
            precondition(decoded.outcome == (code == nil ? .completed : .failed))
            precondition(decoded.events.last?.kind == event)
            precondition(decoded.events.last?.errorCodes == (code.map { [$0] } ?? []))
            precondition(!String(decoding: data, as: UTF8.self).contains("secret-token"))
        }
        print("PASS software updates and redacted reports")
    }

    private static func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: SoftwareUpdate.releases, statusCode: code,
                        httpVersion: nil, headerFields: nil)!
    }
}
