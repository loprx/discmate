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
                    "日常追加不会完整读取旧文件正文。需要进一步检查时，在“可选：读回校验”里选择只校验新增文件或完整读取所有文件。完整读取大盘可能很久。"
                ])

                section("遇到问题", [
                    "刻录中不要拔 USB、强行退出或重复点击操作。当前追加流程不支持安全中途取消。",
                    "如果没有自动弹出，先等设备停止忙碌，再使用“正常推出”；若仍无效，可在访达对光盘点“推出”。",
                    "换盘或重新接入光驱后请重新刷新，不沿用旧会话信息；若设备持续忙碌，停止新增写入。"
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
