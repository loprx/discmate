import Foundation
import CryptoKit
import DiscRecording
import Darwin

struct FileProof: Codable, Equatable, Sendable {
    let path: String
    let bytes: UInt64
    let sha256: String

    /// Bounded-memory hashing/copying of regular local files. Reject mutation
    /// during capture; the burner only receives the captured immutable staging.
    static func capture(_ source: URL, to destination: URL? = nil) throws -> FileProof {
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DiscFailure("无法打开源文件：\(source.lastPathComponent)") }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size >= 0, UInt64(before.st_size) < UInt64(UInt32.max) else {
            throw DiscFailure("当前 ISO 测试仅接受小于 4 GiB 的普通文件。")
        }
        let output: Int32
        if let destination {
            output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw DiscFailure("无法创建测试暂存文件。") }
        } else { output = -1 }
        defer { if output >= 0 { Darwin.close(output) } }
        var digest = SHA256(); var count: UInt64 = 0
        var data = Data(count: 1024 * 1024)
        while true {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            guard n >= 0 else { throw DiscFailure("读取源文件失败：\(source.lastPathComponent)，errno=\(errno)") }
            if n == 0 { break }
            let chunk = Data(data.prefix(n))
            digest.update(data: chunk); count += UInt64(n)
            if output >= 0 {
                try chunk.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < n {
                        let written = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), n - offset)
                        guard written > 0 else { throw DiscFailure("写入暂存文件失败，errno=\(errno)") }
                        offset += written
                    }
                }
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, count == UInt64(before.st_size), after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw DiscFailure("源文件在准备期间发生变化，未开始刻录。")
        }
        return FileProof(path: source.lastPathComponent, bytes: count,
                         sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

struct PreservedFile: Codable, Sendable {
    let path: String
    let bytes: UInt32
    let lba: UInt32
}

struct AppendProof: Codable, Sendable {
    let previousSession: UInt32
    let expectedStart: UInt32
    let files: [FileProof]
    // Absent in legacy manifests, where every file has a source hash.
    var preserved: [PreservedFile]? = nil
    var allPaths: Set<String> { Set(files.map(\.path) + (preserved ?? []).map(\.path)) }

    /// Validate even locally-created manifests at their consumption boundary.
    /// `files` carries content expectations; `preserved` carries only metadata.
    /// A preserved extent is never evidence that its payload was read or hashed.
    func validateStructure() throws {
        let old = preserved ?? []
        let names = files.map(\.path) + old.map(\.path)
        guard previousSession > 0, previousSession < UInt32.max, expectedStart > 0,
              !files.isEmpty, names.count <= 10000,
              names.allSatisfy(Self.validPath),
              Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == names.count,
              files.allSatisfy({ $0.bytes < UInt64(UInt32.max) && Self.validHash($0.sha256) }),
              old.allSatisfy({ UInt64($0.lba) + (UInt64($0.bytes) + 2047) / 2048 <= UInt64(expectedStart) }) else {
            throw DiscFailure("校验清单包含无效会话、文件名、重复文件、哈希或旧区段地址。")
        }
    }

    func validateDirectory(_ snapshot: SessionSnapshot) throws {
        try validateStructure()
        guard snapshot.latest.session == previousSession + 1, snapshot.latest.start == expectedStart,
              snapshot.rootEntries.count == allPaths.count,
              Set(snapshot.rootEntries.map(\.name)) == allPaths,
              snapshot.rootEntries.allSatisfy({ entry in
                  !entry.directory && snapshot.tracks.contains(where: { $0.contains(entry.lba, bytes: entry.bytes) })
              }) else {
            throw DiscFailure("光盘会话或目录与本轮清单不同，请确认放入的是本轮光盘。")
        }
        for old in preserved ?? [] {
            guard snapshot.rootEntries.contains(where: { $0.name == old.path && $0.bytes == old.bytes && $0.lba == old.lba }) else {
                throw DiscFailure("旧文件区段发生变化：\(old.path)")
            }
        }
        for file in files {
            guard let entry = snapshot.rootEntries.first(where: { $0.name == file.path }),
                  UInt64(entry.bytes) == file.bytes,
                  preserved == nil || snapshot.latest.contains(entry.lba, bytes: entry.bytes) else {
                throw DiscFailure("文件目录或新增文件区段不匹配：\(file.path)")
            }
        }
    }

    func validate(_ actual: [VerifiedFile], session: UInt32, start: UInt32, addedOnly: Bool = false) throws {
        try validateStructure()
        let expectedPaths = addedOnly ? Set(files.map(\.path)) : allPaths
        guard session == previousSession + 1, start == expectedStart,
              actual.count == expectedPaths.count, Set(actual.map(\.path)) == expectedPaths,
              actual.allSatisfy({ Self.validHash($0.sha256) }) else {
            throw DiscFailure("读回会话或文件列表与本轮刻录清单不一致。")
        }
        for expected in files {
            guard let found = actual.first(where: { $0.path == expected.path }),
                  UInt64(found.bytes) == expected.bytes, found.sha256 == expected.sha256 else {
                throw DiscFailure("读回内容与刻录源文件不同：\(expected.path)")
            }
        }
        // A full read checks readability/size of preserved files, but no source
        // digest exists for these entries. The UI must keep that distinction.
        if !addedOnly {
            for old in preserved ?? [] {
                guard actual.contains(where: { $0.path == old.path && $0.bytes == old.bytes }) else {
                    throw DiscFailure("旧文件读回大小与目录记录不同：\(old.path)")
                }
            }
        }
    }

    private static func validPath(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf16.count <= 64 &&
        !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 0xffff || "*/\\:;?".unicodeScalars.contains($0) })
    }
    private static func validHash(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

}

struct PreparedTestAppend: Sendable {
    let directory: URL
    let proof: AppendProof
    let snapshot: SessionSnapshot
}

/// Experimental full-copy append, explicitly not the incremental extent import.
/// Only a previously verified DVD+R ISO session with <=64 MiB old files is allowed.
enum TestAppendService {
    static func prepare(snapshot: SessionSnapshot, mount: URL, verified: [VerifiedFile], sources: [URL]) throws -> PreparedTestAppend {
        let fresh = try DVDSessionReader(identity: snapshot.identity).scan()
        guard fresh.latest == snapshot.latest, fresh.descriptorHash == snapshot.descriptorHash,
              fresh.appendable, let writable = fresh.writable, let start = writable.nextWritable,
              !verified.isEmpty, !sources.isEmpty,
              fresh.rootEntries.allSatisfy({ !$0.directory }),
              Set(verified.map(\.path)) == Set(fresh.rootEntries.map(\.name)),
              verified.reduce(UInt64(0), { $0 + UInt64($1.bytes) }) <= 64 * 1024 * 1024 else {
            throw DiscFailure("本测试要求已完整读回的 ISO 数据盘、可用追加轨道及不超过 64 MiB 的根目录旧文件。")
        }
        try checkSystem(dm_mount_matches(mount.path, fresh.identity.bsd), "复核旧文件挂载")
        let names = verified.map(\.path) + sources.map(\.lastPathComponent)
        guard Set(names.map { $0.lowercased() }).count == names.count,
              names.allSatisfy({ !$0.contains("/") && $0.utf16.count <= 64 }) else {
            throw DiscFailure("文件名重复或超出本次 Joliet 测试范围。")
        }
        var required = verified.reduce(UInt64(0), { $0 + UInt64($1.bytes) })
        for source in sources {
            let value = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard value.isRegularFile == true, value.isSymbolicLink != true, let bytes = value.fileSize,
                  bytes >= 0, UInt64(bytes) < UInt64(UInt32.max) else { throw DiscFailure("请选择小于 4 GiB 的普通文件。") }
            required += UInt64(bytes)
        }
        // Deliberately conservative filesystem/session allowance for this test.
        guard required + 32 * 1024 * 1024 < UInt64(writable.freeBlocks) * 2048 else { throw DiscFailure("可追加空间不足。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-append-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        let staging = directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var proofs: [FileProof] = []
        for old in verified {
            let proof = try FileProof.capture(mount.appendingPathComponent(old.path), to: staging.appendingPathComponent(old.path))
            guard proof.bytes == UInt64(old.bytes), proof.sha256 == old.sha256 else { throw DiscFailure("旧文件与已验证结果不一致，停止准备。") }
            proofs.append(proof)
        }
        for source in sources { proofs.append(try FileProof.capture(source, to: staging.appendingPathComponent(source.lastPathComponent))) }
        for expected in proofs {
            let staged = staging.appendingPathComponent(expected.path)
            guard try FileProof.capture(staged) == expected else { throw DiscFailure("暂存文件校验失败。") }
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: staged.path)
        }
        try fresh.identity.validate()
        let proof = AppendProof(previousSession: fresh.latest.session, expectedStart: start, files: proofs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: directory.appendingPathComponent("expected.json"), options: .atomic)
        completed = true
        return PreparedTestAppend(directory: directory, proof: proof, snapshot: fresh)
    }

}
