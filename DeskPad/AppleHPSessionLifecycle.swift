import Foundation

/// Owns one HP attempt. Supply nonblocking resource cancellation closures;
/// closing TCP must be abortive (NWConnection.forceCancel), not a FIN drain.
/// Transport shutdown is not evidence that the host restored its display mode.
actor AppleHPSessionLifecycle {
    enum Phase: Equatable { case idle, starting, playing, stopped }
    enum StopReason: Equatable, Sendable {
        case user, peerClosed, failed, startupTimeout, backgrounded
    }
    enum Failure: Error { case alreadyStarted, unverifiedDisplayMutation }
    struct Cleanup: Sendable {
        let stopInput: @Sendable () -> Void
        let stopMedia: @Sendable () -> Void
        let closeDatagrams: @Sendable () -> Void
        let abortControl: @Sendable () -> Void
        let didStop: @Sendable (StopReason) -> Void
    }
    private(set) var phase: Phase = .idle
    private(set) var stopReason: StopReason?
    private var watchdog: Task<Void, Never>?
    private let cleanup: Cleanup

    init(cleanup: Cleanup) { self.cleanup = cleanup }

    /// No verified physical-mode restoration protocol is currently implemented.
    /// A framebuffer size is not a physical display snapshot; do not substitute it.
    nonisolated static func validateDisplayPolicy(changesHostDisplay: Bool) throws {
        guard !changesHostDisplay else { throw Failure.unverifiedDisplayMutation }
    }

    func begin(timeoutNanoseconds: UInt64 = 10_000_000_000) throws {
        guard phase == .idle else { throw Failure.alreadyStarted }
        phase = .starting
        let timeout = min(max(timeoutNanoseconds, 1_000_000), 30_000_000_000)
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            await self?.startupExpired()
        }
    }

    /// Call only after a visible video frame and audible-ready output are presented,
    /// never merely on authentication, packet arrival, or renderer enqueue success.
    func presentationConfirmed() {
        guard phase == .starting else { return }
        phase = .playing
        watchdog?.cancel()
        watchdog = nil
    }

    private func startupExpired() {
        guard phase == .starting else { return }
        stop(.startupTimeout)
    }

    func stop(_ reason: StopReason) {
        guard phase != .stopped else { return }
        phase = .stopped
        stopReason = reason
        watchdog?.cancel()
        watchdog = nil
        // Prevent new traffic before releasing sockets. No invented display-reset
        // packet is sent on failure, and no automatic re-handshake follows cleanup.
        cleanup.stopInput()
        cleanup.stopMedia()
        cleanup.closeDatagrams()
        cleanup.abortControl()
        cleanup.didStop(reason)
    }
}
