import AppKit
import Foundation
import DiscRecording

@MainActor
final class SessionModel: ObservableObject {
    enum Phase: String { case idle, inspecting, preparing, prepared, burning, finishing, recoveryRequired, awaitingReload, authorizing, unmounting, mounting, verifying, ready, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = "添加要刻录的文件，然后点击“查看追加摘要”。只检查旧目录，不完整读取旧文件。"
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
    @Published private(set) var taskStartedAt: Date?
    @Published private(set) var progressFraction: Double?
    @Published private(set) var remainingEstimate: String?
    var canVerifyAdded: Bool { pendingProof?.preserved != nil }
    var verificationBytes: UInt64 { snapshot?.rootEntries.reduce(0) { $0 + UInt64($1.bytes) } ?? 0 }
    var addedVerificationBytes: UInt64 { pendingProof?.files.reduce(0) { $0 + $1.bytes } ?? 0 }
    private var task: Task<Void, Never>?
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
    func recoverDevice(path: String?, afterRecovery: @escaping @MainActor (String) -> Void) {
        guard task == nil, deviceGate.beginRecovery() else { return }
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
                self.transition(.recoveryRequired, error.localizedDescription)
            }
            self.warning?.cancel(); self.warning = nil
            self.deviceGate.recoveryEnded(accepted: accepted)
            self.task = nil
            if let recoveredPath { afterRecovery(recoveredPath) }
        }
    }

    private func invalidateDeviceCache() {
        monitor?.invalidate(); monitor = nil
        deviceCache.invalidateDevice()
    }

    func invalidatePreparedPlan() {
        guard !isBusy else { return }
        incrementalPlan = nil; incrementalSnapshot = nil
        if phase == .prepared { transition(.ready, "文件选择已变化，请重新准备增量镜像。") }
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
        message = "添加要刻录的文件，然后点击“查看追加摘要”。只检查旧目录，不完整读取旧文件。"
    }
    func inspect(bsd: String?) {
        guard let bsd else { message = "请先选择已放入光盘的刻录机。"; return }
        start {
            self.snapshot = nil; self.mountedURL = nil; self.verified = []
            self.transition(.inspecting, "正在读取会话和 ISO 目录…")
            let snapshot = try await Task.detached { () throws -> SessionSnapshot in
                let identity = try MediaIdentity.current(bsd)
                return try DVDSessionReader(identity: identity).scan()
            }.value
            self.snapshot = snapshot
            self.transition(.ready, "已识别第 \(snapshot.latest.session) 会话，共 \(snapshot.rootEntries.count) 个根目录项目。")
            self.log("media=\(snapshot.identity.registryID) bsd=\(bsd) session=\(snapshot.latest.session) start=\(snapshot.latest.start) descriptor=\(snapshot.descriptorHash)")
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
        return fresh
    }
    func openLatest(bsd: String? = nil) {
        start {
            let expected = try await self.snapshotForReading(bsd: bsd)
            self.verified = []; self.mountedURL = nil
            self.transition(.inspecting, "正在复核盘片身份和最新会话…")
            let fresh = try await Task.detached { try DVDSessionReader(identity: expected.identity).scan() }.value
            guard fresh.latest == expected.latest, fresh.descriptorHash == expected.descriptorHash, fresh.rootEntries == expected.rootEntries else {
                self.snapshot = nil
                throw DiscFailure("会话信息已变化，请重新识别后再打开。")
            }
            let mounting = try SessionMountService()
            let path: URL
            if let existing = try mounting.currentMount(fresh.identity),
               existing.lastPathComponent.hasPrefix("DiscMate-Session-\(fresh.latest.session)-"),
               dm_mount_matches(existing.path, fresh.identity.bsd) == 0 {
                // Reuse our existing read-only mount after checking media/session identity.
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
            try await mounting.unmount(fresh)
            self.transition(.mounting, "正在只读挂载最新会话…")
            path = try await Task.detached { try authorization.mount(fresh) }.value
            }
            // Opening a folder must not implicitly stream the entire disc.
            try await Task.detached {
                let names = try FileManager.default.contentsOfDirectory(atPath: path.path)
                guard Set(names) == Set(fresh.rootEntries.map(\.name)) else { throw DiscFailure("挂载目录不是最新会话。") }
                try fresh.identity.validate()
            }.value
            self.mountedURL = path
            self.transition(.ready, "最新会话已只读打开；仅核对目录，未校验文件正文。重新插盘后可再次打开。")
            NSWorkspace.shared.open(path)
        }
    }
    func verifyRecorded(addedOnly: Bool = false, bsd: String? = nil) {
        let proof = pendingProof
        if addedOnly && proof?.preserved == nil { return }
        let paths = addedOnly ? Set(proof!.files.map(\.path)) : nil
        start {
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
                self.log("SOURCE_SHA256_MATCH \(proof.files.count) files; read=\(files.count); addedOnly=\(addedOnly)")
                let scope = addedOnly ? "本次新增 \(files.count) 个文件 SHA-256 与源清单一致；旧文件仅核对目录及原区段，未重读正文。" : "全部 \(files.count) 个文件已读回，其中 \(proof.files.count) 个与源哈希一致；无源哈希的旧文件仅完成可读性检查。"
                self.transition(.ready, scope + "未验证 Finder 挂载。")
            } else { self.transition(.ready, "第 \(expected.latest.session) 会话 \(files.count) 个文件已完整读回；本次未载入源清单，未验证 Finder 挂载。") }
            self.verified = files
        }
    }

    func prepareIncremental(sources: [URL], bsd: String? = nil) {
        guard !sources.isEmpty else { message = "请先添加文件。"; return }
        guard let target = snapshot?.identity.bsd ?? bsd else { message = "请先放入光盘并刷新设备。"; return }
        start {
            self.transition(.inspecting, "正在检查光盘目录、原区段及可追加空间；不读取旧文件正文…")
            let snapshot = try await Task.detached {
                let reader = try DVDSessionReader(identity: MediaIdentity.current(target))
                defer { reader.close() }
                return try reader.scan()
            }.value
            self.snapshot = snapshot; self.verified = []
            self.watchIdentity()
            self.incrementalPlan = nil; self.incrementalSnapshot = nil
            self.warning?.cancel(); self.warning = nil
            self.transition(.preparing, "正在准备增量镜像：保留旧文件区段，暂存新增文件并校验；尚未写盘…")
            let prepared = try await Task.detached {
                try snapshot.identity.validate()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-incremental-\(UUID().uuidString)")
                let result = try IncrementalISO.build(snapshot: snapshot, verified: [], sources: sources, directory: directory)
                let reader = try DVDSessionReader(identity: snapshot.identity); defer { reader.close() }
                let fresh = try reader.scan()
                guard fresh.latest == snapshot.latest, fresh.descriptorHash == snapshot.descriptorHash,
                      fresh.rootEntries == snapshot.rootEntries,
                      fresh.writable?.nextWritable == result.proof.expectedStart else {
                    throw DiscFailure("准备镜像期间会话变化，请重新识别。")
                }
                return result
            }.value
            self.incrementalPlan = prepared; self.incrementalSnapshot = snapshot
            self.log("oldPayloadReadBytes=0; old hashes not reused; INCREMENTAL_PREPARED imageBytes=\(prepared.imageBytes) referencedBytes=\(prepared.referencedBytes) start=\(prepared.proof.expectedStart) imageSHA256=\(prepared.imageSHA256)")
            for entry in snapshot.rootEntries { self.log("old_extent name=\(entry.name) lba=\(entry.lba) bytes=\(entry.bytes)") }
            self.transition(.prepared, "已准备新增 \(sources.count) 个文件，保留 \(snapshot.rootEntries.count) 个旧文件；镜像约 \(prepared.imageBytes / 1024) KiB。尚未写盘。确认摘要后点击“开始追加”。")
        }
    }

    func burnIncremental() {
        guard incrementalWriteEnabled, !blocksDeviceOperations, let prepared = incrementalPlan, let snapshot = incrementalSnapshot else { return }
        let alert = NSAlert()
        alert.messageText = "开始追加这 \(prepared.proof.files.count) 个文件？"
        alert.informativeText = "新增镜像 \(OperationEstimate.size(prepared.imageBytes))；保留 \(snapshot.rootEntries.count) 个旧文件的原区段，不重写旧内容。盘片空间会永久占用，并保留后续追加能力。\n\n\(OperationEstimate.burn(prepared.imageBytes))。包含系统写后校验，完成后自动推出。旧文件正文未在本轮校验。\n\n开始后请勿断开光驱、电源或强行退出；当前追加流程不支持安全中途取消。自动结束稳定性仍在验证。"
        alert.addButton(withTitle: "开始追加"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        start {
            self.incrementalPlan = nil; self.incrementalSnapshot = nil
            self.warning?.cancel(); self.warning = nil
            // Must succeed before writing. Source evidence must not depend on /tmp.
            let archive = try BurnTaskArchive.create(proof: prepared.proof, priorLog: self.logURL)
            self.pendingProof = prepared.proof
            self.proofURL = archive.proofURL
            self.logURL = archive.logURL
            self.log("Incremental ISO: imageBytes=\(prepared.imageBytes) referencedBytes=\(prepared.referencedBytes) start=\(prepared.proof.expectedStart) imageSHA256=\(prepared.imageSHA256); expected=\(self.proofURL!.path)")
            for entry in snapshot.rootEntries { self.log("old_extent name=\(entry.name) lba=\(entry.lba) bytes=\(entry.bytes)") }
            for file in prepared.proof.files { self.log("source name=\(file.path) bytes=\(file.bytes) sha256=\(file.sha256)") }
            self.transition(.burning, "正在追加文件；请勿退出程序或断开光驱。")
            var lastStatus = ""
            var measuredState = ""
            var phaseStarted = Date()
            try await DiscBurnService.burn(snapshot: snapshot, proof: prepared.proof,
                source: .isoImage(prepared.image, bytes: prepared.imageBytes, sha256: prepared.imageSHA256)) { update in
                let state = update.state, fraction = update.fraction
                if update.kind == .device {
                    self.log("device \(update.detail)"); return
                }
                if update.kind == .finishing {
                    self.transition(.finishing, update.detail); return
                }
                if update.kind == .warning {
                    self.message = update.detail; self.log("warning \(update.detail)"); return
                }
                let titles = [DRStatusStatePreparing: "准备刻录", DRStatusStateSessionOpen: "正在开启新会话",
                              DRStatusStateTrackWrite: "正在写入", DRStatusStateSessionClose: "正在关闭会话",
                              DRStatusStateFinishing: "系统正在执行结束动作",
                              DRStatusStateVerifying: "正在进行系统校验", DRStatusStateDone: "系统任务已结束，等待设备确认"]
                let percent = fraction.flatMap { $0.isFinite && (0...1).contains($0) ? Int($0 * 100) : nil }
                let status = (titles[state] ?? "系统正在处理刻录任务") + (percent.map { " · \($0)%" } ?? "")
                if measuredState != state {
                    measuredState = state; phaseStarted = Date(); self.remainingEstimate = nil
                }
                if let fraction, fraction.isFinite, fraction > 0.02, fraction < 1,
                   [DRStatusStateTrackWrite, DRStatusStateVerifying].contains(state),
                   Date().timeIntervalSince(phaseStarted) > 5 {
                    let elapsed = Date().timeIntervalSince(phaseStarted)
                    self.remainingEstimate = "当前阶段 " + OperationEstimate.duration(elapsed * (1 - fraction) / fraction)
                } else { self.remainingEstimate = nil }
                self.progressFraction = percent.map { Double($0) / 100 }
                if self.phase != .finishing { self.message = status }
                if !update.detail.isEmpty { self.log("backend detail=\(update.detail)") }
                if status != lastStatus { self.log("backend=\(state) \(status)"); lastStatus = status }
            }
            self.snapshot = nil; self.mountedURL = nil; self.verified = []
            self.transition(.awaitingReload, "写入及系统校验结束，系统介质移除检查通过。请确认托盘已弹出；需要独立读回时，合仓后刷新设备，可只校验本次新增文件。尚未完成重新装盘读回。")
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
    func ejectNormally(drivePath: String?, bsd: String? = nil) {
        guard let drivePath, !blocksDeviceOperations else { return }
        let knownIdentity = snapshot?.identity
        guard knownIdentity != nil || bsd != nil else { return }
        start {
            let identity = try await Task.detached {
                if let knownIdentity { try knownIdentity.validate(); return knownIdentity }
                return try MediaIdentity.current(bsd!)
            }.value
            self.transition(.finishing, "正在通过系统磁盘服务正常推出；不会刻录或强制卸载。")
            let service = try DiscEjectService()
            try await service.eject(identity, drivePath: drivePath) { text in
                self.message = text; self.log("normal-eject \(text)")
            }
            self.snapshot = nil; self.mountedURL = nil; self.verified = []
            self.transition(.awaitingReload, "正常推出回调及持续介质移除检查通过，请确认实际托盘状态。此结果不代表刻录自动结束已修复。")
        }
    }
    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        guard deviceGate.beginOperation() else { return }
        recoveryNotice = nil
        incrementalPlan = nil; incrementalSnapshot = nil
        taskStartedAt = Date(); progressFraction = nil; remainingEstimate = nil
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-\(UUID().uuidString).log")
        log("DiscMate session task; system=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        warning = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.isBusy, self.phase != .verifying else { return }
            self.message = "设备操作已等待 30 秒，仍在等待系统结束；未开始任何新操作。"
            self.log("Waiting for outstanding operation; device remains reserved")
        }
        task = Task {
            var recoveryRequired = false
            do { try await operation() }
            catch let error as BurnRecoveryRequired {
                recoveryRequired = true
                self.invalidateDeviceCache()
                self.transition(.recoveryRequired, error.localizedDescription)
            }
            catch { self.transition(.failed, error.localizedDescription) }
            self.warning?.cancel(); self.warning = nil
            self.progressFraction = nil; self.remainingEstimate = nil
            self.deviceGate.operationEnded(needsRecovery: recoveryRequired); self.task = nil
        }
    }
    private func transition(_ next: Phase, _ text: String) {
        log("\(phase.rawValue) -> \(next.rawValue): \(text)")
        phase = next; message = text
        progressFraction = nil; remainingEstimate = nil
    }
    private func log(_ text: String) {
        guard let logURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        do {
            if !FileManager.default.fileExists(atPath: logURL.path) { try Data().write(to: logURL) }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8))
        } catch { NSLog("DiscMate 日志写入失败：%@", error.localizedDescription) }
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
