import Foundation
func packet(_ sequence: UInt16, payloadBytes: Int = 10) throws -> HighPerformanceRTPPacket {
    try HighPerformanceRTPPacket(Data([0x80,100,UInt8(sequence>>8),UInt8(sequence&255),0,0,0,0,0,0,0,1]) + Data(repeating:1,count:payloadBytes))
}
func sequences(_ output: HighPerformanceRTPReorderBuffer.Output) -> [UInt16] { output.packets.map(\.sequenceNumber) }
@main struct Harness {
 static func main() throws {
    func check(_ value: Bool, _ message: String = "check failed") { precondition(value, message) }
    var reorder = HighPerformanceRTPReorderBuffer()
    check(sequences(reorder.insert(try packet(10),now:0)) == [10])
    let gap = reorder.insert(try packet(12),now:0.001)
    check(gap.packets.isEmpty && gap.missing == [11])
    check(reorder.flush(now:0.015).missing.isEmpty)
    check(reorder.flush(now:0.022).missing == [11])
    check(reorder.flush(now:0.045).missing.isEmpty, "more than2NACKs")
    check(sequences(reorder.insert(try packet(11),now:0.05)) == [11,12])
    check(!reorder.hasPending)
    check(reorder.insert(try packet(11),now:0.055).packets.isEmpty, "late duplicate")
    _ = reorder.insert(try packet(15),now:0.06)
    check(sequences(reorder.flush(now:0.121)) == [15], "expired gap must surface discontinuity")
    check(reorder.insert(try packet(14),now:0.13).packets.isEmpty)
    var wrap = HighPerformanceRTPReorderBuffer()
    _ = wrap.insert(try packet(65534),now:0)
    check(wrap.insert(try packet(0),now:0.01).missing == [65535])
    check(sequences(wrap.insert(try packet(65535),now:0.02)) == [65535,0])
    var jump = HighPerformanceRTPReorderBuffer()
    _ = jump.insert(try packet(1),now:0)
    let burst = jump.insert(try packet(270),now:0.001)
    check(burst.missing.count == 268)
    var repaired:[UInt16] = []
    for n in UInt16(2)...269 { repaired += sequences(jump.insert(try packet(n),now:0.01)) }
    check(repaired == Array(UInt16(2)...270))
    var bounded = HighPerformanceRTPReorderBuffer()
    _ = bounded.insert(try packet(0),now:0)
    for n in UInt16(2)...600 {
        _ = bounded.insert(try packet(n),now:0.001)
        check(bounded.bufferedPacketCount <= 512 && bounded.bufferedByteCount <= 2*1024*1024)
    }
    var full = HighPerformanceRTPReorderBuffer()
    _ = full.insert(try packet(0), now:0)
    for n in UInt16(2)...513 { _ = full.insert(try packet(n), now:0.001) }
    let pressure = full.insert(try packet(1), now:0.002)
    check(sequences(pressure) == Array(UInt16(1)...513), "full queue must accept the repairing head before capacity eviction")
    check(full.statistics.capacityFlushes == 0)
    var chained = HighPerformanceRTPReorderBuffer()
    _ = chained.insert(try packet(0), now: 0)
    _ = chained.insert(try packet(2), now: 0.001)
    _ = chained.flush(now: 0.022)
    _ = chained.insert(try packet(4), now: 0.050)
    let headRepair = chained.insert(try packet(1), now: 0.055)
    check(sequences(headRepair) == [1,2] && headRepair.missing == [3], "new head must receive a fresh NACK budget")
    check(chained.flush(now: 0.065).packets.isEmpty, "new gap must not inherit the previous gap deadline")
    check(sequences(chained.insert(try packet(3), now: 0.080)) == [3,4])
    var oldHole = HighPerformanceRTPReorderBuffer()
    _ = oldHole.insert(try packet(0), now: 0)
    _ = oldHole.insert(try packet(4), now: 0.001)
    _ = oldHole.insert(try packet(1), now: 0.050)
    check(sequences(oldHole.flush(now: 0.062)) == [4], "progress cannot extend an already observed hole deadline")
    check(oldHole.statistics.deadlineExpirations == 1)
    var bytes = HighPerformanceRTPReorderBuffer()
    _ = bytes.insert(try packet(0),now:0)
    for n in UInt16(2)...50 {
        _ = bytes.insert(try packet(n,payloadBytes:60000),now:0.001)
        check(bytes.bufferedByteCount <= 2*1024*1024)
    }
    let nack = HighPerformanceNACK.compound(sender:0x11223344,media:0x55667788,sequences:[11,12,27,11])!
    check(nack == Data([0x80,201,0,1,0x11,0x22,0x33,0x44,0x81,205,0,3,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0,11,0x80,1]))
    check(HighPerformanceNACK.compound(sender:1,media:2,sequences:[]) == nil)
    let wrapped = HighPerformanceNACK.compound(sender:1,media:2,sequences:[65535,0])!
    check(wrapped.count == 28)
    print("Reorder repair/expiry/wrap/268-loss recovery/byte+packet bounds and RFC4585 NACK vector passed")
 }
}
