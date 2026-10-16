import Foundation

/// Converts typed preflight failures to the diagnostic whitelist. Never infer
/// a category from localized text or copy source paths into shared reports.
enum AppendDiagnostics {
    static func summary(_ plan: PreparedIncrementalISO) -> DiagnosticEvidence {
        DiagnosticEvidence(append: DiagnosticAppendEvidence(failure: nil,
            addedFiles: plan.addedFileCount, addedDirectories: plan.addedDirectoryCount,
            preservedFiles: plan.preservedFileCount, preservedDirectories: plan.preservedDirectoryCount,
            addedBytes: plan.addedBytes, sessionAllowanceBytes: plan.capacityMarginBytes))
    }

    static func rejection(_ error: Error) -> (error: NSError, evidence: DiagnosticEvidence) {
        let failure = error as? AppendPreflightFailure
        let reason: DiagnosticAppendFailure
        if let legacy = error as? LegacyPreflightFailure {
            switch legacy {
            case .changedMedium, .changedDrive: reason = .mediaChanged
            case .unavailableCapability: reason = .unavailable
            }
        } else {
            reason = failure.flatMap { DiagnosticAppendFailure(rawValue: $0.reason.rawValue) } ?? .other
        }
        return (failure?.underlyingError ?? (error as NSError),
            DiagnosticEvidence(append: DiagnosticAppendEvidence(failure: reason,
                addedFiles: nil, addedDirectories: nil, preservedFiles: nil, preservedDirectories: nil,
                addedBytes: nil, sessionAllowanceBytes: nil)))
    }
}
