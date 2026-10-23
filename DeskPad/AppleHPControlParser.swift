import Foundation

/// Incrementally frames decrypted HP control bytes. Unknown opcodes/encodings
/// fail closed rather than guessing a length and desynchronizing the channel.
struct AppleHPControlParser {
    enum Failure: Error { case malformed, unsupported, oversized, failed, truncated }
    enum Event {
        case mediaAnswer(AppleHPMediaAnswer)
        case mediaAnnouncement(Data)
        case rekey(Data)
        case status(flags: UInt16, command: UInt16)
        case rectangle(encoding: Int32, x: UInt16, y: UInt16, width: UInt16, height: UInt16, payload: Data)
        case bell
        case clipboard(Data)
        // Framed only: an opaque Z_SYNC_FLUSH pasteboard archive, not plain text.
        case clipboardArchive(promise: UInt8, uncompressedSize: UInt32, compressed: Data)
    }
    private var buffer = Data()
    private var rectanglesRemaining = 0
    private(set) var isFailed = false
    var isAtMessageBoundary: Bool { buffer.isEmpty && rectanglesRemaining == 0 }
    private static let limit = 1_048_576

    mutating func append(_ bytes: Data) throws -> [Event] {
        guard !isFailed else { throw Failure.failed }
        do {
            guard bytes.count <= Self.limit - buffer.count else { throw Failure.oversized }
            buffer.append(bytes)
            var events: [Event] = []
            while !buffer.isEmpty {
                let b = [UInt8](buffer)
                if rectanglesRemaining > 0 {
                    guard b.count >= 12 else { break }
                    let encoding = Int32(bitPattern: u32(b, 8))
                    var length: Int
                    switch encoding {
                    case 1103: length = 36
                    case 1010, 1105, 1107, 1109, 1110:
                        guard b.count >= 14 else { return events }
                        length = Int(u16(b, 12)) + 2
                    case 1104:
                        guard b.count >= 20 else { return events }
                        let compressed = Int(u32(b, 16))
                        guard compressed <= 512 * 512 * 6 else { throw Failure.oversized }
                        length = compressed + 8
                    case -223: length = 0
                    default: throw Failure.unsupported
                    }
                    guard length <= Self.limit - 12 else { throw Failure.oversized }
                    guard b.count >= 12 + length else { break }
                    let payload = Data(b[12..<(12 + length)])
                    if encoding == 1103 {
                        guard rectanglesRemaining == 1 else { throw Failure.malformed }
                        events.append(.rekey(payload))
                    } else if encoding == 1010 {
                        if payload.count >= 6, u16([UInt8](payload), 2) == 2, u16([UInt8](payload), 4) == 2 {
                            events.append(.mediaAnswer(try AppleHPMediaAnswer(payload)))
                        } else { events.append(.mediaAnnouncement(payload)) }
                    } else {
                        events.append(.rectangle(encoding: encoding, x: u16(b, 0), y: u16(b, 2),
                                                 width: u16(b, 4), height: u16(b, 6), payload: payload))
                    }
                    buffer = Data(b.dropFirst(12 + length)); rectanglesRemaining -= 1
                    if encoding == 1103 {
                        // A rekey is a record-layer barrier. The caller must install
                        // it before reading/decrypting the next encrypted record.
                        guard buffer.isEmpty else { throw Failure.malformed }
                        return events
                    }
                    continue
                }
                switch b[0] {
                case 0:
                    guard b.count >= 4 else { return events }
                    let count = Int(u16(b, 2))
                    guard count <= 256 else { throw Failure.oversized }
                    rectanglesRemaining = count; buffer = Data(b.dropFirst(4))
                case 2:
                    events.append(.bell); buffer = Data(b.dropFirst())
                case 0x14:
                    guard b.count >= 4 else { return events }
                    let length = Int(u16(b, 2))
                    guard (4...4096).contains(length) else { throw Failure.malformed }
                    guard b.count >= 4 + length else { return events }
                    events.append(.status(flags: u16(b, 4), command: u16(b, 6)))
                    buffer = Data(b.dropFirst(4 + length))
                case 0x1f:
                    guard b.count >= 16 else { return events }
                    let uncompressed = u32(b, 8), compressed = Int(u32(b, 12))
                    guard uncompressed <= UInt32(Self.limit), compressed <= Self.limit - 16 else { throw Failure.oversized }
                    guard b.count >= 16 + compressed else { return events }
                    events.append(.clipboardArchive(promise: b[2], uncompressedSize: uncompressed,
                                                    compressed: Data(b[16..<(16 + compressed)])))
                    buffer = Data(b.dropFirst(16 + compressed))
                case 3:
                    guard b.count >= 8 else { return events }
                    let length = Int(u32(b, 4))
                    guard length <= Self.limit - 8 else { throw Failure.oversized }
                    guard b.count >= 8 + length else { return events }
                    events.append(.clipboard(Data(b[8..<(8 + length)])))
                    buffer = Data(b.dropFirst(8 + length))
                default: throw Failure.unsupported
                }
            }
            return events
        } catch { isFailed = true; buffer = Data(); throw error }
    }
    mutating func finish() throws {
        guard !isFailed else { throw Failure.failed }
        guard isAtMessageBoundary else { isFailed = true; throw Failure.truncated }
    }
    private func u16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) << 8 | UInt16(b[p + 1]) }
    private func u32(_ b: [UInt8], _ p: Int) -> UInt32 { UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3]) }
}
