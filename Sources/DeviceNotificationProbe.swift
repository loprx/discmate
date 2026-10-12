import Foundation
import DiscRecording

/// A bounded, read-only check of the notification transport used by the new
/// burner. No raw sector reads or media-changing operations. One status query.
enum DeviceNotificationProbe {
    static func events(path: String) -> AsyncStream<String> {
        AsyncStream { output in
            Thread {
                autoreleasepool {
                    let observer = Observer(path: path, output: output)
                    observer.run()
                }
                output.finish()
            }.start()
        }
    }
    private final class Observer: NSObject {
        let path: String
        let output: AsyncStream<String>.Continuation
        var appeared = false
        var changes = 0
        var center: DRNotificationCenter?
        init(path: String, output: AsyncStream<String>.Continuation) { self.path = path; self.output = output }

        func run() {
            guard let center = DRNotificationCenter.currentRunLoop() else { output.yield("无法建立设备通知。"); return }
            self.center = center
            center.addObserver(self, selector: #selector(receive(_:)), name: NSNotification.Name.DRDeviceAppeared.rawValue, object: nil)
            center.addObserver(self, selector: #selector(receive(_:)), name: NSNotification.Name.DRDeviceStatusChanged.rawValue, object: nil)
            defer {
                center.removeObserver(self, name: NSNotification.Name.DRDeviceAppeared.rawValue, object: nil)
                center.removeObserver(self, name: NSNotification.Name.DRDeviceStatusChanged.rawValue, object: nil)
            }
            let timer = Timer(timeInterval: 1, repeats: true) { _ in }
            RunLoop.current.add(timer, forMode: .default)
            defer { timer.invalidate() }
            let end = ProcessInfo.processInfo.systemUptime + 45
            while ProcessInfo.processInfo.systemUptime < end {
                autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1)) }
            }
            output.yield(appeared ? "通知通道已收到目标光驱；状态变化通知 \(changes) 次。检查结束，未操作盘片。" : "45 秒内未收到目标光驱通知；结束判据尚不能用于实盘。")
        }
        @objc private func receive(_ note: Notification) {
            guard let device = note.object as? DRDevice, device.ioRegistryEntryPath() == path else { return }
            if note.name == .DRDeviceAppeared {
                guard !appeared else { return }
                appeared = true
                output.yield("收到光驱出现通知，后台 RunLoop 通道可用。")
                if let status = device.status() { describe(status, source: "一次基线查询") }
            } else {
                changes += 1
                if let status = note.userInfo { describe(status, source: "状态通知") }
            }
        }
        private func describe(_ status: [AnyHashable: Any], source: String) {
            let media = status[DRDeviceMediaStateKey] as? String ?? "unknown"
            let busy = (status[DRDeviceIsBusyKey] as? NSNumber)?.stringValue ?? "unknown"
            let tray = (status[DRDeviceIsTrayOpenKey] as? NSNumber)?.stringValue ?? "unknown"
            output.yield("\(source)：media=\(media) busy=\(busy) trayOpen=\(tray)")
        }
    }
}
