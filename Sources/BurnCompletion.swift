import Foundation

/// Pure state model: backend completion and physical completion are independent.
/// Times are monotonic seconds. A deadline is an observation limit, never a cancel.
struct BurnCompletion {
    enum Terminal: Equatable { case done, failed(String) }
    enum Outcome: Equatable {
        case ejected
        case normalEjectRequired
        case failed(String, recoveryRequired: Bool)
    }
    struct DeviceState: Equatable {
        let mediaAbsent: Bool
        let trayOpen: Bool
        let idle: Bool
    }

    private(set) var terminal: Terminal?
    private(set) var terminalTime: TimeInterval?
    private(set) var disconnected = false
    private(set) var lostDuringWrite = false
    private(set) var device: DeviceState?
    private var emptySince: TimeInterval?
    private var presentSince: TimeInterval?
    let completionWait: TimeInterval

    init(completionWait: TimeInterval = 120) { self.completionWait = completionWait }

    func canRefreshStatus(at time: TimeInterval) -> Bool {
        guard let terminalTime, !lostDuringWrite else { return false }
        return time - terminalTime < completionWait
    }

    mutating func backendEnded(_ value: Terminal, at time: TimeInterval) {
        // Duplicate Done must not reset the deadline; contradictory events fail closed.
        if let terminal, terminal != value {
            self.terminal = .failed("刻录后端返回了相互矛盾的结束状态。")
        } else { terminal = value }
        if terminalTime == nil { terminalTime = time }
    }
    mutating func deviceChanged(_ value: DeviceState) {
        // Caller accepts only a fresh notification/status from the original
        // registry identity. An old cached open-tray event cannot clear a loss.
        disconnected = false
        device = value
        if !value.mediaAbsent || !value.trayOpen || !value.idle { emptySince = nil }
        if !value.idle { presentSince = nil }
    }
    mutating func deviceDisconnected() {
        if terminal == nil { lostDuringWrite = true }
        observationUnavailable()
    }

    mutating func observationUnavailable() {
        disconnected = true; device = nil
        emptySince = nil; presentSince = nil
    }

    mutating func outcome(at time: TimeInterval, driveStillRegistered: Bool, registryMediaAbsent: Bool?) -> Outcome? {
        // Even disconnect/timeout cannot release a job whose backend hasn't ended.
        guard let terminal, let terminalTime else { return nil }
        if !driveStillRegistered { observationUnavailable() }
        if lostDuringWrite || disconnected {
            // A transient lookup/notification is not proof of a physical unplug.
            // Keep the existing deadline and ownership, without issuing commands.
            guard time - terminalTime >= completionWait else { return nil }
            let detail: String
            switch terminal {
            case .done: detail = "系统写入及校验已完成，但光驱身份或结束状态未能重新确认。"
            case .failed(let error): detail = "系统刻录失败：\(error)。光驱结束状态也未确认。"
            }
            return .failed(detail + "请使用“重新检查设备”恢复，再只读核验；不要重复刻录。", recoveryRequired: true)
        }
        // A real fourth-session run reported open/empty, but a new IOMedia
        // still existed and the user saw a closed tray. Require independent
        // registry agreement, sustained after terminal. 15 s is an observation
        // grace period, not proof of physical movement or a hardware timeout.
        if let device, device.mediaAbsent && device.trayOpen && device.idle && registryMediaAbsent == true {
            if emptySince == nil { emptySince = time }
        } else { emptySince = nil }
        if registryMediaAbsent == false && device?.idle == true {
            if presentSince == nil { presentSince = time }
        } else { presentSince = nil }
        if let emptySince, time - emptySince >= 15 {
            switch terminal {
            case .done: return .ejected
            case .failed(let detail): return .failed(detail, recoveryRequired: false)
            }
        }
        // A terminal successful backend with stable, independently observed media
        // hands off once to Disk Arbitration. This is not overall job completion.
        if terminal == .done, let presentSince, time - presentSince >= 15 {
            return .normalEjectRequired
        }
        guard time - terminalTime >= completionWait else { return nil }
        let detail: String
        switch terminal {
        case .done: detail = "系统写入及校验结束，但未取得持续一致的设备与介质移除证据。"
        case .failed(let error): detail = "系统刻录失败：\(error)。结束动作也未确认。"
        }
        return .failed(detail + "已停止新增设备操作，未重试弹出或刻录。", recoveryRequired: true)
    }
}

struct BurnProgress: Sendable {
    enum Kind: Sendable { case backend, device, finishing, warning }
    let kind: Kind
    let state: String
    let fraction: Double?
    let detail: String
}

struct BurnRecoveryRequired: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}
