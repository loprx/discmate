import Foundation
import DiscRecording

/// A task owns the device until its awaited operation has actually returned.
/// There is intentionally no timeout/cancel transition that releases this gate.
struct DeviceOperationGate {
    private enum State { case idle, running, recoveryRequired, recovering }
    private var state: State = .idle
    var isBusy: Bool { state == .running || state == .recovering }
    var needsRecovery: Bool { state == .recoveryRequired || state == .recovering }
    var blocksOperations: Bool { state != .idle }
    mutating func beginOperation() -> Bool {
        guard state == .idle else { return false }
        state = .running; return true
    }
    mutating func operationEnded(needsRecovery: Bool) {
        precondition(state == .running)
        state = needsRecovery ? .recoveryRequired : .idle
    }
    mutating func beginRecovery() -> Bool {
        guard state == .recoveryRequired else { return false }
        state = .recovering; return true
    }
    mutating func recoveryEnded(accepted: Bool) {
        precondition(state == .recovering)
        state = accepted ? .idle : .recoveryRequired
    }
}

/// Independent registry identity plus the documented DiscRecording status keys.
/// A new recovery attempt establishes a new baseline, including after reconnect.
struct DeviceRecoveryState: Equatable, Sendable {
    let driveID: UInt64
    let mediaID: UInt64 // Zero means the registry contains no media objects.
    let bsd: String?
    let busy: Bool?
    let mediaPresent: Bool?
    let trayOpen: Bool?

    func validateIdle() throws {
        guard driveID != 0, let busy, let mediaPresent, let trayOpen else {
            throw DiscFailure("光驱状态尚不明确；继续保留恢复锁，稍后可再次检查。")
        }
        guard !busy else { throw DiscFailure("光驱仍忙碌；请等待当前操作结束后再次检查。") }
        guard mediaPresent == (mediaID != 0), mediaPresent == (bsd != nil),
              !mediaPresent || !trayOpen else {
            throw DiscFailure("系统与介质状态不一致；未解除恢复锁，请待盘片稳定后再次检查。")
        }
    }
    static func validateStable(_ first: Self, _ second: Self) throws {
        try first.validateIdle(); try second.validateIdle()
        guard first == second else {
            throw DiscFailure("检查期间光驱或盘片状态变化；旧信息已失效，请稳定后再次检查。")
        }
    }
}

enum DeviceRecoveryService {
    /// Legacy DiscRecording panels are not completion evidence. Check the same
    /// physical drive twice, including its idle and open-tray status.
    static func checkAfterPanel(path: String, driveID: UInt64, requiresEject: Bool) throws -> DeviceRecoveryState {
        precondition(!Thread.isMainThread)
        let devices = (DRDevice.devices() as? [DRDevice]) ?? []
        guard let device = devices.first(where: { $0.ioRegistryEntryPath() == path }) else {
            throw BurnRecoveryRequired(detail: "系统进度窗口结束后无法确认原光驱；保留设备恢复锁。")
        }
        let first = try observe(device, path: path)
        Thread.sleep(forTimeInterval: 2)
        let second = try observe(device, path: path)
        try DeviceRecoveryState.validateStable(first, second)
        guard second.driveID == driveID else {
            throw BurnRecoveryRequired(detail: "系统进度窗口结束后原光驱身份已变化；保留设备恢复锁。")
        }
        if requiresEject && (second.mediaPresent != false || second.trayOpen != true) {
            throw BurnRecoveryRequired(detail: "系统进度窗口结束后仍未确认原光驱空仓并开仓；保留设备恢复锁。")
        }
        return second
    }
    struct Target: Equatable, Sendable {
        let path: String
        let name: String
    }
    enum Result: Sendable {
        case stable(path: String, detail: String)
        case selectionRequired([Target])
    }
    /// No sector reads, unmounts, ejects or writes. Two bounded observations are
    /// separated by a settling interval; this does not cancel a blocked status().
    /// The caller retains its gate until this synchronous worker truly returns.
    static func check(preferredPath: String?) throws -> Result {
        precondition(!Thread.isMainThread)
        return try autoreleasepool {
            let devices = (DRDevice.devices() as? [DRDevice]) ?? []
            let selected = devices.first { preferredPath != nil && $0.ioRegistryEntryPath() == preferredPath }
                ?? (devices.count == 1 ? devices.first : nil)
            guard !devices.isEmpty else {
                throw DiscFailure("未检测到光驱；连接稳定后可再次点击“重新检查设备”。")
            }
            guard let device = selected else {
                let targets = devices.compactMap { device -> Target? in
                    guard let path = device.ioRegistryEntryPath(), !path.isEmpty else { return nil }
                    return Target(path: path, name: device.displayName() ?? "刻录机")
                }
                guard !targets.isEmpty else { throw DiscFailure("无法取得光驱身份，请连接稳定后再次检查。") }
                return .selectionRequired(targets)
            }
            guard let path = device.ioRegistryEntryPath(), !path.isEmpty else { throw DiscFailure("无法取得光驱身份，请稍后再次检查。") }
            let first = try observe(device, path: path)
            try first.validateIdle()
            // Only the serial worker waits. UI and task ownership remain active.
            Thread.sleep(forTimeInterval: 2)
            let second = try observe(device, path: path)
            try DeviceRecoveryState.validateStable(first, second)
            return .stable(path: path, detail: "drive=\(second.driveID) media=\(second.mediaID) bsd=\(second.bsd ?? "none")")
        }
    }

    private static func observe(_ device: DRDevice, path: String) throws -> DeviceRecoveryState {
        func registry() throws -> (UInt64, UInt64, String?) {
            var driveID: UInt64 = 0, mediaID: UInt64 = 0
            var name = [CChar](repeating: 0, count: 64)
            try checkSystem(dm_registry_recovery_state(path, &driveID, &mediaID, &name, name.count), "只读复核光驱与介质身份")
            return (driveID, mediaID, mediaID == 0 ? nil : String(cString: name))
        }
        let before = try registry()
        let status = device.status() ?? [:]
        let after = try registry()
        guard before == after else { throw DiscFailure("状态查询期间设备或盘片已变化，请稳定后再次检查。") }
        let media = status[DRDeviceMediaStateKey] as? String
        let present: Bool? = media == DRDeviceMediaStateMediaPresent ? true : media == DRDeviceMediaStateNone ? false : nil
        let info = status[DRDeviceMediaInfoKey] as? [AnyHashable: Any]
        guard present != true || info?[DRDeviceMediaBSDNameKey] as? String == after.2 else {
            throw DiscFailure("系统仍返回旧盘片信息；继续保留恢复锁，稍后可再次检查。")
        }
        return DeviceRecoveryState(driveID: after.0, mediaID: after.1, bsd: after.2,
            busy: (status[DRDeviceIsBusyKey] as? NSNumber)?.boolValue, mediaPresent: present,
            trayOpen: (status[DRDeviceIsTrayOpenKey] as? NSNumber)?.boolValue)
    }
}
