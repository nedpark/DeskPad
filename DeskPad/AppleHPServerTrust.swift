import Foundation
import CryptoKit
import Security

protocol AppleHPServerPinStore: Sendable {
    func read(account: String) throws -> Data?
    /// Insert only; false means a competing approval already created this entry.
    func insert(_ pin: Data, account: String) throws -> Bool
}

struct AppleHPServerKeychain: AppleHPServerPinStore {
    private let service = "com.africastart.DeskPad.hp-server-pins"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }
    func insert(_ pin: Data, account: String) throws -> Bool {
        var q = query(account)
        q[kSecValueData as String] = pin
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return true
    }
}

/// Trust-on-first-use requires an explicit UI decision. It is not independent
/// verification of the host's identity. Existing pins can never be overwritten.
actor AppleHPServerTrust {
    struct Challenge: Identifiable, Sendable, Equatable {
        let id: UUID
        let host: String
        let port: Int
        let fingerprint: String
    }
    enum Decision: Sendable { case trusted, approvalRequired(Challenge) }
    enum Failure: Error, Equatable {
        case invalidEndpoint, invalidKey, corruptPin, expiredApproval
        case changedKey(expected: String, received: String)
    }
    private struct Pending { let challenge: Challenge; let account: String; let pin: Data }
    private let store: any AppleHPServerPinStore
    private var pending: [UUID: Pending] = [:]
    init(store: any AppleHPServerPinStore = AppleHPServerKeychain()) { self.store = store }

    func inspect(der: Data, host: String, port: Int) throws -> Decision {
        let host = try Self.normalizedHost(host, port: port)
        // RSA import/DER validation belongs to AppleHPAuthentication, before this call.
        guard (64...8192).contains(der.count) else { throw Failure.invalidKey }
        let account = Self.digest(Data("\(host.utf8.count):\(host):\(port)".utf8)).hex
        let pin = Self.digest(der)
        if let saved = try store.read(account: account) {
            try Self.check(saved, against: pin)
            return .trusted
        }
        // Only the latest outstanding decision for one endpoint can be accepted.
        pending = pending.filter { $0.value.account != account }
        guard pending.count < 16 else { throw Failure.expiredApproval }
        let challenge = Challenge(id: UUID(), host: host, port: port, fingerprint: pin.fingerprint)
        pending[challenge.id] = Pending(challenge: challenge, account: account, pin: pin)
        return .approvalRequired(challenge)
    }

    func approve(_ challenge: Challenge) throws {
        guard let item = pending.removeValue(forKey: challenge.id), item.challenge == challenge else {
            throw Failure.expiredApproval
        }
        if let saved = try store.read(account: item.account) {
            try Self.check(saved, against: item.pin)
            return
        }
        if try !store.insert(item.pin, account: item.account) {
            guard let saved = try store.read(account: item.account) else { throw Failure.corruptPin }
            try Self.check(saved, against: item.pin)
        }
    }

    func cancel(_ challenge: Challenge) { pending.removeValue(forKey: challenge.id) }

    private static func check(_ saved: Data, against pin: Data) throws {
        guard saved.count == 32 else { throw Failure.corruptPin }
        guard saved == pin else {
            throw Failure.changedKey(expected: saved.fingerprint, received: pin.fingerprint)
        }
    }
    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func normalizedHost(_ input: String, port: Int) throws -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard (1...65535).contains(port), !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.contains("/"), !host.contains("@"), !host.contains("[") , !host.contains("]") else {
            throw Failure.invalidEndpoint
        }
        return host
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var fingerprint: String { "SHA256:" + map { String(format: "%02X", $0) }.joined(separator: ":") }
}
