import Foundation
import CommonCrypto

/// Apple's legacy HP record format. SHA-1 is mandated by the wire format;
/// this is not a general-purpose authenticated encryption construction.
/// Confine an instance to one serial executor. A framing/integrity error poisons
/// the instance; callers must close the connection rather than retry decoding.
nonisolated final class AppleHPRecordCipher {
    enum Failure: Error {
        case invalidKey, invalidRekey, inactive, failed, invalidLength
        case integrity, crypto, sequenceExhausted, rekeyDuringRecord
    }

    static let maximumCiphertextLength = 65_520
    static let maximumBodyLength = maximumCiphertextLength - 22
    private var wrapKey: Data
    private var key: Data?
    private var sendIV = Data()
    private var receiveIV = Data()
    private var sendCounter: UInt64
    private var receiveCounter: UInt64
    private var pending = Data()
    private var expectedLength: Int?
    private(set) var generation: UInt32?
    private(set) var isFailed = false

    init(wrapKey: Data, sendSequence: UInt32 = 0, receiveSequence: UInt32 = 0) throws {
        guard wrapKey.count == 16 else { throw Failure.invalidKey }
        self.wrapKey = wrapKey
        sendCounter = UInt64(sendSequence)
        receiveCounter = UInt64(receiveSequence)
    }

    /// The first four bytes are an opaque generation counter. ECB wrapping is
    /// unauthenticated: a wrong wrap key is detected by the first record's tag,
    /// not by the unwrap operation itself. Counters survive subsequent rekeys.
    func installRekey(payload: Data) throws {
        try checked {
            guard payload.count == 36 else { throw Failure.invalidRekey }
            guard pending.isEmpty else { throw Failure.rekeyDuringRecord }
            let bytes = [UInt8](payload)
            let next = try Self.crypt(Data(bytes[4..<36]), key: wrapKey, iv: nil, encrypt: false)
            let nextKey = Data(next.prefix(16)), nextIV = Data(next.suffix(16))
            key = nextKey
            wrapKey = nextKey
            sendIV = nextIV
            receiveIV = nextIV
            generation = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
    }

    /// Native HP pointer envelope inside the authenticated control record.
    /// The inner ECB block uses the current post-rekey key, not the initial
    /// authentication wrapping key. Keep that key private to this executor.
    func encodePointer(x: UInt16, y: UInt16, buttonMask: UInt8) throws -> Data {
        try checked {
            guard let key else { throw Failure.inactive }
            var event = Data(repeating: 0, count: 10)
            event.append(0xff)
            event.append(buttonMask)
            event.append(contentsOf: [UInt8(x >> 8), UInt8(truncatingIfNeeded: x),
                                      UInt8(y >> 8), UInt8(truncatingIfNeeded: y)])
            let encryptedEvent = try Self.crypt(event, key: key, iv: nil, encrypt: true)
            return try encode(body: Data([0x10, 0]) + encryptedEvent)
        }
    }

    func encode(body: Data) throws -> Data {
        try checked {
            guard let key else { throw Failure.inactive }
            guard body.count <= Self.maximumBodyLength else { throw Failure.invalidLength }
            guard sendCounter <= UInt64(UInt32.max) else { throw Failure.sequenceExhausted }
            var plaintext = Self.u16(body.count)
            plaintext.append(body)
            let fillerCount = (16 - (plaintext.count + 20) % 16) % 16
            plaintext.append(Data(repeating: 0, count: fillerCount))
            plaintext.append(Self.tag(sequence: UInt32(sendCounter), plaintext: plaintext))
            let ciphertext = try Self.crypt(plaintext, key: key, iv: sendIV, encrypt: true)
            sendIV = Data(ciphertext.suffix(16))
            sendCounter += 1
            var wire = Self.u16(ciphertext.count)
            wire.append(ciphertext)
            return wire
        }
    }

    /// Accepts arbitrary TCP fragmentation/coalescing. Returns ordered bodies;
    /// higher layers concatenate these when a message spans records. Internal
    /// buffering is bounded to one record even for a large incoming chunk.
    func receive(bytes: Data) throws -> [Data] {
        try checked {
            guard key != nil else { throw Failure.inactive }
            var output: [Data] = []
            var offset = bytes.startIndex
            while offset < bytes.endIndex {
                let target = expectedLength.map { $0 + 2 } ?? 2
                let amount = min(target - pending.count, bytes.distance(from: offset, to: bytes.endIndex))
                let end = bytes.index(offset, offsetBy: amount)
                pending.append(contentsOf: bytes[offset..<end])
                offset = end
                if expectedLength == nil, pending.count == 2 {
                    let length = Int(pending[0]) << 8 | Int(pending[1])
                    guard length >= 32, length <= Self.maximumCiphertextLength, length % 16 == 0 else {
                        throw Failure.invalidLength
                    }
                    expectedLength = length
                }
                if let length = expectedLength, pending.count == length + 2 {
                    let body = try decode(Data(pending.dropFirst(2)))
                    pending.removeAll(keepingCapacity: true)
                    expectedLength = nil
                    output.append(body)
                }
            }
            return output
        }
    }

    /// Call at EOF to reject an incomplete header or record.
    func finish() throws {
        try checked {
            guard pending.isEmpty else { throw Failure.invalidLength }
        }
    }

    private func decode(_ ciphertext: Data) throws -> Data {
        guard let key else { throw Failure.inactive }
        guard receiveCounter <= UInt64(UInt32.max) else { throw Failure.sequenceExhausted }
        let plaintext = try Self.crypt(ciphertext, key: key, iv: receiveIV, encrypt: false)
        let authenticated = Data(plaintext.dropLast(20))
        let expected = Self.tag(sequence: UInt32(receiveCounter), plaintext: authenticated)
        let actual = plaintext.suffix(20)
        // Always compare every tag byte; never accept an unsigned fallback.
        var difference: UInt8 = 0
        for (left, right) in zip(expected, actual) { difference |= left ^ right }
        guard difference == 0 else { throw Failure.integrity }
        let length = Int(plaintext[0]) << 8 | Int(plaintext[1])
        let paddedLength = ((2 + length + 20 + 15) / 16) * 16
        guard length <= Self.maximumBodyLength, paddedLength == plaintext.count else { throw Failure.invalidLength }
        receiveIV = Data(ciphertext.suffix(16))
        receiveCounter += 1
        return Data(plaintext[2..<(2 + length)])
    }

    private func checked<T>(_ operation: () throws -> T) throws -> T {
        guard !isFailed else { throw Failure.failed }
        do { return try operation() }
        catch {
            isFailed = true
            key = nil
            wrapKey = Data()
            pending = Data()
            sendIV = Data()
            receiveIV = Data()
            throw error
        }
    }

    private static func u16(_ value: Int) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 255)])
    }

    private static func tag(sequence: UInt32, plaintext: Data) -> Data {
        var input = Data([UInt8(sequence >> 24), UInt8((sequence >> 16) & 255),
                          UInt8((sequence >> 8) & 255), UInt8(sequence & 255)])
        input.append(plaintext)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        input.withUnsafeBytes { raw in
            _ = CC_SHA1(raw.baseAddress, CC_LONG(raw.count), &digest)
        }
        return Data(digest)
    }

    private static func crypt(_ input: Data, key: Data, iv: Data?, encrypt: Bool) throws -> Data {
        guard key.count == 16, iv == nil || iv?.count == 16, input.count % 16 == 0 else { throw Failure.crypto }
        var output = [UInt8](repeating: 0, count: input.count + 16)
        var moved = 0
        let ivBytes = iv ?? Data(repeating: 0, count: 16)
        let status = key.withUnsafeBytes { keyRaw in
            ivBytes.withUnsafeBytes { ivRaw in
                input.withUnsafeBytes { inputRaw in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            iv == nil ? CCOptions(kCCOptionECBMode) : 0,
                            keyRaw.baseAddress, key.count, iv == nil ? nil : ivRaw.baseAddress,
                            inputRaw.baseAddress, input.count, &output, output.count, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == input.count else { throw Failure.crypto }
        return Data(output.prefix(moved))
    }
}
