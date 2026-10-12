import Foundation

/// Source evidence belongs to the completed task. Device-derived data belongs
/// only to a current observation and must not survive a fault or reconnect.
struct SessionDeviceCache {
    var snapshot: SessionSnapshot?
    var mountedURL: URL?
    var verified: [VerifiedFile] = []
    var pendingProof: AppendProof?
    var proofURL: URL?
    var incrementalPlan: PreparedIncrementalISO?
    var incrementalSnapshot: SessionSnapshot?

    mutating func invalidateDevice() {
        snapshot = nil; mountedURL = nil; verified = []
        incrementalPlan = nil; incrementalSnapshot = nil
        // pendingProof and proofURL remain available for explicit readback.
    }
}
