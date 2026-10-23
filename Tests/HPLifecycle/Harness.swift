import Foundation

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ value: String) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return entries }
    var cleanup: AppleHPSessionLifecycle.Cleanup {
        .init(stopInput: { self.add("input") }, stopMedia: { self.add("media") },
              closeDatagrams: { self.add("udp") }, abortControl: { self.add("rst") },
              didStop: { self.add("stop:\($0)") })
    }
}
@main struct Harness {
    static func main() async throws {
        try AppleHPSessionLifecycle.validateDisplayPolicy(changesHostDisplay: false)
        do {
            try AppleHPSessionLifecycle.validateDisplayPolicy(changesHostDisplay: true)
            fatalError("Unverified display mutation accepted")
        } catch AppleHPSessionLifecycle.Failure.unverifiedDisplayMutation {}
        let first = Recorder(), session = AppleHPSessionLifecycle(cleanup: first.cleanup)
        try await session.begin(timeoutNanoseconds: 1_000_000)
        try await Task.sleep(nanoseconds: 30_000_000)
        let reason = await session.stopReason
        precondition(reason == .startupTimeout)
        await session.stop(.user)
        precondition(first.snapshot() == ["input", "media", "udp", "rst", "stop:startupTimeout"])
        let second = Recorder(), playing = AppleHPSessionLifecycle(cleanup: second.cleanup)
        try await playing.begin(timeoutNanoseconds: 1_000_000)
        await playing.presentationConfirmed()
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(second.snapshot().isEmpty)
        await playing.stop(.backgrounded)
        await playing.presentationConfirmed()
        let phase = await playing.phase
        precondition(phase == .stopped)
        precondition(second.snapshot() == ["input", "media", "udp", "rst", "stop:backgrounded"])
        do { try await playing.begin(); fatalError("Stopped attempt reused") }
        catch AppleHPSessionLifecycle.Failure.alreadyStarted {}
        print("HP lifecycle: display guard, timeout, presentation, ordered/idempotent cleanup passed")
    }
}
