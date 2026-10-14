import Foundation
import CoreFoundation

/// DiscRecording reports speeds in KB/s. Keep the device's actual values;
/// multiplication labels are presentation only, never values sent to hardware.
enum BurnSpeedSelection: Hashable, Sendable {
    case automatic
    case kilobytesPerSecond(Double)

    func label(oneX: Double = 1385) -> String {
        switch self {
        case .automatic: return "自动（系统最高可用速度）"
        case .kilobytesPerSecond(let speed):
            guard oneX.isFinite, oneX > 0 else { return String(format: "%.0f KB/s", speed) }
            let multiple = speed / oneX
            let multiplier = abs(multiple.rounded() - multiple) < 0.02
                ? String(format: "%.0f", multiple) : String(format: "%.1f", multiple)
            return "\(multiplier)×（\(String(format: "%.1f", speed / 1000)) MB/s）"
        }
    }

    /// nil means the caller explicitly requests DRDeviceBurnSpeedMax.
    /// A disappeared manual choice must fail before writeLayout, never silently
    /// fall back to a faster or slower setting after a media change.
    func requestedSpeed(supported: [Double]) throws -> Float? {
        switch self {
        case .automatic: return nil
        case .kilobytesPerSecond(let selected):
            guard selected.isFinite, selected > 0, Float(selected).isFinite,
                  BurnSpeedOptions.normalized(supported).contains(Double(Float(selected))) else {
                throw BurnSpeedUnavailable()
            }
            return Float(selected)
        }
    }
}

struct BurnSpeedUnavailable: LocalizedError {
    var errorDescription: String? { "所选刻录速率已不受当前光驱和盘片支持，未开始刻录。请刷新设备并重新选择速率。" }
}

enum BurnSpeedOptions {
    /// The live macOS status dictionary nests speed capabilities under media
    /// info, despite older SDK prose describing a top-level status key. Prefer
    /// that media-specific list; accept top-level layout only when absent.
    static func values(fromStatus status: NSDictionary) -> [Double] {
        if let media = status["DRDeviceMediaInfoKey"] as? NSDictionary,
           let raw = media["DRDeviceBurnSpeedsKey"] {
            return values(from: raw)
        }
        return values(from: status["DRDeviceBurnSpeedsKey"])
    }

    static func normalized(_ values: [Double]) -> [Double] {
        Array(Set(values.compactMap { value -> Double? in
            guard value.isFinite, value > 0, Float(value).isFinite, Float(value) > 0 else { return nil }
            return Double(Float(value))
        })).sorted()
    }

    /// Accept only numeric entries from cached DRDeviceBurnSpeedsKey. Missing
    /// support metadata leaves automatic available without inventing 2x/4x.
    static func values(from raw: Any?) -> [Double] {
        guard let values = raw as? [Any] else { return [] }
        return normalized(values.compactMap { value in
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        })
    }
}
