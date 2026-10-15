import Foundation

/// Planning ranges, not deadlines. Optical firmware may take longer to close
/// a session; only measured progress is used for a live remaining-time estimate.
enum OperationEstimate {
    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "暂无法估算" }
        return seconds < 60 ? "不足 1 分钟" : "约 \(Int(ceil(seconds / 60))) 分钟"
    }
    static func read(_ bytes: UInt64) -> String {
        "约 \(max(1, Int(ceil(Double(bytes) / 8_000_000 / 60))))–\(max(2, Int(ceil(Double(bytes) / 1_000_000 / 60)))) 分钟（按 1–8 MB/s 估算，坏盘可能更久）"
    }
    static func burn(_ bytes: UInt64, verifyAfterWrite: Bool = false) -> String {
        let passes = verifyAfterWrite ? 2.0 : 1.0
        let minutes = Double(bytes) / 5_540_000 * passes / 60
        return "约 \(max(1, Int(ceil(minutes + 1))))–\(max(3, Int(ceil(minutes * 2 + 3)))) 分钟（4× DVD 写入\(verifyAfterWrite ? "、系统校验" : "")及收尾估算）"
    }
}
