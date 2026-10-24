import DiscRecording
import Foundation

/// Blank media may have no usable BSD disk for Disk Arbitration. DiscRecording
/// unmounts any associated volume before issuing a normal media eject.
enum BlankDiscEjectService {
    static func eject(drivePath: String, onRequestAccepted: @escaping @MainActor @Sendable () -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            var driveID: UInt64 = 0
            try checkSystem(dm_registry_identity(drivePath, &driveID), "确认光驱身份")
            guard let device = (DRDevice.devices() as? [DRDevice])?.first(where: {
                $0.ioRegistryEntryPath() == drivePath
            }), device.isValid() else {
                throw BurnRecoveryRequired(detail: "未找到原光驱，未请求推出。")
            }
            let status = device.status() as NSDictionary
            var currentID: UInt64 = 0
            try checkSystem(dm_registry_identity(drivePath, &currentID), "推出前复核光驱身份")
            guard currentID == driveID, device.mediaIsPresent(), device.mediaIsBlank(),
                  (status[DRDeviceIsBusyKey] as? NSNumber)?.boolValue == false else {
                throw BurnRecoveryRequired(detail: "光驱或空白盘状态已变化，未请求推出。")
            }
            guard device.ejectMedia() else {
                throw DiscFailure("光驱拒绝正常推出空白盘；未强制操作或重试。")
            }
            await MainActor.run { onRequestAccepted() }
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            var absentSince: TimeInterval?
            while ProcessInfo.processInfo.systemUptime < deadline {
                let identityResult = dm_registry_identity(drivePath, &currentID)
                if identityResult == ENXIO {
                    throw BurnDriveDisconnected(detail: "推出请求后光驱断开；无法确认盘片是否弹出。重新连接后请刷新设备。")
                }
                guard identityResult == 0, currentID == driveID else {
                    throw BurnRecoveryRequired(detail: "推出期间光驱身份变化，不能确认盘片状态。")
                }
                var present: Int32 = -1
                try checkSystem(dm_registry_has_media(drivePath, &present), "确认空白盘已移除")
                let now = ProcessInfo.processInfo.systemUptime
                if present == 0 {
                    if absentSince == nil { absentSince = now }
                    if now - absentSince! >= 3 { return }
                } else { absentSince = nil }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            throw BurnRecoveryRequired(detail: "光驱已接受推出请求，但未确认介质持续移除；请检查托盘实际状态。")
        }.value
    }
}
