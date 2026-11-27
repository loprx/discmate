import Foundation

/// Relocate the UDF 1.02 structures authored by hdiutil in the same image as
/// ISO/Joliet. The partition retains its old physical base so short allocation
/// descriptors can still address payload in the preceding recorded tracks.
enum HybridUDF: UDFEncoding {
    static func relocate(start: UInt32, blocks: UInt32, partitionStart: UInt32,
                         references: [UInt32: ISOEntry], read: (UInt32) throws -> Data,
                         patch: (UInt32, Data) throws -> Void) throws {
        let unsupported = DiscFailure("本地 UDF 镜像布局超出当前支持范围，未准备写入。")
        guard blocks > 512, UInt64(start) + UInt64(blocks) <= UInt32.max,
              partitionStart < start else { throw unsupported }
        let volume = try UDFVolumeProbe.inspect(sessionStart: 0, capacityBlocks: UInt64(blocks),
                                                allowISOBridge: true, readSector: read)
        let base = volume.partitionStart
        let partitionEnd = base + volume.partitionBlocks
        let size = start + partitionEnd - partitionStart
        func relative(_ original: UInt32) throws -> UInt32 {
            guard original < volume.partitionBlocks else { throw unsupported }
            return start + base + original - partitionStart
        }
        func descriptor(_ lba: UInt32, _ id: UInt16, partition: Bool = false) throws -> Data {
            guard lba < blocks, !partition || (lba >= base && lba < partitionEnd) else { throw unsupported }
            let data = try read(lba)
            try UDFVolumeProbe.checkTag(data, id: id, address: partition ? lba - base : lba)
            return data
        }
        // Main and reserve descriptor sequences each point to the same integrity sequence.
        let anchor = try descriptor(256, 2)
        var integrityStart: UInt32?
        for offset in [16, 24] {
            let first = get32(anchor, offset + 4), length = get32(anchor, offset)
            guard length == 16 * 2048, UInt64(first) + 16 <= blocks else { throw unsupported }
            for (index, id) in [UInt16(1), 4, 5, 6, 7, 8].enumerated() {
                let lba = first + UInt32(index)
                var data = try descriptor(lba, id)
                switch id {
                case 5:
                    guard get32(data, 188) == base, get32(data, 192) == volume.partitionBlocks,
                          data[56..<184].allSatisfy({ $0 == 0 }) else { throw unsupported }
                    put32(&data, 188, partitionStart)
                    put32(&data, 192, size)
                case 6:
                    let integrity = get32(data, 436)
                    guard get32(data, 432) == 4096, UInt64(integrity) + 2 <= blocks,
                          integrityStart == nil || integrityStart == integrity else { throw unsupported }
                    integrityStart = integrity
                    put32(&data, 436, start + integrity)
                    put32(&data, 252, try relative(get32(data, 252)))
                case 7:
                    guard get32(data, 20) == 0 else { throw unsupported }
                default: break
                }
                retag(&data, location: start + lba)
                try patch(lba, data)
            }
        }
        guard let integrityStart else { throw unsupported }
        var integrity = try descriptor(integrityStart, 9)
        guard get32(integrity, 28) == 1, get32(integrity, 32) == 0,
              get32(integrity, 72) == 1, get32(integrity, 84) == volume.partitionBlocks else { throw unsupported }
        put32(&integrity, 84, size)
        retag(&integrity, location: start + integrityStart)
        try patch(integrityStart, integrity)
        var terminator = try descriptor(integrityStart + 1, 8)
        retag(&terminator, location: start + integrityStart + 1)
        try patch(integrityStart + 1, terminator)
        for lba in [256, blocks - 257, blocks - 1] as [UInt32] {
            if lba != blocks - 1 {
                let existing = try descriptor(lba, 2)
                guard existing[16..<32] == anchor[16..<32] else { throw unsupported }
            } else {
                let existing = try read(lba)
                guard existing.allSatisfy({ $0 == 0 }) || existing[16..<32] == anchor[16..<32] else { throw unsupported }
            }
            var relocated = anchor
            for field in [20, 28] { put32(&relocated, field, start + get32(anchor, field)) }
            retag(&relocated, location: start + lba)
            try patch(lba, relocated)
        }
        let fsd = volume.fileSetBlock
        var fileSet = try descriptor(base + fsd, 256, partition: true)
        let root = get32(fileSet, 404)
        guard get32(fileSet, 448) == 0 else { throw unsupported }
        put32(&fileSet, 404, try relative(root))
        retag(&fileSet, location: try relative(fsd))
        try patch(base + fsd, fileSet)
        var endSet = try descriptor(base + fsd + 1, 8, partition: true)
        retag(&endSet, location: try relative(fsd + 1))
        try patch(base + fsd + 1, endSet)

        // Root FIDs identify each FE. Walk actual metadata, never scan sectors
        // for tag-like bytes (file payload can contain any bit pattern).
        var pending = [(block: root, parent: root, directory: true)], visited = Set<UInt32>(), preserved = Set<UInt32>()
        while let node = pending.popLast() {
            let block = node.block
            let location = try relative(block)
            guard visited.insert(block).inserted, visited.count <= 10_001 else { throw unsupported }
            var fe = try descriptor(base + block, 261, partition: true)
            let eaBytes = Int(get32(fe, 168)), ad = 176 + eaBytes
            guard fe[27] == (node.directory ? 4 : 5), get16(fe, 34) & 7 == 0,
                  fe[28..<34].allSatisfy({ $0 == 0 }), get32(fe, 112) == 0,
                  ad <= 2040, get32(fe, 172) == 8 else { throw unsupported }
            if eaBytes > 0 {
                var ea = Data(fe[176..<ad])
                try UDFVolumeProbe.checkTag(ea, id: 262, address: block)
                retag(&ea, location: location)
                fe.replaceSubrange(176..<ad, with: ea)
            }
            let dataBlock = get32(fe, ad + 4), length = get32(fe, ad)
            guard length > 0, length < 0x4000_0000, get64(fe, 56) == UInt64(length),
                  UInt64(dataBlock) + (UInt64(length) + 2047) / 2048 <= volume.partitionBlocks else { throw unsupported }
            if node.directory {
                guard length <= 1024 * 1024 else { throw unsupported }
                let sectorCount = (length + 2047) / 2048
                var directory = Data()
                for index in 0..<sectorCount { directory.append(try read(base + dataBlock + index)) }
                var cursor = 0
                while cursor < Int(length) {
                    guard cursor + 38 <= length else { throw unsupported }
                    let used = 38 + Int(directory[cursor + 19]) + Int(get16(directory, cursor + 36))
                    let end = cursor + ((used + 3) & ~3)
                    guard end <= length else { throw unsupported }
                    var record = Data(directory[cursor..<end])
                    try UDFVolumeProbe.checkTag(record, id: 257, address: dataBlock + UInt32(cursor / 2048))
                    let child = get32(record, 24)
                    switch record[18] {
                    case 0, 2: pending.append((child, block, record[18] == 2))
                    case 10: guard child == node.parent else { throw unsupported }
                    default: throw unsupported
                    }
                    put32(&record, 24, try relative(child))
                    retag(&record, location: try relative(dataBlock + UInt32(cursor / 2048)))
                    directory.replaceSubrange(cursor..<end, with: record)
                    cursor = end
                }
                for index in 0..<sectorCount {
                    let offset = Int(index) * 2048
                    try patch(base + dataBlock + index, directory.subdata(in: offset..<(offset + 2048)))
                }
            }
            if !node.directory, let old = references[base + dataBlock] {
                guard old.lba >= partitionStart, old.bytes < 0x4000_0000,
                      preserved.insert(old.lba).inserted else { throw unsupported }
                put32(&fe, ad + 4, old.lba - partitionStart)
                put32(&fe, ad, old.bytes)
                put64(&fe, 56, UInt64(old.bytes))
                put64(&fe, 64, (UInt64(old.bytes) + 2047) / 2048)
            } else {
                put32(&fe, ad + 4, try relative(dataBlock))
            }
            retag(&fe, location: location)
            try patch(base + block, fe)
        }
        guard preserved == Set(references.values.map(\.lba)) else { throw unsupported }
    }
}
