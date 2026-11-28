import Foundation
import IOKit
import OSLog

// The port is only an in-memory correlation key. Neither it, the registry
// path nor the kernel message is serialised.
struct USBTaskPort: Sendable {
    enum Topology: String, Codable { case direct, hub, unknown }
    let token: String?
    let topology: Topology

    static func resolve(_ path: String) -> Self {
        var node = IORegistryEntryFromPath(kIOMainPortDefault, path)
        var token: String?
        var topology: Topology = .unknown
        while node != 0 {
            if IOObjectConformsTo(node, "IOUSBHostDevice") != 0 {
                if token == nil {
                    guard let location = IORegistryEntryCreateCFProperty(node, "locationID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else {
                        IOObjectRelease(node)
                        break
                    }
                    token = String(format: "@%08x", location.uint32Value)
                } else if (IORegistryEntryCreateCFProperty(node, "bDeviceClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue == 9 {
                    topology = .hub
                    IOObjectRelease(node)
                    break
                }
            }
            if token != nil && IOObjectConformsTo(node, "IOUSBHostController") != 0 {
                topology = .direct
                IOObjectRelease(node)
                break
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent)
            IOObjectRelease(node)
            if result != KERN_SUCCESS { break }
            node = parent
        }
        return Self(token: token, topology: topology)
    }
}

struct USBTaskDiagnostics: Codable, Sendable {
    enum Coverage: String, Codable { case interrupted, pending, portUnknown, unavailable, noMatchingVisibleEvents, observed, truncated }
    enum Signal: String, Codable, CaseIterable {
        case pipeStalled, transactionError, timeout, babbleError, disconnected, reset, enumerated, overcurrent, insufficientPower
    }
    struct Sample: Codable, Sendable {
        let signal: Signal
        let firstUnixMs: Int64
        var lastUnixMs: Int64
        var count: Int
    }
    let topology: USBTaskPort.Topology
    var coverage: Coverage
    var samples: [Sample] = []
    var queryErrorCode: Int?
    private(set) var voltageMeasured = false

    var isValid: Bool {
        !voltageMeasured && samples.count <= 64 && samples.allSatisfy { $0.count > 0 && $0.lastUnixMs >= $0.firstUnixMs }
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    mutating func observe(_ message: String, at date: Date, port: String) {
        let text = message.lowercased()
        guard text.contains(port), let signal = Self.classify(text) else { return }
        let ms = Self.milliseconds(date)
        if samples.last?.signal == signal {
            let i = samples.count - 1
            samples[i].lastUnixMs = ms
            samples[i].count += 1
        } else {
            if samples.count == 64 { samples.remove(at: 1); coverage = .truncated }
            samples.append(Sample(signal: signal, firstUnixMs: ms, lastUnixMs: ms, count: 1))
        }
        if coverage != .truncated { coverage = .observed }
    }

    private static func classify(_ text: String) -> Signal? {
        if text.contains("overcurrent") || text.contains("over-current") || text.contains("over current") { return .overcurrent }
        if text.contains("insufficient power") { return .insufficientPower }
        if text.contains("hardware connection lost") { return .disconnected }
        if text.contains("reset api call") || text.contains("usb reset") { return .reset }
        if text.contains("enumerated ") { return .enumerated }
        if text.contains("(pipe stalled)") { return .pipeStalled }
        if text.contains("(transaction error)") { return .transactionError }
        if text.contains("(timeout)") { return .timeout }
        if text.contains("(babble error)") { return .babbleError }
        return nil
    }

    static func collect(port: USBTaskPort, from start: Date, through end: Date) -> Self {
        var result = Self(topology: port.topology, coverage: .portUnknown)
        guard let token = port.token else { return result }
        do {
            let store = try OSLogStore.local()
            let predicate = NSPredicate(format: "process == %@ AND eventMessage CONTAINS[c] %@", "kernel", token)
            let entries = try store.getEntries(at: store.position(date: start), matching: predicate)
            result.coverage = .noMatchingVisibleEvents
            for (index, entry) in entries.enumerated() {
                if entry.date > end { break }
                if index >= 20000 { result.coverage = .truncated; break }
                if entry.date >= start { result.observe(entry.composedMessage, at: entry.date, port: token) }
            }
        } catch {
            result.coverage = .unavailable
            result.queryErrorCode = (error as NSError).code
        }
        return result
    }
}
