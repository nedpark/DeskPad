import Foundation
@main struct Harness {
 static func main() throws {
    func word(_ data: Data, _ offset: Int) -> UInt32 { data.dropFirst(offset).prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    func packet(_ seq: UInt16, _ timestamp: UInt32 = 0) throws -> HighPerformanceRTPPacket {
        try HighPerformanceRTPPacket(Data([0x80,100,UInt8(seq>>8),UInt8(seq&255),UInt8(truncatingIfNeeded:timestamp>>24),UInt8(truncatingIfNeeded:timestamp>>16),UInt8(truncatingIfNeeded:timestamp>>8),UInt8(truncatingIfNeeded:timestamp),0,0,0,2]))
    }
    var report = AppleHPReceptionReport()
    precondition(report.receiverReport(sender:1,media:2,now:0) == Data([0x80,201,0,1,0,0,0,1]))
    report.observe(try packet(65534),now:0)
    report.observe(try packet(0),now:0)
    let lost = report.receiverReport(sender:1,media:2,now:0)
    precondition(lost.count == 32 && Array(lost.prefix(4)) == [0x81,201,0,7])
    precondition(word(lost,12) == 0x55000001 && word(lost,16) == 65536)
    report.observe(try packet(65535),now:0.01)
    report.observe(HighPerformanceSenderReport(ssrc:2,ntpSeconds:0x12345678,ntpFraction:0xabcdef00,rtpTimestamp:0),now:1)
    let repaired = report.receiverReport(sender:1,media:2,now:1.5)
    precondition(word(repaired,12) == 0 && word(repaired,16) == 65536)
    precondition(word(repaired,24) == 0x5678abcd && word(repaired,28) == 32768)
    let sr = AppleHPReceptionReport.senderReport(sender:1,unixTime:1.5)
    precondition(sr.count == 28 && word(sr,8) == 2208988801 && word(sr,12) == 0x80000000)
    precondition(word(sr,20) == 0 && word(sr,24) == 0)
    let parsed = try HighPerformanceSenderReport.parseCompound(sr + repaired)
    precondition(parsed.count == 1 && parsed[0].ssrc == 1)
    var jitter = AppleHPReceptionReport()
    jitter.observe(try packet(1,0),now:0)
    jitter.observe(try packet(2,900),now:0.02)
    precondition(word(jitter.receiverReport(sender:1,media:2,now:0.02),20) == 56)
    var audioReport = AppleHPReceptionReport(clockRate: 48_000)
    audioReport.observe(try packet(100,0), now: 1)
    audioReport.observe(try packet(102,960), now: 1.03)
    audioReport.observe(HighPerformanceSenderReport(ssrc: 77, ntpSeconds: 0x11223344, ntpFraction: 0x55667788, rtpTimestamp: 960), now: 1.03)
    let audioRR = audioReport.receiverReport(sender: 88, media: 77, now: 1.53)
    precondition(word(audioRR,4) == 88 && word(audioRR,8) == 77, "audio report must name audio SSRCs")
    precondition(word(audioRR,12) == 0x55000001, "one of three audio packets was missing")
    precondition(word(audioRR,20) == 30, "audio jitter must use 48k rather than video 90k")
    precondition(word(audioRR,24) == 0x33445566 && word(audioRR,28) == 32768, "audio SR timing must remain independent of video")
    let audioKey = Data((0..<46).map { UInt8($0) })
    let audioFeedback = try HighPerformanceSRTCPSender(masterKeyBlob: audioKey, ssrc: 88)
    var peerAudio = try HighPerformanceSRTCPReceiver(masterKeyBlob: audioKey)
    let protectedRR = try audioFeedback.protect(audioRR)
    let authenticatedRR = try peerAudio.receive(protectedRR)
    precondition(authenticatedRR == audioRR)
    var wrongVideoKey = try HighPerformanceSRTCPReceiver(masterKeyBlob: Data((0..<46).map { UInt8($0 + 50) }))
    do { _ = try wrongVideoKey.receive(protectedRR); fatalError("audio feedback authenticated with video key") }
    catch HighPerformanceSRTPError.authenticationFailed {}
    // Recovering an authenticated late AU reduces network loss, irrespective of
    // whether its playout deadline has already passed.
    audioReport.observe(try packet(101,480), now: 1.54)
    precondition(word(audioReport.receiverReport(sender: 88, media: 77, now: 1.54),12) == 0)
    print("48k audio RR loss, independent SSRC/LSR/DLSR, late repair and jitter passed")
    print("RR loss fraction, rollover, late repair, LSR/DLSR, jitter and compound SR vectors passed")
 }
}
