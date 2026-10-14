import Foundation

enum LegacyPreflightFailure: LocalizedError {
    case changedMedium
    case changedDrive
    case unavailableCapability

    var errorDescription: String? {
        switch self {
        case .changedMedium: return "设置期间光盘或光驱已变化，未开始操作。请刷新设备。"
        case .changedDrive: return "设置窗口选择了其他光驱，未开始操作。请刷新设备。"
        case .unavailableCapability: return "盘片状态或所需能力已变化，未开始操作。请刷新设备。"
        }
    }
}

/// Bound to the selected whole optical medium before a modal setup/confirmation.
/// Rechecked immediately before handing a legacy task to DiscRecordingUI.
struct LegacyMediaPreflight: Sendable {
    let drivePath: String
    let driveID: UInt64
    let mediaID: UInt64
    let bsd: String
    let wasBlank: Bool

    static func capture(path: String, wasBlank: Bool) throws -> Self {
        var driveID: UInt64 = 0, mediaID: UInt64 = 0
        var bsd = [CChar](repeating: 0, count: 64)
        try checkSystem(dm_registry_recovery_state(path, &driveID, &mediaID, &bsd, bsd.count), "记录系统任务盘片身份")
        guard driveID != 0, mediaID != 0, bsd[0] != 0 else {
            throw DiscFailure("无法确认当前盘片身份，未开始操作。请刷新设备。")
        }
        return Self(drivePath: path, driveID: driveID, mediaID: mediaID,
                    bsd: String(cString: bsd), wasBlank: wasBlank)
    }

    func validate() throws {
        var currentDrive: UInt64 = 0, currentMedia: UInt64 = 0
        var currentBSD = [CChar](repeating: 0, count: 64)
        try checkSystem(dm_registry_recovery_state(drivePath, &currentDrive, &currentMedia,
                                                   &currentBSD, currentBSD.count), "复核系统任务盘片身份")
        try validate(driveID: currentDrive, mediaID: currentMedia, bsd: String(cString: currentBSD))
    }

    func validate(driveID currentDrive: UInt64, mediaID currentMedia: UInt64, bsd currentBSD: String) throws {
        guard currentDrive == driveID, currentMedia == mediaID, currentBSD == bsd else {
            throw LegacyPreflightFailure.changedMedium
        }
    }

    func validateBurnCapability(isBlank: Bool, isAppendable: Bool) throws {
        guard isBlank == wasBlank, isBlank || isAppendable else {
            throw LegacyPreflightFailure.unavailableCapability
        }
    }
}
