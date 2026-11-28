import Foundation
import Darwin

/// Compare a read-only mount with the scanned session without reading payload.
/// Root names alone cannot distinguish two sessions with different children.
enum MountedSessionDirectory {
    static func validateISO(root: URL, snapshot: SessionSnapshot) throws {
        var entries = Dictionary(uniqueKeysWithValues: snapshot.treeEntries.map { ($0.name, $0) })
        if let bridge = snapshot.bridge, snapshot.volume?.joliet == false {
            // The kernel may preserve primary ISO identifier case. Only accept
            // aliases already bound to the same extent by the bridge reader.
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            for entry in snapshot.treeEntries where !names.contains(entry.name) {
                guard let raw = bridge.primaryIDs[entry.lba],
                      var alias = String(data: raw, encoding: .ascii) else { continue }
                if alias.hasSuffix(";1") { alias.removeLast(2) }
                guard alias.lowercased() == entry.name, names.contains(alias),
                      entries[alias] == nil else { continue }
                entries.removeValue(forKey: entry.name)
                entries[alias] = entry
            }
        }
        try validate(root: root, entries: entries)
    }

    static func validate(root: URL, entries: [String: ISOEntry]) throws {
        guard entries.count <= 10000 else { throw DiscFailure("挂载目录项目过多，无法核对。") }
        var children: [String: Set<String>] = ["": []]
        for (path, entry) in entries {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 33,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
                throw DiscFailure("会话目录包含无效相对路径。")
            }
            let parent = parts.dropLast().joined(separator: "/")
            guard parent.isEmpty || entries[parent]?.directory == true else {
                throw DiscFailure("会话目录缺少父目录。")
            }
            children[parent, default: []].insert(String(parts.last!))
            if entry.directory && children[path] == nil { children[path] = [] }
        }
        // Check every ancestor before enumerating any child so no symlink is followed.
        for path in children.keys.sorted(by: { $0.count < $1.count }) {
            let url = path.isEmpty ? root : root.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw posix("无法检查挂载目录。") }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw DiscFailure("挂载目录类型与最新会话不一致。")
            }
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
            guard names == children[path] else { throw DiscFailure("挂载子目录不是最新会话；请重新识别后打开。") }
        }
        for (path, entry) in entries where !entry.directory {
            var info = stat()
            guard lstat(root.appendingPathComponent(path).path, &info) == 0 else {
                throw posix("无法检查挂载文件。")
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size == Int64(entry.bytes) else {
                throw DiscFailure("挂载文件类型或大小与最新会话不一致。")
            }
        }
    }

    private static func posix(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
