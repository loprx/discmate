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
    static let sessionReserveBlocks: UInt64 = 16_384
    static func hasSpaceForSession(_ freeBlocks: UInt32) -> Bool {
        UInt64(freeBlocks) > sessionReserveBlocks + 1
    }
    static func validateCapacity(imageBytes: UInt64, freeBlocks: UInt32, start: UInt32) throws {
        guard imageBytes > 0, imageBytes < UInt64(UInt32.max), imageBytes % 2048 == 0,
              imageBytes / 2048 + sessionReserveBlocks < UInt64(freeBlocks),
              imageBytes / 2048 + UInt64(start) <= UInt64(UInt32.max) else {
            throw AppendPreflightFailure(.capacity, "镜像与 32 MiB 会话收尾预留超出可追加空间，或镜像超出 4 GiB/地址限制。请减少新增内容。")
        }
    }

    static func validateTarget(_ snapshot: SessionSnapshot, imageBytes: UInt64) throws {
        if let track = snapshot.reservedTrack {
            guard imageBytes > 0, imageBytes < UInt64(UInt32.max), imageBytes % 2048 == 0,
                  (imageBytes + 32767) / 32768 * 16 <= UInt64(track.blocks) else {
                throw AppendPreflightFailure(.capacity, "镜像超出预留轨道容量。")
            }
        } else {
            guard let target = snapshot.writable, let start = target.nextWritable else { throw DiscFailure("没有可写轨道。") }
            try validateCapacity(imageBytes: imageBytes, freeBlocks: target.freeBlocks, start: start)
        }
    }

    // Compatibility entry point for existing callers.
    static func build(snapshot: SessionSnapshot, verified: [VerifiedFile], sources: [URL], directory: URL) throws -> PreparedIncrementalISO {
        try AppendImagePreparation.build(snapshot: snapshot, verified: verified, sources: sources, directory: directory)
    }
    static func makeHybrid(_ source: URL, image: URL, log: URL, bridge: BridgeSession?, udf: UDFVolumeProbe?) throws {
        try Data().write(to: log, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        var arguments = ["makehybrid", "-iso", "-joliet"]
        if let label = udf?.label {
            arguments = ["makehybrid", "-udf", "-udf-version", "1.02", "-udf-volume-name", label]
        } else if let bridge {
            arguments += ["-udf", "-udf-version", "1.02", "-iso-volume-name", bridge.isoLabel,
                          "-joliet-volume-name", bridge.udfLabel, "-udf-volume-name", bridge.udfLabel]
        } else { arguments += ["-default-volume-name", "DISCMATE"] }
        process.arguments = arguments + ["-o", image.path, source.path]
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

    static func relocate(_ image: URL, start: UInt32, old: [ISOEntry], new: [FileProof], directories: [String],
                                 bytes: UInt64, preservedPrimaryDirectories: [String]?, bridge: BridgeSession?) throws {
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
        if let bridge {
            try HybridUDF.relocate(start: start, blocks: UInt32(bytes / 2048), partitionStart: bridge.partitionStart,
                                   references: references, read: { try read($0, 2048) }, patch: patch)
        }
        for var tree in trees {
            if !tree.volume.joliet, let preservedPrimaryDirectories {
                // hdiutil can give two names the same shortened ISO alias.
                // Every old path must still identify its own placeholder in
                // the primary namespace, even if the Joliet names are fine.
                let primaryDirectories = Set(tree.entries.filter(\.directory).map(\.name))
                let matchingFiles = tree.entries.filter { !$0.directory && references[$0.lba]?.name == $0.name }
                guard matchingFiles.count == old.count, primaryDirectories.isSuperset(of: preservedPrimaryDirectories) else {
                    throw AppendPreflightFailure(.invalidName, "新目录会改变已有 ISO 文件或目录的名称，请调整与旧名称冲突的新增项目。")
                }
            }
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
                        if !tree.volume.joliet, let id = bridge?.primaryIDs[reference.lba] {
                            record = Data(record.prefix(33)) + id
                            if id.count.isMultiple(of: 2) { record.append(0) }
                            record[0] = UInt8(record.count)
                            record[32] = UInt8(id.count)
                        }
                        putBoth32(&record, 2, reference.lba); putBoth32(&record, 10, reference.bytes)
                        guard foundReferences.insert(entry.lba).inserted else { throw DiscFailure("旧文件引用重复。") }
                    } else {
                        guard UInt64(entry.lba) * 2048 + UInt64(entry.bytes) <= bytes else { throw DiscFailure("生成的文件或目录区段越界。") }
                        putBoth32(&record, 2, try shifted(entry.lba))
                    }
                    relocated.append(record)
                }
                guard special == Set([".", ".."]) else { throw DiscFailure("目录缺少自目录或父目录记录。") }
                if !tree.volume.joliet, bridge != nil {
                    func identifier(_ record: Data) -> Data { Data(record[33..<(33 + Int(record[32]))]) }
                    relocated.sort { identifier($0).lexicographicallyPrecedes(identifier($1)) }
                    let names = try relocated.map { try ISO9660.record($0, joliet: false).name }
                    guard Set(names).count == names.count else { throw AppendPreflightFailure(.conflict, "新增文件的 ISO 短名称与已有文件冲突。") }
                }
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
            if !tree.volume.joliet, let identifier = bridge?.rawISOIdentifier {
                guard identifier.count == 32 else { throw DiscFailure("ISO 卷标字段长度无效。") }
                tree.descriptor.replaceSubrange(40..<72, with: identifier)
            }
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
        if let bridge {
            func readSession(_ lba: UInt32) throws -> Data {
                guard lba >= start else { throw DiscFailure("新 UDF 目录意外引用旧元数据。") }
                return try read(lba - start, 2048)
            }
            let volume = try UDFVolumeProbe.inspect(sessionStart: start, capacityBlocks: UInt64(start) + bytes / 2048,
                                                    allowISOBridge: true, readSector: readSession)
            let udf = try UDFDirectoryReader.entries(volume: volume, capacityBlocks: UInt64(start) + bytes / 2048,
                                                     readSector: readSession)
            guard volume.partitionStart == bridge.partitionStart, volume.label == bridge.udfLabel,
                  udf.count == entries.count, udf.allSatisfy({ item in entries.contains {
                      !$0.directory && $0.name == item.path && $0.bytes == item.bytes &&
                      item.contiguousExtent == UDFRecordedExtent(lba: $0.lba, bytes: $0.bytes)
                  } }) else { throw DiscFailure("UDF 和 Joliet 的文件名、长度或数据位置不一致。") }
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
