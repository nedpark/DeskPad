import Foundation

/// One explicit user connection owns one retry budget. Successful automatic
/// reconnects do not replenish it; close/supersession invalidate every callback.
nonisolated struct SessionRecoveryPolicy {
    enum Action: Equatable { case stop, paused, retry(attempt: Int, delay: Double), resume }
    private(set) var generation = UUID()
    private(set) var established = false
    private(set) var attempts = 0
    private(set) var foreground = true
    private var active = true
    private var pendingResume = false
    private var pendingFailure = false

    mutating func connected() { if active { established = true } }
    mutating func background() { foreground = false }
    mutating func close() { active = false; pendingResume = false; pendingFailure = false; generation = UUID() }
    mutating func pause() {
        guard active else { return }
        pendingResume = true
    }
    mutating func failure(recoverable: Bool, generation: UUID, cancelled: Bool = false) -> Action {
        guard active, self.generation == generation, !cancelled, established, recoverable, attempts < 3 else { return .stop }
        if !foreground { pendingResume = true; pendingFailure = true; return .paused }
        return spendRetry()
    }
    mutating func activate() -> Action? {
        foreground = true
        guard active, pendingResume else { return nil }
        pendingResume = false
        if pendingFailure { pendingFailure = false; return attempts < 3 ? spendRetry() : .stop }
        return .resume
    }
    private mutating func spendRetry() -> Action {
        attempts += 1
        return .retry(attempt: attempts, delay: [1.0, 2.0, 4.0][attempts - 1])
    }
}
