import Foundation

enum RecordedDirectoryTreeTests {
    static func run() throws {
        let track = RecordedTrack(number: 1, session: 1, start: 0, blocks: 100000,
            blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let root = ISOEntry(name: ".", lba: 20, bytes: 2048, directory: true)
        let folder = ISOEntry(name: "资料", lba: 21, bytes: 2048, directory: true)
        let file = ISOEntry(name: "same.txt", lba: 25, bytes: 3, directory: false)
        var reads: [UInt32] = []
        let tree = try RecordedDirectoryTree.scan(root: root, tracks: [track], capacityBytes: 204800000) { entry in
            reads.append(entry.lba)
            return entry.lba == 20 ? [folder, file] : [file]
        }
        precondition(tree.map(\.name) == ["same.txt", "资料", "资料/same.txt"])
        precondition(reads == [20, 21], "Only directory extents may be read")
        CoreTests.reject("recorded tree cycle") {
            _ = try RecordedDirectoryTree.scan(root: root, tracks: [track], capacityBytes: 100) { _ in
                [ISOEntry(name: "cycle", lba: 20, bytes: 2048, directory: true)]
            }
        }
        CoreTests.reject("recorded tree out of range") {
            _ = try RecordedDirectoryTree.scan(root: root, tracks: [track], capacityBytes: 100) { _ in
                [ISOEntry(name: "bad", lba: 100001, bytes: 2048, directory: true)]
            }
        }
        CoreTests.reject("recorded tree duplicate paths") {
            _ = try RecordedDirectoryTree.scan(root: root, tracks: [track], capacityBytes: 100) { _ in [file, file] }
        }
        CoreTests.reject("recorded tree unsafe component") {
            _ = try RecordedDirectoryTree.scan(root: root, tracks: [track], capacityBytes: 100) { _ in
                [ISOEntry(name: "../escape", lba: 25, bytes: 0, directory: false)]
            }
        }
        CoreTests.reject("recorded tree depth") {
            _ = try RecordedDirectoryTree.scan(root: root, tracks: [track], capacityBytes: 100) { entry in
                [ISOEntry(name: "next", lba: entry.lba + 1, bytes: 2048, directory: true)]
            }
        }
        CoreTests.reject("recorded tree item count") {
            _ = try RecordedDirectoryTree.scan(root: root, tracks: [track], capacityBytes: 100) { _ in
                (0...10000).map { ISOEntry(name: "file\($0)", lba: 25, bytes: 0, directory: false) }
            }
        }
        CoreTests.reject("recorded tree aggregate metadata budget") {
            let largeRoot = ISOEntry(name: ".", lba: 20, bytes: 1024 * 1024, directory: true)
            _ = try RecordedDirectoryTree.scan(root: largeRoot, tracks: [track], capacityBytes: 100) { entry in
                entry.lba == 20 ? (1...33).map {
                    ISOEntry(name: "directory\($0)", lba: UInt32(20 + $0 * 512), bytes: 1024 * 1024, directory: true)
                } : []
            }
        }
        CoreTests.reject("recorded tree declared payload exceeds medium") {
            _ = try RecordedDirectoryTree.scan(root: root, tracks: [track], capacityBytes: 2) { _ in [file] }
        }
        print("PASS recorded directory traversal: metadata-only, nested paths, cycles/ranges/names/depth/count/32MiB limits")
    }
}
