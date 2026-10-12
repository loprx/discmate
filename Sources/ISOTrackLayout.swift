import Foundation
import DiscRecording

/// Uses Apple's documented image producer instead of inventing an address unit
/// for custom track callbacks. This creates no device or burn job.
enum ISOTrackLayout {
    static func load(_ image: URL, bytes: UInt64) throws -> DRTrack {
        guard bytes > 0, bytes % 2048 == 0, let layout = DRBurn.layout(forImageFile: image.path) else {
            throw DiscFailure("系统无法读取增量 ISO 镜像布局。")
        }
        func flatten(_ object: Any, depth: Int = 0) throws -> [DRTrack] {
            guard depth <= 4 else { throw DiscFailure("镜像布局嵌套过深。") }
            if let track = object as? DRTrack { return [track] }
            guard let array = object as? [Any] else { throw DiscFailure("镜像包含无法识别的轨道对象。") }
            return try array.flatMap { try flatten($0, depth: depth + 1) }
        }
        let tracks = try flatten(layout)
        guard tracks.count == 1,
              let properties = tracks[0].properties(),
              (properties[DRTrackLengthKey] as? NSNumber)?.uint64Value == bytes / 2048,
              properties[DRVerificationTypeKey] as? String == DRVerificationTypeProduceAgain else {
            throw DiscFailure("系统镜像轨道长度或校验方式不符合预期。")
        }
        return tracks[0]
    }
}
