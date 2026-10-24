import Foundation
import DiscRecording

enum BurnSource: Sendable {
    case stagedFiles(URL)
    case isoImage(URL, bytes: UInt64, sha256: String)
}

private struct BurnInput: Sendable {
    let snapshot: SessionSnapshot
    let proof: AppendProof
    let source: BurnSource
    let speed: BurnSpeedSelection
    let verifyAfterWrite: Bool
    let sourceValidation: PreparedIncrementalISO?
}
private enum BurnJob: Sendable {
    case append(BurnInput)
    case firstData(FirstDataBurnRequest)
    var speed: BurnSpeedSelection {
        switch self { case .append(let input): return input.speed; case .firstData(let input): return input.speed }
    }
}
private struct BurnDrive: Sendable {
    let path: String
    let registryID: UInt64
    let originalMediaID: UInt64
}

/// The system can report an empty/open tray while the physical tray stays
/// closed. This one-shot command only targets the original, currently empty
/// drive. openTray refuses a drive that contains media; never eject a new disc.
private enum DiscTrayOpenService {
    static func openEmptyTray(path: String, driveID: UInt64) throws {
        precondition(!Thread.isMainThread)
        func confirmEmpty() throws {
            var current: UInt64 = 0
            let identityStatus = dm_registry_identity(path, &current)
            if identityStatus == ENXIO {
                throw BurnDriveDisconnected(detail: "打开托盘前原光驱已断开；未确认实际弹出。重新连接后请只读核验。")
            }
            try checkSystem(identityStatus, "复核原光驱身份")
            guard current == driveID else { throw BurnRecoveryRequired(detail: "光驱身份已变化，未打开托盘。") }
            var present: Int32 = -1
            try checkSystem(dm_registry_has_media(path, &present), "复核托盘内介质")
            guard present == 0 else { throw BurnRecoveryRequired(detail: "光驱内已出现介质，未再次发出推出命令。") }
        }
        try confirmEmpty()
        guard let device = (DRDevice.devices() as? [DRDevice])?.first(where: { $0.ioRegistryEntryPath() == path }),
              device.isValid() else { throw BurnRecoveryRequired(detail: "原光驱不可用，未打开托盘。") }
        let status = device.status() as NSDictionary
        try confirmEmpty()
        guard (status[DRDeviceIsBusyKey] as? NSNumber)?.boolValue == false,
              status[DRDeviceMediaStateKey] as? String == DRDeviceMediaStateNone else {
            throw BurnRecoveryRequired(detail: "光驱状态非空闲无盘，未打开托盘。")
        }
        guard device.openTray() else { throw BurnRecoveryRequired(detail: "光驱拒绝打开托盘请求；请检查实际状态。") }
        try confirmEmpty()
    }
}

/// Owns all burn objects on one dedicated thread with a serviced run loop.
/// DRNotificationCenter is run-loop-local (DRNotificationCenter.h); never use
/// NotificationCenter.default or a detached Swift task without a run loop here.
/// No hardware command is dispatched by a notification or completion timer.
private final class DiscBurnWorker: NSObject {
    private let job: BurnJob
    private let events: AsyncStream<Event>.Continuation
    private var completion = BurnCompletion()
    private var device: DRDevice?
    private var burn: DRBurn?
    private var track: DRTrack?
    private var center: DRNotificationCenter?
    private var devicePath = ""
    private var deviceRegistryID: UInt64 = 0
    private var originalMediaID: UInt64 = 0
    private var started = false
    private var result: BurnCompletion.Outcome?
    private var lastBackend = ""
    private var lastDevice = ""
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var warned = false
    private var backendResourcesReleased = false
    private var lastRegistryMedia: String?
    private var queriedRestoredStatus = false

    enum Event {
        case progress(BurnProgress)
        case finished(BurnCompletion.Outcome, BurnDrive?)
    }

    init(job: BurnJob, events: AsyncStream<Event>.Continuation) {
        self.job = job; self.events = events
    }

    static func stream(_ job: BurnJob) -> AsyncStream<Event> {
        AsyncStream { continuation in
            // The thread retains this worker until the backend has really ended.
            // Abandoning a stream does not cancel writing or release its sources.
            let thread = Thread {
                let outcome = autoreleasepool {
                    DiscBurnWorker(job: job, events: continuation).run()
                }
                // Drain autoreleased DR objects before the UI releases its task.
                continuation.yield(outcome)
                continuation.finish()
            }
            thread.name = "DiscMate.Burn"
            thread.start()
        }
    }

    private func run() -> Event {
        defer {
            // Remove run-loop-local registrations before releasing their objects.
            if let center {
                center.removeObserver(self, name: NSNotification.Name.DRBurnStatusChanged.rawValue, object: burn)
                center.removeObserver(self, name: NSNotification.Name.DRDeviceStatusChanged.rawValue, object: device)
                center.removeObserver(self, name: NSNotification.Name.DRDeviceDisappeared.rawValue, object: nil)
                center.removeObserver(self, name: NSNotification.Name.DRDeviceAppeared.rawValue, object: nil)
            }
            track = nil; burn = nil; device = nil; center = nil
        }
        // Creation's autorelease pool must not retain a completed producer while
        // we're waiting for device release/ejection later.
        do { try autoreleasepool { try begin() } }
        catch {
            let appendRejection: (error: NSError, evidence: DiagnosticEvidence)?
            if case .append = job, !started { appendRejection = AppendDiagnostics.rejection(error) }
            else { appendRejection = nil }
            let diagnostic = DiagnosticErrorCode.extract(error: appendRejection?.error ?? (error as NSError), backendError: nil).first
            emit(.warning, state: appendRejection == nil ? "PreflightFailed" : "AppendPreflightFailed", detail: error.localizedDescription,
                 errorCode: diagnostic?.code, evidence: appendRejection?.evidence, errorSource: diagnostic?.source ?? .other)
            return .finished(.failed(error.localizedDescription, recoveryRequired: started), nil)
        }
        // Keep a run-loop source even when DiscRecording isn't delivering events.
        // This timer only evaluates cached notifications plus IORegistry identity.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.current.add(timer, forMode: .default)
        defer { timer.invalidate() }
        while result == nil {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1)) }
        }
        return .finished(result!, BurnDrive(path: devicePath, registryID: deviceRegistryID,
                                             originalMediaID: originalMediaID))
    }

    private func begin() throws {
        precondition(!Thread.isMainThread)
        if case .firstData(let request) = job {
            try beginFirstData(request); return
        }
        guard case .append(let prepared) = job else { preconditionFailure() }
        if case .isoImage(let url, let bytes, let sha256) = prepared.source {
            let image = try FileProof.capture(url)
            guard image.bytes == bytes, image.sha256 == sha256, bytes % 2048 == 0 else {
                throw DiscFailure("增量镜像在准备后发生变化，未开始刻录。")
            }
        }
        let reader = try DVDSessionReader(identity: prepared.snapshot.identity)
        let fresh: SessionSnapshot
        do {
            defer { reader.close() }
            fresh = try reader.scan()
        }
        guard fresh.latest == prepared.snapshot.latest, fresh.descriptorHash == prepared.snapshot.descriptorHash,
              fresh.treeEntries == prepared.snapshot.treeEntries,
              fresh.appendable, fresh.writable?.nextWritable == prepared.proof.expectedStart else {
            throw LegacyPreflightFailure.changedMedium
        }
        originalMediaID = fresh.identity.registryID
        guard let device = DRDevice(forBSDName: fresh.identity.bsd) else {
            throw DiscFailure("目标刻录设备已不可用。")
        }
        self.device = device
        guard let path = device.ioRegistryEntryPath(), !path.isEmpty else { throw DiscFailure("无法取得光驱注册表路径。") }
        devicePath = path
        try checkSystem(dm_registry_identity(devicePath, &deviceRegistryID), "记录刻录设备身份")
        let status = device.status() as NSDictionary
        let media = status[DRDeviceMediaInfoKey] as? NSDictionary
        guard media?[DRDeviceMediaBSDNameKey] as? String == fresh.identity.bsd,
              device.mediaIsPresent(), device.mediaIsAppendable(), !device.mediaIsBlank(),
              let burn = DRBurn(for: device) else {
            throw DiscFailure("目标光驱或盘片不符合追加测试条件。")
        }
        let track: DRTrack
        switch prepared.source {
        case .stagedFiles(let directory):
            guard let root = DRFolder.virtualFolder(withName: "ISO_TEST") else { throw DiscFailure("无法创建光盘目录。") }
            root.setExplicitFilesystemMask(UInt32(DRFilesystemInclusionMaskISO9660 | DRFilesystemInclusionMaskJoliet))
            for file in prepared.proof.files {
                guard let entry = DRFile(path: directory.appendingPathComponent(file.path).path) else { throw DiscFailure("无法创建刻录文件对象。") }
                root.addChild(entry)
            }
            guard let generated = DRTrack(forRootFolder: root) else { throw DiscFailure("无法创建 ISO 轨道。") }
            track = generated
        case .isoImage(let url, let bytes, _):
            track = try ISOTrackLayout.load(url, bytes: bytes)
            try IncrementalISO.validateCapacity(imageBytes: bytes,
                freeBlocks: fresh.writable?.freeBlocks ?? 0, start: prepared.proof.expectedStart)
        }
        self.burn = burn; self.track = track
        burn.setAppendable(true)
        burn.setVerifyDisc(prepared.verifyAfterWrite)
        let supportedSpeeds = BurnSpeedOptions.values(fromStatus: status)
        let requestedSpeed = try prepared.speed.requestedSpeed(supported: supportedSpeeds) ?? DRDeviceBurnSpeedMax
        burn.setRequestedBurnSpeed(requestedSpeed)
        guard burn.requestedBurnSpeed() == requestedSpeed else {
            throw DiscFailure("系统未接受所选刻录速率，未开始刻录。")
        }
        burn.setCompletionAction(DRBurnCompletionActionEject)
        guard burn.appendable(), burn.verifyDisc() == prepared.verifyAfterWrite,
              burn.completionAction() == DRBurnCompletionActionEject else {
            throw DiscFailure("系统未接受追加、校验或弹出设置。")
        }
        emit(.device, state: "PreflightValidated", detail: "追加刻录设置已复核。",
             evidence: DiagnosticEvidence(verifyAfterWriteAccepted: burn.verifyDisc()))
        try observeAndWrite(burn, device: device, track: track) {
            if let plan = prepared.sourceValidation {
                // Recheck original sources after image verification and device
                // setup, immediately before handing the immutable image to DR.
                try plan.validateSourcesUnchanged()
                emit(.device, state: "AppendSourcesRevalidated", detail: "写入前源文件和目录复核通过。",
                     evidence: AppendDiagnostics.summary(plan))
            }
            try fresh.identity.validate()
        }
    }

    private func beginFirstData(_ request: FirstDataBurnRequest) throws {
        try request.validateIdentity()
        guard let device = DRDevice(forBSDName: request.bsd), device.isValid(),
              device.ioRegistryEntryPath() == request.drivePath else { throw DiscFailure("目标刻录机不可用。") }
        self.device = device; devicePath = request.drivePath; deviceRegistryID = request.driveID
        originalMediaID = request.mediaID
        let status = device.status() as NSDictionary
        let media = status[DRDeviceMediaInfoKey] as? NSDictionary
        guard (status[DRDeviceIsBusyKey] as? NSNumber)?.boolValue == false,
              device.mediaIsPresent(), device.mediaIsBlank(), device.mediaType() == DRDeviceMediaTypeDVDPlusR,
              media?[DRDeviceMediaBSDNameKey] as? String == request.bsd,
              let burn = DRBurn(for: device) else { throw DiscFailure("首次数据刻录需要空闲光驱中的空白 DVD+R；未开始写入。") }
        let track = try request.makeTrack()
        // Both APIs use logical blocks (DRCoreTrack.h / DRDevice.h); the
        // filesystem producer includes directory overhead in its estimate.
        let estimatedBlocks = track.estimateLength()
        guard let free = media?[DRDeviceMediaBlocksFreeKey] as? NSNumber, free.int64Value > 0 else {
            throw DiscFailure("系统未提供有效可用容量，未开始写入。")
        }
        try FirstDataBurnRequest.validateCapacity(estimatedBlocks: estimatedBlocks, freeBlocks: free.uint64Value)
        self.burn = burn; self.track = track
        burn.setAppendable(request.appendable)
        burn.setVerifyDisc(request.verifyAfterWrite)
        let speed = try request.speed.requestedSpeed(supported: BurnSpeedOptions.values(fromStatus: status)) ?? DRDeviceBurnSpeedMax
        burn.setRequestedBurnSpeed(speed)
        burn.setCompletionAction(DRBurnCompletionActionEject)
        guard burn.appendable() == request.appendable, burn.verifyDisc() == request.verifyAfterWrite,
              burn.requestedBurnSpeed() == speed,
              burn.completionAction() == DRBurnCompletionActionEject else { throw DiscFailure("系统未接受刻录设置，未开始写入。") }
        emit(.device, state: "PreflightValidated", detail: "空白盘身份和刻录设置已复核。",
             evidence: DiagnosticEvidence(requestedSpeedKBps: Double(speed),
                 requestedSpeedAutomatic: request.speed == .automatic,
                 verifyAfterWriteAccepted: burn.verifyDisc()))
        try observeAndWrite(burn, device: device, track: track, validate: request.validateIdentity)
    }

    private func observeAndWrite(_ burn: DRBurn, device: DRDevice, track: DRTrack, validate: () throws -> Void) throws {
        guard let center = DRNotificationCenter.currentRunLoop() else { throw DiscFailure("无法建立刻录状态通知。") }
        self.center = center
        center.addObserver(self, selector: #selector(burnChanged(_:)), name: NSNotification.Name.DRBurnStatusChanged.rawValue, object: burn)
        center.addObserver(self, selector: #selector(deviceChanged(_:)), name: NSNotification.Name.DRDeviceStatusChanged.rawValue, object: device)
        center.addObserver(self, selector: #selector(deviceGone(_:)), name: NSNotification.Name.DRDeviceDisappeared.rawValue, object: nil)
        center.addObserver(self, selector: #selector(deviceAppeared(_:)), name: NSNotification.Name.DRDeviceAppeared.rawValue, object: nil)
        try validate()
        started = true
        emit(.backend, state: "Starting", detail: "后台线程开始刻录；通过系统通知接收进度。deviceRegistryID=\(deviceRegistryID)")
        burn.writeLayout(track)
    }

    @objc private func burnChanged(_ note: Notification) {
        guard started, let notified = note.object as? DRBurn, notified === burn,
              let info = note.userInfo, let state = info[DRStatusStateKey] as? String else { return }
        let fraction = (info[DRStatusPercentCompleteKey] as? NSNumber)?.doubleValue
        let error = info[DRErrorStatusKey].map { String(describing: $0) } ?? "系统未提供详细错误"
        emit(.backend, state: state, fraction: fraction,
             detail: state == DRStatusStateFailed ? error : "",
             errorCode: DiagnosticErrorCode.extract(error: nil, backendError: info[DRErrorStatusKey]).first?.code,
             evidence: DiagnosticEvidence(backendState: .fromSystemState(state), requestedSpeedKBps: Double(burn?.requestedBurnSpeed() ?? 0),
                actualSpeedKBps: ((info[DRStatusProgressInfoKey] as? NSDictionary)?[DRStatusProgressCurrentKPS] as? NSNumber)?.doubleValue,
                requestedSpeedAutomatic: job.speed == .automatic, sense: .extract(backendError: info[DRErrorStatusKey])))
        lastBackend = state; lastActivity = ProcessInfo.processInfo.systemUptime; warned = false
        if state == DRStatusStateDone || state == DRStatusStateFailed {
            let first = completion.terminal == nil
            completion.backendEnded(state == DRStatusStateDone ? .done : .failed(error), at: lastActivity)
            if first {
                emit(.finishing, state: state,
                     detail: "系统刻录任务结束，正在确认介质移除并完成托盘打开；请等任务解锁后再合仓，尚未读回。")
            }
        }
    }

    @objc private func deviceChanged(_ note: Notification) {
        guard started, let notified = note.object as? DRDevice, notified === device, let info = note.userInfo else { return }
        var current: UInt64 = 0
        guard dm_registry_identity(devicePath, &current) == 0, current == deviceRegistryID else {
            completion.observationUnavailable(); queriedRestoredStatus = false
            return
        }
        acceptDeviceStatus(info)
    }

    private func acceptDeviceStatus(_ info: [AnyHashable: Any]) {
        let media = info[DRDeviceMediaStateKey] as? String
        let busy = (info[DRDeviceIsBusyKey] as? NSNumber)?.boolValue
        let tray = (info[DRDeviceIsTrayOpenKey] as? NSNumber)?.boolValue
        completion.deviceChanged(.init(mediaAbsent: media == DRDeviceMediaStateNone, trayOpen: tray == true, idle: busy == false))
        let detail = "media=\(media ?? "unknown") busy=\(busy.map(String.init) ?? "unknown") trayOpen=\(tray.map(String.init) ?? "unknown")"
        if detail != lastDevice {
            emit(.device, state: "DeviceStatus", detail: detail,
                 evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(busy: busy, trayOpen: tray,
                    mediaAbsent: media.map { $0 == DRDeviceMediaStateNone }, identityConfirmed: true)))
            lastDevice = detail
        }
    }

    @objc private func deviceGone(_ note: Notification) {
        guard let notified = note.object as? DRDevice, notified === device else { return }
        completion.deviceDisconnected()
        queriedRestoredStatus = false
        emit(.warning, state: "DeviceUnavailable", detail: completion.terminal == .done
             ? "系统写入已完成，设备状态暂不可用；正在等待同一光驱重新确认，不会重复刻录。"
             : "收到设备不可用通知，继续等待后端结束；不会自动重试刻录。")
    }

    @objc private func deviceAppeared(_ note: Notification) {
        // Rebind only after the backend has ended and only to the SAME registry
        // entry. A USB reconnect/new drive must use explicit recovery instead.
        guard started, completion.canRefreshStatus(at: ProcessInfo.processInfo.systemUptime),
              let notified = note.object as? DRDevice,
              notified.ioRegistryEntryPath() == devicePath,
              notified !== device || completion.disconnected else { return }
        var current: UInt64 = 0
        guard dm_registry_identity(devicePath, &current) == 0, current == deviceRegistryID else {
            completion.observationUnavailable(); queriedRestoredStatus = false
            return
        }
        center?.removeObserver(self, name: NSNotification.Name.DRDeviceStatusChanged.rawValue, object: device)
        device = notified
        completion.observationUnavailable()
        queriedRestoredStatus = true
        center?.addObserver(self, selector: #selector(deviceChanged(_:)), name: NSNotification.Name.DRDeviceStatusChanged.rawValue, object: notified)
        // A single read-only status query on the owned worker, not the main UI.
        // If it blocks, task ownership remains held; no timeout cancels it.
        let status = notified.status() ?? [:]
        guard dm_registry_identity(devicePath, &current) == 0, current == deviceRegistryID else { return }
        acceptDeviceStatus(status)
        emit(.device, state: "SameDeviceReturned", detail: "原光驱身份重新确认；重新观察结束状态，不沿用此前的空仓计时。")
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if completion.terminal != nil {
            if !backendResourcesReleased {
                // Done/Failed ends the backend's production contract, not the
                // overall device job. Release our producer and burn references
                // outside their callback, while retaining the observation lease.
                center?.removeObserver(self, name: NSNotification.Name.DRBurnStatusChanged.rawValue, object: burn)
                track = nil; burn = nil
                backendResourcesReleased = true
                emit(.device, state: "BackendReleased", detail: "已释放本任务的刻录对象和轨道引用；继续等待设备结束确认。")
            }
            var current: UInt64 = 0
            let identityStatus = dm_registry_identity(devicePath, &current)
            var present: Int32 = -1
            let registryStatus = dm_registry_has_media(devicePath, &present)
            var after: UInt64 = 0
            let afterStatus = dm_registry_identity(devicePath, &after)
            let registered = identityStatus == 0 && afterStatus == 0 && current == deviceRegistryID && after == deviceRegistryID
            let registryText = "expectedDrive=\(deviceRegistryID) before=\(current)/\(identityStatus) after=\(after)/\(afterStatus) " + (registryStatus == 0 ? "present=\(present)" : "queryError=\(registryStatus)")
            if registryText != lastRegistryMedia {
                emit(.device, state: "RegistryMedia", detail: "结束后注册表介质 \(registryText)",
                    errorCode: registryStatus == 0 ? nil : Int64(registryStatus),
                    evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(identityConfirmed: registered,
                        registryMediaPresent: registryStatus == 0 ? present != 0 : nil)))
                lastRegistryMedia = registryText
            }
            if !registered && !completion.disconnected {
                emit(.warning, state: "DeviceIdentityPending", detail: "系统刻录任务已结束，暂时无法核对原光驱身份；继续等待状态恢复，尚不能确认推出。")
            }
            if !registered { queriedRestoredStatus = false }
            if registered, completion.disconnected, completion.canRefreshStatus(at: now),
               !queriedRestoredStatus, let device, device.isValid() {
                // One query when the original registry entry returns. This also
                // handles a transient registry failure with no new DR event.
                queriedRestoredStatus = true
                let status = device.status() ?? [:]
                var confirmed: UInt64 = 0
                if dm_registry_identity(devicePath, &confirmed) == 0, confirmed == deviceRegistryID {
                    acceptDeviceStatus(status)
                    emit(.device, state: "SameDeviceStatusRefreshed", detail: "原光驱身份恢复，已重新读取一次结束状态；重新累计稳定观察。")
                }
                // Never combine the fresh status with registry media observed
                // before that query, nor count a blocked query as settling time.
                return
            }
            result = completion.outcome(at: now, driveStillRegistered: registered,
                                        registryMediaAbsent: registryStatus == 0 ? present == 0 : nil,
                                        driveDefinitelyAbsent: identityStatus == ENXIO && afterStatus == ENXIO)
        } else if !warned && now - lastActivity >= 120 {
            warned = true
            emit(.warning, state: lastBackend, detail: "已等待系统状态更新 120 秒；任务仍受控，不代表底层命令已停止。")
        }
    }

    private func emit(_ kind: BurnProgress.Kind, state: String, fraction: Double? = nil, detail: String, errorCode: Int64? = nil, evidence: DiagnosticEvidence? = nil, errorSource: DiagnosticErrorCode.Source = .discRecording) {
        events.yield(.progress(BurnProgress(kind: kind, state: state, fraction: fraction, detail: detail, errorCode: errorCode, evidence: evidence, errorSource: errorSource)))
    }
}

extension TestAppendService {
    @MainActor
    static func burn(_ prepared: PreparedTestAppend, progress: (BurnProgress) -> Void) async throws {
        try await DiscBurnService.burn(snapshot: prepared.snapshot, proof: prepared.proof,
            source: .stagedFiles(prepared.directory.appendingPathComponent("files")), progress: progress)
    }
}

enum DiscBurnService {
    @MainActor
    static func burn(snapshot: SessionSnapshot, proof: AppendProof, source: BurnSource,
                     speed: BurnSpeedSelection = .automatic, verifyAfterWrite: Bool = false,
                     sourceValidation: PreparedIncrementalISO? = nil,
                     progress: (BurnProgress) -> Void) async throws {
        try await consume(DiscBurnWorker.stream(.append(BurnInput(snapshot: snapshot, proof: proof, source: source,
            speed: speed, verifyAfterWrite: verifyAfterWrite, sourceValidation: sourceValidation))), progress: progress)
    }

    @MainActor
    static func burnFirstData(_ request: FirstDataBurnRequest, progress: (BurnProgress) -> Void) async throws {
        try await consume(DiscBurnWorker.stream(.firstData(request)), progress: progress)
    }

    @MainActor
    private static func consume(_ stream: AsyncStream<DiscBurnWorker.Event>, progress: (BurnProgress) -> Void) async throws {
        for await event in stream {
            switch event {
            case .progress(let update): progress(update)
            case .finished(.emptyDriveObserved, let drive):
                // Empty IOMedia and DiscRecording's tray flag have falsely
                // reported an open tray on this drive. Request one actual tray
                // open after the burn objects are gone, then report the result.
                guard let drive else { throw BurnRecoveryRequired(detail: "缺少原光驱身份，未请求打开托盘。") }
                progress(BurnProgress(kind: .finishing, state: "TrayOpenRequested", fraction: nil,
                    detail: "介质移除已确认；正在向原光驱请求打开托盘，尚未确认实际弹出。"))
                do {
                    try await Task.detached {
                        try DiscTrayOpenService.openEmptyTray(path: drive.path, driveID: drive.registryID)
                    }.value
                } catch let error as BurnDriveDisconnected {
                    throw error
                } catch {
                    let code = DiagnosticErrorCode.extract(error: error as NSError, backendError: nil).first
                    progress(BurnProgress(kind: .warning, state: "TrayOpenFailed", fraction: nil,
                        detail: error.localizedDescription, errorCode: code?.code, errorSource: code?.source ?? .other))
                    throw BurnRecoveryRequired(detail: "系统刻录已结束，但托盘打开请求失败：\(error.localizedDescription) 请检查实际光盘状态，勿重复刻录。")
                }
                progress(BurnProgress(kind: .finishing, state: "TrayOpenAccepted", fraction: nil,
                    detail: "原光驱已接受一次打开托盘请求；请确认光盘实际弹出。"))
                return
            case .finished(.mediaReturned, _):
                progress(BurnProgress(kind: .finishing, state: "MediaReturned", fraction: nil,
                    detail: "收尾期间介质重新出现；已停止后备推出，未确认当前盘片身份。请只读重新识别。"))
                return
            case .finished(.driveDisconnected, _):
                progress(BurnProgress(kind: .warning, state: "DriveDisconnected", fraction: nil,
                    detail: "刻录后端已结束，原光驱已断开；未确认弹出或读回。重新连接后请刷新设备并只读核验。"))
                throw BurnDriveDisconnected(detail: "光驱已断开，本次写入结果尚未读回确认。重新连接后请刷新设备并只读核验。")
            case .finished(.normalEjectRequired, let drive):
                // The worker's autorelease pool and registrations are gone. The
                // enclosing SessionModel still owns the one device task. Resolve
                // CURRENT media under the same drive; never reuse pre-burn BSD.
                do {
                    guard let drive else { throw DiscFailure("缺少刻录设备身份，未执行额外推出。") }
                    var bsd = [CChar](repeating: 0, count: 64); var media = DMMedia()
                    try checkSystem(dm_registry_media(drive.path, drive.registryID, &bsd, bsd.count, &media), "结束后重新识别介质")
                    guard media.registryID == drive.originalMediaID else {
                        progress(BurnProgress(kind: .finishing, state: "MediaReturned", fraction: nil,
                            detail: "收尾时盘片身份已变化；已停止后备推出。请只读重新识别。"))
                        return
                    }
                    let identity = MediaIdentity(bsd: String(cString: bsd), registryID: media.registryID, bytes: media.bytes)
                    progress(BurnProgress(kind: .finishing, state: "SystemEject", fraction: nil,
                        detail: "后端已释放，系统仍识别到介质（\(identity.bsd)，\(identity.registryID)）；开始一次正常卸载和推出。"))
                    let service = try DiscEjectService()
                    try await service.eject(identity, drivePath: drive.path, expectedDriveID: drive.registryID) { detail in
                        progress(BurnProgress(kind: .finishing, state: "SystemEject", fraction: nil, detail: detail))
                    }
                    progress(BurnProgress(kind: .finishing, state: "EjectConfirmed", fraction: nil, detail: "普通推出及持续介质移除检查通过；请确认实际托盘。"))
                    return
                } catch let error as BurnDriveDisconnected {
                    throw error
                } catch {
                    let code = DiagnosticErrorCode.extract(error: error as NSError, backendError: nil).first
                    progress(BurnProgress(kind: .warning, state: "EjectFailed", fraction: nil, detail: error.localizedDescription, errorCode: code?.code, errorSource: code?.source ?? .other))
                    throw BurnRecoveryRequired(detail: "写入已结束，但正常推出未完成：\(error.localizedDescription) 未自动重试。")
                }
            case .finished(.failed(let detail, let recoveryRequired), _):
                if recoveryRequired { throw BurnRecoveryRequired(detail: detail) }
                throw DiscFailure(detail)
            }
        }
        throw BurnRecoveryRequired(detail: "未收到设备结束确认；已停止新增设备操作。")
    }
}
