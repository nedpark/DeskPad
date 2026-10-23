import Foundation

/// Native RTCP APP name 5. The identifier is the packet's decoding-order
/// number, never a local render counter, timestamp, or picture-order count.
nonisolated enum AppleHPLTRAcknowledgement {
    static func packet(sender: UInt32, don: UInt16) -> Data {
        var result = Data([0x80, 204, 0, 3])
        for value in [sender, UInt32(5), UInt32(don)] {
            result.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        return result
    }
}
