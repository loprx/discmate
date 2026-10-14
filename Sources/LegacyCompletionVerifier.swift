import Foundation

struct LegacyCompletionTracker {
    private var absentSince: TimeInterval?

    mutating func observe(now: TimeInterval, mediaPresent: Bool) -> Bool {
        if mediaPresent { absentSince = nil; return false }
        if absentSince == nil { absentSince = now }
        return now - absentSince! >= 15
    }
}

/// Registry observation never ejects, reads sectors, or releases the task on a
/// timeout. A stable empty registry is followed by an independent DR status read.
enum LegacyCompletionVerifier {
    static func verify(path: String, driveID: UInt64, requiresEject: Bool) throws -> DeviceRecoveryState {
        precondition(!Thread.isMainThread)
        if !requiresEject {
            return try DeviceRecoveryService.checkAfterPanel(path: path, driveID: driveID, requiresEject: false)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        var tracker = LegacyCompletionTracker()
        while ProcessInfo.processInfo.systemUptime < deadline {
            var current: UInt64 = 0
            try checkSystem(dm_registry_identity(path, &current), "复核刻录光驱身份")
            guard current == driveID else { throw BurnRecoveryRequired(detail: "刻录后原光驱身份已变化；保留设备恢复锁。") }
            var present: Int32 = -1
            try checkSystem(dm_registry_has_media(path, &present), "复核刻录后介质")
            let now = ProcessInfo.processInfo.systemUptime
            if tracker.observe(now: now, mediaPresent: present != 0) {
                return try DeviceRecoveryService.checkAfterPanel(path: path, driveID: driveID, requiresEject: true)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw BurnRecoveryRequired(detail: "系统窗口已结束，但介质移除未持续确认；保留设备恢复锁。")
    }
}
