import Foundation
import Darwin

struct AppendPreflightFailure: LocalizedError {
    enum Reason: String { case conflict, unsupportedSource, invalidName, sourceChanged, capacity, invalidTree, unavailable, other }
    let reason: Reason
    let message: String
    var underlyingError: NSError? = nil
    var errorDescription: String? { message }
    init(_ reason: Reason, _ message: String, underlyingError: NSError? = nil) {
        self.reason = reason; self.message = message; self.underlyingError = underlyingError
    }
}

struct AppendSourceTree: Sendable {
    struct SourceFile: Equatable, Sendable { let path: String; let url: URL; let bytes: UInt64 }
    private struct Stamp: Equatable, Sendable {
        let path: String; let device: Int32; let inode: UInt64; let size: Int64
        let modified: Int64; let modifiedNS: Int64; let changed: Int64; let changedNS: Int64
    }
    let files: [SourceFile]
    let directories: [String]
    private let roots: [URL]
    private let stamps: [Stamp]
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 8 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf16.count <= 64 &&
            !part.unicodeScalars.contains { $0.value < 32 || $0.value > 0xffff || "*/\\:;?".unicodeScalars.contains($0) }
        }
    }
    static func inspect(_ sources: [URL], existing: [ISOEntry] = []) throws -> AppendSourceTree {
        var files: [SourceFile] = []; var dirs: [String] = []; var stamps: [Stamp] = []
        var names: [String: (String, Bool)] = [:]
        var selected = Set<String>()
        func register(_ path: String, _ directory: Bool) throws {
            guard validPath(path) else { throw AppendPreflightFailure(.invalidName, "名称或目录深度不在 Joliet 支持范围（最多 8 层）：\(path)") }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            if let previous = names[key] {
                guard previous.0 == path && previous.1 && directory else { throw AppendPreflightFailure(.conflict, "名称冲突：\(path)。请在源文件中改名后重试。") }
            } else { names[key] = (path, directory) }
            guard names.count <= 10000 else { throw AppendPreflightFailure(.invalidTree, "目录项超过 10000，请减少本次文件。") }
        }
        for entry in existing { try register(entry.name, entry.directory) }
        func visit(_ url: URL, path: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                throw AppendPreflightFailure(.unavailable, "无法读取源项目：\(path)", underlyingError: error)
            }
            let kind = info.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) else { throw AppendPreflightFailure(.unsupportedSource, "不支持符号链接或特殊文件：\(path)") }
            let directory = kind == mode_t(S_IFDIR)
            try register(path, directory)
            // Repeated directory selection is rejected rather than silently skipping children.
            guard selected.insert(path).inserted else { throw AppendPreflightFailure(.conflict, "重复选择目录：\(path)") }
            stamps.append(Stamp(path: path, device: info.st_dev, inode: info.st_ino, size: info.st_size,
                modified: Int64(info.st_mtimespec.tv_sec), modifiedNS: Int64(info.st_mtimespec.tv_nsec),
                changed: Int64(info.st_ctimespec.tv_sec), changedNS: Int64(info.st_ctimespec.tv_nsec)))
            if directory {
                dirs.append(path)
                let children: [String]
                do { children = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }
                catch { throw AppendPreflightFailure(.unavailable, "无法读取目录：\(path)", underlyingError: error as NSError) }
                for child in children { try visit(url.appendingPathComponent(child), path: path + "/" + child) }
            } else {
                guard info.st_size >= 0, UInt64(info.st_size) < UInt64(UInt32.max) else { throw AppendPreflightFailure(.unsupportedSource, "单个文件必须小于 4 GiB：\(path)") }
                guard access(url.path, R_OK) == 0 else { throw AppendPreflightFailure(.unavailable, "源文件不可读：\(path)", underlyingError: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
                files.append(SourceFile(path: path, url: url, bytes: UInt64(info.st_size)))
            }
        }
        for source in sources.sorted(by: { $0.path < $1.path }) {
            guard source.isFileURL else { throw AppendPreflightFailure(.unsupportedSource, "仅支持本地文件和目录。") }
            try visit(source, path: source.lastPathComponent)
        }
        return AppendSourceTree(files: files.sorted { $0.path < $1.path }, directories: dirs.sorted(), roots: sources, stamps: stamps.sorted { $0.path < $1.path })
    }
    func validateUnchanged() throws {
        do {
            let now = try Self.inspect(roots)
            guard now.files == files, now.directories == directories, now.stamps == stamps else { throw AppendPreflightFailure(.sourceChanged, "源文件或目录已变化，请重新准备摘要。") }
        } catch let failure as AppendPreflightFailure where failure.reason == .sourceChanged { throw failure }
        catch { throw AppendPreflightFailure(.sourceChanged, "源文件或目录已变化，请重新准备摘要。", underlyingError: (error as? AppendPreflightFailure)?.underlyingError ?? error as NSError) }
    }
}
