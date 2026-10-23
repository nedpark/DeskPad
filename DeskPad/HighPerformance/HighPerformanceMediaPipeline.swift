import Foundation
import CoreMedia
#if DEBUG
import os
#endif

@MainActor protocol HighPerformanceMediaOutput: AnyObject {
    var presentationSeconds: Double { get }
    func start(at senderSeconds: Double, playoutDelay: Double) throws
    func enqueueVideo(_ sample: CMSampleBuffer) throws
    func enqueueVideo(_ sample: CMSampleBuffer, prepare: @escaping @MainActor @Sendable () -> Bool, decodeCompletion: @escaping @MainActor @Sendable (Bool) -> Void) throws
    func enqueueAudio(_ sample: CMSampleBuffer) throws
    func reset()
}
extension HighPerformancePlayback: HighPerformanceMediaOutput {}
extension HighPerformanceMediaOutput {
    func enqueueVideo(_ sample: CMSampleBuffer, prepare: @escaping @MainActor @Sendable () -> Bool, decodeCompletion: @escaping @MainActor @Sendable (Bool) -> Void) throws {
        throw HighPerformancePlaybackError.missingConfiguration
    }
}

/// Single-display H.264 + AAC-ELD coordinator. All inputs must already be authenticated.
/// RTP arrival times are never used as A/V timestamps. A session without Sender Reports
/// remains in bounded preroll instead of playing unsynchronized audio.
@MainActor final class HighPerformanceMediaPipeline {
    enum VideoCodec { case h264, hevc }
    enum Failure: Error { case unsupportedStream, tooManyStreams, invalidConfiguration }
    private struct VideoState {
        var depacketizer = AppleHPVideoDepacketizer()
        var hevcDepacketizer = AppleHPHEVCDepacketizer()
        var expectedSequence: UInt16?
        var referenceParameters: [Data] = []
        let factory = HighPerformanceSampleFactory()
    }
    private struct PendingVideo { let ssrc: UInt32; let timestamp: UInt32; let annexB: Data; let keyframe: Bool; var hevcUnits: [Data]? = nil; var don: UInt16? = nil }
    private struct PendingAudio { let ssrc: UInt32; let timestamp: UInt32; let data: Data; var prepared: CMSampleBuffer? = nil }
    private let output: any HighPerformanceMediaOutput
    private let audioFactory = HighPerformanceSampleFactory()
    private let videoCodec: VideoCodec
    private let videoPayloadType: UInt8
    private let videoRate: Double
    private let audioRate: Double
    private let audioFrames: UInt32
    private let aggregation: AppleHPVideoDepacketizer.AggregationFormat
    private var clock = HighPerformanceMediaClock()
    private var videos: [UInt32: VideoState] = [:]
    private var selectedVideo: UInt32?
    private var selectedAudio: UInt32?
    private var pendingVideo: [PendingVideo] = []
    private var pendingAudio: [PendingAudio] = []
    private(set) var audioLateDrops = 0
    private(set) var audioPrerollDrops = 0
    private(set) var audioBackpressureEvents = 0
    private var receivedAudioPackets = 0
    private var audioArrival = HighPerformanceAudioArrivalDiagnostics()
    private var ltrEnabled = false
    private var referenceGuard = AppleHPHEVCReferenceGuard()
    var onCleanHEVCFrame: ((UInt16) -> Void)?
    private final class PreparedPicture { var picture: AppleHPHEVCReferenceGuard.Picture? }
    func configureLTR(enabled: Bool) throws {
        guard !isPlaying, pendingVideo.isEmpty, videos.isEmpty, !enabled || videoCodec == .hevc else { throw Failure.invalidConfiguration }
        ltrEnabled = enabled; referenceGuard.reset()
    }
    private var needsKeyframe = true
    private(set) var isPlaying = false
    private(set) var lastCleanVideoDecodeTime: Double?
    #if DEBUG
    private var diagnosticVideoPackets = 0
    private var diagnosticVideoAUs = 0
    private var diagnosticVideoGaps = 0
    private var diagnosticReports = 0
    private var diagnosticLTRRejected = 0
    private var diagnosticLTRDecoded = 0
    #endif
    var onNeedsKeyframe: (() -> Void)?
    var pendingAudioCount: Int { pendingAudio.count }
    var pendingVideoCount: Int { pendingVideo.count }

    init(output: any HighPerformanceMediaOutput, videoPayloadType: UInt8 = 100, videoCodec: VideoCodec = .h264, videoClockRate: Double = 90000,
         audioClockRate: Double = 48000, audioFramesPerPacket: UInt32 = 480,
         audioSpecificConfig: Data = Data([0xf8, 0xe6, 0x51, 0x32, 0xe0, 0]),
         aggregationFormat: AppleHPVideoDepacketizer.AggregationFormat = .rfc6184) throws {
        // This experimental profile is explicitly AAC-ELD at 48 kHz / 480-frame AUs.
        guard videoPayloadType <= 127, videoPayloadType != 101, videoClockRate == 90000, audioClockRate == 48000, audioFramesPerPacket == 480 else { throw Failure.invalidConfiguration }
        self.videoCodec = videoCodec
        self.output = output; self.videoPayloadType = videoPayloadType; videoRate = videoClockRate; audioRate = audioClockRate
        audioFrames = audioFramesPerPacket; aggregation = aggregationFormat
        try audioFactory.configureAAC(audioSpecificConfig: audioSpecificConfig)
        guard let format = audioFactory.audioStreamDescription, format.mSampleRate == audioRate,
              format.mFramesPerPacket == audioFrames else { throw Failure.invalidConfiguration }
    }

    /// Pass the negotiated clock rate for these SSRCs, not a rate inferred from arrival.
    func observe(_ reports: [HighPerformanceSenderReport], clockRate: Double) throws {
        guard clockRate == videoRate || clockRate == audioRate else { throw Failure.unsupportedStream }
        #if DEBUG
        diagnosticReports += reports.count
        if diagnosticReports <= 10 {
            VNCControlDiagnostics.logger.notice("HP media SR count=\(reports.count) rate=\(clockRate) pending_video=\(self.pendingVideo.count) pending_audio=\(self.pendingAudio.count)")
        }
        #endif
        for report in reports {
            if report.ssrc == selectedVideo && clockRate != videoRate { throw Failure.unsupportedStream }
            if report.ssrc == selectedAudio && clockRate != audioRate { throw Failure.unsupportedStream }
            do { try clock.observe(report, clockRate: clockRate) }
            catch HighPerformanceMediaError.staleSenderReport { continue }
        }
        try drain()
    }

    /// The caller must reorder a bounded packet window before feeding fragmented video.
    /// This does not composite Apple's multi-SSRC tiled HEVC mode.
    func consumeVideo(_ packet: HighPerformanceRTPPacket) throws {
        if videoCodec == .hevc { try consumeHEVC(packet); return }
        guard packet.payloadType == videoPayloadType, packet.ssrc != selectedAudio else { throw Failure.unsupportedStream }
        if videos[packet.ssrc] == nil {
            guard videos.count < 4 else { throw Failure.tooManyStreams }
            var state = VideoState(); state.depacketizer.aggregationFormat = aggregation
            videos[packet.ssrc] = state
        }
        if selectedVideo == nil { selectedVideo = packet.ssrc }
        var state = videos[packet.ssrc]!
        if let expected = state.expectedSequence, expected != packet.sequenceNumber, packet.ssrc == selectedVideo { loseVideoContinuity() }
        state.expectedSequence = packet.sequenceNumber &+ 1
        let result: AppleHPVideoDepacketizer.Output?
        do { result = try state.depacketizer.append(sequence: packet.sequenceNumber, timestamp: packet.timestamp, marker: packet.marker, payload: packet.payload) }
        catch {
            videos[packet.ssrc] = state
            if packet.ssrc == selectedVideo { loseVideoContinuity() }
            throw error
        }
        videos[packet.ssrc] = state
        guard let result else { return }
        switch result {
        case .configuration(let sps, let pps):
            // The factory supports one active SPS/PPS pair. Do not silently pick from
            // a multi-parameter-set configuration and decode against the wrong IDs.
            guard sps.count == 1, pps.count == 1 else { throw Failure.unsupportedStream }
            _ = try state.factory.h264AccessUnit(annexB(sps + pps), presentationSeconds: 0)
        case .accessUnit(let timestamp, let units):
            guard packet.ssrc == selectedVideo else { return }
            let parameters = units.filter { $0.first.map { ($0 & 31) == 7 || ($0 & 31) == 8 } ?? false }
            if !parameters.isEmpty { _ = try state.factory.h264AccessUnit(annexB(parameters), presentationSeconds: 0) }
            let keyframe = HighPerformanceH264Recovery.isIntraPicture(units)
            let hasSlice = units.contains { $0.first.map { (1...5).contains($0 & 31) } ?? false }
            if !hasSlice { _ = try state.factory.h264AccessUnit(annexB(units), presentationSeconds: 0); return }
            if needsKeyframe && !keyframe { return }
            needsKeyframe = false
            if !canBufferVideo(bytes: units.reduce(0) { $0 + $1.count + 4 }) {
                loseVideoContinuity()
                guard keyframe else { return }
                needsKeyframe = false
            }
            pendingVideo.append(PendingVideo(ssrc: packet.ssrc, timestamp: timestamp, annexB: annexB(units), keyframe: keyframe))
        }
        try drain()
    }

    private func consumeHEVC(_ packet: HighPerformanceRTPPacket) throws {
        #if DEBUG
        diagnosticVideoPackets += 1
        if diagnosticVideoPackets <= 12 || diagnosticVideoPackets % 2000 == 0 {
            let nalType = packet.payload.first.map { Int(($0 >> 1) & 63) } ?? -1
            let fuType = nalType == 49 && packet.payload.count >= 3 ? Int(packet.payload[packet.payload.startIndex + 2] & 63) : -1
            VNCControlDiagnostics.logger.notice("HP HEVC packet count=\(self.diagnosticVideoPackets) type=\(nalType) fu_type=\(fuType) bytes=\(packet.payload.count) marker=\(packet.marker)")
        }
        #endif
        guard packet.payloadType == videoPayloadType, packet.ssrc != selectedAudio else { throw Failure.unsupportedStream }
        // Tiled HEVC requires cross-SSRC decode ordering/compositing; do not silently
        // render only tile zero when the server ignores single-picture negotiation.
        if let selectedVideo, selectedVideo != packet.ssrc { throw Failure.unsupportedStream }
        if selectedVideo == nil { selectedVideo = packet.ssrc; videos[packet.ssrc] = VideoState() }
        var state = videos[packet.ssrc]!
        if let expected = state.expectedSequence, expected != packet.sequenceNumber {
            #if DEBUG
            diagnosticVideoGaps += 1
            if diagnosticVideoGaps <= 10 || diagnosticVideoGaps % 100 == 0 {
                let distance = Int16(bitPattern: packet.sequenceNumber &- expected)
                VNCControlDiagnostics.logger.notice("HP HEVC sequence gaps=\(self.diagnosticVideoGaps) relative_distance=\(distance)")
            }
            #endif
            if !ltrEnabled { loseVideoContinuity() }
        }
        state.expectedSequence = packet.sequenceNumber &+ 1
        let units: [Data]?
        do { units = try state.hevcDepacketizer.append(sequence: packet.sequenceNumber, timestamp: packet.timestamp, marker: packet.marker, payload: packet.payload) }
        catch { videos[packet.ssrc] = state; if !ltrEnabled { loseVideoContinuity() }; throw error }
        videos[packet.ssrc] = state
        guard let units else { return }
        // Negotiated LTR may still use ordinary RTP without a DON. Keep native
        // reference validation: a later picture can recover from a clean retained
        // reference. Only the feedback identity is unavailable, never invent one.
        #if DEBUG
        diagnosticVideoAUs += 1
        if diagnosticVideoAUs <= 20 || diagnosticVideoAUs % 120 == 0 {
            let types = units.map { Int(($0.first! >> 1) & 63) }.description
            VNCControlDiagnostics.logger.notice("HP HEVC AU count=\(self.diagnosticVideoAUs) types=\(types, privacy: .public) needs_keyframe=\(self.needsKeyframe) playing=\(self.isPlaying)")
        }
        #endif
        let parameters = units.filter { (32...34).contains(Int(($0.first! >> 1) & 63)) }
        if !parameters.isEmpty {
            _ = try state.factory.hevcAccessUnit(parameters, presentationSeconds: 0)
            for parameter in parameters {
                let type = (parameter.first! >> 1) & 63
                state.referenceParameters.removeAll { ($0.first! >> 1) & 63 == type }
                state.referenceParameters.append(parameter)
            }
            videos[packet.ssrc] = state
        }
        let picture = units.filter { ($0.first! >> 1) & 63 < 32 }
        guard !picture.isEmpty else { return }
        // Accept BLA/IDR pictures; CRA needs RASL suppression and is deliberately
        // excluded until that decode-order path is implemented.
        let keyframe = picture.allSatisfy { (16...20).contains(Int(($0.first! >> 1) & 63)) }
        // Native reference validation can recover after loss only once a real
        // baseline exists. A damaged initial AU may have lost its parameter sets
        // too; do not start the clock or construct P samples from that debris.
        guard state.factory.hasHEVCConfiguration else { onNeedsKeyframe?(); return }
        if needsKeyframe && !keyframe { return }
        needsKeyframe = false
        if !canBufferVideo(bytes: units.reduce(0) { $0 + $1.count }) {
            loseVideoContinuity()
            guard keyframe else { return }
            needsKeyframe = false
        }
        pendingVideo.append(PendingVideo(ssrc: packet.ssrc, timestamp: packet.timestamp, annexB: Data(), keyframe: keyframe, hevcUnits: ltrEnabled ? state.referenceParameters + units.filter { !(32...34).contains(Int(($0.first! >> 1) & 63)) } : units, don: state.hevcDepacketizer.lastCompletedDON))
        try drain()
    }

    /// Feed exactly one raw AAC access unit, after removing any Apple/RTP AU wrapper.
    /// This API intentionally does not guess audio payload framing from its contents.
    func consumeAudioAccessUnit(_ packet: HighPerformanceRTPPacket) throws {
        guard packet.payloadType == 101, packet.ssrc != selectedVideo, !packet.payload.isEmpty, packet.payload.count <= 65535 else { throw Failure.unsupportedStream }
        if let selectedAudio, selectedAudio != packet.ssrc { throw Failure.unsupportedStream }
        selectedAudio = packet.ssrc
        receivedAudioPackets += 1
        audioArrival.observe(sequence: packet.sequenceNumber, timestamp: packet.timestamp, framesPerPacket: audioFrames)
        defer {
            #if DEBUG
            if receivedAudioPackets % 100 == 0 {
                VNCControlDiagnostics.logger.notice("HP audio scheduling received=\(self.receivedAudioPackets) late_drops=\(self.audioLateDrops) preroll_drops=\(self.audioPrerollDrops) backpressure_events=\(self.audioBackpressureEvents) pending=\(self.pendingAudio.count) seq_skipped=\(self.audioArrival.forwardSkipped) seq_behind=\(self.audioArrival.behindHighWater) timestamp_discontinuities=\(self.audioArrival.timestampDiscontinuities)")
            }
            #endif
        }
        pendingAudio.append(PendingAudio(ssrc: packet.ssrc, timestamp: packet.timestamp, data: packet.payload))
        let limit = Int(audioRate * 0.2 / Double(audioFrames))
        if pendingAudio.count > limit {
            audioPrerollDrops += pendingAudio.count - limit
            pendingAudio.removeFirst(pendingAudio.count - limit)
        }
        // Also bound by RTP media duration, not merely packet count, when packets are sparse.
        while let first = pendingAudio.first, let last = pendingAudio.last,
              Int32(bitPattern: last.timestamp &- first.timestamp) > Int32(audioRate * 0.2) - Int32(audioFrames) {
            audioPrerollDrops += 1
            pendingAudio.removeFirst()
        }
        try drain()
    }

    /// Fresh session only; the SRTP receiver must also be replaced with freshly negotiated keys.
    func reset() {
        referenceGuard.reset()
        lastCleanVideoDecodeTime = nil
        output.reset(); clock.reset(); videos.removeAll(); pendingVideo.removeAll(); pendingAudio.removeAll()
        selectedVideo = nil; selectedAudio = nil; needsKeyframe = true; isPlaying = false
        audioLateDrops = 0; audioPrerollDrops = 0; audioBackpressureEvents = 0; receivedAudioPackets = 0
        audioArrival = HighPerformanceAudioArrivalDiagnostics()
        // Keep the successfully negotiated audio format; it carries no session time/key state.
    }

    private func canBufferVideo(bytes: Int) -> Bool {
        // Sender Reports may trail the first IDR by a second. Preserve its
        // dependency chain while waiting, but cap both packet-independent bytes
        // and frame count. Once playing, the normal short queue remains in use.
        let limit = isPlaying ? 2 : 120
        let bufferedBytes = pendingVideo.reduce(0) { sum, frame in
            sum + (frame.hevcUnits?.reduce(0) { $0 + $1.count } ?? frame.annexB.count)
        }
        return pendingVideo.count < limit && bufferedBytes + bytes <= 12 * 1024 * 1024
    }

    private func loseVideoContinuity() {
        pendingVideo.removeAll(); needsKeyframe = true; onNeedsKeyframe?()
    }

    private func drain() throws {
        if !isPlaying {
            // Silent desktops need not emit audio. Video can start with its own SR;
            // audio remains bounded until its independent NTP mapping is available.
            guard let video = pendingVideo.last,
                  let start = clock.presentationSeconds(ssrc: video.ssrc, timestamp: video.timestamp) else { return }
            do {
                try enqueuePending(catchingUpTo: start)
                #if DEBUG
                VNCControlDiagnostics.logger.notice("HP media starting clock pts=\(start)")
                #endif
                try output.start(at: start, playoutDelay: 0.08)
                isPlaying = true
            } catch {
                output.reset(); pendingAudio.removeAll(); loseVideoContinuity()
                throw error
            }
        } else { try enqueuePending() }
    }

    private func enqueuePending(catchingUpTo startupPTS: Double? = nil) throws {
        while let video = pendingVideo.first {
            guard let pts = clock.presentationSeconds(ssrc: video.ssrc, timestamp: video.timestamp), let factory = videos[video.ssrc]?.factory else { break }
            let sample: CMSampleBuffer?
            if let units = video.hevcUnits { sample = try factory.hevcAccessUnit(units, presentationSeconds: pts) }
            else { sample = try factory.h264AccessUnit(video.annexB, presentationSeconds: pts) }
            if let sample {
                if let startupPTS, pts < startupPTS,
                   let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
                    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
                do {
                    if ltrEnabled, let units = video.hevcUnits {
                        let don = video.don
                        let prepared = PreparedPicture()
                        try output.enqueueVideo(sample, prepare: { [weak self] in
                            guard let self, self.ltrEnabled else { return false }
                            do { prepared.picture = try self.referenceGuard.prepare(units); return true }
                            catch {
                                #if DEBUG
                                self.diagnosticLTRRejected += 1
                                if self.diagnosticLTRRejected <= 10 || self.diagnosticLTRRejected % 100 == 0 {
                                    VNCControlDiagnostics.logger.notice("HP LTR reference rejection count=\(self.diagnosticLTRRejected) reason=\(String(describing: error), privacy: .public)")
                                }
                                #endif
                                self.onNeedsKeyframe?(); return false
                            }
                        }, decodeCompletion: { [weak self] successful in
                            guard let self, self.ltrEnabled, let picture = prepared.picture else { return }
                            if successful, self.referenceGuard.decoded(picture) {
                                self.lastCleanVideoDecodeTime = ProcessInfo.processInfo.systemUptime
                                #if DEBUG
                                self.diagnosticLTRDecoded += 1
                                if self.diagnosticLTRDecoded <= 10 || self.diagnosticLTRDecoded % 120 == 0 {
                                    VNCControlDiagnostics.logger.notice("HP LTR native decoded count=\(self.diagnosticLTRDecoded) don=\(don.map(Int.init) ?? -1)")
                                }
                                #endif
                                if let don { self.onCleanHEVCFrame?(don) }
                            }
                            else { self.referenceGuard.reset(); self.needsKeyframe = true; self.onNeedsKeyframe?() }
                        })
                    } else {
                        // Non-LTR HEVC and H.264 need the same actual native
                        // decode evidence; enqueue alone cannot prove progress.
                        try output.enqueueVideo(sample, prepare: { true }) { [weak self] successful in
                            guard let self else { return }
                            if successful { self.lastCleanVideoDecodeTime = ProcessInfo.processInfo.systemUptime }
                            else { self.loseVideoContinuity() }
                        }
                    }
                }
                catch { loseVideoContinuity(); throw error }
            }
            pendingVideo.removeFirst()
        }
        while let audio = pendingAudio.first {
            guard let pts = audio.prepared.map({ CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)) }) ?? clock.presentationSeconds(ssrc: audio.ssrc, timestamp: audio.timestamp) else { break }
            // A late audio SR must not replay obsolete preroll after video has advanced.
            if pts + Double(audioFrames) / audioRate < (startupPTS ?? (isPlaying ? output.presentationSeconds : -.infinity)) {
                audioLateDrops += 1
                pendingAudio.removeFirst()
                continue
            }
            let sample = try audio.prepared ?? audioFactory.aacAccessUnit(audio.data, presentationSeconds: pts)
            pendingAudio[0].prepared = sample
            do { try output.enqueueAudio(sample) }
            catch HighPerformancePlaybackError.backpressure {
                // Count retries, not lost AUs: this AU remains queued for the next drain.
                audioBackpressureEvents += 1
                throw HighPerformancePlaybackError.backpressure
            }
            pendingAudio.removeFirst()
        }
    }

    private func annexB(_ units: [Data]) -> Data {
        var data = Data()
        for unit in units { data.append(contentsOf: [0, 0, 0, 1]); data.append(unit) }
        return data
    }
}

/// Checks the first two H.264 slice-header ue(v) fields, not the NAL type alone.
/// A complete intra picture can bootstrap Apple's non-IDR stream. This does not
/// assert that subsequent open-GOP pictures never reference pictures before it.
enum HighPerformanceH264Recovery {
    static func isIntraPicture(_ units: [Data]) -> Bool {
        var hasFirstSlice = false
        var hasSlice = false
        for unit in units {
            guard let header = unit.first, header & 0x80 == 0 else { return false }
            let type = header & 31
            guard (1...5).contains(type) else { continue }
            guard type == 1 || type == 5 else { return false } // Partitioned slices unsupported.
            var rbsp: [UInt8] = []
            var zeros = 0
            for byte in unit.dropFirst().prefix(128) {
                if zeros == 2 && byte == 3 { zeros = 0; continue }
                rbsp.append(byte)
                zeros = byte == 0 ? min(2, zeros + 1) : 0
            }
            var bit = 0
            func readBit() -> UInt32? {
                guard bit < rbsp.count * 8 else { return nil }
                defer { bit += 1 }
                return UInt32((rbsp[bit / 8] >> (7 - bit % 8)) & 1)
            }
            func unsignedExpGolomb() -> UInt32? {
                var leading = 0
                while true {
                    guard let value = readBit() else { return nil }
                    if value == 1 { break }
                    leading += 1
                    guard leading < 32 else { return nil }
                }
                var suffix: UInt32 = 0
                for _ in 0..<leading {
                    guard let value = readBit() else { return nil }
                    suffix = (suffix << 1) | value
                }
                return ((UInt32(1) << leading) - 1) + suffix
            }
            guard let firstMB = unsignedExpGolomb(), let sliceType = unsignedExpGolomb(),
                  sliceType == 2 || sliceType == 7 else { return false }
            hasFirstSlice = hasFirstSlice || firstMB == 0
            hasSlice = true
        }
        return hasSlice && hasFirstSlice
    }
}

/// Observes authenticated arrival order without changing playback or claiming final loss.
/// Forward holes may subsequently arrive; behind-high-water counts those late arrivals.
/// SRTP has already removed duplicates. Storage stays constant for arbitrarily long sessions.
nonisolated struct HighPerformanceAudioArrivalDiagnostics {
    private var highSequence: UInt16?
    private var highTimestamp: UInt32 = 0
    private(set) var forwardSkipped = 0
    private(set) var behindHighWater = 0
    private(set) var timestampDiscontinuities = 0

    mutating func observe(sequence: UInt16, timestamp: UInt32, framesPerPacket: UInt32) {
        guard let previous = highSequence else {
            highSequence = sequence; highTimestamp = timestamp; return
        }
        let distance = Int(Int16(bitPattern: sequence &- previous))
        guard distance > 0 else { behindHighWater += 1; return }
        forwardSkipped += distance - 1
        if timestamp &- highTimestamp != UInt32(distance) * framesPerPacket {
            timestampDiscontinuities += 1
        }
        highSequence = sequence; highTimestamp = timestamp
    }
}
