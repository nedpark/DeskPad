import Foundation

/// One authenticated media SSRC. All durations use the receiver's monotonic clock.
nonisolated struct AppleHPReceptionReport {
    private let clockRate: Double
    init(clockRate: Double = 90_000) {
        precondition(clockRate.isFinite && clockRate > 0 && clockRate <= 1_000_000_000)
        self.clockRate = clockRate
    }
    private var base: Int64?
    private var highest: Int64 = 0
    private var received: Int64 = 0
    private var priorExpected: Int64 = 0
    private var priorReceived: Int64 = 0
    private var previousArrival: Double?
    private var previousTimestamp: UInt32 = 0
    private var jitter = 0.0
    private var lastSR: (middle: UInt32, arrival: Double)?

    mutating func observe(_ packet: HighPerformanceRTPPacket, now: Double) {
        guard now.isFinite else { return }
        if base == nil { highest = Int64(packet.sequenceNumber); base = highest }
        else {
            let delta = Int64(Int16(bitPattern: packet.sequenceNumber &- UInt16(truncatingIfNeeded: highest)))
            highest = max(highest, highest + delta)
        }
        received += 1
        if let previousArrival {
            let timestampDelta = Double(Int32(bitPattern: packet.timestamp &- previousTimestamp))
            let difference = abs((now - previousArrival) * clockRate - timestampDelta)
            jitter += (difference - jitter) / 16
        }
        previousArrival = now; previousTimestamp = packet.timestamp
    }
    mutating func observe(_ report: HighPerformanceSenderReport, now: Double) {
        guard now.isFinite else { return }
        lastSR = ((report.ntpSeconds << 16) | (report.ntpFraction >> 16), now)
    }
    mutating func receiverReport(sender: UInt32, media: UInt32, now: Double) -> Data {
        guard base != nil else { return Self.header(type: 201, count: 0, words: 1) + Self.word(sender) }
        let expected = highest - base! + 1
        let lost = max(-8_388_608, min(8_388_607, expected - received))
        let intervalExpected = expected - priorExpected
        let intervalLost = intervalExpected - (received - priorReceived)
        let fraction = intervalExpected > 0 && intervalLost > 0 ? min(255, intervalLost * 256 / intervalExpected) : 0
        priorExpected = expected; priorReceived = received
        let delay = lastSR.map { max(0, min(Double(UInt32.max), (now - $0.arrival) * 65_536)) } ?? 0
        let loss = UInt32(fraction) << 24 | (UInt32(truncatingIfNeeded: lost) & 0x00ff_ffff)
        return Self.header(type: 201, count: 1, words: 7) + [sender, media, loss,
            UInt32(truncatingIfNeeded: highest), UInt32(max(0, min(Double(UInt32.max), jitter))),
            lastSR?.middle ?? 0, UInt32(delay)].reduce(into: Data()) { $0.append(Self.word($1)) }
    }
    /// Reference-compatible empty sender report; no video RTP is originated here.
    static func senderReport(sender: UInt32, unixTime: Double) -> Data {
        let seconds = max(0, unixTime) + 2_208_988_800
        let whole = UInt64(seconds)
        let fraction = UInt32((seconds - Double(whole)) * 4_294_967_296)
        return header(type: 200, count: 0, words: 6) + [sender, UInt32(truncatingIfNeeded: whole), fraction,
            UInt32(truncatingIfNeeded: UInt64(max(0, unixTime) * 90_000)), 0, 0].reduce(into: Data()) { $0.append(word($1)) }
    }
    private static func header(type: UInt8, count: UInt8, words: UInt16) -> Data {
        Data([0x80 | count, type, UInt8(words >> 8), UInt8(words & 255)])
    }
    private static func word(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
}
