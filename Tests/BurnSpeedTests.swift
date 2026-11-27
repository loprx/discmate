import Foundation

enum BurnSpeedTests {
    static func run() throws {
        let speeds = BurnSpeedOptions.values(from: [NSNumber(value: 5540), NSNumber(value: 11080), NSNumber(value: 5540),
            NSNumber(value: -1), NSNumber(value: 0), NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
            NSNumber(value: true), "16620"] as [Any])
        precondition(speeds == [5540, 11080])
        let actualStatus: NSDictionary = ["DRDeviceMaximumWriteSpeedKey": 11080,
            "DRDeviceMediaInfoKey": ["DRDeviceBurnSpeedsKey": [5540, 11080]]]
        precondition(BurnSpeedOptions.values(fromStatus: actualStatus) == [5540, 11080])
        precondition(BurnSpeedOptions.values(fromStatus: ["DRDeviceBurnSpeedsKey": [5540]]) == [5540])
        precondition(BurnSpeedOptions.values(fromStatus: ["DRDeviceMediaInfoKey": ["DRDeviceBurnSpeedsKey": []],
            "DRDeviceBurnSpeedsKey": [11080]]).isEmpty)
        precondition(BurnSpeedOptions.values(fromStatus: ["DRDeviceMaximumWriteSpeedKey": 11080]).isEmpty)
        precondition(BurnSpeedOptions.values(from: nil).isEmpty)
        precondition(BurnSpeedOptions.normalized([Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude]).isEmpty)
        let automatic = try BurnSpeedSelection.automatic.requestedSpeed(supported: [])
        precondition(automatic == nil)
        let reduced = BurnSpeedSelection.reduced
        let dvd = [4, 6, 8].map { Double($0 * 1385) }
        let sixX = try reduced.requestedSpeed(supported: dvd)
        precondition(sixX == Float(6 * 1385))
        let exact = try reduced.requestedSpeed(supported: [10, 2, 8, 8])
        precondition(exact == 8)
        let lowerPanel = try reduced.requestedSpeed(supported: dvd, panelLimit: 5540)
        let higherPanel = try reduced.requestedSpeed(supported: dvd, panelLimit: 11080)
        precondition(lowerPanel == 5540 && higherPanel == sixX)
        for unsupported: [Double] in [[], [8], [7, 8], [.nan, 0]] {
            do {
                _ = try reduced.requestedSpeed(supported: unsupported)
                preconditionFailure("Missing lower speed must not request maximum")
            } catch let error as BurnSpeedUnavailable { precondition(error.noReducedSpeed) }
        }
        let manualMax = try BurnSpeedSelection.kilobytesPerSecond(8).requestedSpeed(supported: [8])
        precondition(manualMax == 8)
        let manual = try BurnSpeedSelection.kilobytesPerSecond(5540).requestedSpeed(supported: speeds)
        precondition(manual == 5540)
        for value in [Double.nan, Double.infinity, -1, 0, 16620] {
            do {
                _ = try BurnSpeedSelection.kilobytesPerSecond(value).requestedSpeed(supported: speeds)
                preconditionFailure("Invalid or stale speed must not silently fall back")
            } catch is BurnSpeedUnavailable {}
        }
        do {
            _ = try BurnSpeedSelection.kilobytesPerSecond(5540).requestedSpeed(supported: [11080])
            preconditionFailure("Changing discs must invalidate unavailable choices")
        } catch is BurnSpeedUnavailable {}
        precondition(BurnSpeedSelection.kilobytesPerSecond(5540).label().hasPrefix("4×"))
        precondition(BurnSpeedSelection.kilobytesPerSecond(705.6).label(oneX: 176.4).hasPrefix("4×"))
        print("PASS burn speed validation, unavailable metadata and changed media")
    }
}
