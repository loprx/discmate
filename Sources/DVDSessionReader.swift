import Foundation
import CryptoKit
import Darwin

struct MediaIdentity: Equatable, Sendable {
    let bsd: String
    let registryID: UInt64
    let bytes: UInt64
    static func current(_ bsd: String) throws -> MediaIdentity {
        guard bsd.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else { throw DiscFailure("无效的光盘设备标识。") }
        var raw = DMMedia()
        try checkSystem(dm_media(bsd, &raw), "识别 DVD+R")
        return MediaIdentity(bsd: bsd, registryID: raw.registryID, bytes: raw.bytes)
    }
    func validate() throws {
        guard try Self.current(bsd) == self else { throw DiscFailure("光盘已更换或设备已重连，请重新识别。") }
    }
}

func checkSystem(_ code: Int32, _ operation: String) throws {
    guard code == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation)失败（\(code)）：\(String(cString: strerror(code)))"])
    }
}

struct SessionSnapshot: Sendable {
    let identity: MediaIdentity
    let tracks: [RecordedTrack]
    let latest: RecordedTrack
    let volume: ISOVolume
    let rootEntries: [ISOEntry]
    let descriptorHash: String
    let appendable: Bool
    var incompleteSession = false
    var recordedEntries: [ISOEntry]? = nil
    var treeEntries: [ISOEntry] { (recordedEntries ?? rootEntries).sorted { $0.name < $1.name } }
    var fileEntries: [ISOEntry] { treeEntries.filter { !$0.directory } }
    var directoryPaths: [String] { treeEntries.filter(\.directory).map(\.name) }
    var writable: RecordedTrack? { tracks.last(where: { $0.blank && $0.nextWritable != nil && !$0.damaged }) }
}

struct VerifiedFile: Sendable {
    let path: String
    let bytes: UInt32
    let sha256: String
}

/// Used on a worker task only. Every hardware call is serial. A timeout prevents
/// starting another call; it cannot cancel a read already blocked in the kernel.
final class DVDSessionReader {
    private let identity: MediaIdentity
    private var fd: Int32
    private let deadline: TimeInterval
    init(identity: MediaIdentity, timeBudget: TimeInterval = 60) throws {
        deadline = ProcessInfo.processInfo.systemUptime + timeBudget
        try identity.validate()
        self.identity = identity
        fd = Darwin.open("/dev/r\(identity.bsd)", O_RDONLY | O_NONBLOCK)
        if fd < 0 { try checkSystem(errno, "只读打开光盘") }
    }
    deinit { close() }
    /// Close before transferring the drive to the burn engine. Don't depend on
    /// optimizer-selected object lifetime to release an optical read handle.
    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
    private func preflight() throws {
        guard fd >= 0 else { throw DiscFailure("只读会话已经关闭。") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw DiscFailure("只读任务超过时间预算，已停止发出新的设备命令。") }
        try identity.validate()
    }
    func scan() throws -> SessionSnapshot {
        try preflight()
        var disc = DMDisc()
        try checkSystem(dm_disc(fd, &disc), "读取会话状态")
        guard disc.status != 0, (disc.lastState == 0 || disc.lastState == 1 || disc.lastState == 3), disc.lastTrack > 0, disc.lastTrack <= 64 else {
            throw DiscFailure("不支持当前光盘状态：discStatus=\(disc.status)、lastState=\(disc.lastState)、lastTrack=\(disc.lastTrack)。")
        }
        var tracks: [RecordedTrack] = []
        for number in 1...disc.lastTrack {
            try preflight()
            var raw = DMTrack()
            try checkSystem(dm_track(fd, number, &raw), "读取轨道 \(number)")
            guard raw.number == number, UInt64(raw.start) + UInt64(raw.blocks) <= identity.bytes / 2048 else {
                throw DiscFailure("轨道地址无效，已停止读取。")
            }
            tracks.append(RecordedTrack(number: raw.number, session: raw.session, start: raw.start, blocks: raw.blocks,
                                        blank: raw.blank != 0, damaged: raw.damaged != 0,
                                        nextWritable: raw.nwaValid != 0 ? raw.nwa : nil, freeBlocks: raw.freeBlocks))
        }
        let readable = try ISO9660.readableTracks(tracks, lastState: disc.lastState)
        let latest = try ISO9660.latestCompleted(readable, emptyLastSession: disc.lastState == 0 ? disc.sessions : nil)
        var primary: ISOVolume?; var joliet: ISOVolume?; var descriptors = Data(); var terminated = false
        for offset: UInt32 in 16..<48 {
            let position = UInt64(latest.start) + UInt64(offset)
            guard position <= UInt32.max else { throw DiscFailure("卷描述符地址溢出。") }
            let data = try read(lba: UInt32(position), bytes: 2048, tracks: [latest])
            let volume = try ISO9660.descriptor(data)
            descriptors.append(data)
            if let volume { if volume.joliet { joliet = volume } else { primary = volume } }
            if data[0] == 255 { terminated = true; break }
        }
        guard terminated, primary != nil, let volume = joliet ?? primary else { throw DiscFailure("ISO 卷描述符不完整。") }
        let tree = try RecordedDirectoryTree.scan(root: volume.root, tracks: readable, capacityBytes: identity.bytes) {
            try self.directory($0, volume: volume, tracks: readable)
        }
        let entries = tree.filter { !$0.name.contains("/") }
        try preflight()
        return SessionSnapshot(identity: identity, tracks: readable, latest: latest, volume: volume, rootEntries: entries,
                               descriptorHash: hash(descriptors), appendable: disc.status == 1 && disc.lastState != 1,
                               incompleteSession: disc.lastState == 1, recordedEntries: tree)
    }
    private func read(lba: UInt32, bytes: UInt32, tracks: [RecordedTrack]) throws -> Data {
        guard bytes <= 1024 * 1024, tracks.contains(where: { $0.contains(lba, bytes: bytes) }) else {
            throw DiscFailure("读取范围超出已记录轨道或单次读取上限，已停止。")
        }
        if bytes == 0 { return Data() }
        try preflight()
        let rounded = (Int(bytes) + 2047) / 2048 * 2048
        var result = Data(count: rounded)
        let count = result.withUnsafeMutableBytes { buffer in
            pread(fd, buffer.baseAddress!, rounded, off_t(lba) * 2048)
        }
        if count < 0 { try checkSystem(errno, "光盘只读读取") }
        guard count == rounded else { throw DiscFailure("光盘读回不足：预期 \(rounded) 字节，实际 \(count)。") }
        return Data(result.prefix(Int(bytes)))
    }
    private func directory(_ entry: ISOEntry, volume: ISOVolume, tracks: [RecordedTrack]) throws -> [ISOEntry] {
        guard entry.bytes > 0, entry.bytes <= 1024 * 1024 else { throw DiscFailure("ISO 目录大小超出当前检查范围。") }
        return try ISO9660.directory(read(lba: entry.lba, bytes: entry.bytes, tracks: tracks), joliet: volume.joliet)
    }
    /// Copy only known recorded ranges into a sparse ordinary file for the ISO
    /// generator. Gaps and the empty pending track are never read from hardware.
    /// This prototype caps capture at 64 MiB; it does not re-burn captured bytes.
    func captureRecorded(_ expected: SessionSnapshot, to url: URL) throws {
        let fresh = try scan()
        guard fresh.latest == expected.latest, fresh.descriptorHash == expected.descriptorHash, fresh.treeEntries == expected.treeEntries else {
            throw DiscFailure("创建镜像前会话信息变化，请重新识别。")
        }
        let tracks = fresh.tracks.filter { !$0.blank && $0.session <= fresh.latest.session }
        guard tracks.allSatisfy({ !$0.damaged }), tracks.reduce(UInt64(0), { $0 + UInt64($1.blocks) * 2048 }) <= 64 * 1024 * 1024 else {
            throw DiscFailure("本版增量准备仅支持已记录区段总量不超过 64 MiB 的无损坏测试盘。")
        }
        let file = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw DiscFailure("无法创建旧会话缓存：\(String(cString: strerror(errno)))") }
        defer { Darwin.close(file) }
        for track in tracks {
            var blocks: UInt32 = 0
            while blocks < track.blocks {
                let count = min(UInt32(512), track.blocks - blocks)
                let data = try read(lba: track.start + blocks, bytes: count * 2048, tracks: [track])
                let n = data.withUnsafeBytes { pwrite(file, $0.baseAddress!, data.count, off_t(track.start + blocks) * 2048) }
                guard n == data.count else { throw DiscFailure("写入本地会话缓存失败。") }
                blocks += count
            }
        }
        try preflight()
    }
    /// Bounded verification of ordinary files. Symlinks, cycles and special files
    /// are rejected, never followed into the host filesystem.
    func verify(_ snapshot: SessionSnapshot, mountedAt mount: URL, progress: (String, UInt64) -> Void = { _, _ in }) throws -> [VerifiedFile] {
        try verifyContents(snapshot, mountedAt: mount, progress: progress)
    }
    /// Read actual recorded extents without mounting a filesystem or asking for
    /// administrator credentials. This makes no claim about Finder visibility.
    func verifyRecorded(_ snapshot: SessionSnapshot, paths: Set<String>? = nil, progress: (String, UInt64) -> Void = { _, _ in }) throws -> [VerifiedFile] {
        try verifyContents(snapshot, mountedAt: nil, paths: paths, progress: progress)
    }
    private func verifyContents(_ snapshot: SessionSnapshot, mountedAt mount: URL?, paths: Set<String>? = nil, progress: (String, UInt64) -> Void) throws -> [VerifiedFile] {
        let fresh = try scan()
        guard fresh.identity == snapshot.identity, fresh.latest == snapshot.latest,
              fresh.descriptorHash == snapshot.descriptorHash,
              fresh.treeEntries == snapshot.treeEntries else { throw DiscFailure("校验前介质、会话或目录发生变化。") }
        if let paths {
            // Empty means a directory-only append: validate metadata without
            // claiming hashes or reading any old payload.
            guard paths.count <= 10000, paths.isSubset(of: Set(fresh.fileEntries.map(\.name))) else {
                throw DiscFailure("请选择当前会话中有效的文件进行校验。")
            }
        }
        if let mount {
            try checkSystem(dm_mount_matches(mount.path, identity.bsd), "检查只读挂载来源")
            try MountedSessionDirectory.validate(root: mount,
                entries: Dictionary(uniqueKeysWithValues: fresh.treeEntries.map { ($0.name, $0) }))
        }
        var result: [VerifiedFile] = [], processed: UInt64 = 0
        for child in fresh.fileEntries {
            let relative = child.name
            if let paths, !paths.contains(relative) { continue }
            let url = mount?.appendingPathComponent(relative)
            let localFD = url.map { Darwin.open($0.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
            guard mount == nil || localFD >= 0 else { throw DiscFailure("无法只读打开挂载文件：\(relative)") }
            defer { if localFD >= 0 { Darwin.close(localFD) } }
            if localFD >= 0 {
                var info = stat()
                guard fstat(localFD, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      info.st_size == Int64(child.bytes) else { throw DiscFailure("挂载文件在校验前发生变化。") }
            }
            var digest = SHA256(), offset: UInt32 = 0
            while offset < child.bytes {
                let length = min(UInt32(1024 * 1024), child.bytes - offset)
                let absolute = UInt64(child.lba) + UInt64(offset / 2048)
                guard absolute <= UInt32.max else { throw DiscFailure("文件地址溢出。") }
                let optical = try read(lba: UInt32(absolute), bytes: length, tracks: fresh.tracks)
                if localFD >= 0 {
                    var mounted = Data(count: Int(length))
                    let n = mounted.withUnsafeMutableBytes { pread(localFD, $0.baseAddress!, Int(length), off_t(offset)) }
                    guard n == length, optical == mounted else { throw DiscFailure("挂载内容与会话文件不一致：\(relative)") }
                }
                digest.update(data: optical); offset += length; processed += UInt64(length)
                if offset == child.bytes || offset % (16 * 1024 * 1024) == 0 { progress(relative, processed) }
            }
            result.append(VerifiedFile(path: relative, bytes: child.bytes,
                sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()))
        }
        if let paths, Set(result.map(\.path)) != paths { throw DiscFailure("请求校验的文件不全在当前目录中。") }
        try preflight()
        if let mount { try checkSystem(dm_mount_matches(mount.path, identity.bsd), "复核挂载来源") }
        return result
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
