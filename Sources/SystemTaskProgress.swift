import Foundation

/// UI-only interpretation of system progress. Never authorizes a drive operation.
struct SystemTaskProgress {
    enum Stage: String {
        case preparing, opening, writing, verifying, closing, finishing, erasing, done, failed, waiting
        var title: String {
            switch self {
            case .preparing: return "正在准备"
            case .opening: return "正在开启会话"
            case .writing: return "正在写入"
            case .verifying: return "正在进行系统校验"
            case .closing: return "正在关闭会话"
            case .finishing: return "正在执行系统收尾"
            case .erasing: return "正在擦除"
            case .done: return "系统任务已结束"
            case .failed: return "系统任务失败"
            case .waiting: return "等待系统状态"
            }
        }
        init(systemState: String) {
            switch systemState {
            case "DRStatusStatePreparing": self = .preparing
            case "DRStatusStateSessionOpen", "DRStatusStateTrackOpen": self = .opening
            case "DRStatusStateTrackWrite": self = .writing
            case "DRStatusStateVerifying": self = .verifying
            case "DRStatusStateTrackClose", "DRStatusStateSessionClose": self = .closing
            case "DRStatusStateFinishing": self = .finishing
            case "DRStatusStateErasing": self = .erasing
            case "DRStatusStateDone": self = .done
            case "DRStatusStateFailed": self = .failed
            default: self = .waiting
            }
        }
    }
    private(set) var stage: Stage = .preparing
    private(set) var fraction: Double?
    private(set) var startedAt: Date
    private(set) var phaseStartedAt: Date
    private(set) var phaseInitialFraction: Double?
    private(set) var panelFinished = false
    var terminal: Bool { stage == .done || stage == .failed }
    var canRelease: Bool { terminal && panelFinished }

    init(now: Date = Date()) { startedAt = now; phaseStartedAt = now }
    mutating func panelDidFinish() { panelFinished = true }
    mutating func update(state: String, fraction raw: Double?, now: Date = Date()) {
        let next = Stage(systemState: state)
        // Terminal states cannot be undone by a delayed in-progress callback.
        if terminal {
            if next == .failed { stage = .failed }
            return
        }
        let value = raw.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        if next != stage || (value != nil && fraction != nil && value! < fraction!) {
            phaseStartedAt = now; phaseInitialFraction = value
        }
        stage = next
        fraction = [.writing, .verifying, .erasing].contains(next) ? value : nil
        if phaseInitialFraction == nil, let fraction {
            phaseInitialFraction = fraction; phaseStartedAt = now
        }
    }
    func remaining(at now: Date = Date()) -> String? {
        guard let fraction, let initial = phaseInitialFraction, fraction < 1,
              fraction - initial >= 0.02, now.timeIntervalSince(phaseStartedAt) >= 5 else { return nil }
        let seconds = now.timeIntervalSince(phaseStartedAt) * (1 - fraction) / (fraction - initial)
        return "当前阶段预计剩余 " + OperationEstimate.duration(seconds)
    }
}
