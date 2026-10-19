import Foundation

enum ClipboardSourcesTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-clipboard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文文件.txt")
        try Data("source".utf8).write(to: file)
        switch try ClipboardSource.classify(fileURLs: [file, file], text: "private clipboard text") {
        case .files(let urls): precondition(urls == [file.standardizedFileURL])
        case .text: fatalError("Finder files must take precedence over text")
        }
        CoreTests.reject("remote clipboard URL") {
            _ = try ClipboardSource.classify(fileURLs: [URL(string: "https://example.invalid/a")!], text: nil)
        }
        CoreTests.reject("empty clipboard") { _ = try ClipboardSource.classify(fileURLs: [], text: nil) }
        CoreTests.reject("oversize text") {
            _ = try ClipboardSource.classify(fileURLs: [], text: String(repeating: "密", count: 350_000))
        }
        let secret = "私人合同\nsecret-token\n"
        guard case .text(let bytes) = try ClipboardSource.classify(fileURLs: [], text: secret) else { fatalError() }
        let staged = try ClipboardSource.stageText(bytes, root: root)
        let stagedBytes = try Data(contentsOf: staged)
        let permissions = try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber
        precondition(stagedBytes == bytes)
        precondition(permissions?.intValue == 0o600)
        _ = try AppendSourceTree.inspect([staged])
        try ClipboardSource.discardText(at: staged)
        precondition(!FileManager.default.fileExists(atPath: staged.path))
        print("PASS clipboard sources: Finder selection, text staging, source inspection, bounds and cleanup")
    }
}
