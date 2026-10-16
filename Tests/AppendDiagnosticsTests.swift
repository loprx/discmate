import Foundation
import Darwin

enum AppendDiagnosticsTests {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-append-report-\(UUID())")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("私人文件.txt")
        try Data("private body must not leak".utf8).write(to: file)
        let store = DiagnosticReportStore(directory: root.appendingPathComponent("reports"), appVersion: "0.3.8", appBuild: "1")
        func verify(_ reason: DiagnosticAppendFailure, _ operation: () throws -> Void) async throws {
            let id = store.startTask(kind: .appendPreparation)
            let failure: Error
            do { try operation(); fatalError("Expected preflight failure \(reason)") }
            catch { failure = error }
            let rejection = AppendDiagnostics.rejection(failure)
            precondition(rejection.evidence.append?.failure == reason)
            store.record(taskID: id, event: .appendPreflightRejected, error: rejection.error, evidence: rejection.evidence)
            store.finish(taskID: id, outcome: .failed)
            let data = try await store.exportData(taskID: id)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let report = try decoder.decode(DiagnosticReport.self, from: data)
            precondition(report.id == id && report.appVersion == "0.3.8" && report.outcome == .failed)
            precondition(report.events.last?.evidence?.append?.failure == reason)
            precondition(report.events.last?.errorCodes.isEmpty == false)
            if reason == .unavailable {
                precondition(report.events.last?.errorCodes == [.init(source: .posix, code: 2)])
            }
            let json = String(decoding: data, as: UTF8.self)
            for secret in [root.path, file.lastPathComponent, "missing-private-file.txt", "private body must not leak"] {
                precondition(!json.contains(secret))
            }
        }
        try await verify(.conflict) {
            _ = try AppendSourceTree.inspect([file], existing: [ISOEntry(name: file.lastPathComponent, lba: 25, bytes: 1, directory: false)])
        }
        let link = root.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        try await verify(.unsupportedSource) { _ = try AppendSourceTree.inspect([link]) }
        try await verify(.unavailable) {
            _ = try AppendSourceTree.inspect([root.appendingPathComponent("missing-private-file.txt")])
        }
        try await verify(.unavailable) {
            _ = try FileProof.capture(root.appendingPathComponent("missing-private-file.txt"))
        }
        let fifo = root.appendingPathComponent("special-pipe")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        try await verify(.unsupportedSource) { _ = try FileProof.capture(fifo) }
        let badName = root.appendingPathComponent("bad;name.txt")
        try Data().write(to: badName)
        try await verify(.invalidName) { _ = try AppendSourceTree.inspect([badName]) }
        let tree = try AppendSourceTree.inspect([file])
        try Data("changed after summary".utf8).write(to: file)
        try await verify(.sourceChanged) { try tree.validateUnchanged() }
        try await verify(.capacity) { try IncrementalISO.validateCapacity(imageBytes: 921600, freeBlocks: 100, start: 5000) }
        try await verify(.invalidTree) {
            let track = RecordedTrack(number: 1, session: 1, start: 0, blocks: 100, blank: false,
                damaged: false, nextWritable: nil, freeBlocks: 0)
            _ = try RecordedDirectoryTree.scan(root: ISOEntry(name: ".", lba: 20, bytes: 2048, directory: true),
                tracks: [track], capacityBytes: 204800) { _ in
                    [ISOEntry(name: "cycle", lba: 20, bytes: 2048, directory: true)]
                }
        }
        let medium = LegacyMediaPreflight(drivePath: "offline-only", driveID: 1, mediaID: 2, bsd: "offline-disk", wasBlank: false)
        try await verify(.mediaChanged) { try medium.validate(driveID: 1, mediaID: 3, bsd: "offline-disk") }
        print("PASS actual append failure reports: conflict, symlink, naming, source mutation, capacity; task/version/error codes/privacy")
    }
}
