import Foundation

enum AppendSourceTreeTests {
    static func run() throws {
        let fm = FileManager.default, root = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-source-tree-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("资料")
        for directory in [folder, folder.appendingPathComponent("Nested"), folder.appendingPathComponent("Empty")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try Data("first".utf8).write(to: folder.appendingPathComponent("same.txt"))
        try Data("second".utf8).write(to: folder.appendingPathComponent("Nested/same.txt"))
        let existing = [ISOEntry(name: "资料", lba: 20, bytes: 2048, directory: true)]
        let tree = try AppendSourceTree.inspect([folder], existing: existing)
        precondition(tree.files.count == 2 && tree.directories.count == 3)
        try tree.validateUnchanged()
        CoreTests.reject("source directory/file type conflict") {
            _ = try AppendSourceTree.inspect([folder], existing: [ISOEntry(name: "资料", lba: 20, bytes: 1, directory: false)])
        }
        CoreTests.reject("source repeated directory selection") { _ = try AppendSourceTree.inspect([folder, folder]) }
        let named = root.appendingPathComponent("name.txt")
        try Data().write(to: named)
        CoreTests.reject("source case-insensitive collision") {
            _ = try AppendSourceTree.inspect([named], existing: [ISOEntry(name: "NAME.TXT", lba: 20, bytes: 1, directory: false)])
        }
        let unicode = root.appendingPathComponent("e\u{301}.txt")
        try Data().write(to: unicode)
        CoreTests.reject("source Unicode-normalized collision") {
            _ = try AppendSourceTree.inspect([unicode], existing: [ISOEntry(name: "é.txt", lba: 20, bytes: 1, directory: false)])
        }
        let long = root.appendingPathComponent(String(repeating: "a", count: 65))
        try Data().write(to: long)
        CoreTests.reject("source filename length") { _ = try AppendSourceTree.inspect([long]) }
        let deep = root.appendingPathComponent("Depth")
        var deepest = deep
        for _ in 0..<8 {
            try fm.createDirectory(at: deepest, withIntermediateDirectories: true)
            deepest.appendPathComponent("next")
        }
        try fm.createDirectory(at: deepest, withIntermediateDirectories: true)
        CoreTests.reject("source path depth") { _ = try AppendSourceTree.inspect([deep]) }
        CoreTests.reject("source combined item count") {
            _ = try AppendSourceTree.inspect([], existing: (0...10000).map {
                ISOEntry(name: "file\($0)", lba: 20, bytes: 0, directory: false)
            })
        }
        CoreTests.reject("source nonlocal URL") { _ = try AppendSourceTree.inspect([URL(string: "https://example.invalid/file")!]) }
        try Data().write(to: folder.appendingPathComponent("Empty/added.txt"))
        CoreTests.reject("source tree membership changed after summary") { try tree.validateUnchanged() }
        print("PASS source tree: merge, relative names, empty directories, conflicts, Unicode/case ambiguity, depth/count/name limits and membership mutation")
    }
}
