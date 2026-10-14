import Foundation

enum SystemTaskProgressTests {
    static func run() {
        let start = Date(timeIntervalSince1970: 0)
        var p = SystemTaskProgress(now: start)
        p.update(state: "DRStatusStateTrackWrite", fraction: nil, now: start)
        p.update(state: "DRStatusStateTrackWrite", fraction: 0.2, now: start.addingTimeInterval(60))
        p.update(state: "DRStatusStateTrackWrite", fraction: 0.3, now: start.addingTimeInterval(70))
        precondition(p.fraction == 0.3 && p.phaseStartedAt == start.addingTimeInterval(60))
        precondition(p.remaining(at: start.addingTimeInterval(70)) != nil)
        p.update(state: "DRStatusStateVerifying", fraction: 0.02, now: start.addingTimeInterval(80))
        precondition(p.stage == .verifying && p.fraction == 0.02 && p.remaining(at: start.addingTimeInterval(81)) == nil)
        for invalid in [Double.nan, Double.infinity, -0.1, 1.1] {
            p.update(state: "DRStatusStateVerifying", fraction: invalid)
            precondition(p.fraction == nil)
        }
        p.update(state: "DRStatusStateFinishing", fraction: 1)
        precondition(p.fraction == nil && !p.terminal)
        p.update(state: "DRStatusStateDone", fraction: 1)
        precondition(p.terminal && !p.canRelease && p.fraction == nil)
        p.update(state: "DRStatusStateTrackWrite", fraction: 0.5)
        precondition(p.stage == .done)
        p.panelDidFinish()
        precondition(p.canRelease)
        p.update(state: "DRStatusStateFailed", fraction: nil)
        precondition(p.stage == .failed)
        var earlyPanel = SystemTaskProgress()
        earlyPanel.panelDidFinish()
        precondition(!earlyPanel.canRelease)
        earlyPanel.update(state: "DRStatusStateFailed", fraction: nil)
        precondition(earlyPanel.canRelease)
        var rollback = SystemTaskProgress(now: start)
        rollback.update(state: "DRStatusStateTrackWrite", fraction: 0.8, now: start)
        rollback.update(state: "DRStatusStateTrackWrite", fraction: 0.1, now: start.addingTimeInterval(30))
        precondition(rollback.phaseStartedAt == start.addingTimeInterval(30) && rollback.remaining() == nil)
        print("PASS system progress: phases, invalid percentages, ETA baseline, backend/panel order, terminal ownership")
    }
}
