import SwiftUI

/// Presentation only. Both burn owners keep their own lifecycle and diagnostics;
/// a reported percentage must never be interpreted here as task completion.
struct TaskProgressView: View {
    let message: String
    let fraction: Double?
    let startedAt: Date?
    let remaining: String?
    let speedKBps: Double?

    var body: some View {
        DiscMateSection("当前任务进度") {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.callout).textSelection(.enabled)
                if let fraction, fraction.isFinite, (0...1).contains(fraction) {
                    ProgressView(value: fraction, total: 1)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("当前阶段进度")
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("等待当前阶段进度")
                }
                if let speedKBps {
                    Text(String(format: "当前写入速率 %.1f MB/s", speedKBps / 1000))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let startedAt {
                        Text("已用时")
                        Text(startedAt, style: .timer).monospacedDigit()
                    }
                    Text(remaining.map { "· " + $0 } ?? "· 剩余时间等待设备进度")
                }.font(.caption).foregroundStyle(.secondary)
                Text("请保持光驱连接与供电，等待当前步骤结束。写入、校验和收尾期间请勿强行退出。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
