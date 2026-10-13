import SwiftUI

/// The normal append path is metadata inspection → local preparation → review.
/// Readback and engineering diagnostics remain explicit, optional actions.
struct SessionPane: View {
    @ObservedObject var model: SessionModel
    let bsd: String?
    let otherTaskBusy: Bool
    let sources: [URL]
    let drivePath: String?
    var offersAppend = true
    @State private var showVerification = false
    @State private var showDiagnostics = false

    private var locked: Bool { model.blocksDeviceOperations || otherTaskBusy }

    var body: some View {
        DiscMateSection(offersAppend ? "2 · 查看摘要并追加" : "光盘内容与操作") {
            VStack(alignment: .leading, spacing: 12) {
                if offersAppend {
                    Text("标准追加只检查旧目录与区段，不重新读取旧文件正文；写入后由系统校验本次镜像。")
                        .font(.callout)
                    if let plan = model.incrementalPlan {
                        HStack(alignment: .top, spacing: 24) {
                            summary("保留旧内容", "\(model.snapshot?.rootEntries.count ?? 0) 个文件 · \(OperationEstimate.size(plan.referencedBytes))")
                            summary("本次写入", OperationEstimate.size(plan.imageBytes))
                        }
                        Text(OperationEstimate.burn(plan.imageBytes)).font(.caption).foregroundStyle(.secondary)
                        Text("旧内容沿用原区段；此摘要不表示旧文件正文已重新校验。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("先在本机准备新增文件，再显示实际占用空间；这一步不写光盘，通常数秒至数分钟，大文件需要更久。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(model.incrementalPlan == nil ? "查看追加摘要" : "开始追加…") {
                            if model.incrementalPlan == nil { model.prepareIncremental(sources: sources, bsd: bsd) }
                            else { model.burnIncremental() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(locked || sources.isEmpty || bsd == nil || (model.incrementalPlan != nil && !model.incrementalWriteEnabled))
                        .help(model.incrementalPlan == nil
                              ? "读取光盘目录并暂存新增文件，生成空间与耗时摘要；不写盘、不完整读取旧内容。"
                              : "确认后永久占用光盘空间。写入、系统校验和收尾期间请勿断开光驱或强行退出。")
                        if model.incrementalPlan != nil { Text("开始前还会确认一次").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("当前追加范围：DVD+R、ISO/Joliet、根目录普通文件，单文件小于 4 GiB；不支持重名覆盖或文件夹追加。自动收尾稳定性仍在验证。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let snapshot = model.snapshot {
                    HStack {
                        Text("盘上已有 \(snapshot.rootEntries.count) 个项目")
                        Spacer()
                        if let writable = snapshot.writable, snapshot.appendable {
                            Text("可用约 \(OperationEstimate.size(UInt64(writable.freeBlocks) * 2048))")
                        } else { Text("此盘目前不可追加").foregroundStyle(.orange) }
                    }.font(.callout)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(snapshot.rootEntries.enumerated()), id: \.offset) { item in
                                let entry = item.element
                                HStack(spacing: 10) {
                                    Image(systemName: entry.directory ? "folder" : "doc")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.name).lineLimit(1).help(entry.name)
                                        Text(recordedMetadata(entry, in: snapshot))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .padding(.vertical, 7)
                                Divider()
                            }
                        }
                    }
                    .frame(height: min(220, max(54, CGFloat(snapshot.rootEntries.count) * 54)))
                    .accessibilityLabel("盘上已有文件列表")
                }

                Text(model.message).font(.callout).textSelection(.enabled)
                if model.isBusy {
                    if let fraction = model.progressFraction { ProgressView(value: fraction) }
                    else { ProgressView().controlSize(.small) }
                    HStack {
                        if let start = model.taskStartedAt {
                            Text("已用时")
                            Text(start, style: .timer).monospacedDigit()
                        }
                        if let remaining = model.remainingEstimate { Text("· 预计剩余 \(remaining)") }
                        else { Text("· 剩余时间等待设备进度") }
                    }.font(.caption).foregroundStyle(.secondary)
                    Text("请保持光驱连接与供电，等待当前步骤结束。写入及收尾期间请勿强行退出；当前追加不支持安全中途取消。")
                        .font(.caption).foregroundStyle(.orange)
                }

                HStack {
                    Button("在访达打开最新内容") { model.openLatest(bsd: bsd) }
                        .disabled(locked || (model.snapshot == nil && bsd == nil))
                        .help("只读挂载最新会话，可能需要 macOS 管理员授权；通常数秒，系统忙时可能更久。不会逐个读取或校验文件。请等待打开完成后再推出。")
                    Button("正常推出") { model.ejectNormally(drivePath: drivePath, bsd: bsd) }
                        .disabled(locked || bsd == nil || drivePath == nil)
                        .help("先正常卸载，再请求推出，并等待约 15 秒确认介质移除。不会刻录或强制卸载；请等托盘实际弹出。")
                }
                Text("macOS 默认可能显示较早内容。使用“在访达打开最新内容”只读打开最新会话；会自动检查目录，不完整读取文件正文。")
                    .font(.caption).foregroundStyle(.secondary)

                ExpandableSection("可选：读回校验", isExpanded: $showVerification) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("日常追加无需完整读取旧内容。独立读回需先合仓并刷新设备；校验期间保持光驱连接。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("只校验本次新增文件") { model.verifyRecorded(addedOnly: true, bsd: bsd) }
                                .disabled(locked || (model.snapshot == nil && bsd == nil) || !model.canVerifyAdded)
                                .help("按本次源清单计算新增文件 SHA-256，并检查旧文件目录和区段；不读取旧正文。")
                            if model.canVerifyAdded {
                                Text("\(OperationEstimate.size(model.addedVerificationBytes)) · \(OperationEstimate.read(model.addedVerificationBytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("完整读取所有文件") { model.verifyRecorded(bsd: bsd) }
                                .disabled(locked || (model.snapshot == nil && bsd == nil))
                                .help("只读遍历最新会话全部文件并计算 SHA-256；仅有源清单的文件可比对源哈希。10 GB 可能需几十分钟至数小时。")
                            if model.snapshot != nil {
                                Text("\(OperationEstimate.size(model.verificationBytes)) · \(OperationEstimate.read(model.verificationBytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("检查目录后估算读取量；耗时随盘上数据量增加。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("载入历史校验清单…") { model.loadExpectedProof() }
                            .disabled(locked)
                            .help("打开本机 JSON 源清单供后续只读比对；通常立即完成，不访问或写入光盘。")
                        Text("无源哈希的旧文件只能检查可读性并生成本次哈希，不能称为与原文件一致。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                ExpandableSection("更多工具与诊断", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("重新识别目录") { model.inspect(bsd: bsd) }
                                .disabled(locked || bsd == nil)
                                .help("只读查询介质、最新会话与目录，通常数秒；不扫描旧文件正文，不刻录。已有摘要会失效。")
                            Button("观察光驱状态（45 秒）") { model.checkDeviceNotifications(path: drivePath) }
                                .disabled(locked || drivePath == nil)
                                .help("只读观察系统设备通知 45 秒，用于故障诊断。期间其他设备操作暂停；不会刻录或推出。")
                            Button("显示已挂载内容") { model.reveal() }
                                .disabled(locked || model.mountedURL == nil)
                                .help("在访达显示已确认的挂载目录，通常立即完成；不重新挂载、不校验。")
                        }
                        if let snapshot = model.snapshot {
                            Text("DVD+R · ISO\(snapshot.volume.joliet ? "/Joliet" : "") · 最新会话 \(snapshot.latest.session)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 8)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
    }

    private func recordedMetadata(_ entry: ISOEntry, in snapshot: SessionSnapshot) -> String {
        let kind = entry.directory ? "文件夹" : "文件"
        let size = OperationEstimate.size(UInt64(entry.bytes))
        let session = snapshot.tracks.first(where: { $0.contains(entry.lba, bytes: entry.bytes) })?.session
        return [kind, size, session.map { "第 \($0) 会话" }].compactMap { $0 }.joined(separator: " · ")
    }
}
