import Foundation

final class MemoryPins: AppleHPServerPinStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String: Data] = [:]
    func read(account: String) -> Data? { lock.lock(); defer { lock.unlock() }; return pins[account] }
    func insert(_ pin: Data, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pins[account] == nil else { return false }
        pins[account] = pin; return true
    }
}
@main struct TrustHarness {
    static func challenge(_ decision: AppleHPServerTrust.Decision) -> AppleHPServerTrust.Challenge {
        guard case .approvalRequired(let challenge) = decision else { fatalError("Expected explicit approval") }
        return challenge
    }
    static func main() async throws {
        let store = MemoryPins(), trust = AppleHPServerTrust(store: MemoryPins())
        let key = Data(repeating: 1, count: 294), other = Data(repeating: 2, count: 294)
        let canceled = challenge(try await trust.inspect(der: key, host: "MAC.local.", port: 5900))
        await trust.cancel(canceled)
        do { try await trust.approve(canceled); fatalError("Canceled approval accepted") }
        catch AppleHPServerTrust.Failure.expiredApproval {}
        let old = challenge(try await trust.inspect(der: key, host: "mac.local", port: 5900))
        let fresh = challenge(try await trust.inspect(der: key, host: "MAC.LOCAL.", port: 5900))
        do { try await trust.approve(old); fatalError("Stale approval accepted") }
        catch AppleHPServerTrust.Failure.expiredApproval {}
        try await trust.approve(fresh)
        guard case .trusted = try await trust.inspect(der: key, host: "mac.local", port: 5900) else { fatalError("Pin not saved") }
        do { _ = try await trust.inspect(der: other, host: "mac.local", port: 5900); fatalError("Changed key trusted") }
        catch AppleHPServerTrust.Failure.changedKey {}
        _ = challenge(try await trust.inspect(der: key, host: "mac.local", port: 5901))
        // Separate UI sessions compete for the same Keychain account: never overwrite.
        let a = AppleHPServerTrust(store: store), b = AppleHPServerTrust(store: store)
        let ca = challenge(try await a.inspect(der: key, host: "[::1]", port: 5900))
        let cb = challenge(try await b.inspect(der: other, host: "::1", port: 5900))
        try await a.approve(ca)
        do { try await b.approve(cb); fatalError("Competing changed key overwrote pin") }
        catch AppleHPServerTrust.Failure.changedKey {}
        print("HP trust: explicit approval, cancel/stale rejection, endpoint isolation, changed-key and competing-approval rejection passed")
    }
}
