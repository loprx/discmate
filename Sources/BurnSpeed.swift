import Foundation
import CoreFoundation

/// DiscRecording reports speeds in KB/s. Keep the device's actual values;
/// multiplication labels are presentation only, never values sent to hardware.
enum BurnSpeedSelection: Hashable, Sendable {
    case reduced
    case automatic
    case kilobytesPerSecond(Double)

    func label(oneX: Double = 1385, supported: [Double] = []) -> String {
        switch self {
        case .reduced:
            if let speed = BurnSpeedOptions.reduced(supported) {
                return "默认 · " + Self.kilobytesPerSecond(speed).label(oneX: oneX) + "（≤80%）"
            }
            return "默认（最高档的 80% 以内）"
        case .automatic: return "系统最高可用速度"
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
    func requestedSpeed(supported: [Double], panelLimit: Float? = nil) throws -> Float? {
        let request: Float?
        switch self {
        case .reduced:
            guard let speed = BurnSpeedOptions.reduced(supported) else {
                throw BurnSpeedUnavailable(noReducedSpeed: true)
            }
            request = Float(speed)
        case .automatic: request = nil
        case .kilobytesPerSecond(let selected):
            guard selected.isFinite, selected > 0, Float(selected).isFinite,
                  BurnSpeedOptions.normalized(supported).contains(Double(Float(selected))) else {
                throw BurnSpeedUnavailable()
            }
            request = Float(selected)
        }
        guard let panelLimit else { return request }
        guard panelLimit.isFinite, panelLimit > 0 else { throw BurnSpeedUnavailable() }
        if let request, request <= panelLimit { return request }
        if !supported.isEmpty, !BurnSpeedOptions.normalized(supported).contains(Double(panelLimit)) {
            throw BurnSpeedUnavailable()
        }
        return panelLimit
    }
}

struct BurnSpeedUnavailable: LocalizedError {
    var noReducedSpeed = false
    var errorDescription: String? {
        if noReducedSpeed { return "当前光驱和盘片没有报告 80% 以内的档位，请手动选择刻录速率。" }
        return "所选刻录速率已不受当前光驱和盘片支持，未开始刻录。请刷新设备并重新选择速率。"
    }
}

enum BurnSpeedOptions {
    static func reduced(_ values: [Double]) -> Double? {
        let speeds = normalized(values)
        guard let maximum = speeds.last else { return nil }
        return speeds.last { $0 <= maximum * 0.8 }
    }
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
