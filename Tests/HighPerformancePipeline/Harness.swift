import Foundation
import CoreMedia
@MainActor final class Sink: HighPerformanceMediaOutput {
    var rejectAudio = false
    var presentationSeconds: Double = 0
    var startTimes:[Double]=[]; var audio:[Double]=[];var video:[Double]=[]; var hiddenVideo = 0
    func start(at seconds:Double,playoutDelay:Double)throws { startTimes.append(seconds) }
    func enqueueAudio(_ sample:CMSampleBuffer)throws { if rejectAudio { throw HighPerformancePlaybackError.backpressure }; audio.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) }
    func enqueueVideo(_ sample:CMSampleBuffer)throws {
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]], array.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true { hiddenVideo += 1 }
        video.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) }
    func enqueueVideo(_ sample: CMSampleBuffer, prepare: @escaping @MainActor @Sendable () -> Bool, decodeCompletion: @escaping @MainActor @Sendable (Bool) -> Void) throws {
        precondition(prepare())
        try enqueueVideo(sample)
        decodeCompletion(true)
    }
    func reset() { audio=[];video=[];startTimes=[] }
}
@main struct Harness {
 @MainActor static func main() throws {
    precondition(HighPerformanceH264Recovery.isIntraPicture([Data([0x61,0xb0])])) // first_mb=0, slice_type=2
    precondition(!HighPerformanceH264Recovery.isIntraPicture([Data([0x61,0xc0])])) // P slice
    precondition(!HighPerformanceH264Recovery.isIntraPicture([Data([0x61,0xb0]),Data([0x61,0xc0])]))
    precondition(!HighPerformanceH264Recovery.isIntraPicture([Data([0x61,0])])) // truncated ue(v)
    precondition(!HighPerformanceH264Recovery.isIntraPicture([Data([0x61,0x4c])])) // no first slice
    var arrivals = HighPerformanceAudioArrivalDiagnostics()
    arrivals.observe(sequence: 65534, timestamp: UInt32.max - 479, framesPerPacket: 480)
    arrivals.observe(sequence: 0, timestamp: 480, framesPerPacket: 480)
    precondition(arrivals.forwardSkipped == 1 && arrivals.timestampDiscontinuities == 0)
    arrivals.observe(sequence: 65535, timestamp: 0, framesPerPacket: 480)
    arrivals.observe(sequence: 1, timestamp: 960, framesPerPacket: 480)
    precondition(arrivals.behindHighWater == 1 && arrivals.forwardSkipped == 1 && arrivals.timestampDiscontinuities == 0, "late arrival must not move the sequence/timestamp high water backwards")
    arrivals.observe(sequence: 2, timestamp: 1920, framesPerPacket: 480)
    precondition(arrivals.timestampDiscontinuities == 1, "contiguous packet with missing media time needs distinct evidence")
    let sink=Sink();let pipeline=try HighPerformanceMediaPipeline(output:sink)
    let frame=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
    let b=Array(frame);var units:[Data]=[];var starts:[(Int,Int)]=[];var i=0
    while i+2<b.count { if b[i]==0 && b[i+1]==0 && b[i+2]==1 { starts.append((i,3));i+=3 } else if i+3<b.count && b[i]==0 && b[i+1]==0 && b[i+2]==0 && b[i+3]==1 { starts.append((i,4));i+=4 } else { i+=1 } }
    for (n,s) in starts.enumerated(){ units.append(Data(b[(s.0+s.1)..<(n+1<starts.count ? starts[n+1].0:b.count)])) }
    func packet(_ payload:Data,seq:UInt16,ssrc:UInt32,ts:UInt32,pt:UInt8,marker:Bool=true)throws ->HighPerformanceRTPPacket {
        var bytes:[UInt8]=[0x80,pt|(marker ? 128:0),UInt8(seq>>8),UInt8(truncatingIfNeeded:seq)]
        for v in [ts,ssrc] { bytes += [UInt8(truncatingIfNeeded:v>>24),UInt8(truncatingIfNeeded:v>>16),UInt8(truncatingIfNeeded:v>>8),UInt8(truncatingIfNeeded:v)] };return try HighPerformanceRTPPacket(Data(bytes)+payload)
    }
    for (n,nal) in units.enumerated(){ try pipeline.consumeVideo(packet(nal,seq:UInt16(n),ssrc:1,ts:90000,pt:100,marker:n==units.count-1)) }
    for n in 0..<30 { try pipeline.consumeAudioAccessUnit(packet(Data([1,2,3]),seq:UInt16(n),ssrc:2,ts:UInt32(n*480),pt:101)) }
    precondition(sink.startTimes.isEmpty && pipeline.pendingAudioCount<=20 && pipeline.pendingVideoCount<=2)
    try pipeline.observe([HighPerformanceSenderReport(ssrc:1,ntpSeconds:100,ntpFraction:0,rtpTimestamp:90000)],clockRate:90000)
    precondition(sink.startTimes.count == 1 && sink.video.count == 1 && sink.audio.isEmpty, "video must start with its SR while unmapped audio waits")
    try pipeline.observe([HighPerformanceSenderReport(ssrc:2,ntpSeconds:100,ntpFraction:0,rtpTimestamp:4800)],clockRate:48000)
    precondition(sink.startTimes.count==1 && sink.audio.count<=20 && sink.video.count==1,"did not start common timeline")
    precondition(abs(sink.startTimes[0])<0.000001 && abs(sink.video[0])<0.000001 && abs(sink.audio[0])<0.000001)
    precondition(pipeline.lastCleanVideoDecodeTime != nil, "H264 native completion must advance progress")
    precondition(pipeline.audioPrerollDrops == 10)
    sink.presentationSeconds = 1
    let playedAudio = sink.audio.count
    try pipeline.consumeAudioAccessUnit(packet(Data([1,2,3]),seq:31,ssrc:2,ts:14400,pt:101))
    precondition(sink.audio.count == playedAudio, "late mapped audio must not replay obsolete preroll")
    precondition(pipeline.audioLateDrops == 1)
    sink.presentationSeconds = 0
    sink.rejectAudio = true
    do {
        try pipeline.consumeAudioAccessUnit(packet(Data([1,2,3]),seq:32,ssrc:2,ts:14880,pt:101))
        fatalError("expected native backpressure")
    } catch HighPerformancePlaybackError.backpressure {}
    precondition(pipeline.audioBackpressureEvents == 1 && pipeline.pendingAudioCount == 1)
    sink.rejectAudio = false
    // A fresh SR may move the mapping while renderer backpressure retains an
    // AU. Its already prepared sample must keep the same identity/PTS on retry.
    try pipeline.observe([HighPerformanceSenderReport(ssrc:2,ntpSeconds:101,ntpFraction:0,rtpTimestamp:4800)], clockRate:48000)
    precondition(pipeline.pendingAudioCount == 0 && sink.audio.count == playedAudio + 1, "backpressure must retain rather than drop audio")
    precondition(abs(sink.audio.last! - 0.21) < 0.000001, "backpressure retry remapped an already prepared AU")
    let offsetSink = Sink()
    let offsetPipeline = try HighPerformanceMediaPipeline(output: offsetSink)
    for (n,nal) in units.enumerated() { try offsetPipeline.consumeVideo(packet(nal,seq:UInt16(n),ssrc:10,ts:90000,pt:100,marker:n==units.count-1)) }
    try offsetPipeline.observe([HighPerformanceSenderReport(ssrc:10,ntpSeconds:200,ntpFraction:0,rtpTimestamp:90000)],clockRate:90000)
    try offsetPipeline.consumeAudioAccessUnit(packet(Data([1,2,3]),seq:0,ssrc:20,ts:0,pt:101))
    precondition(offsetSink.audio.isEmpty, "unmapped audio was played")
    try offsetPipeline.observe([HighPerformanceSenderReport(ssrc:20,ntpSeconds:200,ntpFraction:0x20000000,rtpTimestamp:0)],clockRate:48000)
    precondition(offsetSink.video == [0] && offsetSink.audio == [0.125], "independent NTP offset was lost")
    var requests=0; pipeline.onNeedsKeyframe = { requests += 1 }
    try pipeline.consumeVideo(packet(Data([0x61,0x80]),seq:500,ssrc:1,ts:95000,pt:100))
    precondition(requests==1,"loss did not request IDR")
    for ssrc in UInt32(3)...5 { try pipeline.consumeVideo(packet(Data([0x09,0x10]),seq:1,ssrc:ssrc,ts:0,pt:100)) }
    do { try pipeline.consumeVideo(packet(Data([0x09,0x10]),seq:1,ssrc:6,ts:0,pt:100)); fatalError("unbounded video SSRCs") } catch {}
    do { try pipeline.consumeAudioAccessUnit(packet(Data([1]),seq:1,ssrc:1,ts:0,pt:101)); fatalError("shared audio/video SSRC") } catch {}
    let delayedSink = Sink()
    let delayed = try HighPerformanceMediaPipeline(output: delayedSink)
    var sequence: UInt16 = 0
    for nal in units { try delayed.consumeVideo(packet(nal,seq:sequence,ssrc:30,ts:0,pt:100,marker:nal == units.last)); sequence += 1 }
    for n in 1...30 { try delayed.consumeVideo(packet(Data([0x61,0xc0]),seq:sequence,ssrc:30,ts:UInt32(n*3000),pt:100)); sequence += 1 }
    precondition(delayed.pendingVideoCount == 31 && delayedSink.video.isEmpty, "initial dependency chain dropped before SR")
    try delayed.observe([HighPerformanceSenderReport(ssrc:30,ntpSeconds:300,ntpFraction:0,rtpTimestamp:0)],clockRate:90000)
    precondition(delayedSink.video.count == 31 && delayedSink.hiddenVideo == 30, "catchup must decode old references without displaying backlog")
    precondition(delayedSink.startTimes == [1], "startup must use newest PTS, not add one second latency")
    let bounded = try HighPerformanceMediaPipeline(output: Sink())
    sequence = 0
    for nal in units { try bounded.consumeVideo(packet(nal,seq:sequence,ssrc:40,ts:0,pt:100,marker:nal == units.last)); sequence += 1 }
    for n in 1...120 { try bounded.consumeVideo(packet(Data([0x61,0xc0]),seq:sequence,ssrc:40,ts:UInt32(n*3000),pt:100)); sequence += 1 }
    precondition(bounded.pendingVideoCount == 0, "overflow must discard whole dependent chain")
    let alternate=try HighPerformanceMediaPipeline(output:Sink(),videoPayloadType:123)
    try alternate.consumeVideo(packet(Data([0x09,0x10]),seq:1,ssrc:77,ts:0,pt:123))
    do { try alternate.consumeVideo(packet(Data([0x09,0x10]),seq:2,ssrc:77,ts:1,pt:100)); fatalError("unnegotiated video PT accepted") } catch {}
    do { _=try HighPerformanceMediaPipeline(output:Sink(),videoPayloadType:128); fatalError("invalid7bit payload type accepted") } catch {}
    do { _=try HighPerformanceMediaPipeline(output:Sink(),videoPayloadType:101); fatalError("ambiguous audio/video PT accepted") } catch {}
    pipeline.reset();precondition(!pipeline.isPlaying && pipeline.pendingAudioCount==0 && pipeline.pendingVideoCount==0)
    precondition(pipeline.audioLateDrops == 0 && pipeline.audioPrerollDrops == 0 && pipeline.audioBackpressureEvents == 0)
    print("Pipeline: video-first startup and independent audio SRs, bounded preroll, commonPTS startup and reset passed")
 }
}
