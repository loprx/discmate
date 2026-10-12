import Foundation

/// Pure manifest/metadata contract tests. No MediaIdentity.current(), reader,
/// mount, or optical device is opened by these fixtures.
enum AppendProofTests {
    static func run() throws {
        let hash = String(repeating: "a", count: 64)
        let oldHash = String(repeating: "b", count: 64)
        let added = FileProof(path: "new.txt", bytes: 19, sha256: hash)
        let old = PreservedFile(path: "old.bin", bytes: 1_120_401_929, lba: 20)
        let start: UInt32 = 600_000
        let proof = AppendProof(previousSession: 4, expectedStart: start, files: [added], preserved: [old])
        let newActual = VerifiedFile(path: added.path, bytes: UInt32(added.bytes), sha256: hash)
        let oldActual = VerifiedFile(path: old.path, bytes: old.bytes, sha256: oldHash)
        let entries = [ISOEntry(name: old.path, lba: old.lba, bytes: old.bytes, directory: false),
                       ISOEntry(name: added.path, lba: start + 24, bytes: UInt32(added.bytes), directory: false)]
        let prior = RecordedTrack(number: 4, session: 4, start: 0, blocks: start, blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        func snapshot(_ root: [ISOEntry], session: UInt32 = 5, newStart: UInt32 = start,
                      oldTrack: RecordedTrack? = nil) -> SessionSnapshot {
            let latest = RecordedTrack(number: 5, session: session, start: newStart, blocks: 450, blank: false,
                damaged: false, nextWritable: nil, freeBlocks: 0)
            return SessionSnapshot(identity: MediaIdentity(bsd: "offline-only", registryID: 0, bytes: 2_295_104 * 2048),
                tracks: [oldTrack ?? prior, latest], latest: latest,
                volume: ISOVolume(root: ISOEntry(name: ".", lba: newStart + 20, bytes: 2048, directory: true), joliet: true),
                rootEntries: root, descriptorHash: "offline", appendable: true)
        }
        try proof.validateStructure()
        try proof.validateDirectory(snapshot(entries))
        try proof.validate([newActual], session: 5, start: start, addedOnly: true)
        try proof.validate([newActual, oldActual], session: 5, start: start)
        // Full reading without a prior old hash is a readability check, not an
        // assertion of equality to a source that was never provided.
        let otherOldHash = VerifiedFile(path: old.path, bytes: old.bytes, sha256: String(repeating: "c", count: 64))
        try proof.validate([newActual, otherOldHash], session: 5, start: start)
        CoreTests.reject("new-data scope does not silently include old files") {
            try proof.validate([newActual, oldActual], session: 5, start: start, addedOnly: true)
        }
        CoreTests.reject("full scope requires preserved files") { try proof.validate([newActual], session: 5, start: start) }
        CoreTests.reject("full scope preserved size mismatch") {
            try proof.validate([newActual, VerifiedFile(path: old.path, bytes: old.bytes - 1, sha256: oldHash)], session: 5, start: start)
        }
        CoreTests.reject("new-data scope hash mismatch") {
            try proof.validate([VerifiedFile(path: added.path, bytes: UInt32(added.bytes), sha256: oldHash)], session: 5, start: start, addedOnly: true)
        }
        CoreTests.reject("new-data scope duplicate file") { try proof.validate([newActual, newActual], session: 5, start: start, addedOnly: true) }
        CoreTests.reject("new-data scope missing file") { try proof.validate([], session: 5, start: start, addedOnly: true) }
        CoreTests.reject("different disc directory") { try proof.validateDirectory(snapshot([entries[0]])) }
        CoreTests.reject("wrong latest session") { try proof.validateDirectory(snapshot(entries, session: 4)) }
        CoreTests.reject("wrong latest start") { try proof.validateDirectory(snapshot(entries, newStart: start + 1)) }
        var changed = entries
        changed[0] = ISOEntry(name: old.path, lba: old.lba + 1, bytes: old.bytes, directory: false)
        CoreTests.reject("preserved extent moved") { try proof.validateDirectory(snapshot(changed)) }
        changed[0] = ISOEntry(name: old.path, lba: old.lba, bytes: old.bytes - 1, directory: false)
        CoreTests.reject("preserved directory size changed") { try proof.validateDirectory(snapshot(changed)) }
        changed[0] = ISOEntry(name: old.path, lba: old.lba, bytes: old.bytes, directory: true)
        CoreTests.reject("preserved file changed into directory") { try proof.validateDirectory(snapshot(changed)) }
        let damaged = RecordedTrack(number: 4, session: 4, start: 0, blocks: start, blank: false, damaged: true, nextWritable: nil, freeBlocks: 0)
        CoreTests.reject("preserved extent in damaged track") { try proof.validateDirectory(snapshot(entries, oldTrack: damaged)) }
        let truncated = RecordedTrack(number: 4, session: 4, start: 0, blocks: 100, blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        CoreTests.reject("preserved extent outside recorded track") { try proof.validateDirectory(snapshot(entries, oldTrack: truncated)) }
        CoreTests.reject("manifest duplicate new paths") {
            try AppendProof(previousSession: 4, expectedStart: start, files: [added, added]).validateStructure()
        }
        CoreTests.reject("manifest duplicate old/new paths") {
            try AppendProof(previousSession: 4, expectedStart: start, files: [added],
                preserved: [PreservedFile(path: added.path, bytes: 19, lba: 20)]).validateStructure()
        }
        CoreTests.reject("manifest case-insensitive collision") {
            try AppendProof(previousSession: 4, expectedStart: start, files: [added],
                preserved: [PreservedFile(path: "NEW.TXT", bytes: 19, lba: 20)]).validateStructure()
        }
        CoreTests.reject("manifest relative traversal") {
            try AppendProof(previousSession: 4, expectedStart: start,
                files: [FileProof(path: "../new.txt", bytes: 19, sha256: hash)]).validateStructure()
        }
        CoreTests.reject("manifest malformed hash") {
            try AppendProof(previousSession: 4, expectedStart: start,
                files: [FileProof(path: added.path, bytes: 19, sha256: "not-a-hash")]).validateStructure()
        }
        CoreTests.reject("manifest oversized file") {
            try AppendProof(previousSession: 4, expectedStart: start,
                files: [FileProof(path: added.path, bytes: UInt64(UInt32.max), sha256: hash)]).validateStructure()
        }
        CoreTests.reject("manifest session overflow") {
            try AppendProof(previousSession: UInt32.max, expectedStart: start, files: [added]).validateStructure()
        }
        CoreTests.reject("manifest old extent crosses next session") {
            try AppendProof(previousSession: 4, expectedStart: start, files: [added],
                preserved: [PreservedFile(path: old.path, bytes: 4096, lba: start - 1)]).validateStructure()
        }
        let encoded = try JSONEncoder().encode(proof)
        let decoded = try JSONDecoder().decode(AppendProof.self, from: encoded)
        try decoded.validateDirectory(snapshot(entries))
        try decoded.validate([newActual], session: 5, start: start, addedOnly: true)
        // Explicit historical JSON lacks the new field; old archives remain usable.
        let legacyJSON = """
        {"previousSession":4,"expectedStart":600000,"files":[{"path":"new.txt","bytes":19,"sha256":"\(hash)"}]}
        """
        let legacy = try JSONDecoder().decode(AppendProof.self, from: Data(legacyJSON.utf8))
        precondition(legacy.preserved == nil)
        try legacy.validate([newActual], session: 5, start: start)
        print("PASS proof scope: added-only/full, metadata preservation, malformed/foreign directory rejection, legacy and new JSON")
    }
}
