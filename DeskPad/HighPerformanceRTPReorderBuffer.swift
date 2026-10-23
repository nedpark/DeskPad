import Foundation

/// Authenticated RTP only, one instance per SSRC. Uses monotonic arrival time
/// solely for bounded repair deadlines, never as an A/V presentation timestamp.
nonisolated struct HighPerformanceRTPReorderBuffer {
    struct Output {
        var packets: [HighPerformanceRTPPacket] = []
        var missing: [UInt16] = []
    }
    private let packetLimit: Int
    private let byteLimit: Int
    private let forwardLimit: Int
    init(packetLimit: Int = 512, byteLimit: Int = 2 * 1024 * 1024, forwardLimit: Int = 1024) {
        precondition((1...512).contains(packetLimit) && (1...(2 * 1024 * 1024)).contains(byteLimit) && (1...1024).contains(forwardLimit))
        self.packetLimit = packetLimit; self.byteLimit = byteLimit; self.forwardLimit = forwardLimit
    }
    private var expected: UInt16?
    private var pending: [UInt16: HighPerformanceRTPPacket] = [:]
    private var pendingBytes = 0
    private var gapStarted: Double?
    private var lastRequest: Double?
    private var requests = 0
    private var gapSequence: UInt16?
    private var missingSince: [UInt16: Double] = [:]
    struct Statistics {
        var repairedHeads = 0
        var deadlineExpirations = 0
        var capacityFlushes = 0
        var latePackets = 0
        var peakPackets = 0
        var longestRepairMilliseconds = 0
    }
    private(set) var statistics = Statistics()
    var hasPending: Bool { !pending.isEmpty }
    var bufferedPacketCount: Int { pending.count }
    var bufferedByteCount: Int { pendingBytes }

    mutating func insert(_ packet: HighPerformanceRTPPacket, now: Double) -> Output {
        guard now.isFinite else { return Output() }
        if expected == nil { expected = packet.sequenceNumber }
        let distance = Int16(bitPattern: packet.sequenceNumber &- expected!)
        guard distance >= 0 else { statistics.latePackets += 1; return Output() }
        guard pending[packet.sequenceNumber] == nil else { return Output() }
        var output = Output()
        // The missing head frees queued memory; never reject it merely because
        // the repair queue has reached its limit.
        if distance == 0 {
            if let started = missingSince.removeValue(forKey: packet.sequenceNumber) {
                statistics.repairedHeads += 1
                statistics.longestRepairMilliseconds = max(statistics.longestRepairMilliseconds, Int(max(0, now - started) * 1000))
            }
            output.packets.append(packet)
            expected = packet.sequenceNumber &+ 1
            releaseContiguous(into: &output)
            repair(now: now, into: &output)
            return output
        }
        if distance > forwardLimit || pending.count >= packetLimit || pendingBytes + packet.payload.count > byteLimit {
            // A bounded repair cannot span this burst. Release existing packets
            // with visible sequence gaps, allowing the decoder to request an IDR.
            statistics.capacityFlushes += 1
            releaseAll(into: &output)
            if let expected, Int16(bitPattern: packet.sequenceNumber &- expected) < 0 { return output }
            expected = packet.sequenceNumber
        }
        pending[packet.sequenceNumber] = packet
        pendingBytes += packet.payload.count
        statistics.peakPackets = max(statistics.peakPackets, pending.count)
        releaseContiguous(into: &output)
        repair(now: now, into: &output)
        return output
    }

    mutating func flush(now: Double) -> Output {
        var output = Output()
        guard now.isFinite else { return output }
        releaseContiguous(into: &output)
        repair(now: now, into: &output)
        return output
    }

    private mutating func releaseContiguous(into output: inout Output) {
        while let expected, let packet = pending.removeValue(forKey: expected) {
            pendingBytes -= packet.payload.count
            output.packets.append(packet)
            self.expected = expected &+ 1
        }
        if pending.isEmpty { clearGap(); missingSince.removeAll(keepingCapacity: true) }
    }
    private mutating func releaseAll(into output: inout Output) {
        guard let expected else { return }
        let ordered = pending.keys.sorted { $0 &- expected < $1 &- expected }
        for sequence in ordered {
            output.packets.append(pending[sequence]!)
            self.expected = sequence &+ 1
        }
        pending.removeAll(keepingCapacity: true); pendingBytes = 0; clearGap(); missingSince.removeAll(keepingCapacity: true)
    }
    private mutating func clearGap() { gapStarted = nil; gapSequence = nil; lastRequest = nil; requests = 0 }
    private mutating func repair(now: Double, into output: inout Output) {
        guard !pending.isEmpty, let expected else { return }
        let farthest = pending.keys.map { Int($0 &- expected) }.max() ?? 0
        guard farthest <= forwardLimit else { return }
        var missing: [UInt16] = []
        for offset in 0..<farthest {
            let sequence = expected &+ UInt16(offset)
            if pending[sequence] == nil {
                missing.append(sequence)
                if missingSince[sequence] == nil { missingSince[sequence] = now }
            }
        }
        let currentMissing = Set(missing)
        missingSince = missingSince.filter { currentMissing.contains($0.key) }
        if gapSequence != expected {
            clearGap()
            gapSequence = expected
            // Preserve the first observation of an existing hole; progress must
            // not extend its deadline, but a new hole gets its own repair budget.
            gapStarted = missingSince[expected] ?? now
        }
        if now - gapStarted! >= 0.06 {
            statistics.deadlineExpirations += 1
            releaseAll(into: &output)
            return
        }
        guard requests < 2, lastRequest == nil || now - lastRequest! >= 0.02 else { return }
        output.missing = missing
        // At most1024 requested sequence numbers, compressed into PID/BLP pairs.
        requests += 1; lastRequest = now
    }
}

/// RFC4585 generic NACK with an empty RR prefix, carried in authenticated SRTCP.
nonisolated enum HighPerformanceNACK {
    static func compound(sender: UInt32, media: UInt32, sequences: [UInt16]) -> Data? {
        let missing = Set(sequences.prefix(1024)).sorted()
        guard !missing.isEmpty else { return nil }
        var entries: [(UInt16, UInt16)] = []
        var index = 0
        while index < missing.count && entries.count < 64 {
            let first = missing[index]; index += 1
            var mask: UInt16 = 0
            while index < missing.count {
                let distance = Int(missing[index]) - Int(first)
                guard (1...16).contains(distance) else { break }
                mask |= UInt16(1) << (distance - 1); index += 1
            }
            entries.append((first, mask))
        }
        var data = Data([0x80,201,0,1])
        func word(_ value: UInt32) { data.append(contentsOf: [UInt8(truncatingIfNeeded:value>>24),UInt8(truncatingIfNeeded:value>>16),UInt8(truncatingIfNeeded:value>>8),UInt8(truncatingIfNeeded:value)]) }
        word(sender)
        let length = 2 + entries.count
        data.append(contentsOf: [0x81,205,UInt8(length>>8),UInt8(length&255)])
        word(sender); word(media)
        for (first,mask) in entries { data.append(contentsOf: [UInt8(first>>8),UInt8(first&255),UInt8(mask>>8),UInt8(mask&255)]) }
        return data
    }
}
