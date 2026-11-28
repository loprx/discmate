import AppKit
import Foundation

@MainActor
final class SessionModel: ObservableObject {
    static let shared = SessionModel()
    enum Phase: String { case idle, inspecting, preparing, prepared, burning, finishing, recoveryRequired, awaitingReload, authorizing, unmounting, mounting, verifying, ready, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = "添加要刻录的文件或文件夹，然后点击“查看刻录摘要”。只检查旧目录，不完整读取旧文件。"
    @Published private(set) var appendPreparationFailure: String?
    @Published private(set) var unsupportedFilesystem: DiagnosticFilesystem?
    @Published private var deviceCache = SessionDeviceCache()
    private(set) var snapshot: SessionSnapshot? {
        get { deviceCache.snapshot }
        set { deviceCache.snapshot = newValue }
    }
    private(set) var mountedURL: URL? {
        get { deviceCache.mountedURL }
        set { deviceCache.mountedURL = newValue }
    }
    private(set) var verified: [VerifiedFile] {
        get { deviceCache.verified }
        set { deviceCache.verified = newValue }
    }
    @Published private var deviceGate = DeviceOperationGate()
    var isBusy: Bool { deviceGate.isBusy }
    var needsDeviceRecovery: Bool { deviceGate.needsRecovery }
    var blocksDeviceOperations: Bool { deviceGate.blocksOperations }
    // Fourth-session readback and the standalone normal eject passed. This
    // remains experimental: native completion passed once; the post-burn DA
    // handoff has not yet been exercised on hardware.
    let incrementalWriteEnabled = true
    @Published private(set) var logURL: URL?
    @Published private(set) var logError: String?
    private let taskFiles = TaskFileStore()
    @Published private(set) var taskStartedAt: Date?
    @Published private(set) var progressFraction: Double?
    @Published private(set) var remainingEstimate: String?
    @Published private(set) var actualBurnSpeedKBps: Double?
    // A proof survives eject/reload for readback, but belongs to one recorded
    // session. Never offer an old disc's proof for a newly inserted disc.
    var canVerifyAdded: Bool {
        guard let proof = pendingProof, proof.preserved != nil, let snapshot else { return false }
        return proof.targets(snapshot)
    }
    var verificationBytes: UInt64 { snapshot?.fileEntries.reduce(0) { $0 + UInt64($1.bytes) } ?? 0 }
    var addedVerificationBytes: UInt64 {
        guard canVerifyAdded else { return 0 }
        return pendingProof?.files.reduce(0) { $0 + $1.bytes } ?? 0
    }
    private var task: Task<Void, Never>?
    private(set) var diagnosticTaskID: UUID?
    private let coordinator: DeviceTaskCoordinator
    private let selectWriter: (SessionSnapshot) -> any AppendWriter
    init(coordinator: DeviceTaskCoordinator? = nil,
         selectWriter: @escaping (SessionSnapshot) -> any AppendWriter = AppendWriters.select) {
        self.coordinator = coordinator ?? .shared
        self.selectWriter = selectWriter
    }
    var diagnosticDriveModel: DiagnosticDriveModel = .unknown
    var diagnosticMediaType: DiagnosticMediaType = .unknown
    @Published var selectedBurnSpeed: BurnSpeedSelection = .reduced
    @Published var verifyAfterWrite = false
    @Published private(set) var supportedBurnSpeeds: [Double] = []
    @Published private(set) var burnSpeedNotice: String?

    /// Values come from the existing serialized device refresh, never a Picker
    /// triggered hardware query. The worker rechecks them before writeLayout.
    func updateBurnSpeeds(_ values: [Double]) {
        guard !isBusy else { return }
        supportedBurnSpeeds = BurnSpeedOptions.normalized(values)
        if case .kilobytesPerSecond = selectedBurnSpeed,
           (try? selectedBurnSpeed.requestedSpeed(supported: supportedBurnSpeeds)) == nil {
            selectedBurnSpeed = .reduced
            burnSpeedNotice = "原选速率已不可用，已恢复默认降速。"
        }
    }
    private var warning: Task<Void, Never>?
    private var monitor: Timer?
    private var pendingProof: AppendProof? {
        get { deviceCache.pendingProof }
        set { deviceCache.pendingProof = newValue }
    }
    private(set) var proofURL: URL? {
        get { deviceCache.proofURL }
        set { deviceCache.proofURL = newValue }
    }
    private(set) var incrementalPlan: PreparedIncrementalISO? {
        get { deviceCache.incrementalPlan }
        set { deviceCache.incrementalPlan = newValue }
    }
    private var incrementalSnapshot: SessionSnapshot? {
        get { deviceCache.incrementalSnapshot }
        set { deviceCache.incrementalSnapshot = newValue }
    }
    @Published private(set) var recoveryTargets: [DeviceRecoveryService.Target] = []
    @Published var recoveryTargetPath: String?
    @Published private(set) var recoveryNotice: String?

    /// Unlike a normal task, recovery may enter from a faulted gate, but never
    /// while a previous operation is still awaited. The source proof survives.
    /// Accept an unresolved first-burn handoff only after its backend returned.
    /// Reuse the same recovery UI/gate; refresh/reset cannot discard this lock.
    func requireRecovery(_ detail: String) {
        guard deviceGate.beginOperation() else { return }
        invalidateDeviceCache()
        transition(.recoveryRequired, detail)
        deviceGate.operationEnded(needsRecovery: true)
    }

    func recoverDevice(path: String?, afterRecovery: @escaping @MainActor (String) -> Void) {
        guard task == nil, !isBusy, needsDeviceRecovery, let lease = coordinator.beginRecovery() else { return }
        guard deviceGate.beginRecovery() else { coordinator.finishRecovery(lease, accepted: false); return }
        diagnosticTaskID = DiagnosticReportStore.shared.startTask(kind: .deviceRefresh, driveModel: diagnosticDriveModel)
        let targetPath = recoveryTargetPath ?? path
        invalidateDeviceCache()
        transition(.recoveryRequired, "正在只读复核光驱状态；不读文件、不写盘、不弹出，通常数秒。请保持盘片和连接稳定。")
        taskStartedAt = Date()
        warning = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.isBusy else { return }
            self.message = "系统状态查询尚未返回；仍保留当前任务，请等待。不会启动第二次检查或刻录。"
            self.log("Recovery waiting for outstanding status query; device remains reserved")
        }
        task = Task {
            var accepted = false
            var recoveredPath: String?
            do {
                let result = try await Task.detached { try DeviceRecoveryService.check(preferredPath: targetPath) }.value
                switch result {
                case .stable(let path, let detail):
                    self.log("RECOVERY_IDLE_STABLE \(detail); no payload verified; prior source proof retained")
                    let notice = "光驱已空闲，设备与介质身份复核通过。旧会话和准备镜像已清除，源清单仍保留；尚未读回验证本轮刻录。"
                    self.recoveryNotice = notice
                    self.recoveryTargets = []; self.recoveryTargetPath = nil
                    self.transition(.ready, notice)
                    accepted = true; recoveredPath = path
                case .selectionRequired(let targets):
                    self.recoveryTargets = targets; self.recoveryTargetPath = nil
                    self.transition(.recoveryRequired, "检测到多个光驱；请在恢复目标中选择要检查的光驱，再点击“重新检查设备”。")
                }
            } catch {
                self.diagnostic(.recoveryRequired, error: error as NSError)
                self.transition(.recoveryRequired, error.localizedDescription)
            }
            self.warning?.cancel(); self.warning = nil
            if let id = self.diagnosticTaskID {
                DiagnosticReportStore.shared.finish(taskID: id, outcome: accepted ? .completed : .needsRecovery)
            }
            self.diagnosticTaskID = nil
            self.deviceGate.recoveryEnded(accepted: accepted)
            self.coordinator.finishRecovery(lease, accepted: accepted)
            self.task = nil
            if let recoveredPath { afterRecovery(recoveredPath) }
        }
    }

    private func invalidateDeviceCache() {
        monitor?.invalidate(); monitor = nil
        discardPreparedPlan()
        deviceCache.invalidateDevice()
        unsupportedFilesystem = nil
        supportedBurnSpeeds = []; selectedBurnSpeed = .reduced; burnSpeedNotice = nil
    }

    func invalidatePreparedPlan() {
        guard !isBusy else { return }
        discardPreparedPlan()
        appendPreparationFailure = nil
        if phase == .prepared { transition(.ready, "文件选择已变化，请重新准备增量镜像。") }
    }
    private func discardPreparedPlan(preserving image: URL? = nil) {
        if let plan = incrementalPlan, plan.image != image { discardImageDirectory(plan.image) }
        incrementalPlan = nil; incrementalSnapshot = nil
    }
    private func discardImageDirectory(_ image: URL) {
        taskFiles.discardImageDirectory(containing: image) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.logError = "暂存镜像清理失败：\(error.localizedDescription)。请检查可用磁盘空间。"
            }
        }
    }

    func checkDeviceNotifications(path: String?) {
        guard let path else { message = "请先刷新并选择光驱。"; return }
        start {
            self.transition(.inspecting, "正在只读观察光驱通知（45 秒）；不读扇区、不刻录、不弹出。")
            self.warning?.cancel(); self.warning = nil
            self.warning = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self, self.isBusy else { return }
                self.message = "系统状态查询尚未返回；继续保留任务，未启动第二次查询。"
                self.log("device-probe waiting for outstanding status query")
            }
            for await event in DeviceNotificationProbe.events(path: path) {
                self.log("device-probe \(event)"); self.message = event
            }
            self.transition(.ready, self.message)
        }
    }

    func loadExpectedProof() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "选择刻录前保存的 expected.json 或源文件哈希清单，仅用于只读核验，不会写盘。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        invalidatePreparedPlan()
        do {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size <= 1024 * 1024 else {
                throw DiscFailure("校验清单必须为不超过 1 MiB 的普通 JSON 文件。")
            }
            let proof = try JSONDecoder().decode(AppendProof.self, from: Data(contentsOf: url))
            try proof.validateStructure()
            let preserved = proof.preserved ?? []
            pendingProof = proof; proofURL = url; verified = []
            message = "已载入第 \(proof.previousSession + 1) 会话的 \(proof.files.count) 个文件哈希；另保留 \(preserved.count) 个旧文件区段记录。请按需选择校验范围。"
        } catch { message = error.localizedDescription }
    }

    func reset() {
        guard !blocksDeviceOperations else { return }
        invalidateDeviceCache(); phase = .idle
        message = "添加要刻录的文件或文件夹，然后点击“查看刻录摘要”。只检查旧目录，不完整读取旧文件。"
    }
    func inspect(bsd: String?) {
        guard let bsd else { message = "请先选择已放入光盘的刻录机。"; return }
        start {
            self.snapshot = nil; self.mountedURL = nil; self.verified = []
            self.unsupportedFilesystem = nil
            self.transition(.inspecting, "正在识别会话和文件系统目录…")
            let snapshot = try await Task.detached { () throws -> SessionSnapshot in
                let identity = try MediaIdentity.current(bsd)
                return try DVDSessionReader(identity: identity).scan()
            }.value
            self.snapshot = snapshot
            self.recordDisc(snapshot)
            let status = snapshot.reservedTrack.map { "第 \($0.session) 会话有空白预留轨道，可续写。当前目录来自第 \(snapshot.latest.session) 会话。" } ?? (snapshot.incompleteSession
                ? "第 \(snapshot.latest.session) 会话未封闭；已只读识别 \(snapshot.rootEntries.count) 个根目录项目。为避免继续写入，已暂停追加；这不代表盘片报废。"
                : "已识别第 \(snapshot.latest.session) 会话，共 \(snapshot.rootEntries.count) 个根目录项目。")
            self.transition(.ready, status)
            self.log("media=\(snapshot.identity.registryID) bsd=\(bsd) session=\(snapshot.latest.session) start=\(snapshot.latest.start) incomplete=\(snapshot.incompleteSession) descriptor=\(snapshot.descriptorHash)")
            for entry in snapshot.rootEntries { self.log("extent name=\(entry.name) lba=\(entry.lba) bytes=\(entry.bytes)") }
            self.watchIdentity()
        }
    }
    private func snapshotForReading(bsd: String?) async throws -> SessionSnapshot {
        if let snapshot { return snapshot }
        guard let bsd else { throw DiscFailure("请放入光盘并刷新设备。") }
        transition(.inspecting, "正在识别最新目录；不读取文件正文…")
        let fresh = try await Task.detached {
            let reader = try DVDSessionReader(identity: MediaIdentity.current(bsd))
            defer { reader.close() }
            return try reader.scan()
        }.value
        snapshot = fresh; watchIdentity()
        recordDisc(fresh)
        return fresh
    }
    func openLatest(bsd: String? = nil) {
        start(kind: .openLatest) {
            let expected: SessionSnapshot
            do { expected = try await self.snapshotForReading(bsd: bsd) }
            catch let unsupported as UDFAppendUnsupported {
                guard let bsd else { throw DiscFailure("请重新选择光驱后打开 UDF 光盘。") }
                self.diagnostic(.filesystemUnsupported, error: unsupported as NSError,
                    evidence: DiagnosticEvidence(disc: DiagnosticDiscEvidence(
                        filesystem: unsupported.revision == 0x0102 ? .udf102 : .udfOther)))
                let identity = try await Task.detached { try MediaIdentity.current(bsd) }.value
                let service = try SessionMountService()
                guard let path = try service.currentUDFMount(identity) else {
                    throw DiscFailure("系统尚未挂载这张 UDF 光盘；请先在访达确认光盘可见，再重新检查设备。没有执行强制挂载。")
                }
                try identity.validate()
                guard NSWorkspace.shared.open(path) else { throw DiscFailure("访达未能打开已核对来源的 UDF 目录。") }
                self.unsupportedFilesystem = unsupported.revision == 0x0102 ? .udf102 : .udfOther
                self.diagnostic(.mountCompleted, evidence: DiagnosticEvidence(disc:
                    DiagnosticDiscEvidence(filesystem: self.unsupportedFilesystem)))
                self.transition(.ready, "已在访达打开系统当前挂载的 UDF 光盘；只读访问，未选择或验证其他会话，也未写盘。当前盘片布局暂不支持追加。")
                self.log("UDF_SYSTEM_MOUNT_OPENED; readOnly=true; sessionSelection=system; filesVerified=false")
                return
            }
            if expected.udf != nil {
                let service = try SessionMountService()
                guard let path = try service.currentUDFMount(expected.identity) else {
                    throw DiscFailure("系统尚未挂载这张 UDF 光盘。可使用直接读回校验。")
                }
                try expected.identity.validate()
                if expected.vat != nil {
                    try await Task.detached {
                        try MountedSessionDirectory.validate(root: path,
                            entries: Dictionary(uniqueKeysWithValues: expected.treeEntries.map { ($0.name, $0) }))
                        try expected.identity.validate()
                    }.value
                }
                guard NSWorkspace.shared.open(path) else { throw DiscFailure("访达未能打开当前 UDF 光盘。") }
                self.diagnostic(.mountCompleted, evidence: DiagnosticEvidence(disc: DiagnosticDiscEvidence(filesystem: expected.filesystem)))
                self.transition(.ready, expected.vat == nil ? "已打开系统当前挂载的 UDF 目录。可用直接读回校验检查最新会话。" : "已核对当前挂载目录与最新 VAT 会话的文件名和大小，并在访达打开。")
                return
            }
            guard !expected.incompleteSession else {
                throw DiscFailure("末次会话未封闭，无法作为正常光盘挂载；可使用“直接读回校验”检查已记录文件。")
            }
            self.verified = []; self.mountedURL = nil
            self.transition(.inspecting, "正在复核盘片身份和最新会话…")
            let fresh = try await Task.detached { try DVDSessionReader(identity: expected.identity).scan() }.value
            guard fresh.latest == expected.latest, fresh.descriptorHash == expected.descriptorHash, fresh.treeEntries == expected.treeEntries else {
                self.snapshot = nil
                throw DiscFailure("会话信息已变化，请重新识别后再打开。")
            }
            let mounting = try SessionMountService()
            let path: URL
            if let existing = try mounting.matchingMount(fresh) {
                self.diagnostic(.mountReused)
                path = existing
            } else {
                guard let helpers = Bundle.main.builtInPlugInsURL?.deletingLastPathComponent() else {
                    throw DiscFailure("无法定位应用内挂载助手。")
                }
                let helper = helpers.appendingPathComponent("Helpers/DiscMateMount").path
                guard FileManager.default.isExecutableFile(atPath: helper) else { throw DiscFailure("缺少应用内只读挂载助手，请重新构建。") }
                self.transition(.authorizing, "请在 macOS 授权窗口中允许本次只读挂载；应用不接收或保存密码。")
                let authorization = try await Task.detached { try MountAuthorization(helper: helper) }.value
                self.transition(.unmounting, "正在卸载旧目录；不会弹出光盘…")
                try await mounting.unmount(fresh) { self.diagnostic($0, error: $1) }
                self.transition(.mounting, "正在只读挂载最新会话…")
                path = try await Task.detached { try authorization.mount(fresh) }.value
            }
            // Opening a folder must not implicitly stream the entire disc.
            try await Task.detached {
                try MountedSessionDirectory.validateISO(root: path, snapshot: fresh)
                try fresh.identity.validate()
            }.value
            try checkSystem(dm_mount_matches(path.path, fresh.identity.bsd), "复核访达目录来源")
            guard NSWorkspace.shared.open(path) else { throw DiscFailure("访达未能打开已核对的光盘目录。") }
            self.mountedURL = path
            self.diagnostic(.mountCompleted)
            self.transition(.ready, "最新会话已只读打开；本次挂载仅核对目录，不重复校验文件正文。读完后如需取盘，请点击“正常推出”。")
        }
    }
    func verifyRecorded(addedOnly: Bool = false, bsd: String? = nil) {
        let proof = pendingProof
        if addedOnly && proof?.preserved == nil { return }
        let paths = addedOnly ? Set(proof!.files.map(\.path)) : nil
        start(kind: .readback) {
            self.diagnostic(addedOnly ? .readbackAddedStarted : .readbackFullStarted)
            let expected = try await self.snapshotForReading(bsd: bsd)
            let totalBytes = addedOnly ? self.addedVerificationBytes : self.verificationBytes
            self.verified = []
            let started = Date()
            self.transition(.verifying, addedOnly ? "正在只读校验本次新增文件；旧文件仅检查目录和区段，不读取正文。" : "正在完整读取光盘文件并计算 SHA-256；此操作不挂载或写盘。")
            let files = try await Task.detached {
                let reader = try DVDSessionReader(identity: expected.identity, timeBudget: 1800)
                defer { reader.close() }
                if let proof { try proof.validateDirectory(try reader.scan()) }
                return try reader.verifyRecorded(expected, paths: paths) { name, bytes in
                    Task { @MainActor in
                        guard self.phase == .verifying else { return }
                        self.progressFraction = totalBytes > 0 ? min(1, Double(bytes) / Double(totalBytes)) : nil
                        let elapsed = Date().timeIntervalSince(started)
                        if bytes > 0 && elapsed > 3 {
                            self.remainingEstimate = OperationEstimate.duration(Double(totalBytes > bytes ? totalBytes - bytes : 0) / (Double(bytes) / elapsed))
                        }
                        self.message = "正在直接读回：\(name) · 已校验 \(bytes / 1024 / 1024) MiB"
                    }
                }
            }.value
            for file in files { self.log("raw-verified name=\(file.path) bytes=\(file.bytes) sha256=\(file.sha256)") }
            if let proof {
                try proof.validate(files, session: expected.latest.session, start: expected.latest.start, addedOnly: addedOnly)
                if !proof.files.isEmpty {
                    self.diagnostic(addedOnly ? .readbackAddedSourcesMatched : .readbackAllReadableKnownSourcesMatched)
                } else {
                    self.diagnostic(addedOnly ? .readbackDirectoryMatched : .readbackAllReadable)
                }
                self.log(proof.files.isEmpty
                    ? "DIRECTORY_PROOF_MATCH; sourceHashesChecked=0; read=\(files.count); addedOnly=\(addedOnly)"
                    : "SOURCE_SHA256_MATCH \(proof.files.count) files; read=\(files.count); addedOnly=\(addedOnly)")
                let scope = addedOnly && proof.files.isEmpty
                    ? "本轮仅追加目录，目录结构与清单一致；旧文件区段保持，未读取文件正文，也未执行新增文件哈希校验。"
                    : (addedOnly ? "本次新增 \(files.count) 个文件 SHA-256 与源清单一致；旧文件仅核对目录及原区段，未重读正文。" : "全部 \(files.count) 个文件已读回，其中 \(proof.files.count) 个与源哈希一致；无源哈希的旧文件仅完成可读性检查。")
                self.transition(.ready, scope + "未验证 Finder 挂载。读回结束不会自动弹盘；如需取盘，请点击“正常推出”。")
            } else {
                self.diagnostic(.readbackAllReadable)
                self.transition(.ready, "第 \(expected.latest.session) 会话 \(files.count) 个文件已完整读回；本次未载入源清单，未验证 Finder 挂载。读回结束不会自动弹盘；如需取盘，请点击“正常推出”。") }
            self.verified = files
        }
    }

    func prepareIncremental(sources: [URL], bsd: String? = nil) {
        guard !sources.isEmpty else { message = "请先添加文件或文件夹。"; return }
        guard let target = snapshot?.identity.bsd ?? bsd else { message = "请先放入光盘并刷新设备。"; return }
        // Selected roots may be directories; the recursive counts are recorded
        // after preparation rather than pretending each selected URL is a file.
        start(kind: .appendPreparation) {
            self.transition(.inspecting, "正在检查光盘目录、原区段及可追加空间；不读取旧文件正文…")
            let snapshot = try await Task.detached {
                let reader = try DVDSessionReader(identity: MediaIdentity.current(target))
                defer { reader.close() }
                return try reader.scan()
            }.value
            self.snapshot = snapshot; self.verified = []
            self.recordDisc(snapshot)
            self.watchIdentity()
            try snapshot.appendState.require(.appendReady)
            self.warning?.cancel(); self.warning = nil
            self.transition(.preparing, "正在准备增量镜像：保留旧文件区段，暂存新增文件并校验；尚未写盘…")
            let prepared = try await Task.detached {
                try snapshot.identity.validate()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-incremental-\(UUID().uuidString)")
                let result = try AppendImagePreparation.build(snapshot: snapshot, verified: [], sources: sources, directory: directory)
                var accepted = false
                defer {
                    if !accepted {
                        Task { @MainActor in self.discardImageDirectory(result.image) }
                    }
                }
                let reader = try DVDSessionReader(identity: snapshot.identity); defer { reader.close() }
                let fresh = try reader.scan()
                try fresh.appendState.require(.appendReady)
                guard fresh.latest == snapshot.latest, fresh.descriptorHash == snapshot.descriptorHash,
                      fresh.treeEntries == snapshot.treeEntries,
                      fresh.reservedTrack == snapshot.reservedTrack, fresh.writable?.nextWritable == result.proof.expectedStart else {
                    throw LegacyPreflightFailure.changedMedium
                }
                try IncrementalISO.validateTarget(fresh, imageBytes: result.imageBytes)
                accepted = true
                return result
            }.value
            self.incrementalPlan = prepared; self.incrementalSnapshot = snapshot
            self.recordDisc(snapshot, imageBytes: prepared.imageBytes)
            self.diagnostic(.appendSourcesChecked, evidence: AppendDiagnostics.summary(prepared))
            self.log("oldPayloadReadBytes=0; old hashes not reused; INCREMENTAL_PREPARED imageBytes=\(prepared.imageBytes) referencedBytes=\(prepared.referencedBytes) start=\(prepared.proof.expectedStart) imageSHA256=\(prepared.imageSHA256)")
            for entry in snapshot.fileEntries { self.log("old_extent name=\(entry.name) lba=\(entry.lba) bytes=\(entry.bytes)") }
            self.transition(.prepared, "已准备新增 \(prepared.addedFileCount) 个文件、\(prepared.addedDirectoryCount) 个目录，保留 \(prepared.preservedFileCount) 个旧文件；镜像约 \(prepared.imageBytes / 1024) KiB。尚未写盘。确认摘要后点击“开始刻录”。")
        }
    }

    func burnIncremental(drivePath: String?) {
        guard incrementalWriteEnabled, !blocksDeviceOperations, let prepared = incrementalPlan, let snapshot = incrementalSnapshot else { return }
        let selectedSpeed = selectedBurnSpeed
        let selectedVerification = verifyAfterWrite
        let request = AppendWriteRequest(snapshot: snapshot, prepared: prepared, drivePath: drivePath,
                                         speed: selectedSpeed, verify: selectedVerification)
        let operation = AppendWriteOperation(request, select: selectWriter)
        let confirmation = operation.confirmation(rates: supportedBurnSpeeds)
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.detail
        alert.addButton(withTitle: "开始追加"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        start(kind: .append, fileCount: prepared.proof.files.count, totalBytes: prepared.proof.files.reduce(0) { $0 + $1.bytes }, preserving: prepared.image, drivePath: drivePath) {
            defer { self.discardImageDirectory(prepared.image) }
            self.warning?.cancel(); self.warning = nil
            self.transition(.preparing, "正在复核源文件与目录是否变化；尚未写盘。请勿修改来源或更换光盘。")
            try await Task.detached { try prepared.sourceTree?.validateUnchanged() }.value
            // Must succeed before writing. Source evidence must not depend on /tmp.
            await self.taskFiles.flush()
            let priorLog = self.logURL
            let archive = try await Task.detached {
                try BurnTaskArchive.create(proof: prepared.proof, priorLog: priorLog)
            }.value
            self.pendingProof = prepared.proof
            self.proofURL = archive.proofURL
            self.logURL = archive.logURL
            self.log("Incremental ISO: imageBytes=\(prepared.imageBytes) referencedBytes=\(prepared.referencedBytes) start=\(prepared.proof.expectedStart) imageSHA256=\(prepared.imageSHA256); expected=\(self.proofURL!.path)")
            self.log("systemVerifyRequested=\(selectedVerification)")
            for entry in snapshot.fileEntries { self.log("old_extent name=\(entry.name) lba=\(entry.lba) bytes=\(entry.bytes)") }
            for file in prepared.proof.files { self.log("source name=\(file.path) bytes=\(file.bytes) sha256=\(file.sha256)") }
            self.transition(.preparing, "正在复核光盘、镜像和刻录设置；尚未写盘，请保持光驱连接。")
            self.recordDisc(snapshot, imageBytes: prepared.imageBytes)
            let requested: Double?
            if case .kilobytesPerSecond(let value) = selectedSpeed { requested = value } else { requested = nil }
            self.diagnostic(.preparing, evidence: DiagnosticEvidence(requestedSpeedKBps: requested,
                requestedSpeedAutomatic: selectedSpeed == .automatic,
                reducedSpeedRequested: selectedSpeed == .reduced,
                verifyAfterWriteRequested: selectedVerification))
            var lastStatus = ""
            var measuredState = ""
            var phaseStarted = Date()
            var verificationObserved = false
            var mediaReturnedDuringCompletion = false
            let outcome = try await operation.write { event in
                guard case let .progress(update, diagnosticEvent, title, starting) = event else {
                    self.observeAppendEvent(event)
                    return
                }
                let state = update.state, fraction = update.fraction
                if diagnosticEvent == .verifying { verificationObserved = true }
                if diagnosticEvent == .mediaReturnedDuringCompletion { mediaReturnedDuringCompletion = true }
                if diagnosticEvent == .registryObserved {
                    self.diagnostic(diagnosticEvent, error: update.errorCode.map { NSError(domain: NSPOSIXErrorDomain, code: Int($0)) }, evidence: update.evidence)
                } else { self.diagnostic(diagnosticEvent, fraction: fraction, code: update.errorCode, evidence: update.evidence, errorSource: update.errorSource) }
                if starting {
                    self.log("backend detail=\(update.detail)")
                    self.transition(.burning, "正在追加文件；请勿退出程序或断开光驱。")
                    return
                }
                if update.kind == .backend { self.actualBurnSpeedKBps = diagnosticEvent == .writing ? update.evidence?.actualSpeedKBps : nil }
                if update.kind == .device {
                    self.log("device \(update.detail)"); return
                }
                if update.kind == .finishing {
                    self.transition(.finishing, update.detail); return
                }
                if update.kind == .warning {
                    self.message = update.detail; self.log("warning \(update.detail)"); return
                }
                let percent = fraction.flatMap { $0.isFinite && (0...1).contains($0) ? Int($0 * 100) : nil }
                let status = title + (percent.map { " · \($0)%" } ?? "")
                if measuredState != state {
                    measuredState = state; phaseStarted = Date(); self.remainingEstimate = nil
                }
                if let fraction, fraction.isFinite, fraction > 0.02, fraction < 1,
                   [DiagnosticEventKind.writing, .verifying].contains(diagnosticEvent),
                   Date().timeIntervalSince(phaseStarted) > 5 {
                    let elapsed = Date().timeIntervalSince(phaseStarted)
                    self.remainingEstimate = "当前阶段 " + OperationEstimate.duration(elapsed * (1 - fraction) / fraction)
                } else { self.remainingEstimate = nil }
                self.progressFraction = percent.map { Double($0) / 100 }
                if self.phase != .finishing { self.message = status }
                if !update.detail.isEmpty { self.log("backend detail=\(update.detail)") }
                if status != lastStatus { self.log("backend=\(state) \(status)"); lastStatus = status }
            }
            if case .readBack(let fresh) = outcome {
                self.snapshot = fresh
                self.recordDisc(fresh)
                self.diagnostic(prepared.proof.files.isEmpty ? .readbackDirectoryMatched : .readbackAddedSourcesMatched)
                self.log("RESERVED_READBACK_MATCH session=\(fresh.latest.session) start=\(fresh.latest.start) hashes=\(prepared.proof.files.count)")
                self.transition(.ready, "第 \(fresh.latest.session) 会话已关闭；已核对 \(prepared.proof.files.count) 个新增文件的 SHA-256 和旧文件区段，盘片留在仓内。")
                self.watchIdentity()
                return
            }
            self.snapshot = nil; self.mountedURL = nil; self.verified = []
            let verification = verificationObserved ? "系统报告校验阶段" :
                (selectedVerification ? "已请求系统校验，但未记录到校验阶段" : "未请求系统写后校验")
            let finish = mediaReturnedDuringCompletion
                ? "写入结束，但收尾期间介质重新出现；未执行后备推出，也未确认当前盘片。请先只读重新识别。"
                : "写入结束，系统已接受托盘打开请求或正常推出；请确认光盘实际弹出。合仓后刷新设备，可只校验本次新增文件。"
            self.transition(.awaitingReload, "\(finish)\(verification)；尚未完成重新装盘读回。")
        }
    }
    private func observeAppendEvent(_ event: AppendWriteEvent) {
        switch event {
        case .unmounting:
            transition(.unmounting, "正在正常卸载已确认的 DVD+R。")
        case let .deviceOperation(kind, error):
            diagnostic(kind, error: error)
        case .unmounted:
            mountedURL = nil
            transition(.burning, "正在续写预留轨道并关闭会话。请保持光驱连接。")
        case let .closeResult(kind, result, speed, evidence):
            invalidateDeviceCache()
            log("reservedAppend result=\(result) requestedKBps=\(speed) lastOpcode=\(evidence.sessionClose?.lastOpcode ?? 0)")
            diagnostic(kind, code: result == 0 ? nil : Int64(result), evidence: evidence, errorSource: .osStatus)
        case .readingBack:
            transition(.verifying, "会话已关闭，正在重新识别目录并读回本次新增文件。")
            diagnostic(.readbackAddedStarted)
        case .readbackFailed(let error):
            diagnostic(.readbackFailed, error: error)
        case .progress:
            break
        }
    }

    func reveal() {
        guard !blocksDeviceOperations, let mountedURL, let snapshot else { return }
        do {
            try snapshot.identity.validate()
            try checkSystem(dm_mount_matches(mountedURL.path, snapshot.identity.bsd), "检查挂载来源")
            NSWorkspace.shared.open(mountedURL)
        } catch { reset(); message = error.localizedDescription }
    }
    func closeSession(_ target: ManualSessionClose) {
        guard snapshot?.identity == target.snapshot.identity,
              snapshot?.latest == target.snapshot.latest, snapshot?.reservedTrack == nil, snapshot?.incompleteSession == true else {
            message = "盘片或会话已变化，请重新识别。"
            return
        }
        start(kind: .closeSession, drivePath: target.drivePath) {
            self.recordDisc(target.snapshot)
            self.transition(.preparing, "正在复核光驱和待关闭的会话。")
            try await Task.detached { try target.checkTarget() }.value
            self.transition(.unmounting, "正在正常卸载光盘，请保持光驱连接。")
            try await SessionMountService().unmountForSessionClose(target.snapshot.identity) { self.diagnostic($0, error: $1) }
            self.mountedURL = nil
            self.diagnostic(.sessionCloseChecked)
            self.transition(.finishing, "正在复核轨道、关闭末次会话并读取关闭状态，请保持光驱连接。")
            let (rc, evidence) = try await Task.detached { try target.run() }.value
            self.invalidateDeviceCache()
            if rc != 0 {
                let unknown = evidence.sessionClose?.attempted == true || (evidence.sessionClose?.releaseResult ?? 0) != 0
                self.diagnostic(unknown ? .sessionCloseUnconfirmed : .sessionCloseRejected,
                                code: Int64(rc), evidence: evidence, errorSource: .osStatus)
                if unknown {
                    throw BurnRecoveryRequired(detail: "关闭结果或设备释放未能确认（系统码 \(rc)）。已停止操作，请先重新检查设备。")
                }
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(rc), userInfo: [
                    NSLocalizedDescriptionKey: "光驱独占或盘片复核未通过（系统码 \(rc)），未发送关闭请求。请重新识别目录。"])
            }
            self.diagnostic(.sessionCloseConfirmed, evidence: evidence)
            self.transition(.ready, "光驱已确认第 \(target.snapshot.latest.session) 会话关闭。请重新识别目录，查看可追加空间。")
        }
    }

    func ejectNormally(drivePath: String?, bsd: String? = nil) {
        guard let drivePath, !blocksDeviceOperations else { return }
        let knownIdentity = snapshot?.identity
        guard knownIdentity != nil || bsd != nil else { return }
        start(kind: .eject, drivePath: drivePath) {
            let identity = try await Task.detached {
                if let knownIdentity { try knownIdentity.validate(); return knownIdentity }
                return try MediaIdentity.current(bsd!)
            }.value
            self.transition(.finishing, "正在通过系统磁盘服务正常推出；不会刻录或强制卸载。")
            let service = try DiscEjectService()
            try await service.eject(identity, drivePath: drivePath, trace: { self.diagnostic($0, error: $1) }) { text in
                self.message = text; self.log("normal-eject \(text)")
            }
            self.snapshot = nil; self.mountedURL = nil; self.verified = []
            self.diagnostic(.ejectCompleted)
            self.transition(.awaitingReload, "正常推出回调及持续介质移除检查通过，请确认实际托盘状态。此结果不代表刻录自动结束已修复。")
        }
    }
    func ejectBlankDisc(drivePath: String?) {
        guard let drivePath, !blocksDeviceOperations else { return }
        start(kind: .eject, drivePath: drivePath) {
            self.transition(.finishing, "正在正常推出空白盘；不会刻录或强制卸载。")
            try await BlankDiscEjectService.eject(drivePath: drivePath) {
                self.diagnostic(.ejectRequested)
            }
            self.diagnostic(.ejectCompleted)
            self.invalidateDeviceCache()
            self.transition(.awaitingReload, "空白盘推出请求已接受，持续无介质检查通过；请确认托盘实际弹出。")
        }
    }
    private func start(kind: DiagnosticTaskKind = .deviceRefresh, fileCount: Int? = nil,
                       totalBytes: UInt64? = nil, preserving image: URL? = nil, drivePath: String? = nil,
                       _ operation: @escaping @MainActor () async throws -> Void) {
        guard let lease = coordinator.begin() else { return }
        guard deviceGate.beginOperation() else { coordinator.finish(lease); return }
        diagnosticTaskID = DiagnosticReportStore.shared.startTask(kind: kind, media: diagnosticMediaType, driveModel: diagnosticDriveModel, fileCount: fileCount, totalBytes: totalBytes, drivePath: drivePath)
        recoveryNotice = nil
        if kind == .appendPreparation { appendPreparationFailure = nil }
        discardPreparedPlan(preserving: image)
        taskStartedAt = Date(); progressFraction = nil; remainingEstimate = nil
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-\(UUID().uuidString).log")
        logError = nil
        log("DiscMate session task; system=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        warning = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.isBusy, self.phase != .verifying else { return }
            self.message = "设备操作已等待 30 秒，仍在等待系统结束；未开始任何新操作。"
            self.log("Waiting for outstanding operation; device remains reserved")
        }
        task = Task {
            var recoveryRequired = false
            var outcome: DiagnosticOutcome = .completed
            do { try await operation() }
            catch let error as BurnDriveDisconnected {
                outcome = .failed
                self.invalidateDeviceCache()
                self.diagnostic(.deviceUnavailable, error: error as NSError)
                self.transition(.failed, error.localizedDescription)
            }
            catch let error as BurnRecoveryRequired {
                recoveryRequired = true; outcome = .needsRecovery
                self.diagnostic(.recoveryRequired, error: error as NSError)
                self.invalidateDeviceCache()
                self.transition(.recoveryRequired, error.localizedDescription)
            }
            catch let error as UDFAppendUnsupported {
                outcome = .failed
                self.unsupportedFilesystem = error.revision == 0x0102 ? .udf102 : .udfOther
                self.diagnostic(.filesystemUnsupported, error: error as NSError,
                    evidence: DiagnosticEvidence(disc: DiagnosticDiscEvidence(
                        filesystem: self.unsupportedFilesystem)))
                self.transition(.failed, error.localizedDescription)
            }
            catch {
                outcome = .failed
                if kind == .appendPreparation || (kind == .append && error is AppendPreflightFailure) {
                    self.recordAppendFailure(error)
                }
                if kind == .appendPreparation { self.appendPreparationFailure = error.localizedDescription }
                self.diagnostic(.failed, error: error as NSError)
                self.transition(.failed, error.localizedDescription)
            }
            if let id = self.diagnosticTaskID { DiagnosticReportStore.shared.finish(taskID: id, outcome: outcome) }
            self.diagnosticTaskID = nil
            self.warning?.cancel(); self.warning = nil
            self.progressFraction = nil; self.remainingEstimate = nil
            self.deviceGate.operationEnded(needsRecovery: recoveryRequired); self.task = nil
            self.coordinator.finish(lease, needsRecovery: recoveryRequired)
        }
    }
    private func recordAppendFailure(_ error: Error) {
        let rejection = AppendDiagnostics.rejection(error)
        diagnostic(.appendPreflightRejected, error: rejection.error, evidence: rejection.evidence)
    }
    private func transition(_ next: Phase, _ text: String) {
        log("\(phase.rawValue) -> \(next.rawValue): \(text)")
        let event: DiagnosticEventKind
        switch next {
        case .inspecting, .authorizing: event = .waiting
        case .preparing, .prepared: event = .preparing
        case .burning: event = .writing
        case .finishing, .unmounting: event = .finishing
        case .mounting: event = .mountRequested
        case .verifying: event = .readbackStarted
        case .failed: event = .failed
        case .recoveryRequired: event = .recoveryRequired
        case .ready: event = .completed
        default: event = .waiting
        }
        diagnostic(event)
        phase = next; message = text
        progressFraction = nil; remainingEstimate = nil
    }
    private func diagnostic(_ event: DiagnosticEventKind, fraction: Double? = nil,
                            error: NSError? = nil, code: Int64? = nil, evidence: DiagnosticEvidence? = nil,
                            errorSource: DiagnosticErrorCode.Source = .discRecording) {
        guard let id = diagnosticTaskID else { return }
        let domains: [DiagnosticErrorCode.Source: String] = [.posix: NSPOSIXErrorDomain, .osStatus: NSOSStatusErrorDomain, .cocoa: NSCocoaErrorDomain]
        let underlying = error ?? (errorSource == .discRecording ? nil : code.map { NSError(domain: domains[errorSource] ?? "DiscMate", code: Int($0)) })
        DiagnosticReportStore.shared.record(taskID: id, event: event, progress: fraction, error: underlying,
            backendError: errorSource == .discRecording ? code.map { ["DRErrorStatusErrorKey": $0] } : nil, evidence: evidence)
    }
    private func recordDisc(_ snapshot: SessionSnapshot, imageBytes: UInt64? = nil) {
        diagnostic(.preparing, evidence: DiagnosticEvidence(disc: DiagnosticDiscEvidence(
            latestSession: UInt16(exactly: snapshot.latest.session), latestStartLBA: snapshot.latest.start,
            nextWritableLBA: snapshot.writable?.nextWritable, freeBlocks: snapshot.writable?.freeBlocks,
            rootEntryCount: UInt32(exactly: snapshot.rootEntries.count), appendable: snapshot.appendable || snapshot.reservedTrack != nil, imageBytes: imageBytes,
            filesystem: snapshot.filesystem, writeState: snapshot.appendState)))
    }
    private func log(_ text: String) {
        guard let logURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        taskFiles.append(line, to: logURL) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.logURL == logURL else { return }
                self.logError = "任务日志写入失败：\(error.localizedDescription)；请在诊断窗口查看结构化记录。"
            }
        }
    }
    private func watchIdentity() {
        monitor?.invalidate()
        monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.blocksDeviceOperations, let snapshot = self.snapshot else { return }
                do { try snapshot.identity.validate() }
                catch { self.reset(); self.message = "光盘已更换或设备已断开，请重新识别会话。" }
            }
        }
    }
}
