import Foundation
import CoreMedia
import VideoToolbox

/// Native decode is separate from display so reference feedback is never based on
/// enqueue success. One worker and one outstanding pixel buffer bound memory.
nonisolated final class HighPerformanceNativeVideoDecoder: @unchecked Sendable {
    struct Decoded: @unchecked Sendable {
        let sample: CMSampleBuffer
    }
    private struct Entry: @unchecked Sendable {
        let sample: CMSampleBuffer
        let generation: UInt64
        let prepare: @MainActor @Sendable () -> Bool
        let completion: @MainActor @Sendable (Result<Decoded, HighPerformancePlaybackError>) -> Void
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "DeskPad.native-video-decode", qos: .userInteractive)
    private var entries: [Entry] = []
    private var bytes = 0
    private var running = false
    private var generation: UInt64 = 0
    // Accessed only on the serial worker queue.
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var sessionGeneration: UInt64?

    func enqueue(_ sample: CMSampleBuffer, prepare: @escaping @MainActor @Sendable () -> Bool = { true }, completion: @escaping @MainActor @Sendable (Result<Decoded, HighPerformancePlaybackError>) -> Void) throws {
        let count = CMSampleBufferGetTotalSampleSize(sample)
        lock.lock()
        guard entries.count < 120, count <= 12 * 1024 * 1024 - bytes else {
            lock.unlock(); throw HighPerformancePlaybackError.backpressure
        }
        entries.append(Entry(sample: sample, generation: generation, prepare: prepare, completion: completion)); bytes += count
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.processOne() } }
    }

    func reset() {
        lock.lock(); generation &+= 1; entries.removeAll(); bytes = 0; lock.unlock()
        // Invalidation must share the decoder queue, never race an in-flight decode.
        queue.async { self.invalidate() }
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; sessionGeneration = nil
    }

    private func processOne() {
        lock.lock()
        guard !entries.isEmpty else { running = false; lock.unlock(); return }
        let entry = entries.removeFirst(); bytes -= CMSampleBufferGetTotalSampleSize(entry.sample)
        lock.unlock()
        Task { @MainActor in
            guard self.isCurrent(entry.generation) else {
                self.queue.async { self.processOne() }; return
            }
            guard entry.prepare() else {
                entry.completion(.failure(.invalidAccessUnit))
                self.queue.async { self.processOne() }; return
            }
            self.queue.async { self.decodeEntry(entry) }
        }
    }

    private func decodeEntry(_ entry: Entry) {
        let result: Result<Decoded, HighPerformancePlaybackError>
        do { result = .success(Decoded(sample: try decode(entry.sample, generation: entry.generation))) }
        catch let error as HighPerformancePlaybackError { result = .failure(error) }
        catch { result = .failure(.rendererFailed) }
        Task { @MainActor in
            if self.isCurrent(entry.generation) { entry.completion(result) }
            // Wait for delivery before scheduling another decode: no unbounded
            // stream of 6K pixel buffers can accumulate behind the main actor.
            self.queue.async { self.processOne() }
        }
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == value
    }

    private func decode(_ sample: CMSampleBuffer, generation: UInt64) throws -> CMSampleBuffer {
        guard let inputFormat = CMSampleBufferGetFormatDescription(sample) else { throw HighPerformancePlaybackError.missingConfiguration }
        if sessionGeneration != generation || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: inputFormat) }) != false {
            invalidate()
            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: inputFormat,
                decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &created)
            guard status == noErr, let created else { throw HighPerformancePlaybackError.mediaStatus(status) }
            session = created; format = inputFormat; sessionGeneration = generation
        }
        guard let session else { throw HighPerformancePlaybackError.missingConfiguration }
        let result = FrameResult()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, flags, image, pts, duration in
            result.store(status: status, flags: flags, image: image, pts: pts, duration: duration)
        }
        guard status == noErr else { throw HighPerformancePlaybackError.mediaStatus(status) }
        let waited = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard waited == noErr else { throw HighPerformancePlaybackError.mediaStatus(waited) }
        return try result.makeSample(source: sample)
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}

nonisolated private final class FrameResult: @unchecked Sendable {
    private let lock = NSLock()
    private var status: OSStatus = -1
    private var flags: VTDecodeInfoFlags = []
    private var image: CVImageBuffer?
    private var pts: CMTime = .invalid
    private var duration: CMTime = .invalid
    func store(status: OSStatus, flags: VTDecodeInfoFlags, image: CVImageBuffer?, pts: CMTime, duration: CMTime) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; self.flags = flags; self.image = image; self.pts = pts; self.duration = duration
    }
    func makeSample(source: CMSampleBuffer) throws -> CMSampleBuffer {
        lock.lock(); defer { lock.unlock() }
        guard status == noErr else { throw HighPerformancePlaybackError.mediaStatus(status) }
        guard !flags.contains(.frameDropped), let image else { throw HighPerformancePlaybackError.rendererFailed }
        var description: CMVideoFormatDescription?
        var code = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description)
        guard code == noErr, let description else { throw HighPerformancePlaybackError.mediaStatus(code) }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var decoded: CMSampleBuffer?
        code = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &decoded)
        guard code == noErr, let decoded else { throw HighPerformancePlaybackError.mediaStatus(code) }
        if let sourceAttachments = CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: false) as? [[CFString: Any]],
           sourceAttachments.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true,
           let targetAttachments = CMSampleBufferGetSampleAttachmentsArray(decoded, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(targetAttachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return decoded
    }
}
