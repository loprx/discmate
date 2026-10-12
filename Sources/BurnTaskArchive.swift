import Foundation

/// Retain the small source manifest and lifecycle evidence across app/system
/// restarts. Captured payloads stay in temporary staging; never copy them here.
struct BurnTaskArchive {
    let directory: URL
    var proofURL: URL { directory.appendingPathComponent("expected.json") }
    var logURL: URL { directory.appendingPathComponent("events.log") }

    static func create(proof: AppendProof, priorLog: URL?, root: URL? = nil) throws -> BurnTaskArchive {
        let base: URL
        if let root { base = root }
        else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("DiscMate/Tasks", isDirectory: true)
        }
        let archive = BurnTaskArchive(directory: base.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: archive.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: archive.proofURL, options: .atomic)
        let log = try priorLog.map { try Data(contentsOf: $0) } ?? Data()
        try log.write(to: archive.logURL, options: .atomic)
        for url in [archive.proofURL, archive.logURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return archive
    }
}
