import Foundation

/// Synthetic events only; this fixture cannot enumerate or access a drive.
enum DiagnosticPreviewFixture {
    static func seed(_ store: DiagnosticReportStore) async throws -> (large: UUID, small: UUID) {
        let small = store.startTask(kind: .appendPreparation, fileCount: 2, totalBytes: 128)
        store.record(taskID: small, event: .completed)
        store.finish(taskID: small, outcome: .completed)
        let large = store.startTask(kind: .dataBurn, media: .dvdPlusR, driveModel: .lenovoUltraslimDVD,
            fileCount: 1, totalBytes: 1_120_401_929)
        let secret = NSError(domain: NSPOSIXErrorDomain, code: 5,
            userInfo: [NSLocalizedDescriptionKey: "/Users/private-owner/私人文件.txt credential=private-secret"])
        for index in 0..<300 {
            store.record(taskID: large, event: .deviceStatusObserved, progress: Double(index % 101) / 100,
                error: secret, evidence: DiagnosticEvidence(backendState: .finishing,
                    requestedSpeedKBps: 5540, actualSpeedKBps: Double(3000 + index), requestedSpeedAutomatic: false,
                    verifyAfterWriteRequested: true, verifyAfterWriteAccepted: true,
                    device: DiagnosticDeviceEvidence(busy: true, trayOpen: false, mediaAbsent: false,
                        identityConfirmed: true, registryMediaPresent: true),
                    disc: DiagnosticDiscEvidence(latestSession: 1, latestStartLBA: 0, nextWritableLBA: 554176,
                        freeBlocks: 1_000_000, rootEntryCount: 1, appendable: true, imageBytes: 1_121_320_960),
                    opticalRegistry: DiagnosticOpticalRegistryEvidence(discRecordingDevices: 1,
                        lenovoUSBDevices: 1, opticalPeripherals: 1, dvdMedia: 1)))
        }
        store.record(taskID: large, event: .recoveryRequired, error: secret)
        store.finish(taskID: large, outcome: .needsRecovery)
        _ = try await store.exportData(taskID: large)
        return (large, small)
    }
}
