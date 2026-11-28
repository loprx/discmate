import Foundation

enum AppendImagePreparation {
    static func build(snapshot: SessionSnapshot, verified: [VerifiedFile], sources: [URL], directory: URL,
                      selectFormat: (SessionSnapshot) -> any AppendImageFormat = AppendFormats.select) throws -> PreparedIncrementalISO {
        let format = selectFormat(snapshot)
        let oldFiles = format.files(in: snapshot), oldDirectories = snapshot.directoryPaths
        guard snapshot.appendState == .appendReady, let writable = snapshot.writable,
              let start = writable.nextWritable, writable.freeBlocks > 0, !sources.isEmpty,
              (snapshot.recordedEntries != nil || snapshot.rootEntries.allSatisfy { !$0.directory }),
              snapshot.tracks.filter({ !$0.blank }).allSatisfy({ !$0.damaged && UInt64($0.start) + UInt64($0.blocks) <= start }),
              UInt64(start) + UInt64(writable.freeBlocks) <= snapshot.identity.bytes / 2048 else {
            throw AppendPreflightFailure(.invalidTree, "需要可追加的数据盘及完整目录信息，请重新识别光盘。")
        }
        guard verified.isEmpty || (verified.count == oldFiles.count && Set(verified.map(\.path)) == Set(oldFiles.map(\.name))) else {
            throw AppendPreflightFailure(.invalidTree, "旧文件校验依据与目录不一致。")
        }
        let oldDirectorySet = Set(oldDirectories)
        for entry in snapshot.treeEntries {
            let parent = entry.name.split(separator: "/").dropLast().joined(separator: "/")
            guard parent.isEmpty || oldDirectorySet.contains(parent),
                  snapshot.tracks.contains(where: { $0.contains(entry.lba, bytes: entry.bytes) }) else {
                throw AppendPreflightFailure(.invalidTree, "旧目录缺少父项或区段无效，请重新识别光盘。")
            }
            if !entry.directory && !verified.isEmpty {
                guard verified.contains(where: { $0.path == entry.name && $0.bytes == entry.bytes &&
                    $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else {
                    throw AppendPreflightFailure(.invalidTree, "旧文件大小或校验依据不一致。")
                }
            }
        }
        let sourceTree = try AppendSourceTree.inspect(sources, existing: oldFiles + snapshot.treeEntries.filter(\.directory))
        try format.validate(sourceTree, oldFiles: oldFiles)
        let directories = Set(oldDirectories + sourceTree.directories).sorted()
        guard !sourceTree.files.isEmpty || directories.count > oldDirectories.count else {
            throw AppendPreflightFailure(.conflict, "所选目录没有新增内容，无需追加。")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? fm.removeItem(at: directory) } }
        let staging = directory.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for path in directories.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) {
            try fm.createDirectory(at: staging.appendingPathComponent(path), withIntermediateDirectories: false)
        }
        for (index, old) in oldFiles.enumerated() {
            try Data("DiscMate extent reference \(index)\n".utf8).write(to: staging.appendingPathComponent(old.name), options: .withoutOverwriting)
        }
        var newProofs: [FileProof] = []
        for source in sourceTree.files {
            let destination = staging.appendingPathComponent(source.path)
            let captured = try FileProof.capture(source.url, to: destination)
            newProofs.append(FileProof(path: source.path, bytes: captured.bytes, sha256: captured.sha256))
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
        }
        try sourceTree.validateUnchanged()
        let image = directory.appendingPathComponent("append.iso")
        let context = AppendImageContext(snapshot: snapshot, start: start, oldFiles: oldFiles,
            directories: directories, added: newProofs, staging: staging, image: image)
        var proof = AppendProof(previousSession: snapshot.latest.session, expectedStart: start,
            files: verified.map { FileProof(path: $0.path, bytes: UInt64($0.bytes), sha256: $0.sha256) } + newProofs,
            directories: directories.isEmpty ? nil : directories)
        if verified.isEmpty { proof.preserved = oldFiles.map { PreservedFile(path: $0.name, bytes: $0.bytes, lba: $0.lba) } }
        try format.author(context, proof: &proof)
        let bytes = try context.checkedBytes()
        try proof.validateStructure()
        let imageProof = try FileProof.capture(image)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = try encoder.encode(proof)
        guard manifest.count <= 1024 * 1024 else { throw AppendPreflightFailure(.invalidTree, "源清单超过 1 MiB 的安全读取上限，请减少项目或缩短路径。") }
        try manifest.write(to: directory.appendingPathComponent("expected.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: image.path)
        try sourceTree.validateUnchanged()
        completed = true
        return PreparedIncrementalISO(image: image, proof: proof, imageBytes: bytes,
            referencedBytes: oldFiles.reduce(0) { $0 + UInt64($1.bytes) }, imageSHA256: imageProof.sha256,
            sourceTree: sourceTree, preservedDirectoryPaths: oldDirectories)
    }
}
