import Foundation

/// Metadata-only traversal shared by device scans and offline malformed-tree
/// tests. Each directory is bounded independently and across the whole walk.
enum RecordedDirectoryTree {
    static let maximumMetadataBytes: UInt64 = 32 * 1024 * 1024
    static func scan(root: ISOEntry, tracks: [RecordedTrack], capacityBytes: UInt64,
                     readDirectory: (ISOEntry) throws -> [ISOEntry]) throws -> [ISOEntry] {
        var result: [ISOEntry] = []
        var visited = Set<UInt32>(), paths = Set<String>()
        var metadata: UInt64 = 0, payload: UInt64 = 0
        func visit(_ directory: ISOEntry, prefix: String, depth: Int) throws {
            guard depth <= 32, directory.directory, directory.bytes > 0,
                  directory.bytes <= 1024 * 1024,
                  tracks.contains(where: { $0.contains(directory.lba, bytes: directory.bytes) }),
                  visited.insert(directory.lba).inserted else {
                throw AppendPreflightFailure(.invalidTree, "光盘目录含循环、越界或超过支持的深度/大小，已停止读取。")
            }
            metadata += UInt64(directory.bytes)
            guard metadata <= maximumMetadataBytes else { throw AppendPreflightFailure(.invalidTree, "光盘目录元数据超过 32 MiB，已停止读取。") }
            for child in try readDirectory(directory) {
                guard !child.name.isEmpty, child.name != ".", child.name != "..",
                      !child.name.contains("/"), !child.name.contains("\0") else {
                    throw AppendPreflightFailure(.invalidTree, "光盘目录包含无效名称，已停止读取。")
                }
                let path = prefix.isEmpty ? child.name : prefix + "/" + child.name
                guard paths.insert(path).inserted, paths.count <= 10000,
                      tracks.contains(where: { $0.contains(child.lba, bytes: child.bytes) }) else {
                    throw AppendPreflightFailure(.invalidTree, "光盘目录重复、项目超过 10000 或文件区段越界，已停止读取。")
                }
                result.append(ISOEntry(name: path, lba: child.lba, bytes: child.bytes, directory: child.directory))
                if child.directory {
                    try visit(child, prefix: path, depth: depth + 1)
                } else {
                    payload += UInt64(child.bytes)
                    guard payload <= capacityBytes else { throw AppendPreflightFailure(.invalidTree, "目录声明的文件总量超过介质容量，已停止读取。") }
                }
            }
        }
        try visit(root, prefix: "", depth: 0)
        return result.sorted { $0.name < $1.name }
    }
}
