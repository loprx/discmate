import AppKit
import Foundation

enum ClipboardSourceError: LocalizedError {
    case empty, tooLarge, unsupported

    var errorDescription: String? {
        switch self {
        case .empty: return "剪贴板没有可添加的文件、文件夹或文字。"
        case .tooLarge: return "剪贴板文字超过 1 MiB；请先保存为文件后添加。"
        case .unsupported: return "剪贴板内容不是本机文件、文件夹或纯文本。"
        }
    }
}

enum ClipboardSource: Sendable {
    case files([URL])
    case text(Data)

    static let maximumTextBytes = 1024 * 1024

    static func classify(fileURLs: [URL], text: String?) throws -> Self {
        if !fileURLs.isEmpty {
            guard fileURLs.allSatisfy(\.isFileURL) else { throw ClipboardSourceError.unsupported }
            return .files(Array(Set(fileURLs.map(\.standardizedFileURL))).sorted { $0.path < $1.path })
        }
        guard let text, !text.isEmpty else { throw ClipboardSourceError.empty }
        let data = Data(text.utf8)
        guard data.count <= maximumTextBytes else { throw ClipboardSourceError.tooLarge }
        return .text(data)
    }

    @MainActor
    static func readPasteboard(_ pasteboard: NSPasteboard = .general) throws -> Self {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return try classify(fileURLs: urls, text: pasteboard.string(forType: .string))
    }

    static func stageText(_ data: Data, root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard !data.isEmpty else { throw ClipboardSourceError.empty }
        guard data.count <= maximumTextBytes else { throw ClipboardSourceError.tooLarge }
        let directory = root.appendingPathComponent("discmate-clipboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let url = directory.appendingPathComponent("剪贴板文本-\(UUID().uuidString.prefix(8)).txt")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func discardText(at url: URL) throws {
        guard url.lastPathComponent.hasPrefix("剪贴板文本-"), url.pathExtension == "txt",
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("discmate-clipboard-") else { return }
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
