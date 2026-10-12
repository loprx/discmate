import Foundation

enum BurnCompletionTests {
    static func run() {
        let ejected = BurnCompletion.DeviceState(mediaAbsent: true, trayOpen: true, idle: true)
        // Reproduce P0-001: backend Done, tray closed, no completion evidence.
        var stuck = BurnCompletion()
        stuck.backendEnded(.done, at: 100)
        stuck.deviceChanged(.init(mediaAbsent: false, trayOpen: false, idle: false))
        precondition(stuck.outcome(at: 100, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(stuck.outcome(at: 219, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        guard case .failed(_, recoveryRequired: true) = stuck.outcome(at: 220, driveStillRegistered: true, registryMediaAbsent: true) else {
            fatalError("Done must not unlock the device or report successful ejection")
        }
        // Device and burn notifications can arrive in either order.
        var earlyEject = BurnCompletion()
        earlyEject.deviceChanged(ejected)
        precondition(earlyEject.outcome(at: 1000, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        earlyEject.backendEnded(.done, at: 1001)
        precondition(earlyEject.outcome(at: 1001, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(earlyEject.outcome(at: 1016, driveStillRegistered: true, registryMediaAbsent: true) == .ejected)
        var lateEject = BurnCompletion()
        lateEject.backendEnded(.done, at: 0)
        lateEject.deviceChanged(ejected)
        precondition(lateEject.outcome(at: 60, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(lateEject.outcome(at: 80, driveStillRegistered: true, registryMediaAbsent: true) == .ejected)
        // Partial/unknown statuses must never be treated as successful ejection.
        for status in [
            BurnCompletion.DeviceState(mediaAbsent: true, trayOpen: false, idle: true),
            .init(mediaAbsent: true, trayOpen: true, idle: false),
            .init(mediaAbsent: false, trayOpen: true, idle: true)
        ] {
            var incomplete = BurnCompletion()
            incomplete.backendEnded(.done, at: 0); incomplete.deviceChanged(status)
            precondition(incomplete.outcome(at: 1, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        }
        // Disconnect is not ejection; a reconnected device at the same path isn't
        // the same registry identity. Neither situation can report success.
        guard case .failed(_, recoveryRequired: true) = lateEject.outcome(at: 81, driveStillRegistered: false, registryMediaAbsent: true) else {
            fatalError("disconnect mistaken for eject")
        }
        lateEject.deviceDisconnected()
        guard case .failed(_, recoveryRequired: true) = lateEject.outcome(at: 82, driveStillRegistered: true, registryMediaAbsent: true) else {
            fatalError("reconnect erased disconnect evidence")
        }
        var writing = BurnCompletion()
        writing.deviceDisconnected()
        precondition(writing.outcome(at: 99999, driveStillRegistered: false, registryMediaAbsent: true) == nil)
        // Repeated Done notifications don't extend the observation deadline.
        var duplicate = BurnCompletion()
        duplicate.backendEnded(.done, at: 0); duplicate.backendEnded(.done, at: 119)
        guard case .failed(_, recoveryRequired: true) = duplicate.outcome(at: 120, driveStillRegistered: true, registryMediaAbsent: true) else {
            fatalError("duplicate notification postponed deadline")
        }
        // Actual later media insertion invalidates an earlier empty-tray event.
        var reinserted = BurnCompletion()
        reinserted.deviceChanged(ejected)
        reinserted.deviceChanged(.init(mediaAbsent: false, trayOpen: false, idle: true))
        reinserted.backendEnded(.done, at: 0)
        precondition(reinserted.outcome(at: 1, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        // Eject after failure doesn't turn a failed burn into a successful one.
        var failure = BurnCompletion()
        failure.backendEnded(.failed("backend raw error 123"), at: 0)
        failure.deviceChanged(ejected)
        precondition(failure.outcome(at: 1, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(failure.outcome(at: 16, driveStillRegistered: true, registryMediaAbsent: true) == .failed("backend raw error 123", recoveryRequired: false))
        // Reproduce actual fourth-session contradiction: framework open/empty
        // cannot complete while ANY new media object exists under this drive.
        var falseOpen = BurnCompletion()
        falseOpen.backendEnded(.done, at: 0); falseOpen.deviceChanged(ejected)
        precondition(falseOpen.outcome(at: 0, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(falseOpen.outcome(at: 14, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(falseOpen.outcome(at: 15, driveStillRegistered: true, registryMediaAbsent: false) == nil)
        precondition(falseOpen.outcome(at: 30, driveStillRegistered: true, registryMediaAbsent: false) == .normalEjectRequired)
        var transient = BurnCompletion()
        transient.backendEnded(.done, at: 0); transient.deviceChanged(ejected)
        precondition(transient.outcome(at: 0, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(transient.outcome(at: 10, driveStillRegistered: true, registryMediaAbsent: false) == nil)
        precondition(transient.outcome(at: 20, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(transient.outcome(at: 34, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(transient.outcome(at: 35, driveStillRegistered: true, registryMediaAbsent: true) == .ejected)
        // Registry errors must not be interpreted as either absence or presence.
        var unknown = BurnCompletion()
        unknown.backendEnded(.done, at: 0); unknown.deviceChanged(ejected)
        precondition(unknown.outcome(at: 20, driveStillRegistered: true, registryMediaAbsent: nil) == nil)
        guard case .failed(_, recoveryRequired: true) = unknown.outcome(at: 120, driveStillRegistered: true, registryMediaAbsent: nil) else { fatalError("unknown registry state authorized an eject") }
        // A failed burn cannot launch the extra normal-eject stage.
        var failedPresent = BurnCompletion()
        failedPresent.backendEnded(.failed("write failure"), at: 0)
        precondition(failedPresent.outcome(at: 1, driveStillRegistered: true, registryMediaAbsent: false) == nil)
        precondition(failedPresent.outcome(at: 30, driveStillRegistered: true, registryMediaAbsent: false) == nil)
        guard case .failed(_, recoveryRequired: true) = failedPresent.outcome(at: 120, driveStillRegistered: true, registryMediaAbsent: false) else { fatalError("failed backend dispatched extra eject") }
        print("PASS completion registry contradiction, normal-eject handoff, unknown registry, failed burn, transient media")
        print("PASS completion: Done-without-eject, reordered events, partial states, disconnect, duplicate, backend failure")
    }
}
