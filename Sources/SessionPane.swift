import SwiftUI

/// Optional readback, mounting and diagnostics for an already recorded disc.
struct SessionPane: View {
    @ObservedObject var model: SessionModel
    let bsd: String?
    let otherTaskBusy: Bool
    let drivePath: String?
    let recordedMedia: Bool
    @State private var showingAppendFailure = false

    private var locked: Bool { model.blocksDeviceOperations || otherTaskBusy }

    var body: some View {
        DiscMateSection("光盘内容与操作") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if let snapshot = model.snapshot {
                        Text("盘上根目录 \(snapshot.rootEntries.count) 项 · 共 \(snapshot.fileEntries.count) 个文件、\(snapshot.directoryPaths.count) 个目录")
                        Spacer()
                        if let writable = snapshot.writable, snapshot.appendable {
                            Text("可用约 \(OperationEstimate.size(UInt64(writable.freeBlocks) * 2048))")
                        } else if snapshot.incompleteSession {
                            Text("第 \(snapshot.latest.session) 会话未封闭；暂停追加（不代表盘片报废）")
                                .foregroundStyle(.orange)
                        } else { Text("当前状态不支持追加").foregroundStyle(.orange) }
                    } else {
                        Text("盘上文件：等待识别光盘")
                        Spacer()
                        Text("剩余空间待识别").foregroundStyle(.secondary)
                    }
                }.font(.callout)
                ScrollView {
                    if let snapshot = model.snapshot {
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
                    } else {
                        Text("放入已有数据的光盘后，这里显示盘上文件；空白盘或无盘时列表为空。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 82, alignment: .center)
                    }
                }
                .frame(height: 88)
                .accessibilityLabel("盘上已有文件列表")

                Text(recordedMedia ? model.message : "已有数据盘识别完成后，可在访达打开最新内容或执行读回校验。")
                    .font(.callout).textSelection(.enabled)
                if model.isBusy {
                    if let fraction = model.progressFraction { ProgressView(value: fraction) }
                    if model.phase == .burning, let speed = model.actualBurnSpeedKBps {
                        Text(String(format: "当前写入速率 %.1f MB/s", speed / 1000)).font(.caption).foregroundStyle(.secondary)
                    }
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
                        .disabled(locked || !recordedMedia || (model.snapshot == nil && bsd == nil) || model.snapshot?.incompleteSession == true)
                        .help(model.snapshot?.incompleteSession == true
                              ? "末次会话未封闭，不能正常挂载；可使用只读校验读取已记录文件。"
                              : "只读挂载最新会话，可能需要 macOS 管理员授权；通常数秒，系统忙时可能更久。不会逐个读取或校验文件。请等待打开完成后再推出。")
                }
                Text(model.snapshot?.incompleteSession == true
                     ? "末次会话未封闭：已记录文件可只读检查，但最新会话不能在访达正常挂载，也不能继续追加。"
                     : "macOS 默认可能显示较早内容。使用“在访达打开最新内容”只读打开最新会话；会自动检查目录，不完整读取文件正文。读回和挂载后不会自动弹盘，取盘请点击页面顶部的“正常推出”。")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("可选：读回校验").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("日常追加无需完整读取旧内容。独立读回需先合仓并刷新设备；校验期间保持光驱连接。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("只校验本次新增文件") { model.verifyRecorded(addedOnly: true, bsd: bsd) }
                                .disabled(locked || !recordedMedia || (model.snapshot == nil && bsd == nil) || !model.canVerifyAdded)
                                .help("按本次源清单计算新增文件 SHA-256，并检查目录和旧区段；不读取旧正文。若仅追加空目录，只检查目录，不执行文件哈希。")
                            Text(model.canVerifyAdded
                                 ? "\(OperationEstimate.size(model.addedVerificationBytes)) · \(OperationEstimate.read(model.addedVerificationBytes))"
                                 : "需载入本次新增文件的源清单")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("完整读取所有文件") { model.verifyRecorded(bsd: bsd) }
                                .disabled(locked || !recordedMedia || (model.snapshot == nil && bsd == nil))
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("更多工具与诊断").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("重新识别目录") { model.inspect(bsd: bsd) }
                                .disabled(locked || !recordedMedia || bsd == nil)
                                .help("只读查询介质、最新会话与目录，通常数秒；不扫描旧文件正文，不刻录。已有摘要会失效。")
                            Button("观察光驱状态（45 秒）") { model.checkDeviceNotifications(path: drivePath) }
                                .disabled(locked || drivePath == nil)
                                .help("只读观察系统设备通知 45 秒，用于故障诊断。期间其他设备操作暂停；不会刻录或推出。")
                            Button("显示已挂载内容") { model.reveal() }
                                .disabled(locked || model.mountedURL == nil)
                                .help("在访达显示已确认的挂载目录，通常立即完成；不重新挂载、不校验。")
                        }
                        Text(model.snapshot.map { "DVD+R · ISO\($0.volume.joliet ? "/Joliet" : "") · 最新会话 \($0.latest.session)" }
                             ?? "盘型与会话待识别")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
        .onChange(of: model.appendPreparationFailure) { showingAppendFailure = $0 != nil }
        .alert("无法准备追加", isPresented: $showingAppendFailure) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("\(model.appendPreparationFailure ?? "")\n\n本次没有写入光盘。请调整待刻录列表后重新查看摘要。")
        }
    }

    private func recordedMetadata(_ entry: ISOEntry, in snapshot: SessionSnapshot) -> String {
        let kind = entry.directory ? "文件夹" : "文件"
        let size = OperationEstimate.size(UInt64(entry.bytes))
        let session = snapshot.tracks.first(where: { $0.contains(entry.lba, bytes: entry.bytes) })?.session
        return [kind, size, session.map { "第 \($0) 会话" }].compactMap { $0 }.joined(separator: " · ")
    }
}
