import Foundation
import DiscRecording

/// Exercises the real UI task owner with an injected backend. No device API is
/// called and diagnostic output is isolated from the user's task history.
@main
struct FirstDataLifecycleTests {
    @MainActor final class Backend {
        var continuation: CheckedContinuation<Void, Error>?
        func run(_ request: FirstDataBurnRequest, progress: (BurnProgress) -> Void) async throws {
            progress(BurnProgress(kind: .backend, state: DRStatusStateDone, fraction: nil, detail: ""))
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("async task did not reach expected state")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-native-test-\(UUID())")
        let store = DiagnosticReportStore(directory: directory, appVersion: "test", appBuild: "4")
        let request = FirstDataBurnRequest(drivePath: "offline", driveID: 1, mediaID: 2, bsd: "offline",
            sources: [], volumeName: "TEST", appendable: true, speed: .automatic, verifyAfterWrite: false)
        try request.validateIdentity(driveID: 1, mediaID: 2, bsd: "offline")
        for observed in [(3 as UInt64, 2 as UInt64, "offline"), (1, 4, "offline"), (1, 2, "other")] {
            do { try request.validateIdentity(driveID: observed.0, mediaID: observed.1, bsd: observed.2); preconditionFailure("changed identity accepted") }
            catch { }
        }
        let legacyPreflight = LegacyMediaPreflight(drivePath: "offline", driveID: 1, mediaID: 2,
                                                   bsd: "offline", wasBlank: true)
        try legacyPreflight.validate(driveID: 1, mediaID: 2, bsd: "offline")
        try legacyPreflight.validateBurnCapability(isBlank: true, isAppendable: false)
        for state in [(false, true), (false, false)] {
            do {
                try legacyPreflight.validateBurnCapability(isBlank: state.0, isAppendable: state.1)
                preconditionFailure("legacy task accepted changed media capability")
            } catch { }
        }
        for observed in [(3 as UInt64, 2 as UInt64, "offline"), (1, 4, "offline"), (1, 2, "other")] {
            do {
                try legacyPreflight.validate(driveID: observed.0, mediaID: observed.1, bsd: observed.2)
                preconditionFailure("legacy task accepted a replaced drive or disc")
            } catch { }
        }
        try FirstDataBurnRequest.validateCapacity(estimatedBlocks: 100, freeBlocks: 100)
        for (estimate, free) in [(101 as UInt64, 100 as UInt64), (0, 100), (100, 0)] {
            do { try FirstDataBurnRequest.validateCapacity(estimatedBlocks: estimate, freeBlocks: free); preconditionFailure("invalid capacity accepted") }
            catch { }
        }
        let backend = Backend()
        let successfulCoordinator = DeviceTaskCoordinator()
        let model = SystemDiscTaskModel(diagnostics: store, coordinator: successfulCoordinator, firstDataOperation: backend.run)
        model.beginFirstData(request, model: .unknown, fileCount: 0, totalBytes: 0) { _ in
            preconditionFailure("successful task requested recovery")
        }
        await waitUntil { backend.continuation != nil }
        precondition(model.isBusy && model.progress?.terminal == true)
        precondition(successfulCoordinator.begin() == nil, "Done released the application lease")
        // Done alone cannot dismiss the Chinese completion UI or release the lease.
        model.clearResult()
        precondition(model.isBusy && model.progress != nil)
        backend.continuation?.resume(); backend.continuation = nil
        await waitUntil { !model.isBusy }
        precondition(model.message?.contains("推出请求已结束") == true)
        let nextLease = successfulCoordinator.begin()
        precondition(nextLease != nil)
        if let nextLease { successfulCoordinator.finish(nextLease) }

        let failedBackend = Backend()
        let recoveryCoordinator = DeviceTaskCoordinator()
        let failed = SystemDiscTaskModel(diagnostics: store, coordinator: recoveryCoordinator, firstDataOperation: failedBackend.run)
        let sessions = SessionModel(coordinator: recoveryCoordinator)
        failed.beginFirstData(request, model: .unknown, fileCount: 0, totalBytes: 0) { detail in
            precondition(failed.isBusy, "recovery must be transferred BEFORE releasing native ownership")
            sessions.requireRecovery(detail)
        }
        await waitUntil { failedBackend.continuation != nil }
        failedBackend.continuation?.resume(throwing: BurnRecoveryRequired(detail: "test unresolved completion"))
        failedBackend.continuation = nil
        await waitUntil { !failed.isBusy }
        precondition(sessions.needsDeviceRecovery && sessions.blocksDeviceOperations && !sessions.isBusy)
        precondition(recoveryCoordinator.needsRecovery && recoveryCoordinator.begin() == nil)
        if let recovering = recoveryCoordinator.beginRecovery() {
            precondition(recoveryCoordinator.begin() == nil)
            recoveryCoordinator.finishRecovery(recovering, accepted: false)
        } else { preconditionFailure("recovery lease unavailable") }
        sessions.reset()
        precondition(sessions.needsDeviceRecovery && sessions.blocksDeviceOperations, "reset erased recovery lock")

        let preflight = SystemDiscTaskModel(diagnostics: store, coordinator: DeviceTaskCoordinator()) { _, _ in throw DiscFailure("offline preflight failure") }
        preflight.beginFirstData(request, model: .unknown, fileCount: 0, totalBytes: 0) { _ in preconditionFailure("preflight recovery") }
        await waitUntil { !preflight.isBusy }
        precondition(preflight.message == "offline preflight failure")
        let taskFiles = TaskFileStore()
        var completionTracker = LegacyCompletionTracker()
        precondition(!completionTracker.observe(now: 0, mediaPresent: false))
        precondition(!completionTracker.observe(now: 14.9, mediaPresent: false))
        precondition(!completionTracker.observe(now: 15, mediaPresent: true), "media return must reset empty interval")
        precondition(!completionTracker.observe(now: 16, mediaPresent: false))
        precondition(completionTracker.observe(now: 31, mediaPresent: false))
        let log = directory.appendingPathComponent("ordered.log")
        taskFiles.append("first\n", to: log) { _ in preconditionFailure("unexpected log failure") }
        taskFiles.append("second\n", to: log) { _ in preconditionFailure("unexpected log failure") }
        await taskFiles.flush()
        let contents = try String(contentsOf: log)
        precondition(contents == "first\nsecond\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        let imageDir = FileManager.default.temporaryDirectory.appendingPathComponent("discmate-incremental-\(UUID())")
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: false)
        try Data([1]).write(to: imageDir.appendingPathComponent("append.iso"))
        taskFiles.discardImageDirectory(containing: imageDir.appendingPathComponent("append.iso"))
        await taskFiles.flush()
        precondition(!FileManager.default.fileExists(atPath: imageDir.path))
        print("PASS first-data task owner: Done retains lease; service return releases; failure transfers recovery before release; reset cannot unlock; preflight fails without recovery; no panel required")
    }
}
