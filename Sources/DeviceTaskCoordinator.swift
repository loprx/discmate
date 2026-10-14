import Combine
import Foundation

/// Application-wide lease. It serializes all current optical-drive operations;
/// a recovery lease remains reserved until a separate read-only check succeeds.
@MainActor
final class DeviceTaskCoordinator: ObservableObject {
    static let shared = DeviceTaskCoordinator()
    private enum State { case idle, running(UUID), recoveryRequired, recovering(UUID) }
    private var state: State = .idle { didSet { revision &+= 1 } }
    @Published private(set) var revision: UInt64 = 0

    var isOccupied: Bool {
        if case .idle = state { return false }
        return true
    }
    var needsRecovery: Bool {
        switch state { case .recoveryRequired, .recovering: return true; default: return false }
    }
    func begin() -> UUID? {
        guard case .idle = state else { return nil }
        let id = UUID(); state = .running(id); return id
    }
    func finish(_ id: UUID, needsRecovery: Bool = false) {
        guard case .running(let current) = state, current == id else { return }
        state = needsRecovery ? .recoveryRequired : .idle
    }
    func beginRecovery() -> UUID? {
        guard case .recoveryRequired = state else { return nil }
        let id = UUID(); state = .recovering(id); return id
    }
    func finishRecovery(_ id: UUID, accepted: Bool) {
        guard case .recovering(let current) = state, current == id else { return }
        state = accepted ? .idle : .recoveryRequired
    }
}
