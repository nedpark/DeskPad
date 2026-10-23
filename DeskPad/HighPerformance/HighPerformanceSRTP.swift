import Foundation
import CommonCrypto

enum HighPerformanceSRTPError: Error {
    case invalidKey, malformedPacket, authenticationFailed, replay, exhausted, tooManyStreams, cryptoFailure
}

/// AES_256_CM_HMAC_SHA1_80, kdr=0, no MKI. RFC 3711 + RFC 6188.
/// Use the negotiated server-send (key2) blob for receiving. No key material is logged.
nonisolated struct HighPerformanceSRTPKeys {
    let encryption: Data
    let authentication: Data
    let salt: Data

    init(masterKeyBlob: Data, control: Bool = false) throws {
        guard masterKeyBlob.count == 46 else { throw HighPerformanceSRTPError.invalidKey }
        let key = Data(masterKeyBlob.prefix(32))
        let masterSalt = Array(masterKeyBlob.suffix(14))
        func derive(_ label: UInt8, _ length: Int) throws -> Data {
            var iv = masterSalt + [0, 0]
            iv[7] ^= label
            return try srtpCTR(Data(repeating: 0, count: length), key: key, iv: iv)
        }
        let base: UInt8 = control ? 3 : 0
        encryption = try derive(base, 32)
        authentication = try derive(base + 1, 20)
        salt = try derive(base + 2, 14)
    }
}

/// Queue/actor-confined SRTP receiver. Instantiate with fresh negotiated keys on each
/// new media session. Never reset replay state while reusing a key/SSRC pair.
nonisolated struct HighPerformanceSRTPReceiver {
    private let keys: HighPerformanceSRTPKeys
    private var streams: [UInt32: SRTPReplayWindow] = [:]
    private var acceptedPackets: UInt64 = 0

    init(masterKeyBlob: Data) throws { keys = try HighPerformanceSRTPKeys(masterKeyBlob: masterKeyBlob) }

    mutating func receive(_ datagram: Data) throws -> HighPerformanceRTPPacket {
        guard datagram.count >= 22, datagram.count <= 65535 else { throw HighPerformanceSRTPError.malformedPacket }
        let b = Array(datagram)
        guard b[0] >> 6 == 2 else { throw HighPerformanceSRTPError.malformedPacket }
        let authenticatedLength = b.count - 10
        var headerLength = 12 + Int(b[0] & 15) * 4
        guard headerLength <= authenticatedLength else { throw HighPerformanceSRTPError.malformedPacket }
        if b[0] & 0x10 != 0 {
            guard headerLength + 4 <= authenticatedLength else { throw HighPerformanceSRTPError.malformedPacket }
            let words = Int(b[headerLength + 2]) << 8 | Int(b[headerLength + 3])
            headerLength += 4 + words * 4
            guard headerLength <= authenticatedLength else { throw HighPerformanceSRTPError.malformedPacket }
        }
        let sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        let ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        let window = streams[ssrc]
        guard window != nil || streams.count < 16 else { throw HighPerformanceSRTPError.tooManyStreams }
        let index = try estimatedIndex(sequence, highest: window?.highest)
        try window?.check(index)
        guard acceptedPackets < 1 << 31 else { throw HighPerformanceSRTPError.exhausted }
        let roc = UInt32(index >> 16)
        var authenticated = Data(b[..<authenticatedLength])
        authenticated.append(contentsOf: [UInt8(truncatingIfNeeded: roc >> 24), UInt8(truncatingIfNeeded: roc >> 16), UInt8(truncatingIfNeeded: roc >> 8), UInt8(truncatingIfNeeded: roc)])
        let expected = srtpHMAC(authenticated, key: keys.authentication)
        var difference: UInt8 = 0
        for i in 0..<10 { difference |= expected[i] ^ b[authenticatedLength + i] }
        guard difference == 0 else { throw HighPerformanceSRTPError.authenticationFailed }

        var iv = Array(keys.salt) + [0, 0]
        for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> (24 - i * 8)) }
        for i in 0..<6 { iv[8 + i] ^= UInt8(truncatingIfNeeded: index >> (40 - i * 8)) }
        let decrypted = try srtpCTR(Data(b[headerLength..<authenticatedLength]), key: keys.encryption, iv: iv)
        var plain = Data(b[..<headerLength]); plain.append(decrypted)
        let packet = try HighPerformanceRTPPacket(plain)
        // Only authenticated, structurally valid packets can change ROC/replay state.
        var updated = window ?? SRTPReplayWindow(highest: index, wordCount: 64)
        updated.accept(index)
        streams[ssrc] = updated
        acceptedPackets += 1
        return packet
    }

    private func estimatedIndex(_ sequence: UInt16, highest: UInt64?) throws -> UInt64 {
        guard let highest else { return UInt64(sequence) }
        let latest = Int(highest & 0xFFFF)
        var roc = Int64(highest >> 16)
        if latest < 32768 {
            if Int(sequence) - latest > 32768 { roc -= 1 }
        } else if latest - Int(sequence) > 32768 { roc += 1 }
        guard roc >= 0, roc <= Int64(UInt32.max) else { throw HighPerformanceSRTPError.exhausted }
        return UInt64(roc) << 16 | UInt64(sequence)
    }
}

nonisolated private func srtpHMAC(_ data: Data, key: Data) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    key.withUnsafeBytes { k in data.withUnsafeBytes { d in
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), k.baseAddress, key.count, d.baseAddress, data.count, &result)
    } }
    return result
}

nonisolated private func srtpCTR(_ input: Data, key: Data, iv: [UInt8]) throws -> Data {
    guard key.count == 32, iv.count == 16, input.count <= 65535 else { throw HighPerformanceSRTPError.cryptoFailure }
    // AES-ECB encrypts counter blocks only; the packet cipher is CTR, without padding.
    // Batch all counters into one CommonCrypto operation instead of allocating a cipher per block.
    let blocks = (input.count + 15) / 16
    if blocks == 0 { return Data() }
    var counter = iv
    var counters = [UInt8](); counters.reserveCapacity(blocks * 16)
    for _ in 0..<blocks {
        counters.append(contentsOf: counter)
        for i in stride(from: 15, through: 0, by: -1) { counter[i] &+= 1; if counter[i] != 0 { break } }
    }
    var stream = [UInt8](repeating: 0, count: counters.count)
    var written = 0
    let status = key.withUnsafeBytes { k in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                k.baseAddress, key.count, nil, counters, counters.count, &stream, stream.count, &written)
    }
    guard status == kCCSuccess, written == counters.count else { throw HighPerformanceSRTPError.cryptoFailure }
    return Data(zip(input, stream).map { $0 ^ $1 })
}

nonisolated private struct SRTPReplayWindow {
    var highest: UInt64
    private var words: [UInt64]
    init(highest: UInt64, wordCount: Int) {
        self.highest = highest
        words = Array(repeating: 0, count: wordCount)
    }
    func check(_ index: UInt64) throws {
        if index <= highest {
            let age = highest - index
            guard age < UInt64(words.count * 64),
                  words[Int(age / 64)] & (UInt64(1) << (age % 64)) == 0 else {
                throw HighPerformanceSRTPError.replay
            }
        }
    }
    mutating func accept(_ index: UInt64) {
        if index > highest {
            let jump = index - highest
            if jump >= UInt64(words.count * 64) {
                words = Array(repeating: 0, count: words.count)
            } else {
                let whole = Int(jump / 64), bits = Int(jump % 64)
                // Move oldest words first so sources remain untouched.
                for destination in stride(from: words.count - 1, through: 0, by: -1) {
                    let source = destination - whole
                    var shifted: UInt64 = source >= 0 ? words[source] << bits : 0
                    if bits > 0, source > 0 { shifted |= words[source - 1] >> (64 - bits) }
                    words[destination] = shifted
                }
            }
            highest = index
        }
        let age = Int(highest - index)
        words[age / 64] |= UInt64(1) << (age % 64)
    }
}

/// SRTCP counterpart with a separate replay window and key labels 3/4/5.
/// Returns the authenticated compound RTCP datagram with index/tag removed.
nonisolated struct HighPerformanceSRTCPReceiver {
    private let keys: HighPerformanceSRTPKeys
    private var streams: [UInt32: SRTPReplayWindow] = [:]
    private var acceptedPackets: UInt64 = 0

    init(masterKeyBlob: Data) throws { keys = try HighPerformanceSRTPKeys(masterKeyBlob: masterKeyBlob, control: true) }

    mutating func receive(_ datagram: Data) throws -> Data {
        guard datagram.count >= 22, datagram.count <= 65535 else { throw HighPerformanceSRTPError.malformedPacket }
        let b = Array(datagram)
        guard b[0] >> 6 == 2 else { throw HighPerformanceSRTPError.malformedPacket }
        let bodyLength = b.count - 14
        let trailer = UInt32(b[bodyLength]) << 24 | UInt32(b[bodyLength + 1]) << 16 | UInt32(b[bodyLength + 2]) << 8 | UInt32(b[bodyLength + 3])
        let index = UInt64(trailer & 0x7FFF_FFFF)
        let ssrc = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        let window = streams[ssrc]
        guard window != nil || streams.count < 16 else { throw HighPerformanceSRTPError.tooManyStreams }
        try window?.check(index)
        guard acceptedPackets < 1 << 31 else { throw HighPerformanceSRTPError.exhausted }
        let expected = srtpHMAC(Data(b[..<(bodyLength + 4)]), key: keys.authentication)
        var difference: UInt8 = 0
        for i in 0..<10 { difference |= expected[i] ^ b[bodyLength + 4 + i] }
        guard difference == 0 else { throw HighPerformanceSRTPError.authenticationFailed }
        var plain = Data(b[..<8])
        let body = Data(b[8..<bodyLength])
        if trailer & 0x8000_0000 != 0 {
            var iv = Array(keys.salt) + [0, 0]
            for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> (24 - i * 8)) }
            for i in 0..<6 { iv[8 + i] ^= UInt8(truncatingIfNeeded: index >> (40 - i * 8)) }
            plain.append(try srtpCTR(body, key: keys.encryption, iv: iv))
        } else { plain.append(body) }
        _ = try HighPerformanceSenderReport.parseCompound(plain)
        var updated = window ?? SRTPReplayWindow(highest: index, wordCount: 1)
        updated.accept(index)
        streams[ssrc] = updated
        acceptedPackets += 1
        return plain
    }
}

/// Single-stream sender. Create with a fresh client-send 46-byte master key for
/// each media session. Reference semantics prevent accidental sequence cloning.
/// Actor/queue-confined; never reuse a key and SSRC after discarding this object.
nonisolated final class HighPerformanceSRTPSender {
    private let keys: HighPerformanceSRTPKeys
    let ssrc: UInt32
    private var index: UInt64
    private var sent: UInt64 = 0

    init(masterKeyBlob: Data, ssrc: UInt32, initialSequence: UInt16 = 0) throws {
        keys = try HighPerformanceSRTPKeys(masterKeyBlob: masterKeyBlob)
        self.ssrc = ssrc
        index = UInt64(initialSequence)
    }

    /// Timestamp is an RTP media-clock value supplied by the caller, never a
    /// wall-clock timestamp. This codec performs no logging.
    func protect(payload: Data, payloadType: UInt8, timestamp: UInt32, marker: Bool = false) throws -> Data {
        guard payloadType < 128, payload.count <= 65535 - 22 else { throw HighPerformanceSRTPError.malformedPacket }
        guard index < (1 << 48), sent < (1 << 31) else { throw HighPerformanceSRTPError.exhausted }
        let sequence = UInt16(truncatingIfNeeded: index)
        let roc = UInt32(index >> 16)
        var packet = Data([0x80, payloadType | (marker ? 0x80 : 0), UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence)])
        packet.append(contentsOf: srtpU32(timestamp))
        packet.append(contentsOf: srtpU32(ssrc))
        var iv = Array(keys.salt) + [0, 0]
        for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> (24 - i * 8)) }
        for i in 0..<6 { iv[8 + i] ^= UInt8(truncatingIfNeeded: index >> (40 - i * 8)) }
        packet.append(try srtpCTR(payload, key: keys.encryption, iv: iv))
        var authenticated = packet
        authenticated.append(contentsOf: srtpU32(roc))
        packet.append(contentsOf: srtpHMAC(authenticated, key: keys.authentication).prefix(10))
        index += 1
        sent += 1
        return packet
    }
}

/// SRTCP sender with independent control key derivation and monotonic 31-bit
/// index. The entire compound datagram is authenticated; bytes after the first
/// eight are encrypted. The caller builds standards-compliant RR/SDES contents.
nonisolated final class HighPerformanceSRTCPSender {
    private let keys: HighPerformanceSRTPKeys
    let ssrc: UInt32
    private var index: UInt32

    init(masterKeyBlob: Data, ssrc: UInt32, initialIndex: UInt32 = 0) throws {
        guard initialIndex <= 0x7fff_ffff else { throw HighPerformanceSRTPError.exhausted }
        keys = try HighPerformanceSRTPKeys(masterKeyBlob: masterKeyBlob, control: true)
        self.ssrc = ssrc
        index = initialIndex
    }

    func protect(_ compound: Data) throws -> Data {
        guard index <= 0x7fff_ffff else { throw HighPerformanceSRTPError.exhausted }
        guard compound.count >= 8, compound.count <= 65535 - 14 else { throw HighPerformanceSRTPError.malformedPacket }
        _ = try HighPerformanceSenderReport.parseCompound(compound)
        let bytes = Array(compound)
        guard bytes[1] == 200 || bytes[1] == 201,
              Array(bytes[4..<8]) == srtpU32(ssrc) else { throw HighPerformanceSRTPError.malformedPacket }
        let firstLength = ((Int(bytes[2]) << 8 | Int(bytes[3])) + 1) * 4
        let reportCount = Int(bytes[0] & 31)
        guard firstLength >= (bytes[1] == 200 ? 28 : 8) + reportCount * 24 else { throw HighPerformanceSRTPError.malformedPacket }
        var iv = Array(keys.salt) + [0, 0]
        for i in 0..<4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> (24 - i * 8)) }
        for i in 0..<4 { iv[10 + i] ^= UInt8(truncatingIfNeeded: index >> (24 - i * 8)) }
        var packet = Data(bytes.prefix(8))
        packet.append(try srtpCTR(Data(bytes.dropFirst(8)), key: keys.encryption, iv: iv))
        packet.append(contentsOf: srtpU32(index | 0x8000_0000))
        packet.append(contentsOf: srtpHMAC(packet, key: keys.authentication).prefix(10))
        index += 1
        return packet
    }
}

nonisolated private func srtpU32(_ value: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
     UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}
