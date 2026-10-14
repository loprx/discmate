import Foundation
import DiscRecording

/// Immutable input only. All DR objects, including filesystem producers, are
/// created and released by DiscBurnWorker's dedicated run loop.
struct FirstDataBurnRequest: Sendable {
    let drivePath: String
    let driveID: UInt64
    let mediaID: UInt64
    let bsd: String
    let sources: [URL]
    let volumeName: String
    let appendable: Bool
    let speed: BurnSpeedSelection

    static func capture(drivePath: String, sources: [URL], volumeName: String,
                        appendable: Bool, speed: BurnSpeedSelection) throws -> Self {
        var driveID: UInt64 = 0, mediaID: UInt64 = 0
        var bsd = [CChar](repeating: 0, count: 64)
        try checkSystem(dm_registry_recovery_state(drivePath, &driveID, &mediaID, &bsd, bsd.count), "记录首次刻录盘片身份")
        guard driveID != 0, mediaID != 0, !sources.isEmpty else { throw DiscFailure("未识别到待刻录光盘或文件。") }
        return Self(drivePath: drivePath, driveID: driveID, mediaID: mediaID, bsd: String(cString: bsd),
                    sources: sources, volumeName: volumeName, appendable: appendable, speed: speed)
    }
    func validateIdentity() throws {
        var currentDrive: UInt64 = 0, currentMedia: UInt64 = 0
        var name = [CChar](repeating: 0, count: 64)
        try checkSystem(dm_registry_recovery_state(drivePath, &currentDrive, &currentMedia, &name, name.count), "复核首次刻录盘片身份")
        try validateIdentity(driveID: currentDrive, mediaID: currentMedia, bsd: String(cString: name))
    }
    func validateIdentity(driveID currentDrive: UInt64, mediaID currentMedia: UInt64, bsd currentBSD: String) throws {
        guard currentDrive == driveID, currentMedia == mediaID, currentBSD == bsd else {
            throw DiscFailure("确认后光盘或光驱已变化，未开始刻录。请刷新设备。")
        }
    }
    static func validateCapacity(estimatedBlocks: UInt64, freeBlocks: UInt64) throws {
        guard estimatedBlocks > 0, freeBlocks > 0 else { throw DiscFailure("无法确认镜像或盘片容量，未开始写入。") }
        guard estimatedBlocks <= freeBlocks else { throw DiscFailure("文件及光盘目录所需空间超过盘片可用容量，未开始写入。") }
    }
    func makeTrack() throws -> DRTrack {
        precondition(!Thread.isMainThread)
        guard let root = DRFolder.virtualFolder(withName: volumeName) else { throw DiscFailure("无法创建光盘目录。") }
        root.setExplicitFilesystemMask(UInt32(DRFilesystemInclusionMaskISO9660 | DRFilesystemInclusionMaskJoliet))
        for url in sources {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                  FileManager.default.isReadableFile(atPath: url.path) else { throw DiscFailure("源文件不可读取：\(url.lastPathComponent)") }
            if directory.boolValue {
                guard let folder = DRFolder(path: url.path) else { throw DiscFailure("无法读取文件夹：\(url.lastPathComponent)") }
                root.addChild(folder)
            } else {
                guard let file = DRFile(path: url.path) else { throw DiscFailure("无法读取文件：\(url.lastPathComponent)") }
                root.addChild(file)
            }
        }
        guard let track = DRTrack(forRootFolder: root) else { throw DiscFailure("无法创建数据轨道。") }
        return track
    }
}
