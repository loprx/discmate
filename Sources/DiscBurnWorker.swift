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
}
private struct BurnDrive: Sendable {
    let path: String
    let registryID: UInt64
}

/// Owns all burn objects on one dedicated thread with a serviced run loop.
/// DRNotificationCenter is run-loop-local (DRNotificationCenter.h); never use
/// NotificationCenter.default or a detached Swift task without a run loop here.
/// No hardware command is dispatched by a notification or completion timer.
private final class DiscBurnWorker: NSObject {
    private let prepared: BurnInput
    private let events: AsyncStream<Event>.Continuation
    private var completion = BurnCompletion()
    private var device: DRDevice?
    private var burn: DRBurn?
    private var track: DRTrack?
    private var center: DRNotificationCenter?
    private var devicePath = ""
    private var deviceRegistryID: UInt64 = 0
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

    init(prepared: BurnInput, events: AsyncStream<Event>.Continuation) {
        self.prepared = prepared; self.events = events
    }

    static func stream(_ prepared: BurnInput) -> AsyncStream<Event> {
        AsyncStream { continuation in
            // The thread retains this worker until the backend has really ended.
            // Abandoning a stream does not cancel writing or release its sources.
            let thread = Thread {
                let outcome = autoreleasepool {
                    DiscBurnWorker(prepared: prepared, events: continuation).run()
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
        return .finished(result!, BurnDrive(path: devicePath, registryID: deviceRegistryID))
    }

    private func begin() throws {
        precondition(!Thread.isMainThread)
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
              fresh.rootEntries == prepared.snapshot.rootEntries,
              fresh.appendable, fresh.writable?.nextWritable == prepared.proof.expectedStart else {
            throw DiscFailure("准备后盘片状态变化，未开始刻录。")
        }
        guard let device = DRDevice(forBSDName: fresh.identity.bsd) else {
            throw DiscFailure("目标刻录设备已不可用。")
        }
        self.device = device
        guard let path = device.ioRegistryEntryPath(), !path.isEmpty else { throw DiscFailure("无法取得光驱注册表路径。") }
        devicePath = path
        try checkSystem(dm_registry_identity(devicePath, &deviceRegistryID), "记录刻录设备身份")
        let media = (device.status() as NSDictionary)[DRDeviceMediaInfoKey] as? NSDictionary
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
            guard bytes / 2048 <= UInt64(fresh.writable?.freeBlocks ?? 0) else { throw DiscFailure("镜像超出当前剩余空间。") }
        }
        self.burn = burn; self.track = track
        burn.setAppendable(true)
        burn.setVerifyDisc(true)
        burn.setRequestedBurnSpeed(DRDeviceBurnSpeedDVD1x * 4)
        burn.setCompletionAction(DRBurnCompletionActionEject)
        guard burn.appendable(), burn.verifyDisc(), burn.completionAction() == DRBurnCompletionActionEject else {
            throw DiscFailure("系统未接受追加、校验或弹出设置。")
        }
        guard let center = DRNotificationCenter.currentRunLoop() else { throw DiscFailure("无法建立刻录状态通知。") }
        self.center = center
        center.addObserver(self, selector: #selector(burnChanged(_:)), name: NSNotification.Name.DRBurnStatusChanged.rawValue, object: burn)
        center.addObserver(self, selector: #selector(deviceChanged(_:)), name: NSNotification.Name.DRDeviceStatusChanged.rawValue, object: device)
        center.addObserver(self, selector: #selector(deviceGone(_:)), name: NSNotification.Name.DRDeviceDisappeared.rawValue, object: nil)
        center.addObserver(self, selector: #selector(deviceAppeared(_:)), name: NSNotification.Name.DRDeviceAppeared.rawValue, object: nil)
        try fresh.identity.validate()
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
             detail: state == DRStatusStateFailed ? error : "")
        lastBackend = state; lastActivity = ProcessInfo.processInfo.systemUptime; warned = false
        if state == DRStatusStateDone || state == DRStatusStateFailed {
            let first = completion.terminal == nil
            completion.backendEnded(state == DRStatusStateDone ? .done : .failed(error), at: lastActivity)
            if first {
                emit(.finishing, state: state,
                     detail: "系统刻录任务结束，正在交叉核对介质状态并完成正常推出；尚未完成读回验证。")
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
        if detail != lastDevice { emit(.device, state: "DeviceStatus", detail: detail); lastDevice = detail }
    }

    @objc private func deviceGone(_ note: Notification) {
        guard let notified = note.object as? DRDevice, notified === device else { return }
        completion.deviceDisconnected()
        queriedRestoredStatus = false
        emit(.warning, state: "DeviceUnavailable", detail: completion.terminal == .done
             ? "系统写入及校验已完成，设备状态暂不可用；正在等待同一光驱重新确认，不会重复刻录。"
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
                emit(.device, state: "RegistryMedia", detail: "结束后注册表介质 \(registryText)")
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
                                        registryMediaAbsent: registryStatus == 0 ? present == 0 : nil)
        } else if !warned && now - lastActivity >= 120 {
            warned = true
            emit(.warning, state: lastBackend, detail: "已等待系统状态更新 120 秒；任务仍受控，不代表底层命令已停止。")
        }
    }

    private func emit(_ kind: BurnProgress.Kind, state: String, fraction: Double? = nil, detail: String) {
        events.yield(.progress(BurnProgress(kind: kind, state: state, fraction: fraction, detail: detail)))
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
                     progress: (BurnProgress) -> Void) async throws {
        for await event in DiscBurnWorker.stream(BurnInput(snapshot: snapshot, proof: proof, source: source)) {
            switch event {
            case .progress(let update): progress(update)
            case .finished(.ejected, _): return
            case .finished(.normalEjectRequired, let drive):
                // The worker's autorelease pool and registrations are gone. The
                // enclosing SessionModel still owns the one device task. Resolve
                // CURRENT media under the same drive; never reuse pre-burn BSD.
                do {
                    guard let drive else { throw DiscFailure("缺少刻录设备身份，未执行额外推出。") }
                    var bsd = [CChar](repeating: 0, count: 64); var media = DMMedia()
                    try checkSystem(dm_registry_media(drive.path, drive.registryID, &bsd, bsd.count, &media), "结束后重新识别介质")
                    let identity = MediaIdentity(bsd: String(cString: bsd), registryID: media.registryID, bytes: media.bytes)
                    progress(BurnProgress(kind: .finishing, state: "SystemEject", fraction: nil,
                        detail: "后端已释放，系统仍识别到介质（\(identity.bsd)，\(identity.registryID)）；开始一次正常卸载和推出。"))
                    let service = try DiscEjectService()
                    try await service.eject(identity, drivePath: drive.path, expectedDriveID: drive.registryID) { detail in
                        progress(BurnProgress(kind: .finishing, state: "SystemEject", fraction: nil, detail: detail))
                    }
                    return
                } catch {
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
