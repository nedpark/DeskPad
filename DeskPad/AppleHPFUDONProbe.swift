#if DEBUG
import Foundation

/// Diagnostic only: compares candidate header bytes without exposing their value
/// or changing negotiated framing. Consistency is evidence, not DON validation.
nonisolated struct AppleHPFUDONProbe {
    struct Summary { let fragments: Int; let consistent: Bool; let contiguous: Bool; let nalType: Int }
    private var candidate: UInt16?
    private var timestamp: UInt32 = 0
    private var expected: UInt16 = 0
    private var count = 0
    private var same = true
    private var contiguous = true
    mutating func observe(sequence: UInt16, timestamp: UInt32, payload: Data) -> Summary? {
        let b = [UInt8](payload.prefix(5))
        guard b.count == 5, (b[0] >> 1) & 63 == 49 else { return nil }
        let value = UInt16(b[3]) << 8 | UInt16(b[4])
        if b[2] & 128 != 0 {
            candidate = value; self.timestamp = timestamp; expected = sequence
            count = 0; same = true; contiguous = true
        }
        guard let candidate, self.timestamp == timestamp else { return nil }
        count += 1
        same = same && candidate == value
        contiguous = contiguous && expected == sequence
        expected = sequence &+ 1
        guard count <= 8192 else { self.candidate = nil; return nil }
        guard b[2] & 64 != 0 else { return nil }
        self.candidate = nil
        return Summary(fragments:count, consistent:same, contiguous:contiguous,nalType:Int(b[2]&63))
    }
}
#endif
