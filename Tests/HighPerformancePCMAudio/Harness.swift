import Foundation
import CoreMedia
@main struct Harness {
 static func main() throws {
    let rate = 48000.0
    func tone(_ first: Int, _ frames: Int) -> [Float] {
        var result: [Float] = []
        for frame in first..<first+frames {
            let phase = Double(frame) * (2 * Double.pi * 880 / rate)
            let value = Float(sin(phase) * 0.1)
            result.append(value); result.append(value)
        }
        return result
    }
    var smoother = HighPerformanceAudioConcealment(rate:rate,channels:2)
    _ = smoother.process(tone(0,480),at:0)
    _ = smoother.process(tone(480,480),at:0.01)
    let repaired = smoother.process(tone(1440,480),at:0.03)
    precondition(repaired.count == 2 && repaired[0].samples.count == 960 && repaired[0].seconds == 0.02 && repaired[1].seconds == 0.03)
    let expected = tone(960,480)
    let mse = zip(repaired[0].samples,expected).reduce(0.0) { $0 + pow(Double($1.0-$1.1),2) } / Double(expected.count)
    precondition(sqrt(mse) < 0.025, "period continuation must improve a periodic signal over silence")
    precondition(repaired.flatMap(\.samples).allSatisfy { $0.isFinite && abs($0) <= 0.101 })
    let long = smoother.process(tone(48000,480),at:1)
    precondition(long.count == 2 && long[0].samples.count == 1920*2 && long[1].seconds == 1)
    precondition(long[0].samples.suffix(2).allSatisfy { $0 == 0 } && smoother.longGaps == 1)
    precondition(smoother.process(tone(0,480),at:0).count == 1, "timestamp reset must not extrapolate stale history")
    var clock = HighPerformanceMediaClock()
    try clock.observe(HighPerformanceSenderReport(ssrc: 5,ntpSeconds:100,ntpFraction:0,rtpTimestamp:UInt32.max-511),clockRate:48000)
    var wrapped = HighPerformanceAudioConcealment(rate:rate,channels:2)
    _ = wrapped.process(tone(0,512),at:clock.presentationSeconds(ssrc:5,timestamp:UInt32.max-511)!)
    let afterWrap = wrapped.process(tone(1024,512),at:clock.presentationSeconds(ssrc:5,timestamp:512)!)
    precondition(afterWrap.count == 2 && afterWrap[0].samples.count == 512*2 && abs(afterWrap[1].seconds-1024/rate)<0.000001)
    let factory = HighPerformanceSampleFactory()
    try factory.configureAAC(audioSpecificConfig:Data([0xf8,0xe6,0x40,0]))
    let decoder = HighPerformancePCMAudio()
    let bytes = [UInt8](try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    var index=0, cursor=0, nonzero=0, lastEnd=0.0
    while cursor < bytes.count {
        let size = Int(bytes[cursor])<<8|Int(bytes[cursor+1]);cursor += 2
        let au=Data(bytes[cursor..<cursor+size]);cursor += size
        defer { index += 1 }
        if index == 10 || index == 11 { continue }
        let pts=Double(index*512)/rate
        let output=try decoder.prepare(factory.aacAccessUnit(au,presentationSeconds:pts))
        precondition(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(output.last!)) == CMTime(seconds:pts,preferredTimescale:1_000_000).seconds)
        for sample in output {
            let block=CMSampleBufferGetDataBuffer(sample)!
            let count=CMBlockBufferGetDataLength(block)/4
            var pcm=[Float](repeating:0,count:count)
            _=pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count*4,destination:$0.baseAddress!) }
            precondition(pcm.allSatisfy(\.isFinite))
            if pcm.contains(where:{abs($0)>0.001}) { nonzero += 1 }
            lastEnd=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))+CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
        }
    }
    precondition(decoder.decodedFrames == 28*512 && decoder.concealedFrames == 1024 && nonzero >= 28)
    precondition(abs(lastEnd-Double(30*512)/rate)<0.000002,"gap concealment must not drift common sender timeline")
    decoder.reset(); precondition(decoder.decodedFrames == 0 && decoder.concealedFrames == 0)
    let silenceFactory = HighPerformanceSampleFactory()
    try silenceFactory.configureAAC(audioSpecificConfig:Data([0xf8,0xe6,0x51,0x32,0xe0,0]))
    for n in 0..<20 {
        let output=try decoder.prepare(silenceFactory.aacAccessUnit(Data([0,0x68,0x34,0]),presentationSeconds:Double(n)/100))
        precondition(output.count == 1 && CMSampleBufferGetNumSamples(output[0]) == 480)
    }
    precondition(decoder.decodedFrames == 20*480-32 && decoder.concealedFrames == 0)
    let delivery = HighPerformancePCMAudioDelivery()
    let firstSample = try silenceFactory.aacAccessUnit(Data([0,0x68,0x34,0]),presentationSeconds:0)
    var sent: [Double] = []
    try delivery.enqueue(firstSample,isReady:{true},emit:{sent.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)))})
    let delayed = try silenceFactory.aacAccessUnit(Data([0,0x68,0x34,0]),presentationSeconds:0.03)
    var readyChecks = 0
    do {
        try delivery.enqueue(delayed,isReady:{ readyChecks += 1; return readyChecks < 3 },emit:{sent.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)))})
        fatalError("expected backpressure after concealment chunk")
    } catch HighPerformancePlaybackError.backpressure {}
    let decodedBeforeRetry = delivery.decodedFrames
    let concealedBeforeRetry = delivery.concealedFrames
    precondition(sent == [0,0.01])
    try delivery.enqueue(delayed,isReady:{true},emit:{sent.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)))})
    precondition(sent == [0,0.01,0.03] && delivery.decodedFrames == decodedBeforeRetry && delivery.concealedFrames == concealedBeforeRetry)
    var pendingChecks = 0
    do {
        try delivery.enqueue(silenceFactory.aacAccessUnit(Data([0,0x68,0x34,0]),presentationSeconds:0.06), isReady:{ pendingChecks += 1; return pendingChecks == 1 },emit:{_ in fatalError("blocked renderer emitted")})
    } catch HighPerformancePlaybackError.backpressure {}
    delivery.reset()
    sent.removeAll()
    try delivery.enqueue(firstSample,isReady:{true},emit:{sent.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)))})
    precondition(sent == [0], "reconnect must not emit a pending chunk from the old session")
    delivery.reset()
    precondition(delivery.decodedFrames == 0 && delivery.concealedFrames == 0)
    print("Persistent AAC tone/wire decode, 10/20ms continuation, 40ms bound, exact PTS, initial priming and reset passed")
 }
}
