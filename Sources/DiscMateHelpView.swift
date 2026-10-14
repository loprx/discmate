import SwiftUI

struct DiscMateHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("DiscMate 使用帮助") { openWindow(id: "discmate-help") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

struct DiscMateHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("DiscMate 使用帮助").font(.largeTitle.bold())
                Text("当前已实盘验证的追加范围：DVD+R、ISO 9660/Joliet、根目录普通文件。其他盘型和文件夹追加尚未验证。")
                    .foregroundStyle(.secondary)

                section("首次刻录", [
                    "放入空白盘并点击“刷新设备”。确认刻录机和盘片状态后，添加文件。",
                    "需要以后继续添加文件时，保持“保留后续追加能力”开启，再点击“开始刻录”。",
                    "可选择当前盘片支持的刻录速率；自动请求系统最高可用速度。未提供档位时不显示猜测的倍速，实际速度由设备调整。其他刻录类型可在系统设置窗口选择速度。",
                    "确认窗口会说明本次写入；写入、系统校验和收尾期间不要断开光驱或电源。"
                ])

                section("向已有数据盘追加", [
                    "合仓后点击“刷新设备”。界面显示“已有数据光盘”时，添加要新增的普通文件。旧文件无需重新添加。",
                    "点击“查看追加摘要”，检查新增文件、旧目录、空间及预计耗时；确认后点击“开始追加”。",
                    "写入会占用新的盘片空间，不能覆盖同名文件。单个新增文件和新会话镜像均须小于 4 GiB。"
                ])

                section("完成与读取", [
                    "“系统任务已结束”只表示写入和系统校验报告完成。请等应用确认设备收尾，并确认托盘实际弹出。",
                    "重新合仓后点击“刷新设备”。如访达只显示旧会话，点击“在访达打开最新内容”；此操作可能要求管理员授权。",
                    "日常追加不会完整读取旧文件正文。需要进一步检查时，在“可选：读回校验”里选择只校验新增文件或完整读取所有文件。完整读取大盘可能很久。读回和挂载后不会自动弹盘，取盘请点击“正常推出”。"
                ])

                section("遇到问题", [
                    "刻录中不要拔 USB、强行退出或重复点击操作。当前追加流程不支持安全中途取消。",
                    "若显示需要恢复且任务已结束，点击“重新检查设备”。检查只读取状态，通常数秒；设备空闲且身份稳定才会恢复操作，并保留源清单供读回核验。多台光驱时按提示选择恢复目标。",
                    "若显示系统查询仍未返回，请继续等待。此时刷新暂不可用，不会另开查询；恢复检查失败后可待设备稳定再次检查，无需为了清除界面锁重启应用。",
                    "如果没有自动弹出，先等设备停止忙碌，再使用“正常推出”；若仍无效，可在访达对光盘点“推出”。",
                    "换盘或重新接入光驱后请重新刷新，不沿用旧会话信息；若设备持续忙碌，停止新增写入。"
                ])
                section("进度与诊断日志", [
                    "主界面显示写入、系统校验和收尾阶段。百分比可用时显示进度条；剩余时间仅为当前阶段估计，不代表整轮即将结束。",
                    "点击“导出脱敏诊断日志”，选择任务、预览后保存 JSON。记录版本、阶段、耗时、数字错误码、速度和已取得的设备状态；不会访问光驱或自动上传。",
                    "导出不含文件名、路径、正文、盘片标识或凭据。仅记录启用该功能后的任务，无法补录旧版没有采集的信息。未知信息不等于正常；后端完成不等于物理推出或读回校验通过。"
                ])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private func section(_ title: String, _ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold())
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
