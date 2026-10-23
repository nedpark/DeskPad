/// A fresh user connection gets at most one authenticated first-frame retry.
/// Cancellation and superseding connections cannot spend or revive this budget.
nonisolated struct AppleHPStartupRetry {
    private(set) var consumed = false

    mutating func consume(firstFrameExpired: Bool, cancelled: Bool, currentGeneration: Bool) -> Bool {
        guard firstFrameExpired, !cancelled, currentGeneration, !consumed else { return false }
        consumed = true
        return true
    }
}
