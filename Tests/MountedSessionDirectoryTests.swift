import Foundation

enum MountedSessionDirectoryTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-mount-directory-\(UUID())")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("资料/空目录"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appendingPathComponent("资料/a.txt"))
        let entries: [String: ISOEntry] = [
            "资料": .init(name: "资料", lba: 1, bytes: 2048, directory: true),
            "资料/空目录": .init(name: "空目录", lba: 2, bytes: 2048, directory: true),
            "资料/a.txt": .init(name: "a.txt", lba: 3, bytes: 3, directory: false)
        ]
        try MountedSessionDirectory.validate(root: root, entries: entries)
        try Data().write(to: root.appendingPathComponent("资料/stale.txt"))
        CoreTests.reject("mount same root but stale child") { try MountedSessionDirectory.validate(root: root, entries: entries) }
        try fm.removeItem(at: root.appendingPathComponent("资料/stale.txt"))
        try Data("wrong size".utf8).write(to: root.appendingPathComponent("资料/a.txt"))
        CoreTests.reject("mount wrong child length") { try MountedSessionDirectory.validate(root: root, entries: entries) }
        try fm.removeItem(at: root.appendingPathComponent("资料/a.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("资料/a.txt").path, withDestinationPath: "/etc/hosts")
        CoreTests.reject("mount symlink cannot masquerade as file") { try MountedSessionDirectory.validate(root: root, entries: entries) }
        CoreTests.reject("mount path traversal") {
            try MountedSessionDirectory.validate(root: root, entries: ["../escape": .init(name: "escape", lba: 1, bytes: 0, directory: false)])
        }
        print("PASS mounted directory: nested/empty/Chinese paths, stale children, size, symlink and unsafe path rejection; metadata only")
    }
}
