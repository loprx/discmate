import AppKit
import DiscRecording
import DiscRecordingUI
import SwiftUI

@main
struct DiscMateApp: App {
    @NSApplicationDelegateAdaptor(DiscMateApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        WindowGroup("DiscMate") {
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

struct ContentView: View {
    @StateObject private var sessions = SessionModel()
    @State private var mediaBSD: String?
    @State private var isRefreshing = false
    @State private var driveDescriptions: [String] = []
    @State private var driveNames: [String] = []
    @State private var mediaPresent: [Bool] = []
    @State private var mediaBlank: [Bool] = []
    @State private var fileSizes: [URL: UInt64] = [:]
    @State private var driveBSDNames: [String?] = []
    @State private var driveRegistryPaths: [String?] = []
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshWarning: Task<Void, Never>?
    @State private var cachedDiscDescription = "连接刻录机后刷新。"
    @State private var activeErase: DRErase?
    @State private var erasePanel: DREraseProgressPanel?
    @State private var job: Job = .data
    @State private var filesByJob: [Job: [URL]] = [:]
    @State private var drives: [DRDevice] = []
    @State private var selectedDrive = 0
    @State private var discName = "DATA"
    @State private var keepAppendable = true
    @State private var status = "连接刻录机后点击“刷新设备”。"
    @State private var activeBurn: DRBurn?
    @State private var progressPanel: DRBurnProgressPanel?

    private var drive: DRDevice? {
        drives.indices.contains(selectedDrive) ? drives[selectedDrive] : nil
    }

    private var files: [URL] { filesByJob[job] ?? [] }

    private var locked: Bool {
        isRefreshing || sessions.blocksDeviceOperations || activeBurn != nil || activeErase != nil
    }
    private var selectedMediaPresent: Bool {
        mediaPresent.indices.contains(selectedDrive) && mediaPresent[selectedDrive]
    }
    private var selectedMediaBlank: Bool {
        mediaBlank.indices.contains(selectedDrive) && mediaBlank[selectedDrive]
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
                    .help("选择操作类型。数据追加仅开放已验证的 DVD+R ISO/Joliet 根目录文件流程。")

                HStack {
                    Picker("刻录机", selection: $selectedDrive) {
                        if drives.isEmpty { Text("未检测到刻录机").tag(0) }
                        else {
                            ForEach(drives.indices, id: \.self) { index in
                                Text(driveNames.indices.contains(index) ? driveNames[index] : "刻录机 \(index + 1)").tag(index)
                            }
                        }
                    }
                    Button(isRefreshing ? "正在识别…" : "刷新设备") { refresh() }
                        .help("换盘、合仓或重连后更新设备状态，通常数秒；不刻录。若系统仍在处理，请等待，不要反复点击。")
                }.disabled(locked).onChange(of: selectedDrive) { _ in updateSelection() }
                if job != .info {
                    Text(selectedMediaPresent ? (selectedMediaBlank ? "空白光盘 · 可开始首次刻录" : "已有数据光盘 · 新增文件将使用追加流程") : "放入光盘并合仓，然后刷新设备。")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if job == .data || job == .audio || job == .image || job == .video {
                    GroupBox(job == .data ? "1 · 添加要刻录的文件" : "选择刻录内容") {
                        VStack(alignment: .leading, spacing: 10) {
                            if job == .data && !appendMode {
                                TextField("光盘名称", text: $discName)
                                    .help("首次刻录的光盘名称；追加沿用已有目录结构。")
                                Toggle("保留后续追加能力", isOn: $keepAppendable)
                                    .help("首次写入后保留追加能力；介质、文件系统与剩余空间也需要支持追加。关闭后可能无法再加入文件。")
                            }
                            HStack {
                                Button(job == .video ? "选择 VIDEO_TS 文件夹…" : appendMode ? "添加文件…" : "添加文件或文件夹…") { chooseFiles() }
                                    .help("选择本机文件加入待刻录列表；不会写入光盘。开始前会检查容量和文件是否可读。")
                                Button("清空列表") { filesByJob[job] = [] }.disabled(files.isEmpty)
                                    .help("仅移除列表中的待刻录项目，不删除源文件或盘上内容。")
                                Spacer()
                                Text("\(files.count) 个项目 · \(selectedSizeText)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if files.isEmpty {
                                Text(appendMode ? "选择要新增的普通文件。盘上的旧文件会保留，不需重新添加。" : "添加内容后，查看设置并开始刻录。")
                                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
                            } else {
                                ScrollView {
                                    VStack(spacing: 0) {
                                        ForEach(files, id: \.self) { file in
                                            HStack {
                                                Image(systemName: "doc").foregroundStyle(.secondary)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(file.lastPathComponent).lineLimit(1)
                                                    Text(file.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                                Spacer()
                                                Text(fileSizes[file].map(OperationEstimate.size) ?? "大小待检查")
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
                            if job != .data || !appendMode {
                                Text("开始前显示刻录设置或确认。写入、校验和结束期间保持光驱连接；首次刻录及其他类型仍使用系统刻录面板。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(4).disabled(locked)
                    }
                } else if job == .erase {
                    Text("仅适用于可擦写光盘。擦除会删除盘上全部内容；开始前需确认，耗时取决于盘型和擦除方式，可能数分钟或更久。")
                } else { Text(cachedDiscDescription).textSelection(.enabled) }

                if job == .info || appendMode {
                    SessionPane(model: sessions, bsd: mediaBSD, otherTaskBusy: isRefreshing || activeBurn != nil || activeErase != nil,
                                sources: job == .data ? files : [],
                                drivePath: driveRegistryPaths.indices.contains(selectedDrive) ? driveRegistryPaths[selectedDrive] : nil,
                                offersAppend: appendMode)
                }
                if !appendMode {
                    HStack {
                        Button(job == .erase ? "擦除…" : job == .info ? "刷新信息" : "开始刻录…") { runJob() }
                            .buttonStyle(.borderedProminent)
                            .disabled(locked || (job != .info && job != .erase && files.isEmpty) || drive == nil || (job != .info && !selectedMediaPresent))
                            .help(job == .info ? "重新读取设备信息，不写光盘，通常数秒。" : "进入设置或确认后开始操作。写入及结束期间不要断开光驱、电源或强行退出。")
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                } else if isRefreshing {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if activeBurn != nil || activeErase != nil {
                    Text("正在操作光盘。请保持光驱连接与供电，不要强行退出，等待系统进度窗口结束。")
                        .font(.callout).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .onAppear { refresh() }
        .onChange(of: files) { _ in sessions.invalidatePreparedPlan() }
        .onChange(of: job) { _ in sessions.invalidatePreparedPlan() }
        .task(id: files) {
            let selected = files
            let sizes = await Task.detached { () -> [URL: UInt64] in
                var result: [URL: UInt64] = [:]
                for url in selected {
                    if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                       values.isRegularFile == true, let bytes = values.fileSize {
                        result[url] = UInt64(max(0, bytes))
                    }
                }
                return result
            }.value
            guard !Task.isCancelled else { return }
            fileSizes = sizes
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
        let devices: [DRDevice]
        let descriptions: [String]
        let bsdNames: [String?]
        let registryPaths: [String?]
        let names: [String]
        let present: [Bool]
        let blank: [Bool]
    }
    private func refresh() {
        guard !isRefreshing, !sessions.blocksDeviceOperations, activeBurn == nil, activeErase == nil else { return }
        let selectedPath = driveRegistryPaths.indices.contains(selectedDrive) ? driveRegistryPaths[selectedDrive] : nil
        let selectedBSD = driveBSDNames.indices.contains(selectedDrive) ? driveBSDNames[selectedDrive] : nil
        isRefreshing = true; sessions.reset()
        status = "正在等待系统识别刻录设备…"
        refreshWarning = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, isRefreshing else { return }
            status = "系统设备服务尚未返回。界面仍可响应；未启动第二次查询或刻录。"
        }
        refreshTask = Task { @MainActor in
            let result = await Task.detached { () -> Inventory in
                let devices = (DRDevice.devices() as? [DRDevice]) ?? []
                let descriptions = devices.map(Self.readDiscDescription)
                let names = devices.map { device -> String? in
                    let info = (device.status() as NSDictionary)[DRDeviceMediaInfoKey] as? NSDictionary
                    return info?[DRDeviceMediaBSDNameKey] as? String
                }
                return Inventory(devices: devices, descriptions: descriptions, bsdNames: names,
                                 registryPaths: devices.map { $0.ioRegistryEntryPath() },
                                 names: devices.map { $0.displayName() ?? "刻录机" },
                                 present: devices.map { $0.mediaIsPresent() }, blank: devices.map { $0.mediaIsBlank() })
            }.value
            drives = result.devices; driveDescriptions = result.descriptions; driveBSDNames = result.bsdNames
            driveRegistryPaths = result.registryPaths
            driveNames = result.names; mediaPresent = result.present; mediaBlank = result.blank
            if let selectedPath, let index = result.registryPaths.firstIndex(where: { $0 == selectedPath }) {
                selectedDrive = index
            } else if let selectedBSD, let index = result.bsdNames.firstIndex(where: { $0 == selectedBSD }) {
                selectedDrive = index
            } else {
                selectedDrive = 0
            }
            isRefreshing = false
            refreshWarning?.cancel(); refreshWarning = nil
            updateSelection()
            status = drives.isEmpty ? "未检测到刻录机。" : "已检测到 \(drives.count) 台刻录机。"
            refreshTask = nil
        }
    }

    private func updateSelection() {
        guard !isRefreshing, !sessions.blocksDeviceOperations, activeBurn == nil, activeErase == nil else { return }
        sessions.reset()
        mediaBSD = driveBSDNames.indices.contains(selectedDrive) ? driveBSDNames[selectedDrive] : nil
        cachedDiscDescription = driveDescriptions.indices.contains(selectedDrive) ? driveDescriptions[selectedDrive] : "未检测到刻录机。"
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = job != .image && job != .video
        panel.canChooseDirectories = (job == .data && !appendMode) || job == .video
        panel.canChooseFiles = job != .video
        if panel.runModal() == .OK {
            if job == .image || job == .video {
                filesByJob[job] = panel.urls
            } else {
                for url in panel.urls where !files.contains(url) {
                    filesByJob[job, default: []].append(url)
                }
            }
            // The disc can be inserted while the file chooser is open. Refresh
            // once after selection so the append controls reflect current media.
            if job == .data { refresh() }
        }
    }

    private func runJob() {
        guard !isRefreshing, !sessions.blocksDeviceOperations, activeBurn == nil, activeErase == nil, let drive else { return }
        if job == .info {
            refresh()
            return
        }
        if job == .erase {
            guard drive.mediaIsErasable() else {
                status = "当前盘片不可擦除。"
                return
            }
            guard confirm("擦除光盘", "盘上全部内容将被删除。") else { return }
            guard let erase = DRErase(for: drive) else { return }
            activeErase = erase
            let panel = DREraseProgressPanel()
            erasePanel = panel
            _ = panel.perform(NSSelectorFromString("beginProgressPanelForErase:"), with: erase)
            status = "正在擦除。"
            pollErase()
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
        guard let layout = makeLayout() else { return }
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
            let action = drive.mediaIsBlank() ? "写入第一个区段" : "追加新区段"
            guard confirm(action, "将写入 \(files.count) 个项目，并保留后续追加能力。此操作会永久占用盘片空间。") else { return }
            beginBurn(burn, layout: layout, action: action)
            return
        }
        let setup = DRBurnSetupPanel()
        setup.setCanSelectAppendableMedia(job == .data)
        guard setup.run() == NSApplication.ModalResponse.OK.rawValue,
              let burn = setup.burnObject() else { return }
        if job == .data && keepAppendable && !burn.appendable() {
            status = "系统未启用“Leave disc appendable”，已取消刻录，避免封盘。"
            return
        }
        beginBurn(burn, layout: layout, action: "刻录")
    }

    private func pollErase() {
        guard let erase = activeErase else { return }
        let info = erase.status() as NSDictionary
        let state = info[DRStatusStateKey] as? String ?? "未知状态"
        if state == DRStatusStateDone || state == DRStatusStateFailed {
            status = state == DRStatusStateDone ? "擦除完成。" : "擦除失败：\(info[DRErrorStatusKey] ?? "未知错误")"
            activeErase = nil; erasePanel = nil
        } else {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in pollErase() }
        }
    }

    private func beginBurn(_ burn: DRBurn, layout: Any, action: String) {
        activeBurn = burn
        let panel = DRBurnProgressPanel()
        progressPanel = panel
        _ = panel.perform(NSSelectorFromString("beginProgressPanelForBurn:layout:"), with: burn, with: layout)
        status = "正在\(action)…"
        pollBurn()
    }

    private func pollBurn() {
        guard let burn = activeBurn else { return }
        let info = burn.status() as NSDictionary
        let state = info[DRStatusStateKey] as? String ?? "未知状态"
        if state == DRStatusStateDone {
            status = "写入完成；尚未验证盘片能否重新挂载和读取。"
            activeBurn = nil
            progressPanel = nil
        } else if state == DRStatusStateFailed {
            let error = info[DRErrorStatusKey] as? NSDictionary
            let detail = error?[DRErrorStatusErrorStringKey] as? String ?? "未知错误"
            status = "刻录失败：\(detail)"
            activeBurn = nil
            progressPanel = nil
        } else {
            let progress = (info[DRStatusPercentCompleteKey] as? NSNumber)?.doubleValue
            status = progress.map { "刻录中：\(state) · \(Int($0 * 100))%" } ?? "刻录中：\(state)"
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in pollBurn() }
        }
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
