import Foundation
import Combine
import DiscRecording

/// Values copied from notification userInfo. Never calls DRDevice.status(), which
/// would turn observation into another device operation and can feed notifications
/// back into enumeration. Changing write progress/speed alone is not a refresh.
struct DeviceChangeSnapshot: Equatable {
    var mediaState: String?
    var busy: Bool?
    var trayOpen: Bool?
    var bsdName: String?
    var mediaType: String?
    var blank: Bool?
    var appendable: Bool?
    var burnSpeeds: [Double]

    init(_ info: [AnyHashable: Any]) {
        let media = info[DRDeviceMediaInfoKey] as? [AnyHashable: Any] ?? [:]
        mediaState = info[DRDeviceMediaStateKey] as? String
        busy = (info[DRDeviceIsBusyKey] as? NSNumber)?.boolValue
        trayOpen = (info[DRDeviceIsTrayOpenKey] as? NSNumber)?.boolValue
        bsdName = media[DRDeviceMediaBSDNameKey] as? String
        mediaType = media[DRDeviceMediaTypeKey] as? String
        blank = (media[DRDeviceMediaIsBlankKey] as? NSNumber)?.boolValue
        appendable = (media[DRDeviceMediaIsAppendableKey] as? NSNumber)?.boolValue
        let values = (media[DRDeviceBurnSpeedsKey] ?? info[DRDeviceBurnSpeedsKey]) as? [NSNumber] ?? []
        burnSpeeds = Array(Set(values.map(\.doubleValue).filter { $0.isFinite && $0 > 0 })).sorted()
    }
}

/// Pure event gate: pending events survive an application task/recovery lock.
/// Unlocking never changes the task or its recovery status; it only permits the
/// caller's existing, serialized inventory refresh once a meaningful event exists.
struct DeviceChangeGate {
    private var connected: Set<String> = []
    private var snapshots: [String: DeviceChangeSnapshot] = [:]
    private(set) var pending = false
    private(set) var suspended = false

    var canDeliver: Bool {
        pending && !suspended && !snapshots.values.contains { $0.busy == true || $0.mediaState == DRDeviceMediaStateInTransition }
    }
    var waitingForBusy: Bool {
        snapshots.values.contains { $0.busy == true || $0.mediaState == DRDeviceMediaStateInTransition }
    }

    mutating func setSuspended(_ value: Bool) { suspended = value }

    @discardableResult mutating func appeared(_ id: String) -> Bool {
        let new = connected.insert(id).inserted
        if new { pending = true }
        return new
    }

    mutating func disappeared(_ id: String) {
        connected.remove(id)
        snapshots.removeValue(forKey: id)
        pending = true
    }

    @discardableResult mutating func statusChanged(_ id: String, snapshot: DeviceChangeSnapshot) -> Bool {
        connected.insert(id)
        guard snapshots[id] != snapshot else { return false }
        snapshots[id] = snapshot
        pending = true
        return true
    }

    mutating func consume() -> Bool {
        guard canDeliver else { return false }
        pending = false
        return true
    }
}

/// Passive DiscRecording events on the main run loop. There is no periodic timer,
/// enumeration, status query, media reservation, raw read, or device command here.
///
/// Integration: keep one StateObject for the app; start on appearance, stop on
/// disappearance. Set suspended whenever any task, refresh, or recovery lock owns
/// the device. On revision change request the existing serialized refresh path.
/// Keep that path's normal guards; this notification is not evidence of safety or
/// successful physical eject. Initial registration delivers existing devices.
@MainActor
final class DeviceChangeObserver: NSObject, ObservableObject {
    static let shared = DeviceChangeObserver()
    struct Delivery {
        var appeared = 0
        var disappeared = 0
        var status = 0
        var duplicate = 0
        var deferredByTask = false
        var deferredByBusy = false
    }
    @Published private(set) var revision: UInt64 = 0
    private(set) var lastDelivery = Delivery()
    private var center: DRNotificationCenter?
    private var gate = DeviceChangeGate()
    private var delivery: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var pendingDelivery = Delivery()

    func start() {
        guard center == nil, let center = DRNotificationCenter.currentRunLoop() else { return }
        self.center = center
        center.addObserver(self, selector: #selector(receive(_:)), name: Notification.Name.DRDeviceAppeared.rawValue, object: nil)
        center.addObserver(self, selector: #selector(receive(_:)), name: Notification.Name.DRDeviceDisappeared.rawValue, object: nil)
        center.addObserver(self, selector: #selector(receive(_:)), name: Notification.Name.DRDeviceStatusChanged.rawValue, object: nil)
    }

    func stop() {
        delivery?.cancel()
        delivery = nil
        generation &+= 1
        unregister()
        let suspended = gate.suspended
        gate = DeviceChangeGate()
        gate.setSuspended(suspended)
        pendingDelivery = Delivery()
    }

    func setSuspended(_ suspended: Bool) {
        gate.setSuspended(suspended)
        scheduleDelivery()
    }

    @objc private func receive(_ note: Notification) {
        guard center != nil, let device = note.object as? DRDevice else { return }
        let id = String(describing: ObjectIdentifier(device))
        switch note.name {
        case .DRDeviceAppeared:
            if gate.appeared(id) { pendingDelivery.appeared = min(100_000, pendingDelivery.appeared + 1) }
            else { pendingDelivery.duplicate = min(100_000, pendingDelivery.duplicate + 1) }
        case .DRDeviceDisappeared:
            gate.disappeared(id); pendingDelivery.disappeared = min(100_000, pendingDelivery.disappeared + 1)
        case .DRDeviceStatusChanged:
            guard let info = note.userInfo else { return }
            if gate.statusChanged(id, snapshot: DeviceChangeSnapshot(info)) {
                pendingDelivery.status = min(100_000, pendingDelivery.status + 1)
            } else { pendingDelivery.duplicate = min(100_000, pendingDelivery.duplicate + 1) }
        default: return
        }
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        // A single finite coalescing delay, started by events only. Repeated identical
        // status notifications neither deliver more revisions nor reset the delay.
        guard gate.canDeliver else {
            if gate.pending {
                pendingDelivery.deferredByTask = pendingDelivery.deferredByTask || gate.suspended
                pendingDelivery.deferredByBusy = pendingDelivery.deferredByBusy || gate.waitingForBusy
            }
            delivery?.cancel()
            delivery = nil
            generation &+= 1
            return
        }
        guard delivery == nil else { return }
        generation &+= 1
        let expected = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expected else { return }
            self.delivery = nil
            guard self.center != nil, self.gate.consume() else { return }
            self.lastDelivery = self.pendingDelivery
            self.pendingDelivery = Delivery()
            self.revision &+= 1
        }
        delivery = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func unregister() {
        guard let center else { return }
        center.removeObserver(self, name: Notification.Name.DRDeviceAppeared.rawValue, object: nil)
        center.removeObserver(self, name: Notification.Name.DRDeviceDisappeared.rawValue, object: nil)
        center.removeObserver(self, name: Notification.Name.DRDeviceStatusChanged.rawValue, object: nil)
        self.center = nil
    }

    deinit {
        delivery?.cancel()
        if let center {
            center.removeObserver(self, name: Notification.Name.DRDeviceAppeared.rawValue, object: nil)
            center.removeObserver(self, name: Notification.Name.DRDeviceDisappeared.rawValue, object: nil)
            center.removeObserver(self, name: Notification.Name.DRDeviceStatusChanged.rawValue, object: nil)
        }
    }
}
