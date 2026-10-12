import Foundation

enum DeviceRecoveryTests {
    static func run() throws {
        var gate = DeviceOperationGate()
        precondition(!gate.blocksOperations && !gate.beginRecovery())
        precondition(gate.beginOperation())
        // Reproduce the recorded sequence: Done is followed by device loss.
        // Until the owning task has returned, even recovery must stay disabled.
        precondition(gate.isBusy && !gate.beginRecovery() && !gate.beginOperation())
        gate.operationEnded(needsRecovery: true)
        precondition(!gate.isBusy && gate.needsRecovery && gate.blocksOperations)
        precondition(!gate.beginOperation() && gate.beginRecovery())
        precondition(gate.isBusy && gate.needsRecovery && !gate.beginRecovery() && !gate.beginOperation())
        gate.recoveryEnded(accepted: false) // Missing drive, busy, or unknown state.
        precondition(!gate.isBusy && gate.needsRecovery && gate.beginRecovery())
        gate.recoveryEnded(accepted: true)
        precondition(!gate.needsRecovery && !gate.blocksOperations && gate.beginOperation())
        gate.operationEnded(needsRecovery: false)

        let idle = DeviceRecoveryState(driveID: 200, mediaID: 300, bsd: "disk9", busy: false, mediaPresent: true, trayOpen: false)
        try DeviceRecoveryState.validateStable(idle, idle)
        let empty = DeviceRecoveryState(driveID: 200, mediaID: 0, bsd: nil, busy: false, mediaPresent: false, trayOpen: true)
        try DeviceRecoveryState.validateStable(empty, empty)
        let reconnected = DeviceRecoveryState(driveID: 900, mediaID: 901, bsd: "disk12", busy: false, mediaPresent: true, trayOpen: false)
        try DeviceRecoveryState.validateStable(reconnected, reconnected)
        // Old IDs never constrain a new attempt, but changes within an attempt
        // invalidate it, even if both observations individually look idle.
        CoreTests.reject("recovery drive reconnect during observation") { try DeviceRecoveryState.validateStable(idle, reconnected) }
        let swapped = DeviceRecoveryState(driveID: 200, mediaID: 301, bsd: "disk9", busy: false, mediaPresent: true, trayOpen: false)
        CoreTests.reject("recovery media replacement reusing BSD name") { try DeviceRecoveryState.validateStable(idle, swapped) }
        CoreTests.reject("recovery media removed during observation") { try DeviceRecoveryState.validateStable(idle, empty) }
        for state in [
            DeviceRecoveryState(driveID: 200, mediaID: 300, bsd: "disk9", busy: true, mediaPresent: true, trayOpen: false),
            .init(driveID: 200, mediaID: 300, bsd: "disk9", busy: nil, mediaPresent: true, trayOpen: false),
            .init(driveID: 200, mediaID: 300, bsd: "disk9", busy: false, mediaPresent: nil, trayOpen: false),
            .init(driveID: 200, mediaID: 300, bsd: "disk9", busy: false, mediaPresent: true, trayOpen: nil),
            .init(driveID: 200, mediaID: 300, bsd: "disk9", busy: false, mediaPresent: true, trayOpen: true),
            .init(driveID: 200, mediaID: 300, bsd: "disk9", busy: false, mediaPresent: false, trayOpen: true),
            .init(driveID: 200, mediaID: 0, bsd: nil, busy: false, mediaPresent: true, trayOpen: false),
            .init(driveID: 0, mediaID: 0, bsd: nil, busy: false, mediaPresent: false, trayOpen: true)
        ] {
            CoreTests.reject("recovery busy, unknown or contradictory state") { try DeviceRecoveryState.validateStable(state, state) }
        }

        let track = RecordedTrack(number: 1, session: 1, start: 0, blocks: 100, blank: false, damaged: false, nextWritable: nil, freeBlocks: 0)
        let snapshot = SessionSnapshot(identity: MediaIdentity(bsd: "offline-only", registryID: 3, bytes: 204800),
            tracks: [track], latest: track, volume: ISOVolume(root: ISOEntry(name: ".", lba: 20, bytes: 2048, directory: true), joliet: true),
            rootEntries: [], descriptorHash: "old-device", appendable: true)
        let proof = AppendProof(previousSession: 1, expectedStart: 200, files: [FileProof(path: "new.txt", bytes: 1, sha256: String(repeating: "a", count: 64))])
        let proofURL = URL(fileURLWithPath: "/offline-only/expected.json")
        let prepared = PreparedIncrementalISO(image: URL(fileURLWithPath: "/offline-only/append.iso"), proof: proof,
            imageBytes: 2048, referencedBytes: 0, imageSHA256: String(repeating: "b", count: 64))
        var cache = SessionDeviceCache(snapshot: snapshot, mountedURL: URL(fileURLWithPath: "/offline-only/mount"),
            verified: [VerifiedFile(path: "old.txt", bytes: 1, sha256: "old")], pendingProof: proof, proofURL: proofURL,
            incrementalPlan: prepared, incrementalSnapshot: snapshot)
        cache.invalidateDevice()
        precondition(cache.snapshot == nil && cache.mountedURL == nil && cache.verified.isEmpty)
        precondition(cache.incrementalPlan == nil && cache.incrementalSnapshot == nil)
        precondition(cache.pendingProof?.files == proof.files && cache.pendingProof?.expectedStart == proof.expectedStart)
        precondition(cache.proofURL == proofURL)
        print("PASS recovery gate: real task completion required, exclusive recovery, retry after failure, stable reconnect, cache invalidation retains source proof")
    }
}
