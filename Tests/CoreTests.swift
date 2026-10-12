import Foundation

@main
struct CoreTests {
    static func reject(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection: \(name)") } catch { print("PASS reject \(name)") }
    }
    static func main() throws {
        BurnCompletionTests.run()
        OperationEstimateTests.run()
        try AppendProofTests.run()
        try IncrementalISOTests.run(large: CommandLine.arguments.contains("--large-iso"))
        let first = RecordedTrack(number: 1, session: 1, start: 0, blocks: 464, blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let second = RecordedTrack(number: 2, session: 2, start: 2512, blocks: 464, blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let pending = RecordedTrack(number: 3, session: 3, start: 5000, blocks: 10000, blank: true, damaged: false, nextWritable: 5000, freeBlocks: 10000)
        let selected = try ISO9660.latestCompleted([first, second, pending], emptyLastSession: 3)
        precondition(selected == second)
        precondition(second.contains(2975, bytes: 2048))
        precondition(!second.contains(2975, bytes: 2049))
        precondition(!second.contains(2511, bytes: 1))
        precondition(!pending.contains(5000, bytes: 2048))
        let huge = RecordedTrack(number: 1, session: 1, start: UInt32.max - 2, blocks: 2, blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        precondition(!huge.contains(UInt32.max - 1, bytes: UInt32.max))
        reject("empty disc") { _ = try ISO9660.latestCompleted([pending], emptyLastSession: 3) }
        let damaged = RecordedTrack(number: 2, session: 2, start: 2512, blocks: 464, blank: false, damaged: true, nextWritable: nil, freeBlocks: 0)
        reject("damaged newest does not fall back silently") { _ = try ISO9660.latestCompleted([first, damaged], emptyLastSession: nil) }
        reject("short descriptor") { _ = try ISO9660.descriptor(Data(repeating: 0, count: 16)) }
        reject("truncated directory record") { _ = try ISO9660.directory(Data([40, 0, 0]), joliet: false) }
        reject("mixed-endian value") { _ = try ISO9660.both32(Data([1,0,0,0,0,0,0,2]), 0) }
        // Hash/copy chunk boundaries and source-manifest rejection, entirely offline.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-proof-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let original = temporary.appendingPathComponent("sample.bin")
        let copied = temporary.appendingPathComponent("copy.bin")
        try Data((0..<(1024 * 1024 + 31)).map { UInt8($0 % 251) }).write(to: original)
        let proof = try FileProof.capture(original, to: copied)
        let copyProof = try FileProof.capture(copied)
        precondition(proof.bytes == 1024 * 1024 + 31 && proof.sha256 == copyProof.sha256)
        let manifest = AppendProof(previousSession: 2, expectedStart: 5000, files: [proof])
        let archive = try BurnTaskArchive.create(proof: manifest, priorLog: nil,
            root: temporary.appendingPathComponent("archive"))
        let recovered = try JSONDecoder().decode(AppendProof.self, from: Data(contentsOf: archive.proofURL))
        precondition(recovered.previousSession == 2 && recovered.expectedStart == 5000 && recovered.files == [proof])
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.proofURL.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        reject("archive cannot be created, no write may start") {
            _ = try BurnTaskArchive.create(proof: manifest, priorLog: nil, root: original)
        }
        print("PASS persistent source archive: round-trip, permissions, unwritable destination")
        let valid = VerifiedFile(path: "sample.bin", bytes: UInt32(proof.bytes), sha256: proof.sha256)
        try manifest.validate([valid], session: 3, start: 5000)
        reject("wrong session") { try manifest.validate([valid], session: 2, start: 5000) }
        reject("wrong start") { try manifest.validate([valid], session: 3, start: 6000) }
        reject("missing file") { try manifest.validate([], session: 3, start: 5000) }
        reject("hash mismatch") { try manifest.validate([VerifiedFile(path: "sample.bin", bytes: valid.bytes, sha256: "wrong")], session: 3, start: 5000) }
        let link = temporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        reject("source symlink") { _ = try FileProof.capture(link) }
        print("PASS streaming copy and source manifest validation")
        // Optional local capture: regular files only; never opens a device.
        if CommandLine.arguments.count == 3 && CommandLine.arguments.dropFirst().allSatisfy({ !$0.hasPrefix("--") }) {
            for path in CommandLine.arguments.dropFirst() {
                let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey])
                precondition(values.isRegularFile == true)
            }
            let pvd = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let root = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let volume = try ISO9660.descriptor(pvd)!
            precondition(volume.root.lba == 2533 && volume.root.bytes == 2048)
            let entries = try ISO9660.directory(root, joliet: false)
            precondition(entries.map(\.name) == ["iso-first.txt", "iso-second.txt"])
            precondition(entries.map(\.lba) == [2537, 2538])
            precondition(entries.map(\.bytes) == [47, 48])
            var bad = root; bad[0] = 33
            reject("corrupted real directory") { _ = try ISO9660.directory(bad, joliet: false) }
            print("PASS real-disc captured PVD and directory (offline)")
        }
        print("PASS core: session selection, bounded extents, malformed ISO")
    }
}
