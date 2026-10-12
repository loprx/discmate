import Foundation
import CryptoKit
import Darwin

struct PreparedIncrementalISO: Sendable {
    let image: URL
    let proof: AppendProof
    let imageBytes: UInt64
    let referencedBytes: UInt64
    let imageSHA256: String
}

/// File-only preparation for flat ISO/Joliet sessions. hdiutil authors the new
/// namespace; old files are tiny unique placeholders, then both directory trees
/// refer to their original absolute extents. No old payload is read or copied.
/// Standard preparation uses only the old directory/extents. Optional `verified`
/// is retained for legacy callers that explicitly supply complete old digests.
enum IncrementalISO {
    static func build(snapshot: SessionSnapshot, verified: [VerifiedFile], sources: [URL], directory: URL) throws -> PreparedIncrementalISO {
        guard snapshot.appendable, snapshot.volume.joliet, let writable = snapshot.writable,
              let start = writable.nextWritable, writable.freeBlocks > 0,
              snapshot.rootEntries.allSatisfy({ !$0.directory }), !sources.isEmpty,
              (verified.isEmpty || (verified.count == snapshot.rootEntries.count &&
              Set(verified.map(\.path)) == Set(snapshot.rootEntries.map(\.name)))),
              snapshot.tracks.filter({ !$0.blank }).allSatisfy({ !$0.damaged && UInt64($0.start) + UInt64($0.blocks) <= start }),
              UInt64(start) + UInt64(writable.freeBlocks) <= snapshot.identity.bytes / 2048 else {
            throw DiscFailure("增量追加目前支持根目录 ISO/Joliet 普通文件；需要有效追加地址和完整目录信息。")
        }
        for old in snapshot.rootEntries {
            guard snapshot.tracks.contains(where: { $0.contains(old.lba, bytes: old.bytes) }),
                  verified.isEmpty || verified.contains(where: { $0.path == old.name && $0.bytes == old.bytes &&
                      $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else {
                throw DiscFailure("旧文件区段或校验依据无效：\(old.name)")
            }
        }
        let names = snapshot.rootEntries.map(\.name) + sources.map(\.lastPathComponent)
        guard names.count <= 10000, Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == names.count,
              names.allSatisfy(validName) else { throw DiscFailure("文件名重复或不在当前 Joliet 增量支持范围。") }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? fm.removeItem(at: directory) } }
        let staging = directory.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for (index, old) in snapshot.rootEntries.enumerated() {
            try Data("DiscMate extent reference \(index)\n".utf8).write(to: staging.appendingPathComponent(old.name), options: .withoutOverwriting)
        }
        var newProofs: [FileProof] = []
        for source in sources {
            let destination = staging.appendingPathComponent(source.lastPathComponent)
            newProofs.append(try FileProof.capture(source, to: destination))
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
        }
        let image = directory.appendingPathComponent("append.iso")
        try makeHybrid(staging, image: image, log: directory.appendingPathComponent("hdiutil.log"))
        let size = try fm.attributesOfItem(atPath: image.path)[.size] as! NSNumber
        let bytes = size.uint64Value
        // Conservative 32 MiB margin for the unvalidated physical session close.
        guard bytes > 0, bytes % 2048 == 0, bytes / 2048 + 16384 < UInt64(writable.freeBlocks),
              bytes / 2048 + UInt64(start) <= UInt32.max else { throw DiscFailure("增量镜像超出可写容量或地址范围。") }
        try relocate(image, start: start, old: snapshot.rootEntries, new: newProofs, bytes: bytes)
        var proof = AppendProof(previousSession: snapshot.latest.session, expectedStart: start,
            files: verified.map { FileProof(path: $0.path, bytes: UInt64($0.bytes), sha256: $0.sha256) } + newProofs)
        if verified.isEmpty {
            proof.preserved = snapshot.rootEntries.map { PreservedFile(path: $0.name, bytes: $0.bytes, lba: $0.lba) }
        }
        try proof.validateStructure()
        let imageProof = try FileProof.capture(image)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: directory.appendingPathComponent("expected.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: image.path)
        completed = true
        return PreparedIncrementalISO(image: image, proof: proof, imageBytes: bytes,
            referencedBytes: snapshot.rootEntries.reduce(0) { $0 + UInt64($1.bytes) }, imageSHA256: imageProof.sha256)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf16.count <= 64 &&
        !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 0xffff || "*/\\:;?".unicodeScalars.contains($0) })
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
            throw DiscFailure("本地 ISO 创建失败（\(process.terminationStatus)）：\(text)")
        }
    }

    private struct Tree {
        var descriptor: Data
        let sector: UInt32
        let volume: ISOVolume
        let records: [Data]
    }

    private static func relocate(_ image: URL, start: UInt32, old: [ISOEntry], new: [FileProof], bytes: UInt64) throws {
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
        var trees: [Tree] = []; var terminated = false
        for sector: UInt32 in 16..<48 {
            let data = try read(sector, 2048)
            if data[0] == 255 { _ = try ISO9660.descriptor(data); terminated = true; break }
            guard let volume = try ISO9660.descriptor(data), !trees.contains(where: { $0.volume.joliet == volume.joliet }),
                  UInt64(try ISO9660.both32(data, 80)) * 2048 <= bytes,
                  volume.root.bytes > 0, volume.root.bytes % 2048 == 0 else { throw DiscFailure("不支持本地工具生成的 ISO 布局。") }
            let directory = try read(volume.root.lba, volume.root.bytes)
            _ = try ISO9660.directory(directory, joliet: volume.joliet)
            let records = try directoryRecords(directory)
            trees.append(Tree(descriptor: data, sector: sector, volume: volume, records: records))
        }
        guard terminated, trees.count == 2, let joliet = trees.first(where: { $0.volume.joliet }) else { throw DiscFailure("必须同时包含 ISO 和 Joliet 目录。") }
        let all = try joliet.records.map { try ISO9660.record($0, joliet: true) }.filter { $0.name != "." && $0.name != ".." }
        guard Set(all.map(\.name)) == Set(old.map(\.name) + new.map(\.path)), all.allSatisfy({ !$0.directory }) else {
            throw DiscFailure("本地镜像改写了文件名或包含不支持的目录。")
        }
        var references: [UInt32: ISOEntry] = [:]
        for entry in old {
            guard let placeholder = all.first(where: { $0.name == entry.name }), placeholder.bytes > 0,
                  placeholder.bytes <= 2048, references.updateValue(entry, forKey: placeholder.lba) == nil,
                  all.filter({ $0.lba == placeholder.lba }).count == 1 else { throw DiscFailure("旧文件占位区段不唯一。") }
        }
        var patches: [UInt32: Data] = [:]
        func patch(_ lba: UInt32, _ data: Data) throws {
            let end = UInt64(lba) * 2048 + UInt64(data.count)
            guard end <= bytes, !patches.contains(where: { pos, previous in
                UInt64(lba) * 2048 < UInt64(pos) * 2048 + UInt64(previous.count) && UInt64(pos) * 2048 < end
            }) else { throw DiscFailure("ISO 元数据区段重叠。") }
            patches[lba] = data
        }
        for var tree in trees {
            var relocated: [Data] = []; var foundReferences = Set<UInt32>()
            for raw in tree.records {
                let entry = try ISO9660.record(raw, joliet: tree.volume.joliet)
                // Drop System Use entirely (including SP/ER/CE/PX/TF/Apple AA).
                // Carrying placeholder metadata or unrelocated CE pointers would
                // be incorrect. Directory date/name and ordinary ISO flags remain.
                let length = 33 + Int(raw[32]) + (raw[32] % 2 == 0 ? 1 : 0)
                var record = Data(raw.prefix(length)); record[0] = UInt8(length)
                if entry.name == "." || entry.name == ".." {
                    guard entry.directory, entry.lba == tree.volume.root.lba else { throw DiscFailure("只支持根目录。") }
                    putBoth32(&record, 2, try shifted(entry.lba))
                } else if let reference = references[entry.lba] {
                    guard !entry.directory else { throw DiscFailure("旧文件引用变成了目录。") }
                    putBoth32(&record, 2, reference.lba); putBoth32(&record, 10, reference.bytes)
                    foundReferences.insert(entry.lba)
                } else {
                    guard !entry.directory, UInt64(entry.lba) * 2048 + UInt64(entry.bytes) <= bytes else { throw DiscFailure("新文件区段越界。") }
                    putBoth32(&record, 2, try shifted(entry.lba))
                }
                relocated.append(record)
            }
            guard foundReferences == Set(references.keys) else { throw DiscFailure("ISO/Joliet 旧文件引用不一致。") }
            try patch(tree.volume.root.lba, pack(relocated, bytes: Int(tree.volume.root.bytes)))
            guard try ISO9660.both32(tree.descriptor, 132) == 10 else { throw DiscFailure("不支持多目录路径表。") }
            for (offset, big) in [(140, false), (144, false), (148, true), (152, true)] {
                let lba = number32(tree.descriptor, offset, big: big)
                if lba == 0 {
                    guard offset == 144 || offset == 152 else { throw DiscFailure("缺少必需路径表。") }
                    continue
                }
                var table = try read(lba, 10)
                guard table[0] == 1, table[1] == 0, table[8] == 0, table[9] == 0,
                      number32(table, 2, big: big) == tree.volume.root.lba,
                      Array(table[6..<8]) == (big ? [0, 1] : [1, 0]) else { throw DiscFailure("根路径表不一致。") }
                put32(&table, 2, try shifted(tree.volume.root.lba), big: big)
                try patch(lba, table)
                put32(&tree.descriptor, offset, try shifted(lba), big: big)
            }
            putBoth32(&tree.descriptor, 80, try shifted(UInt32(bytes / 2048)))
            putBoth32(&tree.descriptor, 158, try shifted(tree.volume.root.lba))
            try patch(tree.sector, tree.descriptor)
        }
        // Clear orphan placeholder contents; no bytes of an old file are copied.
        for lba in references.keys { try patch(lba, Data(repeating: 0, count: 2048)) }
        for (lba, data) in patches {
            try file.seek(toOffset: UInt64(lba) * 2048); try file.write(contentsOf: data)
        }
        try file.synchronize()
        // Validate generated references and every new byte after patching.
        let entries = try ISO9660.directory(read(joliet.volume.root.lba, joliet.volume.root.bytes), joliet: true)
        for reference in old {
            guard entries.first(where: { $0.name == reference.name }) == reference else { throw DiscFailure("增量镜像未保留旧文件区段。") }
        }
        for expected in new {
            guard let entry = entries.first(where: { $0.name == expected.path }), entry.lba >= start,
                  UInt64(entry.bytes) == expected.bytes else { throw DiscFailure("增量镜像的新文件无效。") }
            try file.seek(toOffset: UInt64(entry.lba - start) * 2048)
            var remaining = UInt64(entry.bytes); var hash = SHA256()
            while remaining > 0 {
                let data = try file.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
                guard !data.isEmpty else { throw DiscFailure("增量镜像新文件截断。") }
                hash.update(data: data); remaining -= UInt64(data.count)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else { throw DiscFailure("增量镜像新文件哈希不一致。") }
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
