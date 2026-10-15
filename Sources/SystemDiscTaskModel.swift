import AppKit
import DiscRecording
import DiscRecordingUI
import SwiftUI

/// Owns legacy system-panel operations independently of SwiftUI view lifetime.
/// The panel notification and backend terminal state must both arrive before reuse.
@MainActor
final class SystemDiscTaskModel: NSObject, ObservableObject {
    static let shared = SystemDiscTaskModel()
    typealias FirstDataOperation = @MainActor (FirstDataBurnRequest, (BurnProgress) -> Void) async throws -> Void
    private let firstDataOperation: FirstDataOperation
    private let diagnostics: DiagnosticReportStore
    private let coordinator: DeviceTaskCoordinator
    init(diagnostics: DiagnosticReportStore = .shared,
         coordinator: DeviceTaskCoordinator? = nil,
         firstDataOperation: @escaping FirstDataOperation = DiscBurnService.burnFirstData) {
        self.diagnostics = diagnostics; self.coordinator = coordinator ?? .shared; self.firstDataOperation = firstDataOperation
        super.init()
    }
    @Published private(set) var isBusy = false
    @Published private(set) var progress: SystemTaskProgress?
    @Published private(set) var message: String?
    @Published private(set) var actualSpeedKBps: Double?
    private var burn: DRBurn?
    private var erase: DRErase?
    private var panel: NSPanel?
    private var center: DRNotificationCenter?
    private var panelObserver: NSObjectProtocol?
    private var taskID: UUID?
    private var failureDescription: String?
    private var observedDevice: DRDevice?
    private var requestedSpeed: Double?
    private var automaticSpeed: Bool?
    private var firstDataVerificationObserved = false
    private var lease: UUID?
    private var legacyDrivePath: String?
    private var legacyDriveID: UInt64?
    private var requireRecovery: (@MainActor (String) -> Void)?
    private var checkingLegacyCompletion = false
    private var legacyRequiresEject = false

    func clearResult() {
        guard !isBusy else { return }
        progress = nil; message = nil; actualSpeedKBps = nil
    }
    /// No system progress panel: the shared worker owns the burn and its entire
    /// completion handoff. Recovery is transferred before releasing the UI lease.
    func beginFirstData(_ request: FirstDataBurnRequest, model: DiagnosticDriveModel,
                        fileCount: Int, totalBytes: UInt64?,
                        requireRecovery: @escaping @MainActor (String) -> Void) {
        guard !isBusy, let lease = coordinator.begin() else { return }
        self.lease = lease
        let id = diagnostics.startTask(kind: .dataBurn, media: .dvdPlusR,
            driveModel: model, fileCount: fileCount, totalBytes: totalBytes)
        taskID = id; isBusy = true; progress = SystemTaskProgress(); actualSpeedKBps = nil
        firstDataVerificationObserved = false
        diagnostics.record(taskID: id, event: .preparing,
            evidence: DiagnosticEvidence(verifyAfterWriteRequested: request.verifyAfterWrite))
        message = "正在检查空白盘、文件与刻录设置…"
        Task { @MainActor in
            var outcome = DiagnosticOutcome.completed
            do {
                try await self.firstDataOperation(request) { update in
                    self.acceptFirstData(update, id: id)
                }
                let verification = self.firstDataVerificationObserved ? "系统报告校验阶段" :
                    (request.verifyAfterWrite ? "已请求系统校验，但未记录到校验阶段" : "未请求系统写后校验")
                self.message = "写入及介质移除检查完成；\(verification)。请确认实际托盘已弹出；重新合仓后可读回核验。"
            } catch {
                let needsRecovery = error is BurnRecoveryRequired
                outcome = needsRecovery ? .needsRecovery : .failed
                self.message = error.localizedDescription
                diagnostics.record(taskID: id, event: needsRecovery ? .recoveryRequired : .failed,
                                                    error: error as NSError)
                if needsRecovery { requireRecovery(error.localizedDescription) }
                if self.progress?.terminal != true { self.progress?.update(state: DRStatusStateFailed, fraction: nil) }
            }
            diagnostics.finish(taskID: id, outcome: outcome)
            self.isBusy = false
            self.coordinator.finish(lease, needsRecovery: outcome == .needsRecovery)
            self.lease = nil
        }
    }
    private func acceptFirstData(_ update: BurnProgress, id: UUID) {
        guard isBusy, taskID == id else { return }
        var event = DiagnosticEventKind.finishing
        if update.kind == .backend, update.state.hasPrefix("DRStatusState") {
            if update.state == DRStatusStateVerifying { firstDataVerificationObserved = true }
            progress?.update(state: update.state, fraction: update.fraction)
            actualSpeedKBps = update.evidence?.actualSpeedKBps
            if let progress { event = Self.event(progress.stage) }
            message = progress?.terminal == true ? "系统任务已结束，正在确认介质状态及完成推出…" : progress?.stage.title
        } else {
            message = update.detail
            switch update.state {
            case "BackendReleased": event = .backendReleased
            case "RegistryMedia": event = .registryObserved
            case "DeviceStatus", "PreflightValidated", "SameDeviceReturned", "SameDeviceStatusRefreshed": event = .deviceStatusObserved
            case "DeviceUnavailable", "DeviceIdentityPending": event = .deviceUnavailable
            case "SystemEject": event = .ejectRequested
            case "EjectConfirmed": event = .ejectCompleted
            case "PreflightFailed", "EjectFailed": event = .failed
            default: event = update.kind == .warning ? .waiting : .finishing
            }
        }
        let domain: String
        switch update.errorSource {
        case .posix: domain = NSPOSIXErrorDomain
        case .osStatus: domain = NSOSStatusErrorDomain
        case .cocoa: domain = NSCocoaErrorDomain
        default: domain = "DiscMate"
        }
        diagnostics.record(taskID: id, event: event, progress: update.fraction,
            error: update.errorSource == .discRecording ? nil : update.errorCode.map { NSError(domain: domain, code: Int($0)) },
            backendError: update.errorSource == .discRecording ? update.errorCode.map { ["DRErrorStatusErrorKey": $0] } : nil,
            evidence: update.evidence)
    }
    func beginBurn(_ burn: DRBurn, layout: Any, kind: DiagnosticTaskKind,
                   model: DiagnosticDriveModel, media: DiagnosticMediaType,
                   fileCount: Int, totalBytes: UInt64?, speedSelection: BurnSpeedSelection? = nil,
                   preflight: LegacyMediaPreflight,
                   requireRecovery: @escaping @MainActor (String) -> Void = { _ in }) {
        guard !isBusy, let lease = coordinator.begin() else { return }
        self.lease = lease; self.requireRecovery = requireRecovery
        taskID = diagnostics.startTask(kind: kind, media: media, driveModel: model,
                                                        fileCount: fileCount, totalBytes: totalBytes)
        guard let panel = DMCreateBurnProgressPanel(), Self.hasProgressIndicator(panel.contentView) else {
            recordStartupFailure(.panelCreationFailed)
            message = "无法加载系统刻录进度窗口，未开始写入。"; return
        }
        guard observeBackend(burn, name: .DRBurnStatusChanged) else { return }
        self.burn = burn
        legacyRequiresEject = burn.completionAction() == DRBurnCompletionActionEject
        requestedSpeed = Double(burn.requestedBurnSpeed())
        automaticSpeed = burn.requestedBurnSpeed() == DRDeviceBurnSpeedMax
        guard observeDevice(burn.device()) else { return }
        begin(panel: panel, notification: .DRBurnProgressPanelDidFinish, kind: kind,
              model: model, media: media, fileCount: fileCount, totalBytes: totalBytes)
        let observedTaskID = taskID
        // The setup panel can outlive the selected media. Keep the lease while
        // validating the original medium and capabilities on a background thread.
        Task { @MainActor in
            do {
                let speed = try await Task.detached { () throws -> Float? in
                    try preflight.validate()
                    guard let device = burn.device(), device.isValid(), device.mediaIsPresent() else {
                        throw LegacyPreflightFailure.unavailableCapability
                    }
                    guard device.ioRegistryEntryPath() == preflight.drivePath else {
                        throw LegacyPreflightFailure.changedDrive
                    }
                    try preflight.validateBurnCapability(isBlank: device.mediaIsBlank(),
                                                         isAppendable: device.mediaIsAppendable())
                    if let speedSelection {
                        guard device.mediaIsBlank() else { throw LegacyPreflightFailure.unavailableCapability }
                        let supported = BurnSpeedOptions.values(fromStatus: device.status() as NSDictionary)
                        try preflight.validate()
                        return try speedSelection.requestedSpeed(supported: supported) ?? DRDeviceBurnSpeedMax
                    }
                    try preflight.validate()
                    return nil
                }.value
                guard self.taskID == observedTaskID, self.burn === burn, self.isBusy else { return }
                if let speed {
                    burn.setRequestedBurnSpeed(speed)
                    guard burn.requestedBurnSpeed() == speed else { throw BurnSpeedUnavailable() }
                }
                if let taskID {
                    diagnostics.record(taskID: taskID, event: .deviceStatusObserved,
                        evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(identityConfirmed: true,
                            registryMediaPresent: true)))
                }
                DMBeginBurnPanel(panel, burn, layout)
            } catch { self.failBeforePanel(error, observedTaskID: observedTaskID) }
        }
    }
    func beginErase(_ erase: DRErase, model: DiagnosticDriveModel, media: DiagnosticMediaType,
                    preflight: LegacyMediaPreflight,
                    requireRecovery: @escaping @MainActor (String) -> Void = { _ in }) {
        guard !isBusy, let lease = coordinator.begin() else { return }
        self.lease = lease; self.requireRecovery = requireRecovery
        taskID = diagnostics.startTask(kind: .erase, media: media, driveModel: model)
        guard let panel = DMCreateEraseProgressPanel(), Self.hasProgressIndicator(panel.contentView) else {
            recordStartupFailure(.panelCreationFailed)
            message = "无法加载系统擦除进度窗口，未开始擦除。"; return
        }
        guard observeBackend(erase, name: .DREraseStatusChanged) else { return }
        self.erase = erase
        legacyRequiresEject = false
        requestedSpeed = nil; automaticSpeed = nil
        guard observeDevice(erase.device()) else { return }
        begin(panel: panel, notification: .DREraseProgressPanelDidFinish, kind: .erase,
              model: model, media: media, fileCount: 0, totalBytes: 0)
        let observedTaskID = taskID
        Task { @MainActor in
            do {
                try await Task.detached {
                    try preflight.validate()
                    guard let device = erase.device(), device.isValid(), device.mediaIsPresent(), device.mediaIsErasable() else {
                        throw LegacyPreflightFailure.unavailableCapability
                    }
                    guard device.ioRegistryEntryPath() == preflight.drivePath else {
                        throw LegacyPreflightFailure.changedDrive
                    }
                    try preflight.validate()
                }.value
                guard self.taskID == observedTaskID, self.erase === erase, self.isBusy else { return }
                if let taskID {
                    diagnostics.record(taskID: taskID, event: .deviceStatusObserved,
                        evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(identityConfirmed: true,
                            registryMediaPresent: true)))
                }
                DMBeginErasePanel(panel, erase)
            } catch { self.failBeforePanel(error, observedTaskID: observedTaskID) }
        }
    }
    private func failBeforePanel(_ error: Error, observedTaskID: UUID?) {
        guard taskID == observedTaskID, isBusy else { return }
        if let taskID {
            let event: DiagnosticEventKind
            switch error {
            case LegacyPreflightFailure.changedMedium, LegacyPreflightFailure.changedDrive:
                event = .preflightIdentityRejected
            case LegacyPreflightFailure.unavailableCapability, is BurnSpeedUnavailable:
                event = .preflightCapabilityRejected
            default: event = .preflightUnavailable
            }
            diagnostics.record(taskID: taskID, event: event, error: error as NSError)
            diagnostics.finish(taskID: taskID, outcome: .failed)
        }
        message = error.localizedDescription
        progress = nil
        releaseObservers()
        finishLease()
    }
    private func begin(panel: NSPanel, notification: Notification.Name, kind: DiagnosticTaskKind,
                       model: DiagnosticDriveModel, media: DiagnosticMediaType, fileCount: Int, totalBytes: UInt64?) {
        self.panel = panel
        isBusy = true; progress = SystemTaskProgress(); message = "正在准备系统任务…"
        failureDescription = nil; actualSpeedKBps = nil
        if let taskID {
            diagnostics.record(taskID: taskID, event: .preparing,
                evidence: DiagnosticEvidence(requestedSpeedKBps: requestedSpeed, requestedSpeedAutomatic: automaticSpeed))
        }
        let observedTaskID = taskID
        panelObserver = NotificationCenter.default.addObserver(forName: notification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isBusy, self.taskID == observedTaskID else { return }
                self.progress?.panelDidFinish()
                if let taskID = self.taskID { diagnostics.record(taskID: taskID, event: .panelFinished) }
                self.finishIfReady()
            }
        }
    }
    private func observeBackend(_ object: Any, name: Notification.Name) -> Bool {
        guard let center = DRNotificationCenter.currentRunLoop() else {
            recordStartupFailure(.backendObservationUnavailable)
            message = "无法建立刻录状态通知，未开始操作。"; return false
        }
        self.center = center
        center.addObserver(self, selector: #selector(backendChanged(_:)), name: name.rawValue, object: object)
        return true
    }
    private func recordStartupFailure(_ event: DiagnosticEventKind) {
        guard let taskID else { return }
        diagnostics.record(taskID: taskID, event: event)
        diagnostics.finish(taskID: taskID, outcome: .failed)
        releaseObservers()
        finishLease()
    }
    private func observeDevice(_ device: DRDevice?) -> Bool {
        guard let device, let path = device.ioRegistryEntryPath() else {
            recordStartupFailure(.deviceUnavailable)
            message = "无法确认光驱身份，未开始操作。"; return false
        }
        var driveID: UInt64 = 0
        guard dm_registry_identity(path, &driveID) == 0 else {
            recordStartupFailure(.deviceUnavailable)
            message = "无法确认原光驱身份，未开始操作。"; return false
        }
        legacyDrivePath = path; legacyDriveID = driveID
        observedDevice = device
        for name in [Notification.Name.DRDeviceStatusChanged, .DRDeviceDisappeared, .DRDeviceAppeared] {
            center?.addObserver(self, selector: #selector(deviceChanged(_:)), name: name.rawValue, object: device)
        }
        return true
    }
    @objc private func deviceChanged(_ note: Notification) {
        guard isBusy, let device = note.object as? DRDevice, device === observedDevice, let taskID else { return }
        let info = note.userInfo ?? [:]
        let media = info[DRDeviceMediaStateKey] as? String
        let evidence = DiagnosticEvidence(device: DiagnosticDeviceEvidence(
            busy: (info[DRDeviceIsBusyKey] as? NSNumber)?.boolValue,
            trayOpen: (info[DRDeviceIsTrayOpenKey] as? NSNumber)?.boolValue,
            mediaAbsent: media.map { $0 == DRDeviceMediaStateNone }))
        let event: DiagnosticEventKind = note.name == .DRDeviceDisappeared ? .deviceUnavailable
            : note.name == .DRDeviceAppeared ? .deviceAvailable : .deviceStatusObserved
        diagnostics.record(taskID: taskID, event: event, evidence: evidence)
    }
    @objc private func backendChanged(_ note: Notification) {
        guard isBusy, let fields = note.userInfo else { return }
        let sameBurn = burn != nil && (note.object as? DRBurn) === burn
        let sameErase = erase != nil && (note.object as? DRErase) === erase
        guard sameBurn || sameErase else { return }
        let info = fields as NSDictionary
        let state = info[DRStatusStateKey] as? String ?? ""
        let fraction = (info[DRStatusPercentCompleteKey] as? NSNumber)?.doubleValue
        progress?.update(state: state, fraction: fraction)
        guard let progress else { return }
        let error = info[DRErrorStatusKey]
        let extended = info[DRStatusProgressInfoKey] as? NSDictionary
        let evidence = DiagnosticEvidence(backendState: .fromSystemState(state),
            requestedSpeedKBps: requestedSpeed, actualSpeedKBps: (extended?[DRStatusProgressCurrentKPS] as? NSNumber)?.doubleValue,
            requestedSpeedAutomatic: automaticSpeed)
        actualSpeedKBps = evidence.actualSpeedKBps
        if progress.stage == .failed {
            // Local UI may show the original error; diagnostic export accepts only numeric fields.
            let detail = (error as? NSDictionary)?[DRErrorStatusErrorStringKey] as? String
            failureDescription = detail ?? failureDescription ?? "系统未提供错误说明。"
        }
        let percent = progress.fraction.map { " · \(Int($0 * 100))%" } ?? ""
        message = progress.stage.title + percent
        if progress.terminal && !progress.panelFinished {
            message = progress.stage == .failed
                ? "系统任务失败：\(failureDescription ?? "未知错误")。等待系统窗口结束。"
                : "系统任务已结束，等待进度窗口结束；尚未确认实际推出和独立读回。"
        }
        if let taskID {
            diagnostics.record(taskID: taskID, event: Self.event(progress.stage),
                                               progress: progress.fraction, backendError: error, evidence: evidence)
        }
        finishIfReady()
    }
    private func finishIfReady() {
        guard let progress, progress.canRelease, !checkingLegacyCompletion else { return }
        checkingLegacyCompletion = true
        let failed = progress.stage == .failed
        let path = legacyDrivePath, driveID = legacyDriveID, id = taskID
        let requiresEject = legacyRequiresEject
        releaseObservers(unlock: false)
        if let id { diagnostics.record(taskID: id, event: .backendReleased) }
        message = failed ? "系统任务失败，正在保留设备恢复锁。"
            : requiresEject ? "系统窗口已结束，正在只读复核原光驱空闲、介质移除与开仓状态…"
            : "系统窗口已结束，正在只读复核原光驱稳定空闲状态…"
        if failed {
            finishLegacyRecovery("系统任务失败：\(failureDescription ?? "未知错误")。请检查光驱状态。", taskID: id)
            return
        }
        guard let path, let driveID else {
            finishLegacyRecovery("系统任务结束，但缺少原光驱身份；请先恢复设备。", taskID: id)
            return
        }
        Task { @MainActor in
            do {
                let observed = try await Task.detached {
                    try LegacyCompletionVerifier.verify(path: path, driveID: driveID, requiresEject: requiresEject)
                }.value
                if let id {
                    diagnostics.record(taskID: id, event: .registryObserved,
                        evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(busy: observed.busy,
                            trayOpen: observed.trayOpen, mediaAbsent: observed.mediaPresent.map { !$0 },
                            identityConfirmed: true, registryMediaPresent: observed.mediaPresent)))
                    diagnostics.finish(taskID: id, outcome: .completed)
                }
                message = requiresEject
                    ? "系统任务及持续空仓检查完成；请确认实际托盘状态。文件读回仍需重新装盘验证。"
                    : "系统任务结束，原光驱稳定空闲；盘片若仍在仓内，可按需推出或读回验证。"
                isBusy = false; finishLease()
            } catch {
                if let id { diagnostics.record(taskID: id, event: .recoveryRequired, error: error as NSError) }
                finishLegacyRecovery(error.localizedDescription, taskID: id)
            }
        }
    }
    private func finishLegacyRecovery(_ detail: String, taskID: UUID?) {
        message = detail
        if let taskID { diagnostics.finish(taskID: taskID, outcome: .needsRecovery) }
        requireRecovery?(detail)
        isBusy = false
        finishLease(needsRecovery: true)
    }
    private func finishLease(needsRecovery: Bool = false) {
        if let lease { coordinator.finish(lease, needsRecovery: needsRecovery) }
        lease = nil; requireRecovery = nil; legacyDrivePath = nil; legacyDriveID = nil
        checkingLegacyCompletion = false; legacyRequiresEject = false
    }
    private func releaseObservers(unlock: Bool = true) {
        if let burn { center?.removeObserver(self, name: Notification.Name.DRBurnStatusChanged.rawValue, object: burn) }
        if let erase { center?.removeObserver(self, name: Notification.Name.DREraseStatusChanged.rawValue, object: erase) }
        if let observedDevice {
            for name in [Notification.Name.DRDeviceStatusChanged, .DRDeviceDisappeared, .DRDeviceAppeared] {
                center?.removeObserver(self, name: name.rawValue, object: observedDevice)
            }
        }
        observedDevice = nil
        center = nil
        if let panelObserver { NotificationCenter.default.removeObserver(panelObserver) }
        panelObserver = nil
        burn = nil; erase = nil; panel = nil
        if unlock { isBusy = false }
    }
    private static func event(_ stage: SystemTaskProgress.Stage) -> DiagnosticEventKind {
        switch stage {
        case .preparing, .opening: return .preparing
        case .writing, .erasing: return .writing
        case .verifying: return .verifying
        case .closing, .finishing: return .finishing
        case .done: return .backendDone
        case .failed: return .backendFailed
        case .waiting: return .waiting
        }
    }
    private static func hasProgressIndicator(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view is NSProgressIndicator || view.subviews.contains { hasProgressIndicator($0) }
    }
}

struct SystemTaskProgressView: View {
    let progress: SystemTaskProgress
    let isBusy: Bool
    var actualSpeedKBps: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBusy, progress.stage == .writing {
                Text(actualSpeedKBps.map { String(format: "当前写入速率 %.1f MB/s", $0 / 1000) } ?? "当前写入速率：系统暂未报告")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isBusy && progress.terminal {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在确认设备结束状态与推出结果…")
                }
            } else if !progress.terminal {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction, total: 1)
                        .accessibilityLabel(progress.stage.title)
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(progress.stage.title)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if isBusy {
                    Text("已用时 " + OperationEstimate.duration(max(0, context.date.timeIntervalSince(progress.startedAt))) +
                         (progress.remaining(at: context.date).map { " · " + $0 } ?? " · 剩余时间等待系统进度"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if isBusy {
                Text("请保持光驱连接与供电。写入、校验和收尾期间不要强行退出。")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }
}
