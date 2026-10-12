import Foundation

enum OperationEstimateTests {
    static func run() {
        // Live throughput starts at zero and may become unavailable. UI must
        // remain printable instead of trapping when converting Double to Int.
        for value in [Double.nan, Double.infinity, -Double.infinity, -1, Double.greatestFiniteMagnitude] {
            precondition(OperationEstimate.duration(value) == "暂无法估算")
        }
        precondition(OperationEstimate.duration(0) == "不足 1 分钟")
        precondition(OperationEstimate.duration(59.9) == "不足 1 分钟")
        precondition(OperationEstimate.duration(60) == "约 1 分钟")
        precondition(OperationEstimate.duration(61) == "约 2 分钟")
        // Ten GB is an estimate stress case, not a claim of DVD+R capacity.
        for bytes: UInt64 in [0, 1, 1_120_401_929, 10_000_000_000, UInt64.max] {
            for text in [OperationEstimate.size(bytes), OperationEstimate.read(bytes), OperationEstimate.burn(bytes)] {
                precondition(!text.isEmpty && !text.lowercased().contains("nan") && !text.lowercased().contains("inf"))
            }
        }
        print("PASS operation estimates: zero, 1.12 GB, 10 GB, overflow and unavailable throughput")
    }
}
