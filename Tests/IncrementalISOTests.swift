import Foundation

enum IncrementalISOTests {
    static func run(large: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("discmate-incremental-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            if CommandLine.arguments.contains("--keep-iso") { print("Offline ISO artifacts: \(root.path)") }
            else { try? fm.removeItem(at: root) }
        }
        let original = root.appendingPathComponent("old", isDirectory: true)
        let additions = root.appendingPathComponent("new", isDirectory: true)
        try fm.createDirectory(at: original, withIntermediateDirectories: false)
        try fm.createDirectory(at: additions, withIntermediateDirectories: false)
        let oldLarge = original.appendingPathComponent("large-old.bin")
        try Data("DiscMate large old-file prefix\n".utf8).write(to: oldLarge)
        let oldBytes: UInt64 = large ? 1_120_401_929 : 1_048_607
        let largeHandle = try FileHandle(forWritingTo: oldLarge)
        try largeHandle.truncate(atOffset: oldBytes)
        try largeHandle.seek(toOffset: oldBytes - 32)
        try largeHandle.write(contentsOf: Data(repeating: 0x5a, count: 32)); try largeHandle.close()
        let oldText = original.appendingPathComponent("old.txt")
        try Data("Preserve this old file.\n".utf8).write(to: oldText)
        let newText = additions.appendingPathComponent("新增 空格.txt")
        let longName = additions.appendingPathComponent(String(repeating: "甲", count: 60) + ".txt")
        try Data("New session contents\n".utf8).write(to: newText)
        try Data("Long UCS-2 name\n".utf8).write(to: longName)
        let initial = root.appendingPathComponent("initial.iso")
        try command("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", initial.path, original.path], output: root.appendingPathComponent("initial.log"))
        let length = (try fm.attributesOfItem(atPath: initial.path)[.size] as! NSNumber).uint64Value
        let source = try FileHandle(forReadingFrom: initial); defer { try? source.close() }
        try source.seek(toOffset: 17 * 2048)
        let descriptor = try source.read(upToCount: 2048)!
        let volume = try ISO9660.descriptor(descriptor)!
        precondition(volume.joliet)
        try source.seek(toOffset: UInt64(volume.root.lba) * 2048)
        let oldEntries = try ISO9660.directory(source.read(upToCount: Int(volume.root.bytes))!, joliet: true)
        let oldProofs = try [oldLarge, oldText].map { try FileProof.capture($0) }
        let verified = oldProofs.map { VerifiedFile(path: $0.path, bytes: UInt32($0.bytes), sha256: $0.sha256) }
        let first = RecordedTrack(number: 1, session: 1, start: 0, blocks: UInt32(length / 2048), blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        // Synthetic next writable address, never used for an optical device.
        let start = UInt32(length / 2048) + 2048
        let capacity: UInt32 = 2_295_104
        let next = RecordedTrack(number: 2, session: 2, start: start, blocks: capacity - start, blank: true, damaged: false, nextWritable: start, freeBlocks: capacity - start)
        let snapshot = SessionSnapshot(identity: MediaIdentity(bsd: "offline-only", registryID: 0, bytes: UInt64(capacity) * 2048),
            tracks: [first, next], latest: first, volume: volume, rootEntries: oldEntries, descriptorHash: "offline", appendable: true)
        // All old source files disappear before preparation. The only old payload
        // remaining is the fixture ISO used later by the independent reader;
        // its URL is never passed to the builder.
        try fm.removeItem(at: original)
        precondition(!fm.fileExists(atPath: oldLarge.path) && !fm.fileExists(atPath: oldText.path))
        let prepared = try IncrementalISO.build(snapshot: snapshot, verified: [], sources: [newText, longName], directory: root.appendingPathComponent("prepared"))
        precondition(prepared.referencedBytes == oldBytes + oldProofs.first(where: { $0.path == "old.txt" })!.bytes)
        precondition(prepared.imageBytes < 1024 * 1024)
        precondition(Set(prepared.proof.files.map(\.path)) == Set([newText.lastPathComponent, longName.lastPathComponent]))
        precondition(prepared.proof.preserved?.count == oldEntries.count)
        for old in oldEntries {
            precondition(prepared.proof.preserved!.contains { $0.path == old.name && $0.bytes == old.bytes && $0.lba == old.lba })
        }
        // Retain the explicit full-hash preparation path for prior diagnostics.
        let withOldHashes = try IncrementalISO.build(snapshot: snapshot, verified: verified,
            sources: [newText, longName], directory: root.appendingPathComponent("prepared-full-proof"))
        precondition(withOldHashes.proof.preserved == nil)
        precondition(withOldHashes.proof.files.count == oldProofs.count + prepared.proof.files.count)
        let track = try ISOTrackLayout.load(prepared.image, bytes: prepared.imageBytes)
        precondition(track.estimateLength() == prepared.imageBytes / 2048)
        precondition(track.testProductionSpeed(forLength: UInt32(prepared.imageBytes)) > 0)
        CoreTests.reject("image producer rejects mismatched byte length") {
            _ = try ISOTrackLayout.load(prepared.image, bytes: prepared.imageBytes + 2048)
        }
        // A regular-file view selecting the new descriptors for an independent
        // ISO reader. Copy only descriptors to block 16; old file extents stay at
        // their original addresses. This is not a physical disc modification.
        let view = root.appendingPathComponent("latest-view.iso")
        try fm.copyItem(at: initial, to: view)
        let handle = try FileHandle(forUpdating: view)
        let newImage = try Data(contentsOf: prepared.image) // proven <1 MiB above
        try handle.seek(toOffset: UInt64(start) * 2048); try handle.write(contentsOf: newImage)
        try handle.seek(toOffset: 16 * 2048); try handle.write(contentsOf: newImage.subdata(in: 16 * 2048..<19 * 2048))
        try handle.close()
        // libarchive is independent of our ISO parser and hdiutil's generator.
        let listing = root.appendingPathComponent("listing.txt")
        try command("/usr/bin/tar", ["-tf", view.path], output: listing)
        let names = try String(contentsOf: listing, encoding: .utf8)
        for file in oldProofs + prepared.proof.files {
            precondition(names.contains(file.path))
            let extracted = root.appendingPathComponent("extract-\(file.path)")
            try command("/usr/bin/tar", ["-xOf", view.path, file.path], output: extracted)
            let actual = try FileProof.capture(extracted)
            precondition(actual.bytes == file.bytes && actual.sha256 == file.sha256)
        }
        // Parse the emitted new directory and independently compare every old LBA.
        let latestVolume = try ISO9660.descriptor(newImage.subdata(in: 17 * 2048..<18 * 2048))!
        let rootOffset = Int(latestVolume.root.lba - start) * 2048
        let latestEntries = try ISO9660.directory(newImage.subdata(in: rootOffset..<rootOffset + Int(latestVolume.root.bytes)), joliet: true)
        for old in oldEntries { precondition(latestEntries.contains(old)) }
        let written = RecordedTrack(number: 2, session: 2, start: start, blocks: UInt32(prepared.imageBytes / 2048),
            blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let latest = SessionSnapshot(identity: snapshot.identity, tracks: [first, written], latest: written,
            volume: latestVolume, rootEntries: latestEntries, descriptorHash: "offline-new", appendable: true)
        try prepared.proof.validateDirectory(latest)
        let actual = (oldProofs + prepared.proof.files).map { VerifiedFile(path: $0.path, bytes: UInt32($0.bytes), sha256: $0.sha256) }
        try prepared.proof.validate(actual, session: 2, start: start)
        try prepared.proof.validate(actual.filter { prepared.proof.files.map(\.path).contains($0.path) }, session: 2, start: start, addedOnly: true)
        CoreTests.reject("incremental rejects old/new filename collision") {
            _ = try IncrementalISO.build(snapshot: snapshot, verified: verified, sources: [oldText], directory: root.appendingPathComponent("collision"))
        }
        let tightTrack = RecordedTrack(number: 2, session: 2, start: start, blocks: 1000, blank: true,
                                       damaged: false, nextWritable: start, freeBlocks: 1000)
        let tight = SessionSnapshot(identity: snapshot.identity, tracks: [first, tightTrack], latest: first,
            volume: volume, rootEntries: oldEntries, descriptorHash: "offline", appendable: true)
        CoreTests.reject("incremental reserves session-close capacity") {
            _ = try IncrementalISO.build(snapshot: tight, verified: verified, sources: [newText], directory: root.appendingPathComponent("capacity"))
        }
        var wrong = verified
        wrong[0] = VerifiedFile(path: wrong[0].path, bytes: wrong[0].bytes + 1, sha256: wrong[0].sha256)
        CoreTests.reject("incremental rejects stale old-file sizes") {
            _ = try IncrementalISO.build(snapshot: snapshot, verified: wrong, sources: [newText], directory: root.appendingPathComponent("stale"))
        }
        print("PASS independent incremental ISO: oldBytes=\(oldBytes), newImageBytes=\(prepared.imageBytes), files=\(oldProofs.count + prepared.proof.files.count); deleted old sources, metadata-only preparation; libarchive extracts and SHA-256 matches all; old extents unchanged")
    }

    private static func command(_ executable: String, _ arguments: [String], output: URL) throws {
        try Data().write(to: output)
        let stream = try FileHandle(forWritingTo: output); defer { try? stream.close() }
        let errorURL = output.appendingPathExtension("err")
        try Data().write(to: errorURL)
        let errors = try FileHandle(forWritingTo: errorURL); defer { try? errors.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = stream; process.standardError = errors
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { _, value in value }
        try process.run(); process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw DiscFailure("Offline command failed \(executable): \(String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))")
        }
    }
}
