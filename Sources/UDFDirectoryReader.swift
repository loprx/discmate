import Foundation

struct UDFRecordedExtent: Equatable {
    let lba: UInt32
    let bytes: UInt32
}

struct UDFRecordedEntry: Equatable {
    let path: String
    let directory: Bool
    let bytes: UInt64
    let extents: [UDFRecordedExtent]
}

/// A bounded, read-only UDF 1.02 directory walker for physical type-1 partitions.
/// Unsupported allocation forms fail closed. It never scans unrecorded sectors.
enum UDFDirectoryReader {
    static func entries(volume: UDFVolumeProbe, capacityBlocks: UInt64,
                        readSector: (UInt32) throws -> Data) throws -> [UDFRecordedEntry] {
        guard volume.revision == 0x0102, volume.partitionMapType == 1 else {
            throw DiscFailure("当前只支持解析 UDF 1.02 单物理分区目录。")
        }
        func u16(_ data: Data, _ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
        }
        func u64(_ data: Data, _ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
        }
        func physical(_ block: UInt32, count: UInt64 = 1) throws -> UInt32 {
            guard UInt64(block) + count <= UInt64(volume.partitionBlocks),
                  UInt64(volume.partitionStart) + UInt64(block) + count <= capacityBlocks,
                  UInt64(volume.partitionStart) + UInt64(block) + count <= UInt32.max else {
                throw DiscFailure("UDF 文件区段超出已识别分区。")
            }
            return volume.partitionStart + block
        }
        func readBlock(_ block: UInt32) throws -> Data {
            let data = try readSector(physical(block))
            guard data.count == 2048 else { throw DiscFailure("UDF 目录扇区读取不完整。") }
            return data
        }
        func readExtents(_ extents: [UDFRecordedExtent], bytes: UInt64) throws -> Data {
            guard bytes <= 32 * 1024 * 1024 else { throw DiscFailure("UDF 目录元数据超过 32 MiB。") }
            var result = Data()
            for extent in extents {
                let blocks = (UInt64(extent.bytes) + 2047) / 2048
                guard UInt64(extent.lba) + blocks <= capacityBlocks else { throw DiscFailure("UDF 数据区段越界。") }
                var remaining = Int(extent.bytes)
                for i in 0..<blocks {
                    let data = try readSector(extent.lba + UInt32(i))
                    guard data.count == 2048 else { throw DiscFailure("UDF 数据区段读取不完整。") }
                    let count = min(remaining, 2048)
                    result.append(data.prefix(count))
                    remaining -= count
                }
            }
            guard UInt64(result.count) >= bytes else { throw DiscFailure("UDF 目录数据截断。") }
            return Data(result.prefix(Int(bytes)))
        }
        func name(_ data: Data) throws -> String {
            guard data.count > 1 else { throw DiscFailure("UDF 文件名为空。") }
            let decoded: String?
            if data[0] == 8 { decoded = String(bytes: data.dropFirst(), encoding: .isoLatin1) }
            else if data[0] == 16 { decoded = String(data: Data(data.dropFirst()), encoding: .utf16BigEndian) }
            else { decoded = nil }
            guard let decoded, !decoded.isEmpty, decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\0") else {
                throw DiscFailure("UDF 文件名编码或路径无效。")
            }
            return decoded
        }
        func fileEntry(_ block: UInt32) throws -> (directory: Bool, bytes: UInt64,
                                                  extents: [UDFRecordedExtent], embedded: Data?) {
            _ = try physical(block)
            let data = try readBlock(block)
            try UDFVolumeProbe.checkTag(data, id: 261, address: block)
            let fileType = data[27], allocationType = u16(data, 34) & 7
            guard fileType == 4 || fileType == 5 else { throw DiscFailure("UDF 文件类型未支持。") }
            let bytes = u64(data, 56)
            let eaBytes = Int(u32(data, 168)), adBytes = Int(u32(data, 172))
            guard eaBytes <= 2048 - 176, adBytes <= 2048 - 176 - eaBytes else {
                throw DiscFailure("UDF 文件入口属性或区段表越界。")
            }
            let offset = 176 + eaBytes
            if allocationType == 3 {
                guard bytes <= UInt64(adBytes) else { throw DiscFailure("UDF 内嵌文件长度无效。") }
                return (fileType == 4, bytes, [], Data(data[offset..<(offset + Int(bytes))]))
            }
            guard allocationType == 0 || allocationType == 1 else {
                throw DiscFailure("UDF 文件区段分配形式暂不支持。")
            }
            let recordStride = allocationType == 0 ? 8 : 16
            guard adBytes % recordStride == 0 else { throw DiscFailure("UDF 区段表长度无效。") }
            var extents: [UDFRecordedExtent] = []
            var total: UInt64 = 0
            for cursor in stride(from: offset, to: offset + adBytes, by: recordStride) {
                let encodedLength = u32(data, cursor)
                let length = encodedLength & 0x3fff_ffff
                guard encodedLength >> 30 == 0, length > 0 else { throw DiscFailure("UDF 稀疏或续接区段暂不支持。") }
                let lbn = u32(data, cursor + 4)
                if allocationType == 1 && u16(data, cursor + 8) != volume.partitionNumber {
                    throw DiscFailure("UDF 跨分区区段暂不支持。")
                }
                let sectors = (UInt64(length) + 2047) / 2048
                extents.append(UDFRecordedExtent(lba: try physical(lbn, count: sectors), bytes: length))
                total += UInt64(length)
            }
            guard total >= bytes else { throw DiscFailure("UDF 文件区段不足。") }
            return (fileType == 4, bytes, extents, nil)
        }
        let fileSet = try readBlock(volume.fileSetBlock)
        try UDFVolumeProbe.checkTag(fileSet, id: 256, address: volume.fileSetBlock)
        let rootBlock = u32(fileSet, 404)
        guard u16(fileSet, 408) == volume.partitionNumber else { throw DiscFailure("UDF 根目录分区不一致。") }
        var visited = Set<UInt32>(), result: [UDFRecordedEntry] = []
        var metadataBytes: UInt64 = 0
        func walk(_ block: UInt32, prefix: String, depth: Int) throws {
            guard depth <= 8, visited.insert(block).inserted else { throw DiscFailure("UDF 目录循环或层数过多。") }
            let entry = try fileEntry(block)
            guard entry.directory else { throw DiscFailure("UDF 目录入口指向普通文件。") }
            metadataBytes += entry.bytes
            guard metadataBytes <= 32 * 1024 * 1024 else { throw DiscFailure("UDF 目录元数据超过上限。") }
            let body = try entry.embedded ?? readExtents(entry.extents, bytes: entry.bytes)
            var cursor = 0, names = Set<String>()
            while cursor < body.count {
                guard cursor + 38 <= body.count else { throw DiscFailure("UDF 目录项截断。") }
                let nameLength = Int(body[cursor + 19]), implementationBytes = Int(u16(body, cursor + 36))
                let unpadded = 38 + implementationBytes + nameLength
                let length = (unpadded + 3) & ~3
                guard cursor + length <= body.count else { throw DiscFailure("UDF 目录项长度越界。") }
                let record = Data(body[cursor..<(cursor + length)])
                try UDFVolumeProbe.checkTag(record, id: 257, address: u32(record, 12))
                let flags = body[cursor + 18]
                if flags & 0x0c == 0 { // Skip parent and deleted FIDs.
                    let component = try name(Data(body[(cursor + 38 + implementationBytes)..<(cursor + unpadded)]))
                    guard names.insert(component).inserted else { throw DiscFailure("UDF 目录有重名文件。") }
                    let childBlock = u32(body, cursor + 24)
                    guard u16(body, cursor + 28) == volume.partitionNumber else {
                        throw DiscFailure("UDF 目录项跨分区。")
                    }
                    let child = try fileEntry(childBlock)
                    guard (flags & 0x02 != 0) == child.directory else { throw DiscFailure("UDF 目录项类型与文件入口不一致。") }
                    let path = prefix.isEmpty ? component : prefix + "/" + component
                    guard result.count < 10000 else { throw DiscFailure("UDF 目录项超过上限。") }
                    result.append(UDFRecordedEntry(path: path, directory: child.directory,
                                                   bytes: child.bytes, extents: child.extents))
                    if child.directory { try walk(childBlock, prefix: path, depth: depth + 1) }
                }
                cursor += length
            }
        }
        try walk(rootBlock, prefix: "", depth: 0)
        return result
    }
}
