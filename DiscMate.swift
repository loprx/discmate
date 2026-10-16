import AppKit
import DiscRecording
import DiscRecordingUI
import SwiftUI

@main
struct DiscMateApp: App {
    @NSApplicationDelegateAdaptor(DiscMateApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        Window("DiscMate", id: "main") {
            ContentView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            DiscMateHelpCommands()
        }
        Window("DiscMate 使用帮助", id: "discmate-help") {
            DiscMateHelpView()
                .frame(minWidth: 560, minHeight: 440)
        }
    }
}

private final class DiscMateApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "DiscMate", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL), icon.isValid else { return }
        NSApp.applicationIconImage = icon
    }
}

private enum Job: String, CaseIterable, Identifiable {
    case data = "数据光盘"
    case audio = "音频 CD"
    case image = "刻录镜像"
    case video = "VIDEO_TS"
    case erase = "擦除光盘"
    case info = "光盘信息"

    var id: String { rawValue }
}

/// One refresh result per drive; never combine fields from different indexes.
private struct DriveInventoryEntry: @unchecked Sendable {
    let device: DRDevice
    let description: String
    let name: String
    let bsd: String?
    let path: String?
    let present: Bool
    let blank: Bool
    let media: DiagnosticMediaType
    let speeds: [Double]
}

struct ContentView: View {
    @StateObject private var sessions = SessionModel.shared
    @StateObject private var nativeTask = SystemDiscTaskModel.shared
    @StateObject private var deviceChanges = DeviceChangeObserver.shared
    @StateObject private var coordinator = DeviceTaskCoordinator.shared
    @State private var showingDiagnostics = false
    @State private var isRefreshing = false
    @State private var inventory: [DriveInventoryEntry] = []
    @State private var firstBurnSpeed: BurnSpeedSelection = .automatic
    @State private var fileSizes: [URL: UInt64] = [:]
    @State private var directoryURLs: Set<URL> = []
    @State private var selectionRevision = UUID()
    private struct SelectionKey: Equatable { let files: [URL]; let revision: UUID }
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshWarning: Task<Void, Never>?
    @State private var cachedDiscDescription = "连接刻录机后刷新。"
    @State private var job: Job = .data
    @State private var filesByJob: [Job: [URL]] = [:]
    @State private var selectedDrive = 0
    @State private var discName = "DATA"
    @State private var keepAppendable = true
    @State private var showVerifyHelp = false
    @State private var status = "连接刻录机后点击“刷新设备”。"

    private var selectedEntry: DriveInventoryEntry? {
        inventory.indices.contains(selectedDrive) ? inventory[selectedDrive] : nil
    }
    private var drive: DRDevice? { selectedEntry?.device }

    private var files: [URL] { filesByJob[job] ?? [] }

    private var locked: Bool {
        isRefreshing || coordinator.isOccupied || sessions.blocksDeviceOperations || nativeTask.isBusy
    }
    private var deviceTaskActive: Bool {
        isRefreshing || coordinator.isOccupied || sessions.isBusy || nativeTask.isBusy
    }
    private var selectedMediaPresent: Bool {
        selectedEntry?.present == true
    }
    private var selectedMediaBlank: Bool {
        selectedEntry?.blank == true
    }
    private var appendMode: Bool { job == .data && selectedMediaPresent && !selectedMediaBlank }
    private var selectedBytes: UInt64 { files.reduce(0) { $0 + (fileSizes[$1] ?? 0) } }
    private var selectedSizeText: String {
        let known = OperationEstimate.size(selectedBytes)
        return files.allSatisfy { fileSizes[$0] != nil } ? known : "已知文件 \(known)，其余待检查"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    Text("DiscMate").font(.largeTitle.bold())
                    Text("免费的 macOS 光盘刻录工具").foregroundStyle(.secondary)
                }
                Picker("任务", selection: $job) {
                    ForEach(Job.allCases) { task in Text(task.rawValue).tag(task) }
                }.pickerStyle(.segmented).disabled(locked)
                    .help("选择操作类型。数据追加当前仅支持已实盘验证的 DVD+R ISO/Joliet 文件和文件夹流程。")

                HStack {
                    Picker("刻录机", selection: $selectedDrive) {
                        if inventory.isEmpty { Text("未检测到刻录机").tag(0) }
                        else {
                            ForEach(inventory.indices, id: \.self) { index in
                                Text(inventory[index].name).tag(index)
                            }
                        }
                    }.disabled(locked)
                    Button(isRefreshing ? "正在识别…" : sessions.needsDeviceRecovery ? "重新检查设备" : "刷新设备") { refresh() }
                        .disabled(deviceTaskActive)
                        .help("设备插拔及盘片变化会自动更新；此按钮可手动重新检查，通常数秒，不刻录。系统忙时请等待。")
                }.onChange(of: selectedDrive) { _ in updateSelection() }
                if sessions.needsDeviceRecovery {
                    if !sessions.recoveryTargets.isEmpty {
                        Picker("恢复目标", selection: $sessions.recoveryTargetPath) {
                            Text("请选择光驱").tag(Optional<String>.none)
                            ForEach(sessions.recoveryTargets, id: \.path) { target in
                                Text(target.name).tag(Optional(target.path))
                            }
                        }.disabled(deviceTaskActive)
                    }
                    Text(sessions.message + (sessions.isBusy ? "" : " 可点击“重新检查设备”；写入仍暂停。"))
                        .font(.callout).foregroundStyle(.orange)
                } else if let result = nativeTask.message {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                } else if isRefreshing {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                } else if sessions.isBusy {
                    Text("设备正由当前任务使用：\(sessions.message) 刷新将在任务结束后恢复。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let recoveryNotice = sessions.recoveryNotice {
                    Text(recoveryNotice).font(.callout).foregroundStyle(.secondary)
                }
                if job != .info {
                    Text(sessions.needsDeviceRecovery ? "设备与盘片状态待确认，请重新检查设备。" : selectedMediaPresent ? (selectedMediaBlank ? "空白光盘 · 可开始首次刻录" : "已有数据光盘 · 新增文件将使用追加流程") : "放入光盘并合仓，识别完成后会自动更新。")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if job == .data || job == .audio || job == .image || job == .video {
                    DiscMateSection(job == .data ? "1 · 添加要刻录的文件" : "选择刻录内容") {
                        VStack(alignment: .leading, spacing: 10) {
                            if job == .data {
                                HStack(spacing: 6) {
                                    Toggle("刻录后由系统校验", isOn: $sessions.verifyAfterWrite)
                                        .help("默认关闭。勾选后，首次刻录或追加完成后由系统校验本次写入，会增加耗时。")
                                    Button {
                                        showVerifyHelp.toggle()
                                    } label: {
                                        Image(systemName: "info.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("刻录后系统校验说明")
                                    .help("查看系统写后校验的作用与耗时说明")
                                    .popover(isPresented: $showVerifyHelp, arrowEdge: .trailing) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("刻录后由系统校验").font(.headline)
                                            Text("勾选后，光盘写入完成时，DiscRecording 会再读取并校验本次写入的数据，通常会增加刻录后的等待时间。")
                                            Text("此项默认关闭，可在未插入光盘时提前设置，首次刻录和追加都会采用该选择。它不重新读取旧文件；如需检查盘上文件内容，可在刻录后单独进行读回校验。")
                                                .foregroundStyle(.secondary)
                                        }
                                        .font(.callout)
                                        .padding(14)
                                        .frame(width: 330, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            if job == .data && selectedMediaPresent && selectedMediaBlank {
                                TextField("光盘名称", text: $discName)
                                    .help("首次刻录的光盘名称；追加沿用已有目录结构。")
                                Toggle("保留后续追加能力", isOn: $keepAppendable)
                                    .help("首次写入后保留追加能力；介质、文件系统与剩余空间也需要支持追加。关闭后可能无法再加入文件。")
                                if keepAppendable || diagnosticMedia == .dvdPlusR {
                                    Picker("刻录速率", selection: $firstBurnSpeed) {
                                        Text(BurnSpeedSelection.automatic.label()).tag(BurnSpeedSelection.automatic)
                                        ForEach(selectedBurnSpeeds, id: \.self) { speed in
                                            Text(BurnSpeedSelection.kilobytesPerSecond(speed).label(oneX: speedOneX))
                                                .tag(BurnSpeedSelection.kilobytesPerSecond(speed))
                                        }
                                    }.help("仅列出当前光驱和盘片报告支持的速率。自动请求系统最高可用速度；实际速度可能随写入阶段变化。")
                                    if selectedBurnSpeeds.isEmpty {
                                        Text("系统未提供可选速率，当前可使用自动速度。")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            HStack {
                                Button(job == .video ? "选择 VIDEO_TS 文件夹…" : "添加文件或文件夹…") { chooseFiles() }
                                    .help("选择本机文件加入待刻录列表；不会写入光盘。开始前会检查容量和文件是否可读。")
                                Button("清空列表") { filesByJob[job] = [] }.disabled(files.isEmpty)
                                    .help("仅移除列表中的待刻录项目，不删除源文件或盘上内容。")
                                Spacer()
                                Text("已选 \(files.count) 个顶层项目 · \(selectedSizeText)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if files.isEmpty {
                                Text(appendMode ? "选择或拖入新增文件、文件夹。盘上旧内容会保留，不需重新添加。" : "添加内容后，查看设置并开始刻录。")
                                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
                            } else {
                                ScrollView {
                                    VStack(spacing: 0) {
                                        ForEach(files, id: \.self) { file in
                                            HStack {
                                                Image(systemName: directoryURLs.contains(file) ? "folder" : "doc").foregroundStyle(.secondary)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(file.lastPathComponent).lineLimit(1)
                                                    Text(file.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                                Spacer()
                                                Text(directoryURLs.contains(file) ? "目录内大小待检查" : (fileSizes[file].map(OperationEstimate.size) ?? "大小待检查"))
                                                    .font(.caption).foregroundStyle(.secondary)
                                                Button { filesByJob[job]?.removeAll { $0 == file } } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                }.buttonStyle(.borderless).accessibilityLabel("移除 \(file.lastPathComponent)")
                                                    .help("从待刻录列表移除此项目，不删除源文件。")
                                            }.padding(.vertical, 7)
                                            Divider()
                                        }
                                    }
                                }.frame(height: min(170, CGFloat(files.count) * 53))
                            }
                            if sessions.needsDeviceRecovery {
                                Text("设备状态尚未确认，请先重新检查设备；待刻录文件仍保留。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if job == .data && !selectedMediaPresent {
                                Text("文件已加入，当前未识别到光盘。放入光盘并合仓，识别完成后自动显示；已有数据盘会显示追加摘要。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if job != .data || !appendMode {
                                Text("开始前显示刻录设置或确认。写入、校验和结束期间保持光驱连接；数据 DVD+R 在本窗口显示刻录与收尾进度。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(4).disabled(locked)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard job == .data, !locked, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
                            addSelectedURLs(urls)
                            return true
                        }
                    }
                } else if job == .erase {
                    Text("仅适用于可擦写光盘。擦除会删除盘上全部内容；开始前需确认，耗时取决于盘型和擦除方式，可能数分钟或更久。")
                } else { Text(cachedDiscDescription).textSelection(.enabled) }

                if job == .info || appendMode {
                    SessionPane(model: sessions, bsd: selectedEntry?.bsd, otherTaskBusy: isRefreshing || nativeTask.isBusy,
                                sources: job == .data ? files : [],
                                drivePath: selectedEntry?.path,
                                offersAppend: appendMode)
                }
                if !appendMode {
                    HStack {
                        Button(job == .erase ? "擦除…" : job == .info ? "刷新信息" : "开始刻录…") { runJob() }
                            .buttonStyle(.borderedProminent)
                            .disabled(locked || (job != .info && job != .erase && files.isEmpty) || drive == nil || (job != .info && !selectedMediaPresent))
                            .help(job == .info ? "重新读取设备信息，不写光盘，通常数秒。" : "进入设置或确认后开始操作。写入及结束期间不要断开光驱、电源或强行退出。")
                        Text(nativeTask.message ?? status).font(.caption).foregroundStyle(.secondary)
                    }
                } else if isRefreshing {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if let progress = nativeTask.progress {
                    SystemTaskProgressView(progress: progress, isBusy: nativeTask.isBusy, actualSpeedKBps: nativeTask.actualSpeedKBps)
                }
                if let logError = sessions.logError {
                    Text(logError).font(.caption).foregroundStyle(.orange)
                }
                Button("导出脱敏诊断日志…") { showingDiagnostics = true }
                    .help("选择任务并预览脱敏报告后保存；只读取本机诊断记录，不访问光驱或上传数据。")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .onAppear {
            deviceChanges.setSuspended(true)
            deviceChanges.start()
            refresh(source: .startup)
            deviceChanges.setSuspended(locked)
        }
        .onDisappear { deviceChanges.stop() }
        .onChange(of: locked) { deviceChanges.setSuspended($0) }
        .onChange(of: deviceChanges.revision) { _ in
            guard !locked else { return }
            refresh(preserveNativeResult: true, trigger: deviceChanges.lastDelivery, source: .deviceNotification)
        }
        .sheet(isPresented: $showingDiagnostics) { DiagnosticsView() }
        .onChange(of: sessions.needsDeviceRecovery) { needsRecovery in
            guard needsRecovery else { return }
            // A disconnected/replaced drive invalidates the previous inventory,
            // even while automatic refresh is intentionally held by recovery.
            inventory = []
        }
        .onChange(of: nativeTask.isBusy) { busy in
            guard !busy else { return }
            // The completed burn may replace IOMedia without opening the tray.
            // Discard the pre-burn blank/media/BSD caches before any next action.
            let completedDrivePath = selectedEntry?.path
            inventory = []
            if !sessions.needsDeviceRecovery { refresh(preferredPath: completedDrivePath, preserveNativeResult: true, source: .taskCompleted) }
        }
        .onChange(of: files) { _ in sessions.invalidatePreparedPlan() }
        .onChange(of: job) { _ in sessions.invalidatePreparedPlan() }
        .task(id: SelectionKey(files: files, revision: selectionRevision)) {
            let selected = files
            let metadata = await Task.detached { () -> ([URL: UInt64], Set<URL>) in
                var result: [URL: UInt64] = [:]
                var directories: Set<URL> = []
                for url in selected {
                    if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) {
                        if values.isDirectory == true { directories.insert(url) }
                        if values.isRegularFile == true, let bytes = values.fileSize {
                            result[url] = UInt64(max(0, bytes))
                        }
                    }
                }
                return (result, directories)
            }.value
            guard !Task.isCancelled, selected == files else { return }
            fileSizes = metadata.0
            directoryURLs = metadata.1
        }
    }

    private nonisolated static func readDiscDescription(_ drive: DRDevice) -> String {
        guard drive.mediaIsPresent() else { return "\(drive.displayName() ?? "刻录机")：未放入光盘。" }
        let deviceStatus = drive.status() as NSDictionary
        let info = deviceStatus[DRDeviceMediaInfoKey] as? NSDictionary
        let sessions = (info?[DRDeviceMediaSessionCountKey] as? NSNumber)?.intValue
        let sessionText = sessions.map(String.init) ?? "未知"
        let trackInfo = deviceStatus[DRDeviceTrackInfoKey] as? NSDictionary
        let trackLines = (trackInfo?.allValues ?? []).compactMap { $0 as? NSDictionary }.map { track in
            let session = (track[DRSessionNumberKey] as? NSNumber)?.intValue ?? -1
            let number = (track[DRTrackNumberKey] as? NSNumber)?.intValue ?? -1
            let start = (track[DRTrackStartAddressKey] as? NSNumber)?.intValue ?? -1
            let length = track[DRTrackLengthKey].map { String(describing: $0) } ?? "未知"
            return (session, number, "区段 \(session) 轨道 \(number)：起点 \(start)，长度 \(length)")
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2).joined(separator: "\n")
        return "设备：\(drive.displayName() ?? "未知")\n盘片：\(drive.mediaType() ?? "未知")\n区段数：\(sessionText)\n空白：\(drive.mediaIsBlank() ? "是" : "否")\n允许追加：\(drive.mediaIsAppendable() ? "是" : "否")\n可擦除：\(drive.mediaIsErasable() ? "是" : "否")\n\(trackLines)"
    }

    // DiscRecording enumeration itself can wait on a stale device. Keep that
    // wait off the main thread, and retain the task/lock until it really returns.
    // A warning never starts a second enumeration or claims the first was cancelled.
    private struct Inventory: @unchecked Sendable {
        let entries: [DriveInventoryEntry]
        let registry: DMOpticalRegistryProbe
        let registryCode: Int32
    }
    private func refresh(preferredPath: String? = nil, preserveNativeResult: Bool = false,
                         trigger: DeviceChangeObserver.Delivery? = nil,
                         source: DiagnosticRefreshSource = .manual) {
        guard !isRefreshing, !sessions.isBusy, !nativeTask.isBusy else { return }
        let selectedPath = preferredPath ?? selectedEntry?.path
        if sessions.needsDeviceRecovery {
            sessions.recoverDevice(path: selectedPath) { refreshAfterRecovery(path: $0) }
            return
        }
        guard let lease = coordinator.begin() else { return }
        let selectedBSD = selectedEntry?.bsd
        isRefreshing = true; sessions.reset()
        if !preserveNativeResult { nativeTask.clearResult() }
        let diagnosticID = DiagnosticReportStore.shared.startTask(kind: .deviceRefresh, driveModel: diagnosticDriveModel)
        DiagnosticReportStore.shared.record(taskID: diagnosticID, event: .preparing,
            evidence: DiagnosticEvidence(refresh: DiagnosticRefreshEvidence(source: source,
                appeared: trigger?.appeared ?? 0, disappeared: trigger?.disappeared ?? 0,
                status: trigger?.status ?? 0, duplicate: trigger?.duplicate ?? 0,
                deferredByTask: trigger?.deferredByTask ?? false,
                deferredByBusy: trigger?.deferredByBusy ?? false)))
        status = "正在等待系统识别刻录设备…"
        refreshWarning = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, isRefreshing else { return }
            status = "系统设备服务尚未返回。界面仍可响应；未启动第二次查询或刻录。"
            DiagnosticReportStore.shared.record(taskID: diagnosticID, event: .waiting)
        }
        refreshTask = Task { @MainActor in
            let result = await Task.detached { () -> Inventory in
                let devices = (DRDevice.devices() as? [DRDevice]) ?? []
                let entries = devices.map { device -> DriveInventoryEntry in
                    let status = device.status() as NSDictionary
                    let info = status[DRDeviceMediaInfoKey] as? NSDictionary
                    return DriveInventoryEntry(device: device, description: Self.readDiscDescription(device),
                        name: device.displayName() ?? "刻录机", bsd: info?[DRDeviceMediaBSDNameKey] as? String,
                        path: device.ioRegistryEntryPath(), present: device.mediaIsPresent(), blank: device.mediaIsBlank(),
                        media: Self.mediaKind(device.mediaType()), speeds: BurnSpeedOptions.values(fromStatus: status))
                }
                var registry = DMOpticalRegistryProbe()
                let registryCode = dm_registry_optical_probe(&registry)
                return Inventory(entries: entries, registry: registry, registryCode: registryCode)
            }.value
            inventory = result.entries
            if let selectedPath, let index = result.entries.firstIndex(where: { $0.path == selectedPath }) {
                selectedDrive = index
            } else if let selectedBSD, let index = result.entries.firstIndex(where: { $0.bsd == selectedBSD }) {
                selectedDrive = index
            } else {
                selectedDrive = 0
            }
            isRefreshing = false
            refreshWarning?.cancel(); refreshWarning = nil
            coordinator.finish(lease)
            updateSelection()
            if result.registryCode == 0 {
                DiagnosticReportStore.shared.record(taskID: diagnosticID, event: .registryObserved,
                    evidence: DiagnosticEvidence(opticalRegistry: DiagnosticOpticalRegistryEvidence(
                        discRecordingDevices: inventory.count,
                        lenovoUSBDevices: Int(result.registry.lenovoUSBDevices),
                        opticalPeripherals: Int(result.registry.opticalPeripherals),
                        dvdMedia: Int(result.registry.dvdMedia))))
            } else {
                DiagnosticReportStore.shared.record(taskID: diagnosticID, event: .registryObserved,
                    error: NSError(domain: NSPOSIXErrorDomain, code: Int(result.registryCode)))
            }
            DiagnosticReportStore.shared.record(taskID: diagnosticID, event: inventory.isEmpty ? .deviceUnavailable : .deviceAvailable,
                evidence: DiagnosticEvidence(device: DiagnosticDeviceEvidence(mediaAbsent: inventory.isEmpty ? nil : !selectedMediaPresent)))
            DiagnosticReportStore.shared.record(taskID: diagnosticID, event: .completed)
            DiagnosticReportStore.shared.finish(taskID: diagnosticID, outcome: .completed)
            status = inventory.isEmpty ? "未检测到刻录机。" : "已检测到 \(inventory.count) 台刻录机。"
            refreshTask = nil
        }
    }

    private func refreshAfterRecovery(path: String) {
        let recoveryMessage = sessions.message
        refresh(preferredPath: path, source: .recovery)
        // Refresh invalidates UI caches too. Keep the result explicit even when
        // the data-pane is hidden; recovery never certifies the preceding burn.
        status = recoveryMessage + " 正在刷新当前设备列表…"
    }

    private func updateSelection() {
        guard !isRefreshing, !coordinator.isOccupied, !sessions.blocksDeviceOperations, !nativeTask.isBusy else { return }
        sessions.reset()
        sessions.diagnosticDriveModel = diagnosticDriveModel
        sessions.diagnosticMediaType = diagnosticMedia
        sessions.updateBurnSpeeds(selectedBurnSpeeds)
        firstBurnSpeed = .automatic
        cachedDiscDescription = selectedEntry?.description ?? "未检测到刻录机。"
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = job != .image && job != .video
        panel.canChooseDirectories = job == .data || job == .video
        panel.canChooseFiles = job != .video
        if panel.runModal() == .OK {
            addSelectedURLs(panel.urls)
        }
    }

    private func addSelectedURLs(_ urls: [URL]) {
        guard !locked else { return }
        selectionRevision = UUID()
        if job == .image || job == .video {
            filesByJob[job] = urls
        } else {
            for url in urls where !filesByJob[job, default: []].contains(url) {
                filesByJob[job, default: []].append(url)
            }
        }
        sessions.invalidatePreparedPlan()
        // A disc may change while the chooser is open; drop follows the same
        // invalidation and refresh path, without inspecting the source tree here.
        if job == .data { refresh(source: .fileSelection) }
    }

    private func runJob() {
        guard !isRefreshing, !coordinator.isOccupied, !sessions.blocksDeviceOperations, !nativeTask.isBusy, let drive else { return }
        if job == .info {
            refresh()
            return
        }
        if job == .erase {
            guard drive.mediaIsErasable() else {
                status = "当前盘片不可擦除。"
                return
            }
            guard let path = drive.ioRegistryEntryPath() else { status = "无法确认光驱身份。"; return }
            let preflight: LegacyMediaPreflight
            do { preflight = try LegacyMediaPreflight.capture(path: path, wasBlank: drive.mediaIsBlank()) }
            catch { recordPreflightFailure(error, kind: .erase); return }
            guard confirm("擦除光盘", "盘上全部内容将被删除。") else { return }
            guard let erase = DRErase(for: drive) else { return }
            nativeTask.beginErase(erase, model: diagnosticDriveModel, media: diagnosticMedia,
                                  preflight: preflight,
                                  requireRecovery: sessions.requireRecovery)
            return
        }
        guard drive.mediaIsPresent() else {
            status = "请先放入光盘。"
            return
        }
        guard drive.mediaIsBlank() || drive.mediaIsAppendable() else {
            status = "这张光盘已封盘或不可追加。"
            return
        }
        if job == .data && !drive.mediaIsBlank() {
            status = "已有数据盘请添加文件后点击“查看追加摘要”。无需完整读取旧内容。"
            return
        }
        if job == .data && diagnosticMedia == .dvdPlusR {
            guard let path = drive.ioRegistryEntryPath() else { status = "无法确认光驱身份。"; return }
            do {
                let request = try FirstDataBurnRequest.capture(drivePath: path, sources: files,
                    volumeName: discName.isEmpty ? "DATA" : discName, appendable: keepAppendable,
                    speed: firstBurnSpeed, verifyAfterWrite: sessions.verifyAfterWrite)
                guard confirm("开始首次刻录", "将写入 \(files.count) 个项目。速率：\(firstBurnSpeed.label(oneX: speedOneX))。\(keepAppendable ? "保留后续追加能力。" : "结束后封盘，无法继续追加。")\(sessions.verifyAfterWrite ? "写入后由系统校验。" : "跳过系统写后校验；独立读回需重新合仓后手动执行。")结束后自动执行正常推出。") else { return }
                sessions.reset()
                nativeTask.beginFirstData(request, model: diagnosticDriveModel, fileCount: files.count,
                    totalBytes: files.allSatisfy { fileSizes[$0] != nil } ? selectedBytes : nil,
                    requireRecovery: sessions.requireRecovery)
            } catch { status = error.localizedDescription }
            return
        }
        guard let layout = makeLayout() else { return }
        guard let path = drive.ioRegistryEntryPath() else { status = "无法确认光驱身份。"; return }
        let preflight: LegacyMediaPreflight
        do { preflight = try LegacyMediaPreflight.capture(path: path, wasBlank: drive.mediaIsBlank()) }
        catch {
            let kind: DiagnosticTaskKind = job == .audio ? .audioBurn : job == .image ? .imageBurn
                : job == .video ? .videoBurn : .dataBurn
            recordPreflightFailure(error, kind: kind)
            return
        }
        if job == .data && keepAppendable {
            guard let burn = DRBurn(for: drive) else {
                status = "无法创建刻录任务。"
                return
            }
            burn.setAppendable(true)
            guard burn.appendable() else {
                status = "系统未接受保留追加能力的设置，已取消刻录。"
                return
            }
            do {
                burn.setRequestedBurnSpeed(try firstBurnSpeed.requestedSpeed(supported: selectedBurnSpeeds) ?? DRDeviceBurnSpeedMax)
            } catch { status = error.localizedDescription; return }
            let action = drive.mediaIsBlank() ? "写入第一个区段" : "追加新区段"
            guard confirm(action, "将写入 \(files.count) 个项目，并保留后续追加能力。速率：\(firstBurnSpeed.label(oneX: speedOneX))。此操作会永久占用盘片空间。") else { return }
            beginBurn(burn, layout: layout, preflight: preflight, speedSelection: firstBurnSpeed)
            return
        }
        guard let setup = DMCreateBurnSetupPanel() else {
            status = "无法加载刻录设置窗口，未开始写入。"; return
        }
        setup.setCanSelectAppendableMedia(job == .data)
        guard setup.run() == NSApplication.ModalResponse.OK.rawValue,
              let burn = setup.burnObject() else { return }
        if job == .data && keepAppendable && !burn.appendable() {
            status = "系统未启用“Leave disc appendable”，已取消刻录，避免封盘。"
            return
        }
        beginBurn(burn, layout: layout, preflight: preflight)
    }

    private var diagnosticDriveModel: DiagnosticDriveModel {
        .knownModel(selectedEntry?.name)
    }
    private func recordPreflightFailure(_ error: Error, kind: DiagnosticTaskKind) {
        status = error.localizedDescription
        let reports = DiagnosticReportStore.shared
        let id = reports.startTask(kind: kind, media: diagnosticMedia, driveModel: diagnosticDriveModel)
        reports.record(taskID: id, event: .preflightUnavailable, error: error as NSError)
        reports.finish(taskID: id, outcome: .failed)
    }
    private var selectedBurnSpeeds: [Double] {
        selectedEntry?.speeds ?? []
    }
    private var speedOneX: Double {
        switch diagnosticMedia {
        case .cdR, .cdRW: return Double(DRDeviceBurnSpeedCD1x)
        case .bdR, .bdRE: return Double(DRDeviceBurnSpeedBD1x)
        case .unknown: return 0
        default: return Double(DRDeviceBurnSpeedDVD1x)
        }
    }
    private var diagnosticMedia: DiagnosticMediaType {
        selectedEntry?.media ?? .unknown
    }
    private nonisolated static func mediaKind(_ type: String?) -> DiagnosticMediaType {
        switch type {
        case DRDeviceMediaTypeCDR: return .cdR
        case DRDeviceMediaTypeCDRW: return .cdRW
        case DRDeviceMediaTypeDVDRAM: return .dvdRAM
        case DRDeviceMediaTypeDVDR, DRDeviceMediaTypeDVDRDualLayer: return .dvdMinusR
        case DRDeviceMediaTypeDVDRW, DRDeviceMediaTypeDVDRWDualLayer: return .dvdMinusRW
        case DRDeviceMediaTypeDVDPlusR, DRDeviceMediaTypeDVDPlusRDoubleLayer: return .dvdPlusR
        case DRDeviceMediaTypeDVDPlusRW, DRDeviceMediaTypeDVDPlusRWDoubleLayer: return .dvdPlusRW
        case DRDeviceMediaTypeBDR: return .bdR
        case DRDeviceMediaTypeBDRE: return .bdRE
        default: return .unknown
        }
    }
    private func beginBurn(_ burn: DRBurn, layout: Any, preflight: LegacyMediaPreflight,
                           speedSelection: BurnSpeedSelection? = nil) {
        let kind: DiagnosticTaskKind
        switch job {
        case .audio: kind = .audioBurn
        case .image: kind = .imageBurn
        case .video: kind = .videoBurn
        default: kind = .dataBurn
        }
        nativeTask.beginBurn(burn, layout: layout, kind: kind, model: diagnosticDriveModel,
                             media: diagnosticMedia, fileCount: files.count,
                             totalBytes: files.allSatisfy { fileSizes[$0] != nil } ? selectedBytes : nil,
                             speedSelection: speedSelection, preflight: preflight,
                             requireRecovery: sessions.requireRecovery)
    }

    private func makeLayout() -> Any? {
        switch job {
        case .data, .video:
            let sourceFiles = files
            let volumeName = discName.isEmpty ? "DATA" : discName
            let filesystemMask = UInt32(DRFilesystemInclusionMaskISO9660 | DRFilesystemInclusionMaskJoliet)
            guard let root = DRFolder.virtualFolder(withName: volumeName) else {
                status = "无法创建光盘目录。"
                return nil
            }
            if job == .data {
                root.setExplicitFilesystemMask(filesystemMask)
            }
            for url in sourceFiles {
                if job == .video && url.lastPathComponent.uppercased() != "VIDEO_TS" {
                    status = "请选择名为 VIDEO_TS 的文件夹。"
                    return nil
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    status = "找不到文件：\(url.lastPathComponent)"
                    return nil
                }
                if isDirectory.boolValue {
                    guard let folder = DRFolder(path: url.path) else {
                        status = "无法读取文件夹：\(url.lastPathComponent)"
                        return nil
                    }
                    root.addChild(folder)
                } else if let file = DRFile(path: url.path) {
                    root.addChild(file)
                } else {
                    status = "无法读取文件：\(url.lastPathComponent)"
                    return nil
                }
            }
            return DRTrack(forRootFolder: root)
        case .audio:
            let tracks = files.compactMap { DRTrack(forAudioFile: $0.path) }
            guard tracks.count == files.count else {
                status = "部分音频格式无法转换为音频 CD。"
                return nil
            }
            return tracks
        case .image:
            guard let path = files.first?.path,
                  let layout = DRBurn.layout(forImageFile: path) else {
                status = "无法识别镜像文件。"
                return nil
            }
            return layout
        default:
            return nil
        }
    }

    private func confirm(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
