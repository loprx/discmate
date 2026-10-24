import Foundation
import DiskArbitration

/// One normal whole-disc unmount, then one normal eject. Never force, retry or
/// open a raw descriptor. The DA callback owns the request until it finishes.
@MainActor
final class DiscEjectService {
    private let session: DASession
    init() throws {
        guard let value = DASessionCreate(kCFAllocatorDefault) else { throw DiscFailure("无法连接系统磁盘管理服务。") }
        session = value; DASessionSetDispatchQueue(value, .main)
    }
    deinit { DASessionSetDispatchQueue(session, nil) }

    func eject(_ identity: MediaIdentity, drivePath: String, expectedDriveID: UInt64? = nil, progress: (String) -> Void) async throws {
        try identity.validate()
        var driveID: UInt64 = 0
        try checkSystem(dm_registry_identity(drivePath, &driveID), "确认光驱身份")
        guard expectedDriveID == nil || expectedDriveID == driveID else {
            throw BurnRecoveryRequired(detail: "刻录后的光驱身份已变化，未发起卸载或推出。")
        }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/\(identity.bsd)"),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              description[kDADiskDescriptionMediaWholeKey as String] as? Bool == true else {
            throw DiscFailure("未找到已识别的整张光盘。")
        }
        progress("请求系统正常卸载整张光盘；未使用强制选项。")
        try await request(disk, eject: false)
        try identity.validate()
        var current: UInt64 = 0
        guard dm_registry_identity(drivePath, &current) == 0, current == driveID else {
            throw BurnRecoveryRequired(detail: "卸载后光驱身份变化，未继续推出。")
        }
        progress("正常卸载回调成功；请求一次系统正常推出。")
        try await request(disk, eject: true)
        progress("推出回调成功，正在交叉核对注册表介质移除；尚需确认实际托盘。")
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var absentSince: TimeInterval?
        var driveGoneSince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            var present: Int32 = -1
            let identityStatus = dm_registry_identity(drivePath, &current)
            let now = ProcessInfo.processInfo.systemUptime
            if identityStatus == ENXIO {
                if driveGoneSince == nil { driveGoneSince = now }
                if now - driveGoneSince! >= 3 {
                    throw BurnDriveDisconnected(detail: "系统推出回调已结束，但光驱随后断开；未确认持续介质移除或实际托盘。重新连接后请刷新设备。")
                }
                absentSince = nil
            } else if identityStatus == 0 && current == driveID {
                driveGoneSince = nil
                if dm_registry_has_media(drivePath, &present) == 0 && present == 0 {
                    if absentSince == nil { absentSince = now }
                    if now - absentSince! >= 15 { return }
                } else { absentSince = nil }
            } else {
                throw BurnRecoveryRequired(detail: "推出期间光驱身份变化或状态未知，不能认定为正常弹出。")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw BurnRecoveryRequired(detail: "推出回调结束，但介质移除未持续确认。未重试，也未解除设备故障状态。")
    }
    private func request(_ disk: DADisk, eject: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Unmanaged.passRetained(Callback(continuation, action: eject ? "推出" : "卸载")).toOpaque()
            if eject { DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), Self.callback, context) }
            else { DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), Self.callback, context) }
        }
    }
    private final class Callback {
        let continuation: CheckedContinuation<Void, Error>
        let action: String
        init(_ continuation: CheckedContinuation<Void, Error>, action: String) { self.continuation = continuation; self.action = action }
    }
    private nonisolated static let callback: DADiskEjectCallback = { _, dissenter, context in
        guard let context else { return }
        let value = Unmanaged<Callback>.fromOpaque(context).takeRetainedValue()
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            let message = DADissenterGetStatusString(dissenter) as String? ?? "系统拒绝请求"
            value.continuation.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "正常\(value.action)失败：\(message)（\(status)）；未强制操作或重试。"]))
        } else { value.continuation.resume() }
    }
}
