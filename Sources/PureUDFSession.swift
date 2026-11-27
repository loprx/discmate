import Foundation
import CryptoKit

extension UDFVolumeProbe {
    /// The append proof records one absolute extent per ordinary file.
    /// Reject other allocation layouts before they reach the staging directory.
    func importTree(capacity: UInt64, tracks: [RecordedTrack],
                    read: (UInt32) throws -> Data) throws -> [ISOEntry] {
        let unsupported = UDFAppendUnsupported(revision: revision, partitionMapType: partitionMapType)
        let entries = try UDFDirectoryReader.entries(volume: self, capacityBlocks: capacity, strictImport: true, readSector: read)
        var names = Set<String>(), starts = Set<UInt32>()
        return try entries.map { entry in
            guard AppendSourceTree.validPath(entry.path),
                  names.insert(entry.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  entry.extents.count == 1, let extent = entry.extents.first,
                  extent.bytes > 0, UInt64(extent.bytes) == entry.bytes,
                  starts.insert(extent.lba).inserted,
                  tracks.contains(where: { $0.contains(extent.lba, bytes: extent.bytes) }) else { throw unsupported }
            return ISOEntry(name: entry.path, lba: extent.lba, bytes: extent.bytes, directory: entry.directory)
        }.sorted { $0.name < $1.name }
    }
}

enum PureUDFSession {
    /// hdiutil supplies a complete fresh directory hierarchy. Only the tiny
    /// placeholders for old files are redirected into earlier recorded tracks.
    static func relocate(image: URL, bytes: UInt64, start: UInt32, udf: UDFVolumeProbe,
                         old: [ISOEntry], added: [FileProof], directories: [String]) throws {
        let file = try FileHandle(forUpdating: image)
        defer { try? file.close() }
        let blocks = UInt32(bytes / 2048)
        let invalid = DiscFailure("新 UDF 会话的目录、文件区段或内容与追加清单不一致。")
        func sector(_ lba: UInt32) throws -> Data {
            guard lba < blocks else { throw invalid }
            try file.seek(toOffset: UInt64(lba) * 2048)
            guard let data = try file.read(upToCount: 2048), data.count == 2048 else { throw invalid }
            return data
        }
        let local = try UDFVolumeProbe.inspect(sessionStart: 0, capacityBlocks: UInt64(blocks), readSector: sector)
        let authored = try UDFDirectoryReader.entries(volume: local, capacityBlocks: UInt64(blocks), readSector: sector)
        let oldByName = Dictionary(uniqueKeysWithValues: old.map { ($0.name, $0) })
        var references: [UInt32: ISOEntry] = [:]
        for item in authored {
            guard let original = oldByName[item.path] else { continue }
            guard !item.directory, item.extents.count == 1, let placeholder = item.extents.first,
                  placeholder.bytes > 0, placeholder.bytes <= 2048,
                  references.updateValue(original, forKey: placeholder.lba) == nil else { throw invalid }
        }
        guard references.count == old.count else { throw invalid }
        var patched = Set<UInt32>()
        func patch(_ lba: UInt32, _ data: Data) throws {
            guard lba < blocks, data.count == 2048, patched.insert(lba).inserted else { throw invalid }
            try file.seek(toOffset: UInt64(lba) * 2048)
            try file.write(contentsOf: data)
        }
        try HybridUDF.relocate(start: start, blocks: blocks, partitionStart: udf.partitionStart,
                               references: references, read: sector, patch: patch)
        for lba in references.keys { try patch(lba, Data(count: 2048)) }
        try file.synchronize()

        func relocatedSector(_ lba: UInt32) throws -> Data {
            guard lba >= start else { throw invalid }
            return try sector(lba - start)
        }
        let capacity = UInt64(start) + UInt64(blocks)
        let latest = try UDFVolumeProbe.inspect(sessionStart: start, capacityBlocks: capacity, readSector: relocatedSector)
        let entries = try UDFDirectoryReader.entries(volume: latest, capacityBlocks: capacity, readSector: relocatedSector)
        guard latest.revision == udf.revision, latest.label == udf.label, latest.partitionStart == udf.partitionStart,
              entries.count == directories.count + old.count + added.count,
              Set(entries.filter(\.directory).map(\.path)) == Set(directories) else { throw invalid }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        for entry in old {
            guard let saved = byPath[entry.name], !saved.directory, saved.bytes == entry.bytes,
                  saved.extents == [UDFRecordedExtent(lba: entry.lba, bytes: entry.bytes)] else { throw invalid }
        }
        for source in added {
            guard let saved = byPath[source.path], !saved.directory, saved.bytes == source.bytes,
                  saved.extents.count == 1, let extent = saved.extents.first, extent.bytes == saved.bytes,
                  extent.lba >= start, UInt64(extent.lba) + (saved.bytes + 2047) / 2048 <= capacity else { throw invalid }
            try file.seek(toOffset: UInt64(extent.lba - start) * 2048)
            var remaining = saved.bytes, digest = SHA256()
            while remaining > 0 {
                guard let chunk = try file.read(upToCount: Int(min(remaining, 1024 * 1024))), !chunk.isEmpty else { throw invalid }
                digest.update(data: chunk)
                remaining -= UInt64(chunk.count)
            }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == source.sha256 else { throw invalid }
        }
    }
}
