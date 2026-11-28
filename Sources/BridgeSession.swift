import Foundation

/// One UDF name and one primary ISO identifier per ordinary root file.
/// Matching the size alone would conflate unrelated files.
struct BridgeSession: Equatable, Sendable {
    let partitionStart: UInt32
    let files: [ISOEntry]
    let primaryIDs: [UInt32: Data]
    let isoLabel: String
    let udfLabel: String
    var rawISOIdentifier: Data? = nil

    static func inspect(latest: RecordedTrack, capacity: UInt64, primary: ISOVolume, joliet: Bool,
                        entries: [ISOEntry], label: String,
                        read: (UInt32) throws -> Data) throws -> BridgeSession? {
        guard !entries.isEmpty, entries.count <= 32, entries.allSatisfy({ !$0.directory && $0.bytes > 0 }),
              (1...2048).contains(primary.root.bytes), latest.blocks > 256 else { return nil }
        let volume = try UDFVolumeProbe.inspect(sessionStart: latest.start, capacityBlocks: capacity,
                                                allowISOBridge: true, readSector: read)
        guard volume.revision == 0x0102, let udfLabel = volume.label else { return nil }
        var ids: [UInt32: Data] = [:], plain = true
        let rootSector = try read(primary.root.lba)
        guard rootSector.count == 2048 else { throw DiscFailure("ISO 主目录扇区读取不完整。") }
        let rootData = Data(rootSector.prefix(Int(primary.root.bytes)))
        let aliases = try ISO9660.directory(rootData, joliet: false) { raw, entry in
            if !ISO9660.canImportPrimaryRecord(raw, entry: entry) { plain = false }
            if entry.name != ".", entry.name != ".." {
                if ids.updateValue(Data(raw[33..<(33 + Int(raw[32]))]), forKey: entry.lba) != nil { plain = false }
            }
        }
        guard plain, aliases.count == entries.count else { return nil }
        let udf = try UDFDirectoryReader.entries(volume: volume, capacityBlocks: capacity, readSector: read)
        guard udf.count == aliases.count else { return nil }
        var used = Set<UInt32>(), files: [ISOEntry] = []
        for file in udf {
            guard !file.directory, let extent = file.contiguousExtent,
                  extent.bytes > 0, extent.bytes == file.bytes, !file.path.contains("/"), AppendSourceTree.validPath(file.path),
                  used.insert(extent.lba).inserted,
                  aliases.contains(where: { !$0.directory && $0.lba == extent.lba && $0.bytes == extent.bytes }),
                  entries.contains(where: { $0.lba == extent.lba && $0.bytes == extent.bytes && (!joliet || $0.name == file.path) }) else { return nil }
            files.append(ISOEntry(name: file.path, lba: extent.lba, bytes: extent.bytes, directory: false))
        }
        return BridgeSession(partitionStart: volume.partitionStart, files: files.sorted { $0.name < $1.name },
                             primaryIDs: ids, isoLabel: label, udfLabel: udfLabel)
    }
}

extension UDFRecordedEntry {
    /// ISO carries a single byte range. Every intermediate UDF allocation must
    /// end on a block boundary and the next one must start at that exact LBA.
    var contiguousExtent: UDFRecordedExtent? {
        guard let first = extents.first, let length = UInt32(exactly: bytes), length > 0 else { return nil }
        var consumed: UInt64 = 0
        for extent in extents {
            guard extent.bytes > 0, consumed % 2048 == 0,
                  UInt64(first.lba) + consumed / 2048 == UInt64(extent.lba) else { return nil }
            consumed += UInt64(extent.bytes)
            guard consumed <= bytes else { return nil }
        }
        return consumed == bytes ? UDFRecordedExtent(lba: first.lba, bytes: length) : nil
    }
}
