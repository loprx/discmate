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

enum ISOVolumeExtension: Sendable {
    case none, udf, unrecognized
}

struct SessionSnapshot: Sendable {
    let identity: MediaIdentity
    let tracks: [RecordedTrack]
    let latest: RecordedTrack
    let volume: ISOVolume?
    let rootEntries: [ISOEntry]
    let descriptorHash: String
    let appendable: Bool
    var incompleteSession = false
    var recordedEntries: [ISOEntry]? = nil
    var primaryImportVerified = false
    var volumeExtension: ISOVolumeExtension = .none
    var bridge: BridgeSession? = nil
    var udf: UDFVolumeProbe? = nil
    var filesystemLabel: String {
        if udf != nil { return "UDF 1.02" }
        if hasUDFRecognition { return "ISO/UDF" }
        return volume?.joliet == true ? "ISO/Joliet" : "ISO"
    }
    var hasUDFRecognition: Bool { volumeExtension == .udf }
    var importableISO: Bool { volumeExtension == .none && (volume?.joliet == true || primaryImportVerified) }
    var filesystem: DiagnosticFilesystem {
        if udf != nil { return .udf102 }
        switch volumeExtension {
        case .udf: return .isoUdfBridge
        case .unrecognized: return .isoWithUnknownExtension
        case .none: return volume?.joliet == true ? .isoJoliet : .iso9660
        }
    }
    var treeEntries: [ISOEntry] { (recordedEntries ?? rootEntries).sorted { $0.name < $1.name } }
    var fileEntries: [ISOEntry] { treeEntries.filter { !$0.directory } }
    var directoryPaths: [String] { treeEntries.filter(\.directory).map(\.name) }
    // A previously reserved fragment belongs to the open session after latest.
    // Only the complete preceding session supplies filesystem metadata.
    var reservedTrack: RecordedTrack? = nil
    var writable: RecordedTrack? {
        if let reservedTrack { return reservedTrack }
        guard let last = tracks.last, last.blank, !last.damaged, last.nextWritable != nil else { return nil }
        return last
    }
    var appendState: DiscWriteState {
        if incompleteSession && reservedTrack == nil { return .incompleteSession }
        guard appendable || reservedTrack != nil else { return .notAppendable }
        if hasUDFRecognition && bridge == nil { return .unsupportedBridge }
        if udf != nil && incompleteSession { return .incompleteSession }
        guard importableISO || bridge != nil || udf != nil else { return .unsupportedFormat }
        guard let writable, let start = writable.nextWritable,
              tracks.filter({ !$0.blank }).allSatisfy({ !$0.damaged && UInt64($0.start) + UInt64($0.blocks) <= start }),
              UInt64(start) + UInt64(writable.freeBlocks) <= identity.bytes / 2048 else { return .noWritableTrack }
        if writable.freeBlocks == 0 { return .full }
        if reservedTrack != nil { return .appendReady }
        return IncrementalISO.hasSpaceForSession(writable.freeBlocks) ? .appendReady : .insufficientSpace
    }
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
    func closeSessionDescriptor(matching expected: SessionSnapshot) throws -> Data {
        let fresh = try scan()
        guard fresh.identity == expected.identity, fresh.incompleteSession, expected.incompleteSession,
              fresh.latest == expected.latest, fresh.tracks == expected.tracks,
              fresh.reservedTrack == expected.reservedTrack, fresh.descriptorHash == expected.descriptorHash, fresh.treeEntries == expected.treeEntries,
              let sector = UInt32(exactly: UInt64(fresh.latest.start) + 16) else {
            throw DiscFailure("盘片、轨道或目录已变化，请重新识别后再确认。")
        }
        return try read(lba: sector, bytes: 2048, tracks: [fresh.latest])
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
        if let reserved = ISO9660.blankReservation(tracks, disc: disc, capacity: identity.bytes / 2048) {
            let prior = Array(tracks.dropLast(2))
            let latest = try ISO9660.latestCompleted(prior, emptyLastSession: nil)
            var snapshot = try Self.scanSession(identity: identity, tracks: tracks, latest: latest,
                discStatus: disc.status, lastState: disc.lastState, read: read(lba:bytes:tracks:))
            snapshot.reservedTrack = reserved
            try preflight()
            return snapshot
        }
        let readable = try ISO9660.readableTracks(tracks, lastState: disc.lastState)
        let latest = try ISO9660.latestCompleted(readable, emptyLastSession: disc.lastState == 0 ? disc.sessions : nil)
        let snapshot = try Self.scanSession(identity: identity, tracks: readable, latest: latest,
            discStatus: disc.status, lastState: disc.lastState, read: read(lba:bytes:tracks:))
        try preflight()
        return snapshot
    }

    static func scanSession(identity: MediaIdentity, tracks readable: [RecordedTrack], latest: RecordedTrack,
                            discStatus: UInt32, lastState: UInt32,
                            read: (UInt32, UInt32, [RecordedTrack]) throws -> Data) throws -> SessionSnapshot {
        var primary: ISOVolume?; var joliet: ISOVolume?; var descriptors = Data(); var terminated = false
        var plainRecords = true
        var bridgeDescriptorsSupported = true
        var primaryLabel = ""
        var volumeExtension = ISOVolumeExtension.none
        for offset: UInt32 in 16..<48 {
            let position = UInt64(latest.start) + UInt64(offset)
            guard position <= UInt32.max else { throw DiscFailure("卷描述符地址溢出。") }
            let data = try read(UInt32(position), 2048, [latest])
            if offset == 16 && data.subdata(in: 1..<6) == Data("BEA01".utf8) {
                var cache: [UInt32: Data] = [:]
                func metadata(_ address: UInt32) throws -> Data {
                    if let data = cache[address] { return data }
                    guard cache.count < 16_384 else { throw DiscFailure("UDF 目录元数据超过 32 MiB。") }
                    let data = try read(address, 2048, [latest])
                    cache[address] = data
                    return data
                }
                let capacity = identity.bytes / 2048
                let udf = try UDFVolumeProbe.inspect(sessionStart: latest.start, capacityBlocks: capacity, readSector: metadata)
                let unsupported = UDFAppendUnsupported(revision: udf.revision, partitionMapType: udf.partitionMapType)
                guard udf.revision == 0x0102, udf.partitionNumber == 0, udf.label?.isEmpty == false,
                      lastState != 1 else { throw unsupported }
                let tree = try udf.importTree(capacity: capacity, tracks: readable, read: metadata)
                var digest = SHA256()
                for address in cache.keys.sorted() { digest.update(data: cache[address]!) }
                return SessionSnapshot(identity: identity, tracks: readable, latest: latest, volume: nil,
                    rootEntries: tree.filter { !$0.name.contains("/") },
                    descriptorHash: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                    appendable: discStatus == 1, recordedEntries: tree, udf: udf)
            }
            let volume = try ISO9660.descriptor(data)
            descriptors.append(data)
            if let volume {
                if volume.joliet { joliet = volume }
                else {
                    if primary != nil { plainRecords = false; bridgeDescriptorsSupported = false }
                    primary = volume
                    primaryLabel = String(decoding: data[40..<72], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
                }
            }
            if data[0] == 255 {
                terminated = true
                // An ISO/UDF bridge may continue with a volume recognition sequence.
                if let next = UInt32(exactly: position + 1), latest.contains(next, bytes: 2048) {
                    let following = try read(next, 2048, [latest])
                    if following[1..<6] == Data("BEA01".utf8) {
                        plainRecords = false
                        volumeExtension = .unrecognized
                        descriptors.append(following)
                        if let address = UInt32(exactly: position + 2), latest.contains(address, bytes: 2048) {
                            let recognition = try read(address, 2048, [latest])
                            descriptors.append(recognition)
                            if ["NSR02", "NSR03"].contains(String(decoding: recognition[1..<6], as: UTF8.self)) {
                                volumeExtension = .udf
                            }
                        }
                    }
                }
                break
            }
            if data[0] != 1 { plainRecords = false }
            if data[0] != 1 && volume?.joliet != true { bridgeDescriptorsSupported = false }
        }
        guard terminated, primary != nil, let volume = joliet ?? primary else { throw DiscFailure("ISO 卷描述符不完整。") }
        let tree = try RecordedDirectoryTree.scan(root: volume.root, tracks: readable, capacityBytes: identity.bytes) { entry in
            let data = try read(entry.lba, entry.bytes, readable)
            return try ISO9660.directory(data, joliet: volume.joliet) { raw, child in
                if !volume.joliet && plainRecords { plainRecords = ISO9660.canImportPrimaryRecord(raw, entry: child) }
            }
        }
        let entries = tree.filter { !$0.name.contains("/") }
        var bridge: BridgeSession?
        if volumeExtension == .udf, bridgeDescriptorsSupported, !primaryLabel.contains("\0"), let primary {
            var cache: [UInt32: Data] = [:]
            bridge = try BridgeSession.inspect(latest: latest, capacity: identity.bytes / 2048, primary: primary,
                                               joliet: volume.joliet, entries: tree, label: primaryLabel) { sector in
                if let data = cache[sector] { return data }
                guard cache.count < 128 else { throw DiscFailure("混合盘目录超出本版识别范围。") }
                let data = try read(sector, 2048, readable)
                cache[sector] = data
                descriptors.append(data)
                return data
            }
        }
        return SessionSnapshot(identity: identity, tracks: readable, latest: latest, volume: volume, rootEntries: entries,
                               descriptorHash: hash(descriptors), appendable: discStatus == 1 && lastState != 1,
                               incompleteSession: lastState == 1, recordedEntries: tree,
                               primaryImportVerified: !volume.joliet && plainRecords, volumeExtension: volumeExtension, bridge: bridge)
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
    /// Copy only known recorded ranges into a sparse ordinary file for the ISO
    /// generator. Gaps and the empty pending track are never read from hardware.
    /// This prototype caps capture at 64 MiB; it does not re-burn captured bytes.
    func captureRecorded(_ expected: SessionSnapshot, to url: URL) throws {
        let fresh = try scan()
        guard fresh.latest == expected.latest, fresh.reservedTrack == expected.reservedTrack, fresh.descriptorHash == expected.descriptorHash, fresh.treeEntries == expected.treeEntries else {
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
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
