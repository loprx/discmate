import Foundation

enum UDFVolumeProbeTests: UDFEncoding {
    static func run() throws {
        let first = UDFRecordedExtent(lba: 100, bytes: 0x3fff_f800)
        func joined(_ firstExtent: UDFRecordedExtent, _ next: UInt32) -> UDFRecordedExtent? {
            UDFRecordedEntry(path: "large.zip", directory: false, bytes: UInt64(firstExtent.bytes) + 17,
                extents: [firstExtent, .init(lba: next, bytes: 17)]).contiguousExtent
        }
        let second = first.lba + first.bytes / 2048
        precondition(joined(first, second) == .init(lba: 100, bytes: first.bytes + 17))
        precondition(joined(first, second + 1) == nil && joined(first, second - 1) == nil)
        precondition(joined(.init(lba: 100, bytes: 2047), 101) == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-udf-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("UDF offline fixture\n".utf8).write(to: source.appendingPathComponent("sample.txt"))
        let image = root.appendingPathComponent("fixture.iso")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-udf", "-udf-version", "1.02", "-o", image.path, source.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        precondition(process.terminationReason == .exit && process.terminationStatus == 0)
        let bytes = try Data(contentsOf: image)
        precondition(bytes.count % 2048 == 0)
        func read(_ sector: UInt32, from content: Data) throws -> Data {
            let start = Int(sector) * 2048
            guard start + 2048 <= content.count else { throw DiscFailure("离线扇区越界。") }
            return content.subdata(in: start..<(start + 2048))
        }
        let found = try UDFVolumeProbe.inspect(sessionStart: 0,
            capacityBlocks: UInt64(bytes.count / 2048)) { try read($0, from: bytes) }
        precondition(found.revision == 0x0102 && found.blockBytes == 2048 &&
                     found.partitionMapType == 1 && found.partitionBlocks > 0)
        let entries = try UDFDirectoryReader.entries(volume: found,
            capacityBlocks: UInt64(bytes.count / 2048)) { try read($0, from: bytes) }
        guard let file = entries.first(where: { $0.path == "sample.txt" }),
              !file.directory, file.bytes == 20, file.extents.count == 1 else {
            fatalError("UDF fixture file was not found with its recorded extent")
        }
        let extent = file.extents[0]
        let payload = bytes[(Int(extent.lba) * 2048)..<(Int(extent.lba) * 2048 + Int(file.bytes))]
        precondition(Data(payload) == Data("UDF offline fixture\n".utf8))
        let added = source.appendingPathComponent("append.txt")
        let addedContent = Data("New UDF session file\n".utf8)
        try addedContent.write(to: added)
        let start = UInt32(bytes.count / 2048) + 2048
        let session = root.appendingPathComponent("append-session.iso")
        let prepared = try UDFIncremental.build(oldImage: image, oldRecordedBlocks: UInt32(bytes.count / 2048),
                                                sessionStart: start, newFile: added, destination: session)
        precondition(prepared.oldFiles == 1 && prepared.newBytes == addedContent.count)
        let newBlocks = try Data(contentsOf: session)
        precondition(newBlocks.count == UDFIncremental.sessionBlocks * 2048)
        var combined = bytes + Data(count: Int(start) * 2048 - bytes.count)
        combined.append(newBlocks)
        let latest = try UDFVolumeProbe.inspect(sessionStart: start, capacityBlocks: UInt64(combined.count / 2048)) {
            try read($0, from: combined)
        }
        // Reproduce a later session whose anchor refers to the first VDS.
        do {
            _ = try UDFVolumeProbe.inspect(sessionStart: start, capacityBlocks: UInt64(combined.count / 2048)) { sector in
                if sector == start + 256 {
                    var anchor = try read(256, from: bytes)
                    retag(&anchor, location: sector)
                    return anchor
                }
                var block = try read(sector, from: combined)
                if sector < start, get16(block, 0) == 6 {
                    put16(&block, 240, 0x0201)
                    put32(&block, 264, 70)
                    put32(&block, 268, 2)
                    block[446] = 2
                    block[447] = 64
                    block.replaceSubrange(451..<474, with: Data("*UDF Virtual Partition".utf8) + [0])
                    retag(&block, location: sector, crcLength: 494)
                }
                return block
            }
            fatalError("VAT volume accepted by physical partition writer")
        } catch let error as UDFAppendUnsupported {
            precondition(error.revision == 0x0201 && error.partitionMapType == 2)
        }
        let after = try UDFDirectoryReader.entries(volume: latest, capacityBlocks: UInt64(combined.count / 2048)) {
            try read($0, from: combined)
        }
        guard after.count == 2,
              let preserved = after.first(where: { $0.path == "sample.txt" }),
              let inserted = after.first(where: { $0.path == "append.txt" }),
              preserved.extents == file.extents, preserved.bytes == file.bytes,
              inserted.bytes == addedContent.count, inserted.extents.count == 1,
              inserted.extents[0].lba >= start else {
            fatalError("UDF incremental session did not preserve old extent and add new file")
        }
        let newPayload = combined[(Int(inserted.extents[0].lba) * 2048)..<(Int(inserted.extents[0].lba) * 2048 + addedContent.count)]
        precondition(Data(newPayload) == addedContent)
        do {
            _ = try UDFIncremental.build(oldImage: image, oldRecordedBlocks: UInt32(bytes.count / 2048),
                                         sessionStart: start, newFile: source.appendingPathComponent("sample.txt"),
                                         destination: root.appendingPathComponent("duplicate.iso"))
            fatalError("UDF duplicate filename was accepted")
        } catch let error as DiscFailure { precondition(error.message.contains("重复")) }
        let oversized = source.appendingPathComponent("oversized.txt")
        try Data(count: 2049).write(to: oversized)
        do {
            _ = try UDFIncremental.build(oldImage: image, oldRecordedBlocks: UInt32(bytes.count / 2048),
                                         sessionStart: start, newFile: oversized,
                                         destination: root.appendingPathComponent("oversized.iso"))
            fatalError("UDF oversized source was accepted")
        } catch let error as DiscFailure { precondition(error.message.contains("2048")) }
        var damaged = bytes
        damaged[256 * 2048 + 4] ^= 1
        do {
            _ = try UDFVolumeProbe.inspect(sessionStart: 0,
                capacityBlocks: UInt64(damaged.count / 2048)) { try read($0, from: damaged) }
            fatalError("damaged UDF anchor was accepted")
        } catch let error as DiscFailure {
            precondition(error.message.contains("校验和"))
        }
        print("PASS UDF 1.02 recognition, old extent preservation, new session payload and corrupted anchor rejection")
    }
}
