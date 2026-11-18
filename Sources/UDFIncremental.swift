import Foundation
import CryptoKit
import Darwin

/// Restricted UDF 1.02 single-root-file candidate. Uses only metadata from an
/// already recorded session; existing file entries and payload remain on disc.
/// This builder does not authorize a device write.
enum UDFIncremental {
    static let blockBytes = 2048
    static let sessionBlocks = 600

    struct Result {
        let image: URL
        let imageSHA256: String
        let oldFiles: Int
        let newBytes: Int
        let sessionStart: UInt32
    }

    static func build(oldImage: URL, oldRecordedBlocks: UInt32, sessionStart: UInt32,
                      newFile: URL, destination: URL) throws -> Result {
        guard oldRecordedBlocks > 300, sessionStart > oldRecordedBlocks,
              UInt64(sessionStart) + UInt64(sessionBlocks) <= UInt32.max else {
            throw DiscFailure("UDF 旧会话或新会话地址无效。")
        }
        let source = try FileHandle(forReadingFrom: oldImage)
        defer { try? source.close() }
        func readOld(_ lba: UInt32) throws -> Data {
            guard lba < oldRecordedBlocks else { throw DiscFailure("UDF 元数据超出已记录轨道。") }
            try source.seek(toOffset: UInt64(lba) * 2048)
            let data = try source.read(upToCount: 2048) ?? Data()
            guard data.count == 2048 else { throw DiscFailure("UDF 旧会话元数据不完整。") }
            return data
        }
        let volume = try UDFVolumeProbe.inspect(sessionStart: 0, capacityBlocks: UInt64(oldRecordedBlocks), readSector: readOld)
        guard volume.revision == 0x0102, volume.partitionMapType == 1,
              volume.partitionStart < sessionStart,
              volume.partitionBlocks + volume.partitionStart <= oldRecordedBlocks else {
            throw DiscFailure("只支持已确认的 UDF 1.02 单物理分区旧会话。")
        }
        let entries = try UDFDirectoryReader.entries(volume: volume, capacityBlocks: UInt64(oldRecordedBlocks), readSector: readOld)
        let name = newFile.lastPathComponent
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"),
              !entries.contains(where: { $0.path.precomposedStringWithCanonicalMapping.lowercased() == name.precomposedStringWithCanonicalMapping.lowercased() }),
              !name.utf16.contains(0), 1 + name.utf16.count * 2 <= 255 else {
            throw DiscFailure("UDF 新文件名无效、重复或过长。")
        }
        let payload = try readSource(newFile)

        let anchor = try readOld(256)
        try UDFVolumeProbe.checkTag(anchor, id: 2, address: 256)
        let oldVDSStart = get32(anchor, 20)
        guard get32(anchor, 16) == 16 * 2048, oldVDSStart > 0,
              get32(anchor, 24) == 16 * 2048,
              UInt64(oldVDSStart) + 16 <= oldRecordedBlocks,
              UInt64(get32(anchor, 28)) + 16 <= oldRecordedBlocks else {
            throw DiscFailure("旧 UDF 卷描述符布局不符合当前受限生成器。")
        }
        let oldVDS = try (0..<6).map { try readOld(oldVDSStart + UInt32($0)) }
        let ids = oldVDS.map { get16($0, 0) }
        guard Set(ids) == Set([1, 4, 5, 6, 7, 8]),
              let logicalIndex = ids.firstIndex(of: 6), let partitionIndex = ids.firstIndex(of: 5),
              get32(oldVDS[partitionIndex], 188) == volume.partitionStart,
              get32(oldVDS[partitionIndex], 192) == volume.partitionBlocks else {
            throw DiscFailure("旧 UDF 描述符顺序或分区字段不符合当前受限生成器。")
        }
        let integrityBytes = get32(oldVDS[logicalIndex], 432)
        let integrityStart = get32(oldVDS[logicalIndex], 436)
        guard integrityBytes > 0, integrityBytes <= 16 * 2048, integrityBytes % 2048 == 0,
              UInt64(integrityStart) + UInt64(integrityBytes / 2048) <= oldRecordedBlocks else {
            throw DiscFailure("旧 UDF 完整性描述符范围无效。")
        }
        for (index, block) in oldVDS.enumerated() {
            try UDFVolumeProbe.checkTag(block, id: get16(block, 0), address: oldVDSStart + UInt32(index))
        }
        let part = volume.partitionStart
        let fsdAbs = part + volume.fileSetBlock
        let oldFSD = try readOld(fsdAbs)
        try UDFVolumeProbe.checkTag(oldFSD, id: 256, address: volume.fileSetBlock)
        guard get16(oldFSD, 408) == volume.partitionNumber else { throw DiscFailure("UDF 根目录分区不一致。") }
        let oldRootLBN = get32(oldFSD, 404)
        let oldRoot = try readOld(part + oldRootLBN)
        try UDFVolumeProbe.checkTag(oldRoot, id: 261, address: oldRootLBN)
        let rootAD = 176 + Int(get32(oldRoot, 168))
        guard oldRoot[27] == 4, get16(oldRoot, 34) & 7 == 0,
              rootAD + 8 <= 2048, get32(oldRoot, 172) == 8,
              get64(oldRoot, 56) > 0, get64(oldRoot, 56) < 1500,
              get32(oldRoot, rootAD) == get64(oldRoot, 56) else {
            throw DiscFailure("旧 UDF 根目录使用未支持的分配形式。")
        }
        let oldDirLBN = get32(oldRoot, rootAD + 4)
        let oldDir = try readOld(part + oldDirLBN)
        var body = Data(oldDir.prefix(Int(get64(oldRoot, 56))))
        var cursor = 0, template: Data?
        let newFSD = sessionStart + 288, newRoot = sessionStart + 290
        let newDir = sessionStart + 291, newFE = sessionStart + 292, newPayload = sessionStart + 293
        let reserve = sessionStart + 544
        func relative(_ absolute: UInt32) throws -> UInt32 {
            guard absolute >= part else { throw DiscFailure("UDF 分区相对地址下溢。") }
            return absolute - part
        }
        while cursor < body.count {
            guard cursor + 38 <= body.count else { throw DiscFailure("UDF 根目录项截断。") }
            let rawLength = 38 + Int(get16(body, cursor + 36)) + Int(body[cursor + 19])
            let length = (rawLength + 3) & ~3
            guard cursor + length <= body.count else { throw DiscFailure("UDF 根目录项越界。") }
            var record = Data(body[cursor..<(cursor + length)])
            try UDFVolumeProbe.checkTag(record, id: 257, address: oldDirLBN)
            if record[18] & 0x08 != 0 { put32(&record, 24, try relative(newRoot)) }
            else if record[18] & 0x02 == 0, template == nil {
                guard get16(record, 28) == volume.partitionNumber else { throw DiscFailure("UDF 根目录项跨分区。") }
                let fileLBN = get32(record, 24)
                let candidate = try readOld(part + fileLBN)
                try UDFVolumeProbe.checkTag(candidate, id: 261, address: fileLBN)
                let candidateAD = 176 + Int(get32(candidate, 168))
                if candidate[27] == 5, get16(candidate, 34) & 7 == 0,
                   candidateAD + 8 <= 2048, get32(candidate, 172) == 8 { template = candidate }
            }
            retag(&record, location: try relative(newDir))
            body.replaceSubrange(cursor..<(cursor + length), with: record)
            cursor += length
        }
        guard let template else { throw DiscFailure("旧 UDF 根目录缺少可复用的普通文件入口模板。") }
        let encoded = Array(name.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
        let fidLength = (38 + 1 + encoded.count + 3) & ~3
        guard body.count + fidLength <= 2048 else { throw DiscFailure("新增文件后 UDF 根目录超过一个扇区。") }
        var fid = Data(count: fidLength)
        put16(&fid, 0, 257); put16(&fid, 2, 2); put16(&fid, 16, 1)
        fid[19] = UInt8(1 + encoded.count)
        put32(&fid, 20, 2048); put32(&fid, 24, try relative(newFE))
        put16(&fid, 28, volume.partitionNumber)
        fid[38] = 16
        fid.replaceSubrange(39..<(39 + encoded.count), with: encoded)
        retag(&fid, location: try relative(newDir), crcLength: fidLength - 16)
        body.append(fid)

        var blocks = [Data](repeating: Data(count: 2048), count: sessionBlocks)
        func set(_ address: UInt32, _ data: Data) throws {
            guard address >= sessionStart, UInt64(address - sessionStart) < UInt64(sessionBlocks),
                  data.count <= 2048 else { throw DiscFailure("UDF 新会话区段越界。") }
            blocks[Int(address - sessionStart)] = data.count == 2048 ? data : data + Data(count: 2048 - data.count)
        }
        for offset: UInt32 in 16...18 { try set(sessionStart + offset, readOld(offset)) }
        for (index, original) in oldVDS.enumerated() {
            var descriptor = original
            if index == partitionIndex { put32(&descriptor, 192, sessionStart + UInt32(sessionBlocks) - part) }
            if index == logicalIndex {
                put32(&descriptor, 252, try relative(newFSD))
                put32(&descriptor, 436, sessionStart + 64)
            }
            retag(&descriptor, location: sessionStart + 32 + UInt32(index))
            try set(sessionStart + 32 + UInt32(index), descriptor)
            retag(&descriptor, location: reserve + UInt32(index))
            try set(reserve + UInt32(index), descriptor)
        }
        for index in 0..<(integrityBytes / 2048) {
            var integrity = try readOld(integrityStart + index)
            if get16(integrity, 0) != 0 {
                try UDFVolumeProbe.checkTag(integrity, id: get16(integrity, 0), address: integrityStart + index)
                retag(&integrity, location: sessionStart + 64 + index)
            }
            try set(sessionStart + 64 + index, integrity)
        }
        var fsd = oldFSD
        put32(&fsd, 404, try relative(newRoot)); retag(&fsd, location: try relative(newFSD))
        try set(newFSD, fsd)
        var root = oldRoot
        put64(&root, 56, UInt64(body.count)); put64(&root, 64, 1)
        put32(&root, rootAD, UInt32(body.count)); put32(&root, rootAD + 4, try relative(newDir))
        retag(&root, location: try relative(newRoot))
        try set(newRoot, root)
        try set(newDir, body)
        var file = template
        let fileAD = 176 + Int(get32(file, 168))
        put64(&file, 56, UInt64(payload.count)); put64(&file, 64, 1)
        put32(&file, fileAD, UInt32(payload.count)); put32(&file, fileAD + 4, try relative(newPayload))
        retag(&file, location: try relative(newFE))
        try set(newFE, file)
        try set(newPayload, payload)
        var newAnchor = anchor
        put32(&newAnchor, 16, 6 * 2048); put32(&newAnchor, 20, sessionStart + 32)
        put32(&newAnchor, 24, 6 * 2048); put32(&newAnchor, 28, reserve)
        for address in [sessionStart + 256, sessionStart + UInt32(sessionBlocks) - 257,
                        sessionStart + UInt32(sessionBlocks) - 1] {
            var anchorAt = newAnchor
            retag(&anchorAt, location: address)
            try set(address, anchorAt)
        }
        var image = Data(capacity: sessionBlocks * 2048)
        for block in blocks { image.append(block) }
        try image.write(to: destination, options: .withoutOverwriting)
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        return Result(image: destination, imageSHA256: digest,
                      oldFiles: entries.filter { !$0.directory }.count,
                      newBytes: payload.count, sessionStart: sessionStart)
    }

    private static func get16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    private static func readSource(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DiscFailure("无法安全打开 UDF 新文件。") }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size > 0, before.st_size <= 2048 else {
            throw DiscFailure("本 UDF 候选仅支持 1～2048 字节的普通文件。")
        }
        var data = Data(count: Int(before.st_size))
        let readCount = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
        guard readCount == data.count, fstat(fd, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DiscFailure("UDF 新文件读取不完整或准备期间发生变化。")
        }
        return data
    }
    private static func get32(_ data: Data, _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << (8 * $1) }
    }
    private static func get64(_ data: Data, _ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[at + $1]) << (8 * $1) }
    }
    private static func put16(_ data: inout Data, _ at: Int, _ value: UInt16) {
        for i in 0..<2 { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private static func put32(_ data: inout Data, _ at: Int, _ value: UInt32) {
        for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private static func put64(_ data: inout Data, _ at: Int, _ value: UInt64) {
        for i in 0..<8 { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private static func retag(_ data: inout Data, location: UInt32, crcLength: Int? = nil) {
        put32(&data, 12, location)
        if let crcLength { put16(&data, 10, UInt16(crcLength)) }
        var crc: UInt16 = 0
        for byte in data[16..<(16 + Int(get16(data, 10)))] {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021 }
        }
        put16(&data, 8, crc)
        data[4] = UInt8(truncatingIfNeeded: (0..<16).filter { $0 != 4 }.reduce(0) { $0 + Int(data[$1]) })
    }
}
