import Foundation

@main struct Integration {
 static func main() throws {
    let master = Data((0..<46).map { UInt8($0) })
    let sender = try HighPerformanceSRTPSender(masterKeyBlob: master, ssrc: 7, initialSequence: 65534)
    var receiver = try HighPerformanceSRTPReceiver(masterKeyBlob: master)
    var encrypted: [Data] = []
    for n in 0...270 { encrypted.append(try sender.protect(payload: Data([0x26,1,UInt8(truncatingIfNeeded:n)]),payloadType:100,timestamp:UInt32(n*3000),marker:true)) }
    var reorder = HighPerformanceRTPReorderBuffer()
    let first = reorder.insert(try receiver.receive(encrypted[0]),now:0)
    precondition(first.packets.map(\.sequenceNumber) == [65534])
    let hole = reorder.insert(try receiver.receive(encrypted[269]),now:0.001)
    precondition(hole.packets.isEmpty && hole.missing.count == 268)
    let nack = HighPerformanceNACK.compound(sender:8,media:7,sequences:hole.missing)!
    let feedbackSender = try HighPerformanceSRTCPSender(masterKeyBlob:master,ssrc:8)
    var feedbackReceiver = try HighPerformanceSRTCPReceiver(masterKeyBlob:master)
    let protectedNACK = try feedbackSender.protect(nack)
    let authenticatedNACK = try feedbackReceiver.receive(protectedNACK)
    precondition(authenticatedNACK == nack, "NACK authentication changed feedback")
    var delivered:[UInt16] = []
    for n in 1...268 {
        delivered += reorder.insert(try receiver.receive(encrypted[n]),now:0.025).packets.map(\.sequenceNumber)
    }
    precondition(delivered == (1...269).map { UInt16(truncatingIfNeeded:65534+$0) }, "authenticated repair crossed ROC out of order")
    precondition(!reorder.hasPending)
    do { _ = try receiver.receive(encrypted[1]); fatalError("replay reached jitter buffer") } catch HighPerformanceSRTPError.replay {}
    var forged = encrypted[270]; forged[forged.count-1] ^= 1
    do { _ = try receiver.receive(forged); fatalError("forged retransmit accepted") } catch HighPerformanceSRTPError.authenticationFailed {}
    let next = reorder.insert(try receiver.receive(encrypted[270]),now:0.03)
    precondition(next.packets.count == 1, "forged packet advanced replay/reorder state")
    // Audio feedback carries its own key/SSRC and preserves the original 10 ms AU.
    let audioKey = Data((0..<46).map { UInt8($0 + 50) })
    let audioSender = try HighPerformanceSRTPSender(masterKeyBlob: audioKey, ssrc: 11, initialSequence: 65535)
    var audioReceiver = try HighPerformanceSRTPReceiver(masterKeyBlob: audioKey)
    var audioPackets: [Data] = []
    for n in 0..<8 { audioPackets.append(try audioSender.protect(payload: Data([UInt8(n), 0x42]), payloadType: 101, timestamp: UInt32(n * 480), marker: true)) }
    var audioRepair = HighPerformanceRTPReorderBuffer(packetLimit: 32, byteLimit: 65536, forwardLimit: 64)
    _ = audioRepair.insert(try audioReceiver.receive(audioPackets[0]), now: 0)
    let audioHole = audioRepair.insert(try audioReceiver.receive(audioPackets[2]), now: 0.02)
    precondition(audioHole.missing == [0] && audioHole.packets.isEmpty)
    let audioFeedback = try HighPerformanceSRTCPSender(masterKeyBlob: audioKey, ssrc: 12)
    var audioFeedbackReceiver = try HighPerformanceSRTCPReceiver(masterKeyBlob: audioKey)
    let audioNack = HighPerformanceNACK.compound(sender: 12, media: 11, sequences: audioHole.missing)!
    let decryptedAudioNack = try audioFeedbackReceiver.receive(audioFeedback.protect(audioNack))
    precondition(decryptedAudioNack == audioNack)
    let repairedAudio = audioRepair.insert(try audioReceiver.receive(audioPackets[1]), now: 0.04)
    precondition(repairedAudio.packets.map(\.timestamp) == [480, 960])
    precondition(repairedAudio.packets.map(\.payload) == [Data([1,0x42]), Data([2,0x42])])
    precondition(audioRepair.statistics.repairedHeads == 1)
    let ignored = audioRepair.insert(try audioReceiver.receive(audioPackets[4]), now: 0.05)
    precondition(ignored.packets.isEmpty && ignored.missing == [2])
    precondition(audioRepair.flush(now: 0.071).missing == [2])
    precondition(audioRepair.flush(now: 0.09).missing.isEmpty, "audio retries must be bounded")
    let expired = audioRepair.flush(now: 0.111)
    precondition(expired.packets.map(\.timestamp) == [1920] && !audioRepair.hasPending, "unsupported audio NACK must not freeze playback")
    let tooLate = audioRepair.insert(try audioReceiver.receive(audioPackets[3]), now: 0.12)
    precondition(tooLate.packets.isEmpty, "expired audio must not be replayed out of time")
    print("Audio authenticated 10ms AU repair, separate feedback key, bounded unsupported-peer timeout passed")
    print("Authenticated RTP268-packet repair acrossROC, protectedNACK roundtrip, replay+forgery isolation passed")
 }
}
