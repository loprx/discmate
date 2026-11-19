import Foundation
import SwiftUI

enum SoftwareUpdateResult: Equatable {
    case current
    case available(version: String, page: URL)
}

enum SoftwareUpdate {
    static let releases = URL(string: "https://github.com/loprx/discmate/releases")!
    private static let endpoint = URL(string: "https://api.github.com/repos/loprx/discmate/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
    }

    static func fetch() async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try await session.data(for: request)
    }

    static func compare(_ data: Data, response: URLResponse, installed: String) throws -> SoftwareUpdateResult {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NSError(domain: "DiscMate.UpdateHTTP", code: status) }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let latest = components(release.tag_name),
              let current = components(installed) else {
            throw NSError(domain: "DiscMate.UpdateVersion", code: 1)
        }
        guard current.lexicographicallyPrecedes(latest) else { return .current }
        return .available(version: latest.map(String.init).joined(separator: "."),
                          page: releases.appendingPathComponent("tag").appendingPathComponent(release.tag_name))
    }

    private static func components(_ version: String) -> [Int]? {
        let digits = version.hasPrefix("v") ? version.dropFirst() : version[...]
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            return nil
        }
        let values = parts.compactMap { Int($0) }
        return values.count == parts.count ? values : nil
    }
}

@MainActor
final class SoftwareUpdateModel: ObservableObject {
    enum State: Equatable {
        case idle, checking, finished(SoftwareUpdateResult), failed
    }

    @Published private(set) var state: State = .idle
    let version: String
    let build: String

    init(version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
        self.version = version ?? "未知"
        self.build = build ?? "未知"
    }

    func check(reports: DiagnosticReportStore = .shared,
               fetch: () async throws -> (Data, URLResponse) = SoftwareUpdate.fetch) async {
        guard state != .checking else { return }
        state = .checking
        let id = reports.startTask(kind: .softwareUpdate)
        do {
            let (data, response) = try await fetch()
            let result = try SoftwareUpdate.compare(data, response: response, installed: version)
            state = .finished(result)
            reports.record(taskID: id, event: result == .current ? .updateCurrent : .updateAvailable)
            reports.finish(taskID: id, outcome: .completed)
        } catch {
            state = .failed
            reports.record(taskID: id, event: .updateCheckFailed, error: error as NSError)
            reports.finish(taskID: id, outcome: .failed)
        }
    }
}
