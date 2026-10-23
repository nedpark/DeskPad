import Foundation
import CoreMedia
@MainActor final class HEVCSink: HighPerformanceMediaOutput {
    var presentationSeconds: Double = 0
    var decodes: [(@MainActor @Sendable () -> Bool, @MainActor @Sendable (Bool) -> Void)] = []
    func enqueueVideo(_ sample: CMSampleBuffer, prepare: @escaping @MainActor @Sendable () -> Bool, decodeCompletion: @escaping @MainActor @Sendable (Bool) -> Void) throws { decodes.append((prepare, decodeCompletion)) }
    var starts = 0; var video = 0
    func start(at senderSeconds: Double, playoutDelay: Double) throws { starts += 1 }
    func enqueueVideo(_ sample: CMSampleBuffer) throws { precondition(CMFormatDescriptionGetMediaSubType(CMSampleBufferGetFormatDescription(sample)!) == kCMVideoCodecType_HEVC); video += 1 }
    func enqueueAudio(_ sample: CMSampleBuffer) throws {}
    func reset() { starts = 0; video = 0 }
}
@main struct Harness {
 @MainActor static func main() throws {
    func check(_ value: Bool) { precondition(value) }
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    var starts: [(Int,Int)] = []; var p = 0
    while p+3 < bytes.count {
        if Array(bytes[p..<(p+4)]) == [0,0,0,1] { starts.append((p,4)); p += 4 }
        else if Array(bytes[p..<(p+3)]) == [0,0,1] { starts.append((p,3)); p += 3 }
        else { p += 1 }
    }
    let units = starts.enumerated().map { n,s in Data(bytes[(s.0+s.1)..<(n+1 < starts.count ? starts[n+1].0 : bytes.count)]) }
    var dep = AppleHPHEVCDepacketizer(packetization: .appleDON)
    var assembled: [Data]?
    for (n,u) in units.enumerated() {
        let wire = Data(u.prefix(2)) + Data([0,9]) + Data(u.dropFirst(2))
        assembled = try dep.append(sequence: UInt16(n), timestamp: 1, marker: n == units.count-1, payload: wire)
    }
    precondition(assembled == units, "single-NAL DON stripping")
    var ap = Data([96,1,0,9])
    for u in units { ap.append(contentsOf: [UInt8(u.count>>8), UInt8(u.count&255)]); ap.append(u) }
    var apDep = AppleHPHEVCDepacketizer(packetization: .appleDON)
    check(try apDep.append(sequence: 0, timestamp: 1, marker: true, payload: ap) == units)
    let nal = units.last!, b = [UInt8](nal), middle = b.count/2
    let type = (b[0]>>1)&63
    let first = Data([(b[0]&0x81)|98,b[1],128|type,0,9]) + Data(b[2..<middle])
    let last = Data([(b[0]&0x81)|98,b[1],64|type,0,9]) + Data(b[middle...])
    var fu = AppleHPHEVCDepacketizer(packetization: .appleDON)
    check(try fu.append(sequence: 65535, timestamp: 2, marker: false, payload: first) == nil)
    check(try fu.append(sequence: 0, timestamp: 2, marker: true, payload: last) == [nal])
    var lost = AppleHPHEVCDepacketizer(packetization: .appleDON)
    _ = try lost.append(sequence: 1, timestamp: 2, marker: false, payload: first)
    check(try lost.append(sequence: 3, timestamp: 2, marker: true, payload: last) == nil)
    var truncated = AppleHPHEVCDepacketizer(packetization: .appleDON)
    do { _ = try truncated.append(sequence: 0, timestamp: 0, marker: true, payload: Data([96,1,0,0,255,255,0])); fatalError("bad AP accepted") } catch {}
    var mismatch = AppleHPHEVCDepacketizer(packetization: .appleDON)
    _ = try mismatch.append(sequence: 0, timestamp: 0, marker: false, payload: first)
    var changed = last; changed[4] = 10
    do { _ = try mismatch.append(sequence: 1, timestamp: 0, marker: true, payload: changed); fatalError("changed DON accepted") } catch {}
    let sink = HEVCSink()
    var paramsApple = Data([96,1,0,9])
    for u in units where (32...34).contains(Int((u.first! >> 1) & 63)) {
        paramsApple.append(contentsOf: [UInt8(u.count>>8), UInt8(u.count&255)]); paramsApple.append(u)
    }
    let paramsRFC = Data(paramsApple.prefix(2)) + Data(paramsApple.dropFirst(4))
    for (wire, expected) in [(paramsApple, AppleHPHEVCDepacketizer.Packetization.appleDON), (paramsRFC, .rfc7798NoDON)] {
        var auto = AppleHPHEVCDepacketizer()
        _ = try auto.append(sequence: 0, timestamp: 1, marker: true, payload: wire)
        precondition(auto.detectedPacketization == expected)
        let picture = expected == .appleDON ? Data(nal.prefix(2)) + Data([0,9]) + Data(nal.dropFirst(2)) : nal
        check(try auto.append(sequence: 1, timestamp: 2, marker: true, payload: picture) == [nal])
        precondition(auto.detectedPacketization == expected, "mode must persist across timestamps")
        precondition(auto.lastCompletedDON == (expected == .appleDON ? 9 : nil))
    }
    var metadata = AppleHPHEVCDepacketizer(packetization: .appleDON)
    _ = try metadata.append(sequence: 1, timestamp: 1, marker: false, payload: Data([2,1,0,7,128]))
    precondition(metadata.lastCompletedDON == nil)
    do {
        _ = try metadata.append(sequence: 2, timestamp: 1, marker: true, payload: Data([2,1,0,8,128]))
        fatalError("mixed DON must not acknowledge an AU")
    } catch {}
    precondition(metadata.lastCompletedDON == nil)
    _ = try metadata.append(sequence: 3, timestamp: 2, marker: true, payload: Data([2,1,255,255,128]))
    precondition(metadata.lastCompletedDON == 65535)
    _ = try metadata.append(sequence: 4, timestamp: 3, marker: true, payload: Data([2,1,0,0,128]))
    precondition(metadata.lastCompletedDON == 0)
    var unresolved = AppleHPHEVCDepacketizer()
    do { _ = try unresolved.append(sequence: 0, timestamp: 0, marker: true, payload: nal); fatalError("guessed framing from slice") } catch {}
    precondition(unresolved.detectedPacketization == nil)
    var incomplete = AppleHPHEVCDepacketizer()
    do { _ = try incomplete.append(sequence: 0, timestamp: 0, marker: true, payload: Data([96,1,0,3,64,1,128])); fatalError("incomplete parameter set selected framing") } catch {}
    precondition(incomplete.detectedPacketization == nil)
    let pipeline = try HighPerformanceMediaPipeline(output: sink, videoPayloadType: 100, videoCodec: .hevc)
    func packet(_ ssrc: UInt32, seq: UInt8 = 0, payload: Data? = nil) throws -> HighPerformanceRTPPacket {
        var data = Data([0x80,228,0,seq,0,0,0,seq])
        data.append(contentsOf: [UInt8(truncatingIfNeeded:ssrc>>24),UInt8(truncatingIfNeeded:ssrc>>16),UInt8(truncatingIfNeeded:ssrc>>8),UInt8(truncatingIfNeeded:ssrc)])
        data.append(payload ?? paramsApple); return try HighPerformanceRTPPacket(data)
    }
    try pipeline.consumeVideo(packet(1));
    try pipeline.consumeVideo(packet(1, seq: 1, payload: Data(nal.prefix(2)) + Data([0,9]) + Data(nal.dropFirst(2)))); precondition(sink.video == 0)
    try pipeline.observe([HighPerformanceSenderReport(ssrc:1,ntpSeconds:10,ntpFraction:0,rtpTimestamp:1)],clockRate:90000)
    precondition(sink.decodes.count == 1 && sink.starts == 1)
    precondition(pipeline.lastCleanVideoDecodeTime == nil, "enqueue is not native decode progress")
    let plainDecode = sink.decodes.removeFirst()
    precondition(plainDecode.0()); plainDecode.1(true)
    precondition(pipeline.lastCleanVideoDecodeTime != nil, "non-LTR decode must advance progress")
    do { try pipeline.consumeVideo(packet(2)); fatalError("multi-SSRC silently accepted") } catch {}
    pipeline.reset(); precondition(!pipeline.isPlaying)
    let feedbackSink = HEVCSink()
    let feedbackPipeline = try HighPerformanceMediaPipeline(output: feedbackSink, videoPayloadType: 100, videoCodec: .hevc)
    try feedbackPipeline.configureLTR(enabled: true)
    var acknowledgements: [UInt16] = []
    feedbackPipeline.onCleanHEVCFrame = { acknowledgements.append($0) }
    var configWire = Data([0x80, 228, 0, 0, 0, 0, 0, 0, 0, 0, 0, 99, 96, 1, 0, 8])
    for unit in units where (32...34).contains(Int((unit.first! >> 1) & 63)) {
        configWire.append(contentsOf: [UInt8(unit.count >> 8), UInt8(unit.count & 255)]); configWire.append(unit)
    }
    try feedbackPipeline.consumeVideo(HighPerformanceRTPPacket(configWire))
    var feedbackWire = Data([0x80, 228, 0, 1, 0, 0, 0, 1, 0, 0, 0, 99])
    feedbackWire.append(ap)
    try feedbackPipeline.consumeVideo(HighPerformanceRTPPacket(feedbackWire))
    try feedbackPipeline.observe([HighPerformanceSenderReport(ssrc: 99, ntpSeconds: 1, ntpFraction: 0, rtpTimestamp: 0)], clockRate: 90000)
    precondition(acknowledgements.isEmpty && feedbackSink.decodes.count == 1, "enqueue must not ACK")
    let firstDecode = feedbackSink.decodes.removeFirst()
    precondition(firstDecode.0(), "fixture references should validate")
    firstDecode.1(false)
    precondition(acknowledgements.isEmpty, "failed native output must not ACK")
    feedbackWire[3] = 2; feedbackWire[7] = 2
    try feedbackPipeline.consumeVideo(HighPerformanceRTPPacket(feedbackWire))
    let successfulDecode = feedbackSink.decodes.removeFirst()
    precondition(successfulDecode.0())
    successfulDecode.1(true)
    precondition(acknowledgements == [9], "ACK must preserve exact AU DON only after validated decode")
    let fallbackSink = HEVCSink()
    let fallback = try HighPerformanceMediaPipeline(output: fallbackSink, videoPayloadType: 100, videoCodec: .hevc)
    try fallback.configureLTR(enabled: true)
    var fallbackACKs = 0
    fallback.onCleanHEVCFrame = { _ in fallbackACKs += 1 }
    try fallback.consumeVideo(packet(55, payload: paramsRFC))
    // A pre-IDR P picture must not start the clock or enter native decode.
    try fallback.consumeVideo(packet(55, seq: 1, payload: Data([2,1,0x80])))
    try fallback.observe([HighPerformanceSenderReport(ssrc: 55, ntpSeconds: 100, ntpFraction: 0, rtpTimestamp: 0)], clockRate: 90000)
    precondition(!fallback.isPlaying && fallbackSink.video == 0 && fallbackSink.decodes.isEmpty)
    try fallback.consumeVideo(packet(55, seq: 2, payload: nal))
    let cleanNoDON = fallbackSink.decodes.removeFirst()
    precondition(cleanNoDON.0()); cleanNoDON.1(true)
    precondition(fallbackSink.video == 0 && fallbackACKs == 0, "no-DON native validation must never ACK")
    let damagedSink = HEVCSink()
    let damagedStartup = try HighPerformanceMediaPipeline(output: damagedSink, videoPayloadType:100, videoCodec:.hevc)
    try damagedStartup.configureLTR(enabled:true)
    // Parameters belonged to an incomplete initial AU. A new timestamp discards
    // them along with the lost IDR; subsequent P pictures must not throw or start.
    var incompleteInitial = Data([0x80,100,0,0,0,0,0,0,0,0,0,66]); incompleteInitial.append(paramsRFC)
    try damagedStartup.consumeVideo(HighPerformanceRTPPacket(incompleteInitial))
    try damagedStartup.observe([HighPerformanceSenderReport(ssrc:66,ntpSeconds:1,ntpFraction:0,rtpTimestamp:0)],clockRate:90000)
    for seq in UInt8(2)...27 { try damagedStartup.consumeVideo(packet(66,seq:seq,payload:Data([2,1,0x80]))) }
    precondition(!damagedStartup.isPlaying && damagedStartup.pendingVideoCount == 0 && damagedSink.decodes.isEmpty)
    // IDR without the missing configuration must likewise wait safely.
    try damagedStartup.consumeVideo(packet(66,seq:28,payload:nal))
    precondition(!damagedStartup.isPlaying && damagedStartup.pendingVideoCount == 0)
    try damagedStartup.consumeVideo(packet(66,seq:29,payload:paramsRFC))
    try damagedStartup.consumeVideo(packet(66,seq:30,payload:nal))
    precondition(damagedStartup.isPlaying && damagedSink.decodes.count == 1)
    let recoveredStart = damagedSink.decodes.removeFirst()
    precondition(recoveredStart.0()); recoveredStart.1(true)
    let chainBytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: "Tests/HighPerformancePlayback/chain120.hevc")))
    var chainStarts: [(Int,Int)] = []; var chainIndex = 0
    while chainIndex + 3 < chainBytes.count {
        if Array(chainBytes[chainIndex..<chainIndex+4]) == [0,0,0,1] { chainStarts.append((chainIndex,4)); chainIndex += 4 }
        else if Array(chainBytes[chainIndex..<chainIndex+3]) == [0,0,1] { chainStarts.append((chainIndex,3)); chainIndex += 3 }
        else { chainIndex += 1 }
    }
    let chainUnits = chainStarts.enumerated().map { n,p in Data(chainBytes[(p.0+p.1)..<(n+1 < chainStarts.count ? chainStarts[n+1].0 : chainBytes.count)]) }
    var chainParams = Data([96,1])
    for unit in chainUnits where (32...34).contains(Int((unit.first! >> 1) & 63)) {
        chainParams.append(contentsOf: [UInt8(unit.count >> 8),UInt8(unit.count & 255)]); chainParams.append(unit)
    }
    let chainSink = HEVCSink()
    let chain = try HighPerformanceMediaPipeline(output: chainSink, videoPayloadType: 100, videoCodec: .hevc)
    try chain.configureLTR(enabled: true)
    var chainACKs = 0
    chain.onCleanHEVCFrame = { _ in chainACKs += 1 }
    try chain.consumeVideo(packet(77, payload: chainParams))
    try chain.observe([HighPerformanceSenderReport(ssrc:77,ntpSeconds:1,ntpFraction:0,rtpTimestamp:0)], clockRate:90000)
    var chainFrames = 0
    for unit in chainUnits where (unit.first! >> 1) & 63 < 32 {
        chainFrames += 1
        try chain.consumeVideo(packet(77,seq:UInt8(chainFrames),payload:unit))
        precondition(chainSink.decodes.count == 1)
        let work = chainSink.decodes.removeFirst()
        precondition(work.0(), "complete no-DON reference chain must remain decodable")
        work.1(true)
    }
    precondition(chainFrames == 120 && chainACKs == 0 && chainSink.video == 0)
    print("HEVC single/AP/FU, wrap/loss/malformed/DON, native format and single-SSRC pipeline passed")
 }
}
