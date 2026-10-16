import Foundation
import CryptoKit
import Darwin

struct PreparedIncrementalISO: Sendable {
    let image: URL
    let proof: AppendProof
    let imageBytes: UInt64
    let referencedBytes: UInt64
    let imageSHA256: String
    var sourceTree: AppendSourceTree? = nil
    var preservedDirectoryPaths: [String] = []
    var addedFileCount: Int { sourceTree?.files.count ?? proof.files.count }
    var addedDirectoryCount: Int {
        let preserved = Set(preservedDirectoryPaths)
        return sourceTree?.directories.filter { !preserved.contains($0) }.count ?? 0
    }
    var preservedFileCount: Int { proof.preserved?.count ?? max(0, proof.files.count - addedFileCount) }
    var preservedDirectoryCount: Int { preservedDirectoryPaths.count }
    var addedBytes: UInt64 { sourceTree?.files.reduce(0) { $0 + $1.bytes } ?? proof.files.reduce(0) { $0 + $1.bytes } }
    var capacityMarginBytes: UInt64 { 32 * 1024 * 1024 }

    func validateSourcesUnchanged() throws {
        guard let sourceTree else { return }
        do {
            try sourceTree.validateUnchanged()
            let expected = Dictionary(uniqueKeysWithValues: proof.files.map { ($0.path, $0) })
            for source in sourceTree.files {
                let actual = try FileProof.capture(source.url)
                guard let proof = expected[source.path], actual.bytes == proof.bytes, actual.sha256 == proof.sha256 else {
                    throw AppendPreflightFailure(.sourceChanged, "源文件内容已变化，请重新准备追加摘要。")
                }
            }
            try sourceTree.validateUnchanged()
        } catch let failure as AppendPreflightFailure where failure.reason == .sourceChanged { throw failure }
        catch {
            throw AppendPreflightFailure(.sourceChanged, "源文件或目录已变化，请重新准备追加摘要。",
                underlyingError: (error as? AppendPreflightFailure)?.underlyingError ?? error as NSError)
        }
    }
}

/// hdiutil authors both namespaces. Old files are unique tiny placeholders;
/// recursive directory records then reference old absolute extents. Neither
/// old source files nor old payload are needed during standard preparation.
enum IncrementalISO {
    static func validateCapacity(imageBytes: UInt64, freeBlocks: UInt32, start: UInt32) throws {
        guard imageBytes > 0, imageBytes < UInt64(UInt32.max), imageBytes % 2048 == 0,
              imageBytes / 2048 + 16384 < UInt64(freeBlocks),
              imageBytes / 2048 + UInt64(start) <= UInt64(UInt32.max) else {
            throw AppendPreflightFailure(.capacity, "镜像与 32 MiB 会话收尾预留超出可追加空间，或镜像超出 4 GiB/地址限制。请减少新增内容。")
        }
    }

    static func build(snapshot: SessionSnapshot, verified: [VerifiedFile], sources: [URL], directory: URL) throws -> PreparedIncrementalISO {
        let oldFiles = snapshot.fileEntries, oldDirectories = snapshot.directoryPaths
        guard snapshot.appendable, snapshot.volume.joliet, let writable = snapshot.writable,
              let start = writable.nextWritable, writable.freeBlocks > 0, !sources.isEmpty,
              (snapshot.recordedEntries != nil || snapshot.rootEntries.allSatisfy { !$0.directory }),
              snapshot.tracks.filter({ !$0.blank }).allSatisfy({ !$0.damaged && UInt64($0.start) + UInt64($0.blocks) <= start }),
              UInt64(start) + UInt64(writable.freeBlocks) <= snapshot.identity.bytes / 2048 else {
            throw AppendPreflightFailure(.invalidTree, "需要可追加的 ISO/Joliet 光盘及完整目录信息，请重新识别光盘。")
        }
        guard verified.isEmpty || (verified.count == oldFiles.count && Set(verified.map(\.path)) == Set(oldFiles.map(\.name))) else {
            throw AppendPreflightFailure(.invalidTree, "旧文件校验依据与目录不一致。")
        }
        let oldDirectorySet = Set(oldDirectories)
        for entry in snapshot.treeEntries {
            let parent = entry.name.split(separator: "/").dropLast().joined(separator: "/")
            guard parent.isEmpty || oldDirectorySet.contains(parent),
                  snapshot.tracks.contains(where: { $0.contains(entry.lba, bytes: entry.bytes) }) else {
                throw AppendPreflightFailure(.invalidTree, "旧目录缺少父项或区段无效，请重新识别光盘。")
            }
            if !entry.directory && !verified.isEmpty {
                guard verified.contains(where: { $0.path == entry.name && $0.bytes == entry.bytes &&
                    $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else {
                    throw AppendPreflightFailure(.invalidTree, "旧文件大小或校验依据不一致。")
                }
            }
        }
        let sourceTree = try AppendSourceTree.inspect(sources, existing: snapshot.treeEntries)
        let directories = Set(oldDirectories + sourceTree.directories).sorted()
        guard !sourceTree.files.isEmpty || directories.count > oldDirectories.count else {
            throw AppendPreflightFailure(.conflict, "所选目录没有新增内容，无需追加。")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? fm.removeItem(at: directory) } }
        let staging = directory.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for path in directories.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) {
            try fm.createDirectory(at: staging.appendingPathComponent(path), withIntermediateDirectories: false)
        }
        for (index, old) in oldFiles.enumerated() {
            try Data("DiscMate extent reference \(index)\n".utf8).write(to: staging.appendingPathComponent(old.name), options: .withoutOverwriting)
        }
        var newProofs: [FileProof] = []
        for source in sourceTree.files {
            let destination = staging.appendingPathComponent(source.path)
            let captured = try FileProof.capture(source.url, to: destination)
            newProofs.append(FileProof(path: source.path, bytes: captured.bytes, sha256: captured.sha256))
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
        }
        try sourceTree.validateUnchanged()
        let image = directory.appendingPathComponent("append.iso")
        try makeHybrid(staging, image: image, log: directory.appendingPathComponent("hdiutil.log"))
        let bytes = (try fm.attributesOfItem(atPath: image.path)[.size] as! NSNumber).uint64Value
        try validateCapacity(imageBytes: bytes, freeBlocks: writable.freeBlocks, start: start)
        try relocate(image, start: start, old: oldFiles, new: newProofs, directories: directories, bytes: bytes)
        var proof = AppendProof(previousSession: snapshot.latest.session, expectedStart: start,
            files: verified.map { FileProof(path: $0.path, bytes: UInt64($0.bytes), sha256: $0.sha256) } + newProofs,
            directories: directories.isEmpty ? nil : directories)
        if verified.isEmpty { proof.preserved = oldFiles.map { PreservedFile(path: $0.name, bytes: $0.bytes, lba: $0.lba) } }
        try proof.validateStructure()
        let imageProof = try FileProof.capture(image)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = try encoder.encode(proof)
        guard manifest.count <= 1024 * 1024 else { throw AppendPreflightFailure(.invalidTree, "源清单超过 1 MiB 的安全读取上限，请减少项目或缩短路径。") }
        try manifest.write(to: directory.appendingPathComponent("expected.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: image.path)
        try sourceTree.validateUnchanged()
        completed = true
        return PreparedIncrementalISO(image: image, proof: proof, imageBytes: bytes,
            referencedBytes: oldFiles.reduce(0) { $0 + UInt64($1.bytes) }, imageSHA256: imageProof.sha256,
            sourceTree: sourceTree, preservedDirectoryPaths: oldDirectories)
    }

    private static func makeHybrid(_ source: URL, image: URL, log: URL) throws {
        try Data().write(to: log, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-iso", "-joliet", "-default-volume-name", "DISCMATE", "-o", image.path, source.path]
        process.standardOutput = output; process.standardError = output
        try process.run()
        // Local-files-only process. Termination on timeout is never applied to a
        // hardware burner; keep waiting for this child to actually exit.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 300)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume(); defer { timer.cancel() }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let text = String(decoding: try Data(contentsOf: log).prefix(8192), as: UTF8.self)
            throw NSError(domain: "DiscMate.Process", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "本地 ISO 创建失败（\(process.terminationStatus)）：\(text)"])
        }
    }

    private struct DirectoryNode {
        let entry: ISOEntry
        let path: String
        let parent: UInt32
        let identifier: Data
        let records: [Data]
    }
    private struct Tree {
        var descriptor: Data
        let sector: UInt32
        let volume: ISOVolume
        let nodes: [DirectoryNode]
        let entries: [ISOEntry]
    }

    private static func relocate(_ image: URL, start: UInt32, old: [ISOEntry], new: [FileProof], directories: [String], bytes: UInt64) throws {
        let file = try FileHandle(forUpdating: image); defer { try? file.close() }
        func read(_ lba: UInt32, _ count: UInt32) throws -> Data {
            guard count <= 1024 * 1024, UInt64(lba) * 2048 + UInt64(count) <= bytes else { throw DiscFailure("本地 ISO 元数据越界。") }
            try file.seek(toOffset: UInt64(lba) * 2048)
            let data = try file.read(upToCount: Int(count)) ?? Data()
            guard data.count == count else { throw DiscFailure("本地 ISO 读取不完整。") }
            return data
        }
        func shifted(_ lba: UInt32) throws -> UInt32 {
            guard UInt64(lba) + UInt64(start) <= UInt32.max else { throw DiscFailure("ISO 地址溢出。") }
            return lba + start
        }
        var trees: [Tree] = [], terminated = false
        for sector: UInt32 in 16..<48 {
            let data = try read(sector, 2048)
            if data[0] == 255 { _ = try ISO9660.descriptor(data); terminated = true; break }
            guard let volume = try ISO9660.descriptor(data), !trees.contains(where: { $0.volume.joliet == volume.joliet }),
                  UInt64(try ISO9660.both32(data, 80)) * 2048 <= bytes else { throw DiscFailure("不支持本地工具生成的 ISO 布局。") }
            var nodes: [DirectoryNode] = [], entries: [ISOEntry] = [], visited = Set<UInt32>(), metadata: UInt64 = 0
            func visit(_ entry: ISOEntry, path: String, parent: UInt32, identifier: Data, depth: Int) throws {
                guard depth <= 8, entry.directory, entry.bytes > 0, entry.bytes % 2048 == 0,
                      visited.insert(entry.lba).inserted else { throw DiscFailure("生成的 ISO 目录有循环或超过深度限制。") }
                metadata += UInt64(entry.bytes)
                guard metadata <= 32 * 1024 * 1024 else { throw DiscFailure("生成的 ISO 目录元数据超过上限。") }
                let content = try read(entry.lba, entry.bytes)
                _ = try ISO9660.directory(content, joliet: volume.joliet)
                let records = try directoryRecords(content)
                nodes.append(DirectoryNode(entry: entry, path: path, parent: parent, identifier: identifier, records: records))
                for raw in records {
                    let child = try ISO9660.record(raw, joliet: volume.joliet)
                    if child.name == "." || child.name == ".." { continue }
                    let relative = path.isEmpty ? child.name : path + "/" + child.name
                    entries.append(ISOEntry(name: relative, lba: child.lba, bytes: child.bytes, directory: child.directory))
                    guard entries.count <= 10000 else { throw DiscFailure("生成的 ISO 目录项超过上限。") }
                    if child.directory {
                        try visit(child, path: relative, parent: entry.lba,
                            identifier: raw.subdata(in: 33..<(33 + Int(raw[32]))), depth: depth + 1)
                    }
                }
            }
            try visit(volume.root, path: "", parent: volume.root.lba, identifier: Data([0]), depth: 0)
            trees.append(Tree(descriptor: data, sector: sector, volume: volume, nodes: nodes, entries: entries))
        }
        guard terminated, trees.count == 2, let joliet = trees.first(where: { $0.volume.joliet }) else { throw DiscFailure("必须同时包含 ISO 和 Joliet 目录。") }
        let allFiles = joliet.entries.filter { !$0.directory }
        guard allFiles.count == old.count + new.count,
              Set(allFiles.map(\.name)) == Set(old.map(\.name) + new.map(\.path)),
              Set(joliet.entries.filter(\.directory).map(\.name)) == Set(directories) else {
            throw DiscFailure("本地镜像改写了文件名或目录结构，请调整名称后重试。")
        }
        var references: [UInt32: ISOEntry] = [:]
        for entry in old {
            guard let placeholder = allFiles.first(where: { $0.name == entry.name }), placeholder.bytes > 0,
                  placeholder.bytes <= 2048, references.updateValue(entry, forKey: placeholder.lba) == nil,
                  allFiles.filter({ $0.lba == placeholder.lba }).count == 1 else { throw DiscFailure("旧文件占位区段不唯一。") }
        }
        var patches: [UInt32: Data] = [:]
        func patch(_ lba: UInt32, _ data: Data) throws {
            guard UInt64(lba) * 2048 + UInt64(data.count) <= bytes, patches[lba] == nil else { throw DiscFailure("ISO 元数据区段重复或越界。") }
            patches[lba] = data
        }
        for var tree in trees {
            var foundReferences = Set<UInt32>()
            for node in tree.nodes {
                var relocated: [Data] = [], special = Set<String>()
                for raw in node.records {
                    let entry = try ISO9660.record(raw, joliet: tree.volume.joliet)
                    // Drop System Use, including unrelocated CE and placeholder
                    // metadata. Directory dates/names and ISO flags remain.
                    let length = 33 + Int(raw[32]) + (raw[32] % 2 == 0 ? 1 : 0)
                    var record = Data(raw.prefix(length)); record[0] = UInt8(length)
                    if entry.name == "." || entry.name == ".." {
                        guard entry.directory, entry.lba == (entry.name == "." ? node.entry.lba : node.parent),
                              special.insert(entry.name).inserted else { throw DiscFailure("ISO 自目录或父目录记录不一致。") }
                        putBoth32(&record, 2, try shifted(entry.lba))
                    } else if !entry.directory, let reference = references[entry.lba] {
                        putBoth32(&record, 2, reference.lba); putBoth32(&record, 10, reference.bytes)
                        guard foundReferences.insert(entry.lba).inserted else { throw DiscFailure("旧文件引用重复。") }
                    } else {
                        guard UInt64(entry.lba) * 2048 + UInt64(entry.bytes) <= bytes else { throw DiscFailure("生成的文件或目录区段越界。") }
                        putBoth32(&record, 2, try shifted(entry.lba))
                    }
                    relocated.append(record)
                }
                guard special == Set([".", ".."]) else { throw DiscFailure("目录缺少自目录或父目录记录。") }
                try patch(node.entry.lba, pack(relocated, bytes: Int(node.entry.bytes)))
            }
            guard foundReferences == Set(references.keys) else { throw DiscFailure("ISO/Joliet 旧文件引用不一致。") }
            let tableBytes = try ISO9660.both32(tree.descriptor, 132)
            guard tableBytes > 0, tableBytes <= 1024 * 1024 else { throw DiscFailure("ISO 路径表大小越界。") }
            let nodes = Dictionary(uniqueKeysWithValues: tree.nodes.map { ($0.entry.lba, $0) })
            for (offset, big) in [(140, false), (144, false), (148, true), (152, true)] {
                let lba = number32(tree.descriptor, offset, big: big)
                if lba == 0 {
                    guard offset == 144 || offset == 152 else { throw DiscFailure("缺少必需路径表。") }
                    continue
                }
                var table = try read(lba, tableBytes), cursor = 0
                var ordered: [UInt32] = [], seen = Set<UInt32>()
                while cursor < table.count {
                    guard cursor + 8 <= table.count else { throw DiscFailure("路径表记录截断。") }
                    let length = Int(table[cursor]), recordBytes = 8 + length + (length % 2)
                    guard length > 0, table[cursor + 1] == 0, cursor + recordBytes <= table.count else { throw DiscFailure("路径表名称或长度无效。") }
                    let directoryLBA = number32(table, cursor + 2, big: big)
                    let parentIndex = big ? Int(table[cursor + 6]) * 256 + Int(table[cursor + 7]) : Int(table[cursor + 6]) + Int(table[cursor + 7]) * 256
                    guard let node = nodes[directoryLBA], seen.insert(directoryLBA).inserted,
                          table.subdata(in: (cursor + 8)..<(cursor + 8 + length)) == node.identifier else { throw DiscFailure("路径表与目录不一致。") }
                    if ordered.isEmpty {
                        guard directoryLBA == tree.volume.root.lba, parentIndex == 1 else { throw DiscFailure("根路径表无效。") }
                    } else {
                        guard parentIndex >= 1, parentIndex <= ordered.count, ordered[parentIndex - 1] == node.parent else { throw DiscFailure("路径表父目录索引无效。") }
                    }
                    ordered.append(directoryLBA)
                    put32(&table, cursor + 2, try shifted(directoryLBA), big: big)
                    cursor += recordBytes
                }
                guard seen == Set(nodes.keys) else { throw DiscFailure("路径表没有完整覆盖目录。") }
                try patch(lba, table)
                put32(&tree.descriptor, offset, try shifted(lba), big: big)
            }
            putBoth32(&tree.descriptor, 80, try shifted(UInt32(bytes / 2048)))
            putBoth32(&tree.descriptor, 158, try shifted(tree.volume.root.lba))
            try patch(tree.sector, tree.descriptor)
        }
        for lba in references.keys { try patch(lba, Data(repeating: 0, count: 2048)) }
        var end: UInt64 = 0
        for lba in patches.keys.sorted() {
            guard UInt64(lba) * 2048 >= end else { throw DiscFailure("ISO 元数据区段重叠。") }
            let data = patches[lba]!
            try file.seek(toOffset: UInt64(lba) * 2048); try file.write(contentsOf: data)
            end = UInt64(lba) * 2048 + UInt64(data.count)
        }
        try file.synchronize()
        var entries: [ISOEntry] = []
        let expectedDirectories = Dictionary(uniqueKeysWithValues: joliet.nodes.map { ($0.path, $0.entry) })
        for node in joliet.nodes {
            for entry in try ISO9660.directory(read(node.entry.lba, node.entry.bytes), joliet: true) {
                let path = node.path.isEmpty ? entry.name : node.path + "/" + entry.name
                entries.append(ISOEntry(name: path, lba: entry.lba, bytes: entry.bytes, directory: entry.directory))
                if entry.directory {
                    guard let expected = expectedDirectories[path], entry.lba == (try shifted(expected.lba)), entry.bytes == expected.bytes else {
                        throw DiscFailure("改写后的子目录地址不一致。")
                    }
                }
            }
        }
        for reference in old {
            guard entries.first(where: { $0.name == reference.name }) == reference else { throw DiscFailure("增量镜像未保留旧文件区段。") }
        }
        for expected in new {
            guard let entry = entries.first(where: { $0.name == expected.path }), !entry.directory, entry.lba >= start,
                  UInt64(entry.bytes) == expected.bytes else { throw DiscFailure("增量镜像的新文件无效。") }
            try file.seek(toOffset: UInt64(entry.lba - start) * 2048)
            var remaining = UInt64(entry.bytes), digest = SHA256()
            while remaining > 0 {
                let data = try file.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
                guard !data.isEmpty else { throw DiscFailure("增量镜像新文件截断。") }
                digest.update(data: data); remaining -= UInt64(data.count)
            }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else { throw DiscFailure("增量镜像新文件哈希不一致。") }
        }
    }

    private static func directoryRecords(_ data: Data) throws -> [Data] {
        var offset = 0; var records: [Data] = []
        while offset < data.count {
            let length = Int(data[offset])
            if length == 0 { offset = (offset / 2048 + 1) * 2048; continue }
            guard length >= 34, offset + length <= data.count, offset % 2048 + length <= 2048 else { throw DiscFailure("目录记录越界。") }
            records.append(data.subdata(in: offset..<(offset + length))); offset += length
        }
        return records
    }
    private static func pack(_ records: [Data], bytes: Int) throws -> Data {
        var output = Data(repeating: 0, count: bytes); var offset = 0
        for record in records {
            if offset % 2048 + record.count > 2048 { offset = (offset / 2048 + 1) * 2048 }
            guard offset + record.count <= bytes else { throw DiscFailure("重建目录超出分配区段。") }
            output.replaceSubrange(offset..<(offset + record.count), with: record); offset += record.count
        }
        return output
    }
    private static func number32(_ data: Data, _ offset: Int, big: Bool) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * (big ? 3 - $1 : $1)) }
    }
    private static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32, big: Bool) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (big ? 3 - i : i))) }
    }
    private static func putBoth32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        put32(&data, offset, value, big: false); put32(&data, offset + 4, value, big: true)
    }
}
