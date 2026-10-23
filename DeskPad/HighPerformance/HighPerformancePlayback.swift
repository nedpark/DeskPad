import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
#if DEBUG
import os
#endif

enum HighPerformancePlaybackError: Error {
    case invalidAccessUnit, missingConfiguration, unsupportedAudio, mediaStatus(OSStatus), backpressure, rendererFailed
}

/// Builds complete, authenticated access units into compressed CMSampleBuffers.
/// No RTP depacketization is performed here. Confine to one queue/actor.
final class HighPerformanceSampleFactory {
    private var hevcParameters: [Int: Data] = [:]
    private var hevcFormat: CMVideoFormatDescription?
    var hasHEVCConfiguration: Bool { hevcFormat != nil }
    private var sps: Data?
    private var pps: Data?
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?

    var audioStreamDescription: AudioStreamBasicDescription? {
        guard let audioFormat else { return nil }
        return CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee
    }

    func reset() { hevcParameters.removeAll(); hevcFormat = nil; sps = nil; pps = nil; videoFormat = nil; audioFormat = nil }

    /// Wraps MPEG-4 AudioSpecificConfig in an ESDS descriptor for CoreAudio's magic cookie API.
    /// Format parameters are obtained from CoreAudio, never inferred from RTP timestamps.
    func configureAAC(audioSpecificConfig asc: Data) throws {
        audioFormat = nil
        guard !asc.isEmpty, asc.count <= 64 else { throw HighPerformancePlaybackError.unsupportedAudio }
        func descriptor(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] { [tag, UInt8(payload.count)] + payload }
        let decoder = descriptor(4, [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + descriptor(5, Array(asc)))
        let cookie = descriptor(3, [0, 1, 0] + decoder + descriptor(6, [2]))
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatMPEG4AAC_ELD
        var size = UInt32(MemoryLayout.size(ofValue: asbd))
        let status = cookie.withUnsafeBytes { AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(cookie.count), $0.baseAddress, &size, &asbd) }
        guard status == noErr, asbd.mSampleRate > 0, asbd.mSampleRate <= 192000,
              asbd.mChannelsPerFrame > 0, asbd.mChannelsPerFrame <= 2,
              asbd.mFramesPerPacket > 0,
              [kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR].contains(asbd.mFormatID) else {
            throw HighPerformancePlaybackError.unsupportedAudio
        }
        // Fail before enqueueing if this OS cannot create the decoder or accept its cookie.
        var pcm = AudioStreamBasicDescription(mSampleRate: asbd.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * asbd.mChannelsPerFrame,
            mFramesPerPacket: 1, mBytesPerFrame: 4 * asbd.mChannelsPerFrame, mChannelsPerFrame: asbd.mChannelsPerFrame,
            mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        try requireStatus(AudioConverterNew(&asbd, &pcm, &converter))
        guard let converter else { throw HighPerformancePlaybackError.unsupportedAudio }
        defer { AudioConverterDispose(converter) }
        try cookie.withUnsafeBytes { try requireStatus(AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)) }
        var format: CMAudioFormatDescription?
        try cookie.withUnsafeBytes { try requireStatus(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: $0.baseAddress,
            extensions: nil, formatDescriptionOut: &format)) }
        audioFormat = format
    }

    func aacAccessUnit(_ data: Data, presentationSeconds: Double) throws -> CMSampleBuffer {
        guard !data.isEmpty, data.count <= 65535, presentationSeconds.isFinite else { throw HighPerformancePlaybackError.invalidAccessUnit }
        guard let audioFormat else { throw HighPerformancePlaybackError.missingConfiguration }
        let block = try makeBlock(data)
        var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
        var sample: CMSampleBuffer?
        try requireStatus(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: audioFormat, sampleCount: 1, presentationTimeStamp: CMTime(seconds: presentationSeconds, preferredTimescale: 1_000_000),
            packetDescriptions: &description, sampleBufferOut: &sample))
        guard let sample else { throw HighPerformancePlaybackError.invalidAccessUnit }
        return sample
    }

    /// One complete HEVC AU after authenticated depacketization. Only one picture
    /// stream is supported; callers must reject multi-SSRC tiled negotiation.
    func hevcAccessUnit(_ units: [Data], presentationSeconds: Double) throws -> CMSampleBuffer? {
        guard presentationSeconds.isFinite, !units.isEmpty, units.count <= 256,
              units.reduce(0, { $0 + $1.count }) <= 8 * 1024 * 1024 else { throw HighPerformancePlaybackError.invalidAccessUnit }
        var buffer = Data()
        var hasPicture = false
        for unit in units {
            let b = [UInt8](unit.prefix(2))
            guard unit.count >= 3, b[0] & 128 == 0, b[1] & 7 != 0 else { throw HighPerformancePlaybackError.invalidAccessUnit }
            let type = Int((b[0] >> 1) & 63)
            guard type < 48 else { throw HighPerformancePlaybackError.invalidAccessUnit }
            if (32...34).contains(type) {
                if hevcParameters[type] != unit { hevcFormat = nil; hevcParameters[type] = unit }
            } else {
                hasPicture = hasPicture || type < 32
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }
                buffer.append(unit)
            }
        }
        if hevcFormat == nil, let vps = hevcParameters[32], let sps = hevcParameters[33], let pps = hevcParameters[34] {
            try vps.withUnsafeBytes { v in try sps.withUnsafeBytes { s in try pps.withUnsafeBytes { p in
                var pointers = [v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                var sizes = [vps.count, sps.count, pps.count]
                try requireStatus(CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 3, parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &hevcFormat))
            } } }
        }
        guard hasPicture else { return nil }
        guard let hevcFormat else { throw HighPerformancePlaybackError.missingConfiguration }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: presentationSeconds, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = buffer.count
        var sample: CMSampleBuffer?
        try requireStatus(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: try makeBlock(buffer),
            formatDescription: hevcFormat, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
        return sample
    }

    /// Returns nil for a configuration-only access unit; VCL requires valid SPS/PPS.
    /// Accepts Annex-B H.264 only. HEVC must use a separately negotiated decoder path.
    func h264AccessUnit(_ data: Data, presentationSeconds: Double) throws -> CMSampleBuffer? {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024, presentationSeconds.isFinite else { throw HighPerformancePlaybackError.invalidAccessUnit }
        let b = Array(data)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0 && b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < b.count && b[i + 2] == 0 && b[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        guard let first = starts.first, b[..<first.0].allSatisfy({ $0 == 0 }), starts.count <= 4096 else { throw HighPerformancePlaybackError.invalidAccessUnit }
        var avcc = Data()
        var hasSlice = false
        var changed = false
        for (n, start) in starts.enumerated() {
            let begin = start.0 + start.1
            var end = n + 1 < starts.count ? starts[n + 1].0 : b.count
            while end > begin && b[end - 1] == 0 { end -= 1 }
            guard end > begin, b[begin] & 0x80 == 0 else { throw HighPerformancePlaybackError.invalidAccessUnit }
            let nal = Data(b[begin..<end]), type = b[begin] & 31
            if type == 7 { if sps != nal { sps = nal; changed = true } }
            else if type == 8 { if pps != nal { pps = nal; changed = true } }
            else {
                if (1...5).contains(type) { hasSlice = true }
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }; avcc.append(nal)
            }
        }
        if changed { videoFormat = nil }
        if videoFormat == nil, let sps, let pps {
            try sps.withUnsafeBytes { s in try pps.withUnsafeBytes { p in
                var pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                var sizes = [sps.count, pps.count]
                try requireStatus(CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &videoFormat))
            } }
        }
        guard hasSlice else { return nil }
        guard let videoFormat else { throw HighPerformancePlaybackError.missingConfiguration }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: presentationSeconds, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        try requireStatus(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: try makeBlock(avcc),
            formatDescription: videoFormat, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
        return sample
    }
}

/// Native audio and video share one playback clock. Video can start with its own
/// SR-derived timestamp; audio joins after its independent SR. Reset on reconnect.
@MainActor final class HighPerformancePlayback {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var nativeVideoDecoder: HighPerformanceNativeVideoDecoder?
    private let pcmAudio = HighPerformancePCMAudioDelivery()

    #if DEBUG
    private var diagnosticAudioEnqueues = 0
    private var diagnosticPresentationPolls = 0
    private var audioDiagnostic = HighPerformanceAudioDiagnostic()
    #endif
    /// Suspension can invalidate the renderer even while its network remains healthy.
    /// Recreate the session instead of flushing away a predictive frame's references.
    var needsRecovery: Bool {
        videoLayer.sampleBufferRenderer.requiresFlushToResumeDecoding ||
        videoLayer.sampleBufferRenderer.status == .failed || audioRenderer.status == .failed
    }

    var presentationSeconds: Double { CMTimeGetSeconds(synchronizer.currentTime()) }

    /// A decoded pixel buffer actually selected for display, not merely queued RTP.
    var hasDisplayedVideoFrame: Bool {
        if #available(macOS 14.4, iOS 17.4, *) {
            let displayed = videoLayer.sampleBufferRenderer.displayedPixelBuffer() != nil
            #if DEBUG
            diagnosticPresentationPolls += 1
            if diagnosticPresentationPolls <= 2 || diagnosticPresentationPolls % 100 == 0 {
                let status = videoLayer.sampleBufferRenderer.status.rawValue
                let error = (videoLayer.sampleBufferRenderer.error as NSError?)?.code ?? 0
                let time = presentationSeconds
                VNCControlDiagnostics.logger.notice("HP renderer poll=\(self.diagnosticPresentationPolls) displayed=\(displayed) status=\(status) error=\(error) time=\(time) width=\(self.videoLayer.bounds.width) height=\(self.videoLayer.bounds.height)")
            }
            #endif
            return displayed
        }
        return false
    }

    init() {
        // Idle audio must not hold the shared clock at zero indefinitely.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(videoLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
    }

    func start(at senderSeconds: Double, playoutDelay: Double = 0.08) throws {
        guard senderSeconds.isFinite, playoutDelay.isFinite, (0...1).contains(playoutDelay) else { throw HighPerformancePlaybackError.invalidAccessUnit }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: playoutDelay, preferredTimescale: 1_000_000)
        synchronizer.setRate(1, time: CMTime(seconds: senderSeconds, preferredTimescale: 1_000_000), atHostTime: host)
    }

    func enqueueVideo(_ sample: CMSampleBuffer) throws {
        guard videoLayer.sampleBufferRenderer.status != .failed else { throw HighPerformancePlaybackError.rendererFailed }
        guard videoLayer.sampleBufferRenderer.isReadyForMoreMediaData else { throw HighPerformancePlaybackError.backpressure }
        videoLayer.sampleBufferRenderer.enqueue(sample)
    }

    /// The caller must independently validate reference dependencies before ACK.
    /// Success means native decode produced an image and the display accepted it.
    func enqueueVideo(_ sample: CMSampleBuffer, prepare: @escaping @MainActor @Sendable () -> Bool = { true }, decodeCompletion: @escaping @MainActor @Sendable (Bool) -> Void) throws {
        if nativeVideoDecoder == nil { nativeVideoDecoder = HighPerformanceNativeVideoDecoder() }
        try nativeVideoDecoder!.enqueue(sample, prepare: prepare) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let decoded):
                do { try self.enqueueVideo(decoded.sample); decodeCompletion(true) }
                catch { decodeCompletion(false) }
            case .failure: decodeCompletion(false)
            }
        }
    }

    func enqueueAudio(_ sample: CMSampleBuffer) throws {
        guard audioRenderer.status != .failed else { throw HighPerformancePlaybackError.rendererFailed }
        try pcmAudio.enqueue(sample, isReady: { audioRenderer.isReadyForMoreMediaData }, emit: { audioRenderer.enqueue($0) })
        #if DEBUG
        audioDiagnostic.inspect(sample, clock: presentationSeconds)
        diagnosticAudioEnqueues += 1
        if diagnosticAudioEnqueues <= 2 || diagnosticAudioEnqueues % 500 == 0 {
            VNCControlDiagnostics.logger.notice("HP PCM playback enqueued=\(self.diagnosticAudioEnqueues) decoded_frames=\(self.pcmAudio.decodedFrames) concealed_frames=\(self.pcmAudio.concealedFrames) long_gaps=\(self.pcmAudio.longGaps)")
        }
        #endif
    }

    func setMuted(_ muted: Bool) { audioRenderer.isMuted = muted }

    func reset() {
        nativeVideoDecoder?.reset()
        pcmAudio.reset()
        synchronizer.setRate(0, time: .zero)
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        audioRenderer.flush()
        #if DEBUG
        audioDiagnostic = HighPerformanceAudioDiagnostic()
        diagnosticAudioEnqueues = 0
        #endif
    }
}

private func requireStatus(_ status: OSStatus) throws { if status != noErr { throw HighPerformancePlaybackError.mediaStatus(status) } }
private func makeBlock(_ data: Data) throws -> CMBlockBuffer {
    var block: CMBlockBuffer?
    try requireStatus(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block))
    guard let block else { throw HighPerformancePlaybackError.invalidAccessUnit }
    try data.withUnsafeBytes { try requireStatus(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)) }
    return block
}

#if DEBUG
/// Independent native decode for bounded, content-free audio acceptance metrics.
/// This measures received PCM, not speaker output or perceived A/V synchronization.
final class HighPerformanceAudioDiagnostic {
    private var converter: AudioConverterRef?
    private var packetFrames: UInt32 = 480
    private var channels: UInt32 = 2
    private var count = 0
    private(set) var nonSilent = 0
    private var maximumPeak: Float = 0
    private(set) var decodedFrames: UInt64 = 0

    func inspect(_ sample: CMSampleBuffer, clock: Double) {
        count += 1
        do {
            let format = CMSampleBufferGetFormatDescription(sample)!
            if converter == nil {
                var source = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
                guard source.mSampleRate > 0, source.mChannelsPerFrame <= 2, source.mFramesPerPacket <= 4096 else { return }
                channels = source.mChannelsPerFrame; packetFrames = source.mFramesPerPacket
                var target = AudioStreamBasicDescription(mSampleRate: source.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: channels * 4,
                    mFramesPerPacket: 1, mBytesPerFrame: channels * 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
                try requireStatus(AudioConverterNew(&source, &target, &converter))
                var size = 0
                guard let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size), let converter else { return }
                try requireStatus(AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(size), cookie))
                VNCControlDiagnostics.logger.notice("HP audio decode profile rate=\(source.mSampleRate) channels=\(source.mChannelsPerFrame) frames_per_packet=\(source.mFramesPerPacket) codec=\(source.mFormatID)")
            }
            guard let converter, let block = CMSampleBufferGetDataBuffer(sample) else { return }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length <= 65535 else { return }
            let input = Input(count: length)
            try requireStatus(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: input.bytes))
            var pcm = [Float](repeating: 0, count: 4096 * Int(channels))
            var frames: UInt32 = packetFrames
            let status = pcm.withUnsafeMutableBytes { output -> OSStatus in
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(output.count), mData: output.baseAddress))
                return AudioConverterFillComplexBuffer(converter, { _, count, buffers, descriptions, context in
                    let input = Unmanaged<Input>.fromOpaque(context!).takeUnretainedValue()
                    guard !input.delivered else {
                        // Zero packets + noErr means permanent end-of-stream.
                        // RTP supplies another AU later; preserve decoder state.
                        count.pointee = 0; return -12345
                    }
                    input.delivered = true; count.pointee = 1
                    buffers.pointee = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(input.count), mData: input.bytes))
                    descriptions?.pointee = input.description
                    return noErr
                }, Unmanaged.passUnretained(input).toOpaque(), &frames, &buffers, nil)
            }
            if status != -12345 { try requireStatus(status) }
            let peak = pcm.prefix(Int(frames * channels)).reduce(Float(0)) { max($0, abs($1)) }
            decodedFrames += UInt64(frames); maximumPeak = max(maximumPeak, peak)
            if peak > 0.001 { nonSilent += 1 }
            if count <= 2 || count % 100 == 0 || (peak > 0.001 && nonSilent <= 2) {
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                VNCControlDiagnostics.logger.notice("HP audio PCM packets=\(self.count) non_silent=\(self.nonSilent) decoded_frames=\(self.decodedFrames) peak=\(self.maximumPeak) sample_pts=\(pts) playback_clock=\(clock) queued_ahead=\(pts-clock)")
                maximumPeak = 0
            }
        } catch {
            if count <= 2 || count % 100 == 0 {
                let code = (error as NSError).code
                VNCControlDiagnostics.logger.notice("HP audio diagnostic decode failed count=\(self.count) error=\(code)")
            }
        }
    }
    deinit { if let converter { AudioConverterDispose(converter) } }
    private final class Input {
        let bytes: UnsafeMutableRawPointer
        let count: Int
        let description: UnsafeMutablePointer<AudioStreamPacketDescription>
        var delivered = false
        init(count: Int) {
            self.count = count; bytes = .allocate(byteCount: count, alignment: 1)
            description = .allocate(capacity: 1)
            description.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(count)))
        }
        deinit { bytes.deallocate(); description.deinitialize(count: 1); description.deallocate() }
    }
}
#endif
