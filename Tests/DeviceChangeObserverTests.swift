import Foundation
import DiscRecording

enum DeviceChangeObserverTests {
    static func run() {
        func state(busy: Bool = false, media: String = DRDeviceMediaStateMediaPresent,
                   bsd: String = "disk-test", speeds: [Int] = [5540, 11080], progress: Double = 0) -> DeviceChangeSnapshot {
            DeviceChangeSnapshot([DRDeviceIsBusyKey: busy, DRDeviceIsTrayOpenKey: false,
                DRDeviceMediaStateKey: media, DRDeviceCurrentWriteSpeedKey: progress,
                DRDeviceMediaInfoKey: [DRDeviceMediaBSDNameKey: bsd, DRDeviceMediaIsBlankKey: true,
                    DRDeviceBurnSpeedsKey: speeds]])
        }
        var gate = DeviceChangeGate()
        precondition(!gate.consume(), "No polling or initial synthetic events")
        gate.appeared("drive")
        gate.statusChanged("drive", snapshot: state())
        precondition(gate.consume())
        gate.appeared("drive")
        gate.statusChanged("drive", snapshot: state(speeds: [11080, 5540, 5540], progress: 4000))
        precondition(!gate.consume(), "Duplicate notification/current speed must not cause refresh loops")
        gate.setSuspended(true)
        gate.statusChanged("drive", snapshot: state(busy: true))
        gate.statusChanged("drive", snapshot: state())
        precondition(gate.pending && !gate.consume(), "Idle event does not release external recovery lock")
        gate.setSuspended(false)
        precondition(gate.consume() && !gate.consume(), "One merged refresh on explicit unlock")
        gate.statusChanged("drive", snapshot: state(busy: true))
        precondition(!gate.consume(), "No inventory queries while device is busy")
        gate.statusChanged("drive", snapshot: state(media: DRDeviceMediaStateInTransition))
        precondition(!gate.consume(), "Wait for actual media-ready event")
        gate.statusChanged("drive", snapshot: state(bsd: "disk-reinserted"))
        precondition(gate.consume(), "Media-node changes refresh after transition")
        gate.statusChanged("drive", snapshot: state(speeds: [5540]))
        precondition(gate.consume(), "Late arriving capability data refreshes speed choices")
        gate.statusChanged("drive", snapshot: state(busy: true))
        gate.disappeared("drive")
        precondition(gate.consume(), "Disconnected busy device cannot permanently block inventory")
        print("PASS device events: deduplication, task/recovery locks, busy transitions, media/speed changes")
    }
}
