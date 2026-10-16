import Foundation
import DiscRecording

enum BurnCompletionTests {
    static func run() {
        precondition(BurnProgress(kind: .warning, state: "AppendPreflightFailed", fraction: nil,
                                  detail: "").diagnosticEventKind == .appendPreflightRejected)
        precondition(BurnProgress(kind: .device, state: "AppendSourcesRevalidated", fraction: nil,
                                  detail: "").diagnosticEventKind == .appendSourcesRevalidated)
        precondition(BurnProgress(kind: .finishing, state: "EjectConfirmed", fraction: nil,
                                  detail: "").diagnosticEventKind == .ejectCompleted)
        precondition(BurnProgress(kind: .finishing, state: "SystemEject", fraction: nil,
                                  detail: "").diagnosticEventKind == .ejectRequested)
        precondition(BurnProgress(kind: .finishing, state: "MediaReturned", fraction: nil,
                                  detail: "").diagnosticEventKind == .mediaReturnedDuringCompletion)
        precondition(BurnProgress(kind: .backend, state: DRStatusStateDone, fraction: nil,
                                  detail: "").diagnosticEventKind == .backendDone)
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
        precondition(earlyEject.outcome(at: 1002.5, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(earlyEject.outcome(at: 1003, driveStillRegistered: true, registryMediaAbsent: true) == .ejected)
        var lateEject = BurnCompletion()
        lateEject.backendEnded(.done, at: 0)
        lateEject.deviceChanged(ejected)
        precondition(lateEject.outcome(at: 60, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(lateEject.outcome(at: 62, driveStillRegistered: true, registryMediaAbsent: true) == .ejected)
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
        precondition(lateEject.outcome(at: 81, driveStillRegistered: false, registryMediaAbsent: true) == nil)
        lateEject.deviceDisconnected()
        precondition(lateEject.outcome(at: 82, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        guard case .failed(_, recoveryRequired: true) = lateEject.outcome(at: 120, driveStillRegistered: true, registryMediaAbsent: true) else {
            fatalError("cached tray status survived loss of device identity")
        }
        var writing = BurnCompletion()
        writing.deviceDisconnected()
        precondition(writing.outcome(at: 99999, driveStillRegistered: false, registryMediaAbsent: true) == nil)
        writing.backendEnded(.done, at: 100000)
        precondition(!writing.canRefreshStatus(at: 100001))
        writing.deviceChanged(ejected)
        precondition(writing.outcome(at: 100000, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        guard case .failed(_, recoveryRequired: true) = writing.outcome(at: 100120, driveStillRegistered: true, registryMediaAbsent: true) else { fatalError("loss during writing was erased") }
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
        precondition(failure.outcome(at: 3, driveStillRegistered: true, registryMediaAbsent: true) == .failed("backend raw error 123", recoveryRequired: false))
        // Reproduce actual fourth-session contradiction: framework open/empty
        // cannot complete while ANY new media object exists under this drive.
        var falseOpen = BurnCompletion()
        falseOpen.backendEnded(.done, at: 0); falseOpen.deviceChanged(ejected)
        precondition(falseOpen.outcome(at: 0, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(falseOpen.outcome(at: 1, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(falseOpen.outcome(at: 1.5, driveStillRegistered: true, registryMediaAbsent: false) == .mediaReturned)
        precondition(falseOpen.outcome(at: 30, driveStillRegistered: true, registryMediaAbsent: false) == .mediaReturned)
        // Replay 2026-10-16 14:45:56: the drive was empty after Done, the
        // user reinserted the disc seven seconds later, and the old worker
        // incorrectly launched Disk Arbitration eject at +42 seconds.
        var actualReinsert = BurnCompletion()
        actualReinsert.backendEnded(.done, at: 0); actualReinsert.deviceChanged(ejected)
        precondition(actualReinsert.outcome(at: 0, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        actualReinsert.deviceChanged(.init(mediaAbsent: false, trayOpen: false, idle: true))
        precondition(actualReinsert.outcome(at: 7, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(actualReinsert.outcome(at: 26, driveStillRegistered: true, registryMediaAbsent: false) == .mediaReturned)
        precondition(actualReinsert.outcome(at: 42, driveStillRegistered: true, registryMediaAbsent: false) != .normalEjectRequired)
        var transient = BurnCompletion()
        transient.backendEnded(.done, at: 0); transient.deviceChanged(ejected)
        precondition(transient.outcome(at: 0, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(transient.outcome(at: 1, driveStillRegistered: true, registryMediaAbsent: false) == .mediaReturned)
        precondition(transient.outcome(at: 20, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(transient.outcome(at: 22, driveStillRegistered: true, registryMediaAbsent: true) == .ejected)
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
        // Replay E0267F12: Done/open/empty, then registry lookup fails 14s
        // later. Previously this immediately latched recoveryRequired. Neither
        // a transient gap nor an actual disconnect may certify an eject.
        var afterDone = BurnCompletion()
        precondition(!afterDone.canRefreshStatus(at: 0))
        afterDone.backendEnded(.done, at: 0); afterDone.deviceChanged(ejected)
        precondition(afterDone.canRefreshStatus(at: 119) && !afterDone.canRefreshStatus(at: 120))
        precondition(afterDone.outcome(at: 0, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(afterDone.outcome(at: 14, driveStillRegistered: false, registryMediaAbsent: nil) == nil)
        afterDone.deviceDisconnected()
        precondition(afterDone.outcome(at: 15, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(afterDone.outcome(at: 30, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        // A fresh status from the SAME identity starts a new settling window.
        afterDone.deviceChanged(ejected)
        precondition(afterDone.outcome(at: 31, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(afterDone.outcome(at: 32.5, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(afterDone.outcome(at: 33, driveStillRegistered: true, registryMediaAbsent: true) == .ejected)
        // Identity failure while routing a notification must invalidate the
        // previous open/idle state even if the following timer sees the drive.
        var droppedNotification = BurnCompletion()
        droppedNotification.backendEnded(.done, at: 0); droppedNotification.deviceChanged(ejected)
        precondition(droppedNotification.outcome(at: 0, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        droppedNotification.observationUnavailable()
        precondition(droppedNotification.outcome(at: 15, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        droppedNotification.deviceChanged(ejected)
        precondition(droppedNotification.outcome(at: 16, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(droppedNotification.outcome(at: 17.5, driveStillRegistered: true, registryMediaAbsent: true) == nil)
        precondition(droppedNotification.outcome(at: 18, driveStillRegistered: true, registryMediaAbsent: true) == .ejected)
        var remainsGone = BurnCompletion()
        remainsGone.backendEnded(.done, at: 0); remainsGone.deviceDisconnected()
        precondition(remainsGone.outcome(at: 14, driveStillRegistered: false, registryMediaAbsent: nil) == nil)
        remainsGone.backendEnded(.done, at: 119)
        guard case .failed(let detail, recoveryRequired: true) = remainsGone.outcome(at: 120, driveStillRegistered: false, registryMediaAbsent: nil),
              detail.contains("系统刻录任务已结束"), !detail.contains("刻录失败") else { fatalError("completion warning lost successful backend result or extended deadline") }
        var failedGone = BurnCompletion()
        failedGone.backendEnded(.failed("raw error 456"), at: 0); failedGone.deviceDisconnected()
        guard case .failed(let detail, recoveryRequired: true) = failedGone.outcome(at: 120, driveStillRegistered: false, registryMediaAbsent: nil), detail.contains("raw error 456") else { fatalError("lost original backend failure") }
        // A new registry identity is never accepted merely because it reports
        // an open tray, and busy/unknown status cannot trigger fallback eject.
        var replaced = BurnCompletion()
        replaced.backendEnded(.done, at: 0); replaced.deviceChanged(ejected)
        precondition(replaced.outcome(at: 0, driveStillRegistered: false, registryMediaAbsent: true) == nil)
        replaced.deviceChanged(ejected)
        guard case .failed(_, recoveryRequired: true) = replaced.outcome(at: 120, driveStillRegistered: false, registryMediaAbsent: true) else { fatalError("replacement accepted as original drive") }
        var busyPresent = BurnCompletion()
        busyPresent.backendEnded(.done, at: 0)
        busyPresent.deviceChanged(.init(mediaAbsent: false, trayOpen: false, idle: false))
        precondition(busyPresent.outcome(at: 0, driveStillRegistered: true, registryMediaAbsent: false) == nil)
        precondition(busyPresent.outcome(at: 20, driveStillRegistered: true, registryMediaAbsent: false) == nil)
        busyPresent.deviceChanged(.init(mediaAbsent: false, trayOpen: false, idle: true))
        precondition(busyPresent.outcome(at: 21, driveStillRegistered: true, registryMediaAbsent: false) == nil)
        precondition(busyPresent.outcome(at: 36, driveStillRegistered: true, registryMediaAbsent: false) == .normalEjectRequired)
        print("PASS post-Done loss: bounded observation, fresh same-drive status, no stale success, no busy eject, original write result retained")
        print("PASS fast removal confirmation, no second eject after media return, normal-eject handoff, unknown registry, failed burn")
        print("PASS completion: Done-without-eject, reordered events, partial states, disconnect, duplicate, backend failure")
    }
}
