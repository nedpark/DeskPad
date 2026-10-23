import Foundation
import AudioToolbox
import CoreMedia

/// Short-gap waveform continuation, not recovery of the missing original audio.
/// Sender PTS is authoritative: concealment never shifts subsequent real samples.
nonisolated struct HighPerformanceAudioConcealment {
    struct Chunk { let samples: [Float]; let seconds: Double }
    let rate: Double
    let channels: Int
    private var history: [Float] = []
    private var expected: Double?
    private(set) var concealedFrames = 0
    private(set) var longGaps = 0

    init(rate: Double, channels: Int) { self.rate = rate; self.channels = channels }
    mutating func process(_ samples: [Float], at seconds: Double) -> [Chunk] {
        guard seconds.isFinite, !samples.isEmpty, samples.count % channels == 0 else { return [] }
        let frames = samples.count / channels
        var actual = samples
        var result: [Chunk] = []
        if let expected {
            let difference = (seconds - expected) * rate
            if difference > 1, !history.isEmpty {
                let maximum = Int(rate * 0.04)
                let gap = Int(min(difference.rounded(), Double(maximum + 1)))
                let filled = min(gap, maximum)
                let lag = period()
                let historyFrames = history.count / channels
                var continuation = [Float](repeating: 0, count: filled * channels)
                for frame in 0..<filled {
                    // Decay across at most 40 ms, including long gaps. A short gap
                    // resumes against the same continued waveform with a crossfade.
                    let gain = Float(max(0, 1 - Double(frame + 1) / Double(maximum)))
                    for channel in 0..<channels {
                        continuation[frame * channels + channel] = history[(historyFrames - lag + frame % lag) * channels + channel] * gain
                    }
                }
                result.append(Chunk(samples: continuation, seconds: expected))
                concealedFrames += filled
                if gap > maximum { longGaps += 1 }
                let fade = min(frames, Int(rate * 0.002))
                for frame in 0..<fade {
                    let mix = Float(frame + 1) / Float(fade)
                    let gain = gap > maximum ? 0 : Float(max(0, 1 - Double(gap + frame + 1) / Double(maximum)))
                    for channel in 0..<channels {
                        let predicted = history[(historyFrames - lag + (gap + frame) % lag) * channels + channel] * gain
                        actual[frame * channels + channel] = predicted * (1 - mix) + samples[frame * channels + channel] * mix
                    }
                }
                if gap > maximum { history.removeAll(keepingCapacity: true) }
            } else if difference < -1 {
                // A new SR anchor can move the timeline; never extrapolate across it.
                history.removeAll(keepingCapacity: true)
            }
        }
        result.append(Chunk(samples: actual, seconds: seconds))
        expected = seconds + Double(frames) / rate
        history.append(contentsOf: samples)
        let limit = Int(rate * 0.02) * channels
        if history.count > limit { history.removeFirst(history.count - limit) }
        return result
    }
    private func period() -> Int {
        let frames = history.count / channels
        let window = min(Int(rate * 0.005), frames / 2)
        let maximum = min(Int(rate * 0.01), frames - window)
        let minimum = min(maximum, max(1, Int(rate / 1000)))
        guard maximum >= minimum, window > 0 else { return max(1, frames) }
        var best = maximum, error = Double.infinity
        // Only 20 ms of history; bounded search independent of session duration.
        for lag in minimum...maximum {
            var candidate = 0.0
            for frame in (frames - window)..<frames {
                for channel in 0..<channels {
                    let delta = Double(history[frame * channels + channel] - history[(frame - lag) * channels + channel])
                    candidate += delta * delta
                }
            }
            if candidate < error { error = candidate; best = lag }
        }
        return best
    }
}

/// Persistent native AAC decoder. The temporary no-input callback status is not
/// EOF; each future RTP AU must continue the same converter state.
nonisolated final class HighPerformancePCMAudio {
    private var converter: AudioConverterRef?
    private var sourceFormat: CMAudioFormatDescription?
    private var pcmFormat: CMAudioFormatDescription?
    private var framesPerPacket: UInt32 = 0
    private var channels: UInt32 = 0
    private var rate = 0.0
    private var concealment: HighPerformanceAudioConcealment?
    private(set) var decodedFrames: UInt64 = 0
    var concealedFrames: Int { concealment?.concealedFrames ?? 0 }
    var longGaps: Int { concealment?.longGaps ?? 0 }

    func prepare(_ sample: CMSampleBuffer) throws -> [CMSampleBuffer] {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { throw HighPerformancePlaybackError.invalidAccessUnit }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard pts.isFinite else { throw HighPerformancePlaybackError.invalidAccessUnit }
        if sourceFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) != false { try configure(format) }
        guard let converter else { throw HighPerformancePlaybackError.missingConfiguration }
        let size = CMBlockBufferGetDataLength(block)
        guard (1...65535).contains(size) else { throw HighPerformancePlaybackError.invalidAccessUnit }
        let input = Input(count: size, channels: channels)
        try check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: input.bytes))
        var pcm = [Float](repeating: 0, count: Int(framesPerPacket * channels))
        var frames = framesPerPacket
        let status = pcm.withUnsafeMutableBytes { output -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(output.count), mData: output.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, count, buffers, descriptions, context in
                let input = Unmanaged<Input>.fromOpaque(context!).takeUnretainedValue()
                guard !input.delivered else { count.pointee = 0; return -12345 }
                input.delivered = true; count.pointee = 1
                buffers.pointee = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: input.channels, mDataByteSize: UInt32(input.count), mData: input.bytes))
                descriptions?.pointee = input.description
                return noErr
            }, Unmanaged.passUnretained(input).toOpaque(), &frames, &list, nil)
        }
        if status != -12345 { try check(status) }
        guard frames > 0, frames <= framesPerPacket else { throw HighPerformancePlaybackError.invalidAccessUnit }
        decodedFrames += UInt64(frames)
        // The wire ELD profile's first decode yields 448/480 frames (32-frame
        // priming). Pad only that initial delay, preserving one RTP AU duration.
        if frames < framesPerPacket {
            guard decodedFrames == UInt64(frames) else { throw HighPerformancePlaybackError.invalidAccessUnit }
            pcm = [Float](repeating: 0, count: Int((framesPerPacket - frames) * channels)) + Array(pcm.prefix(Int(frames * channels)))
        }
        guard pcm.allSatisfy(\.isFinite) else { throw HighPerformancePlaybackError.invalidAccessUnit }
        return try concealment!.process(pcm, at: pts).map(makeSample)
    }

    private func configure(_ format: CMAudioFormatDescription) throws {
        reset()
        guard var source = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              source.mSampleRate == 48000, (1...2).contains(source.mChannelsPerFrame),
              (1...1024).contains(source.mFramesPerPacket),
              [kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR].contains(source.mFormatID) else { throw HighPerformancePlaybackError.unsupportedAudio }
        channels = source.mChannelsPerFrame; rate = source.mSampleRate; framesPerPacket = source.mFramesPerPacket
        var target = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: channels * 4,
            mFramesPerPacket: 1, mBytesPerFrame: channels * 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioConverterNew(&source, &target, &converter))
        guard let converter else { throw HighPerformancePlaybackError.unsupportedAudio }
        var cookieSize = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieSize) else { throw HighPerformancePlaybackError.unsupportedAudio }
        try check(AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookieSize), cookie))
        try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &target, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &pcmFormat))
        sourceFormat = format; concealment = HighPerformanceAudioConcealment(rate: rate, channels: Int(channels))
    }
    private func makeSample(_ chunk: HighPerformanceAudioConcealment.Chunk) throws -> CMSampleBuffer {
        guard let pcmFormat else { throw HighPerformancePlaybackError.missingConfiguration }
        var block: CMBlockBuffer?
        let bytes = chunk.samples.count * MemoryLayout<Float>.size
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block))
        guard let block else { throw HighPerformancePlaybackError.invalidAccessUnit }
        try chunk.samples.withUnsafeBytes { try check(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: CMTime(seconds: chunk.seconds, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?, sampleSize = Int(channels) * 4
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: pcmFormat,
            sampleCount: chunk.samples.count / Int(channels), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample))
        guard let sample else { throw HighPerformancePlaybackError.invalidAccessUnit }; return sample
    }
    func reset() {
        if let converter { AudioConverterDispose(converter) }
        converter = nil; sourceFormat = nil; pcmFormat = nil; concealment = nil; decodedFrames = 0
    }
    deinit { if let converter { AudioConverterDispose(converter) } }
    private func check(_ status: OSStatus) throws { if status != noErr { throw HighPerformancePlaybackError.mediaStatus(status) } }
    private final class Input {
        let bytes: UnsafeMutableRawPointer, description: UnsafeMutablePointer<AudioStreamPacketDescription>
        let count: Int; let channels: UInt32
        var delivered = false
        init(count: Int, channels: UInt32) {
            self.count = count; self.channels = channels; bytes = .allocate(byteCount: count, alignment: 1)
            description = .allocate(capacity: 1)
            description.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(count)))
        }
        deinit { bytes.deallocate(); description.deinitialize(count: 1); description.deallocate() }
    }
}

/// Retains prepared chunks across partial renderer backpressure. Retrying the
/// same AU must never advance the stateful AAC decoder or concealment twice.
nonisolated final class HighPerformancePCMAudioDelivery {
    private let decoder = HighPerformancePCMAudio()
    private var pending: [CMSampleBuffer] = []
    private var sourcePTS: CMTime?
    var decodedFrames: UInt64 { decoder.decodedFrames }
    var concealedFrames: Int { decoder.concealedFrames }
    var longGaps: Int { decoder.longGaps }
    func enqueue(_ sample: CMSampleBuffer, isReady: () -> Bool, emit: (CMSampleBuffer) -> Void) throws {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if let previous = sourcePTS, CMTimeCompare(previous, pts) != 0 {
            // An obsolete AU may have been dropped by the pipeline while the
            // renderer was blocked. Retain decoder state, not stale output.
            pending.removeAll(); sourcePTS = nil
        }
        if sourcePTS == nil {
            guard isReady() else { throw HighPerformancePlaybackError.backpressure }
            pending = try decoder.prepare(sample); sourcePTS = pts
        }
        while let chunk = pending.first {
            guard isReady() else { throw HighPerformancePlaybackError.backpressure }
            emit(chunk); pending.removeFirst()
        }
        sourcePTS = nil
    }
    func reset() { decoder.reset(); pending.removeAll(); sourcePTS = nil }
}
