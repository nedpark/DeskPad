import Foundation
import CoreMedia

@main struct Harness {
    @MainActor static func main() async throws {
        let factory = HighPerformanceSampleFactory()
        let path = CommandLine.arguments[1]
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let hevc = path.hasSuffix(".hevc")
        let bytes = [UInt8](data)
        var positions: [(Int, Int)] = []; var index = 0
        while index + 3 < bytes.count {
            if Array(bytes[index..<index+4]) == [0,0,0,1] { positions.append((index,4)); index += 4 }
            else if Array(bytes[index..<index+3]) == [0,0,1] { positions.append((index,3)); index += 3 }
            else { index += 1 }
        }
        let units = positions.enumerated().map { n, p in Data(bytes[(p.0+p.1)..<(n+1 < positions.count ? positions[n+1].0 : bytes.count)]) }
        let video = try (hevc ? factory.hevcAccessUnit(units, presentationSeconds: 1.25) : factory.h264AccessUnit(data, presentationSeconds: 1.25))!
        let decoder = HighPerformanceNativeVideoDecoder()
        let success = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            do { try decoder.enqueue(video) { result in
                switch result {
                case .success(let decoded):
                    continuation.resume(returning: CMSampleBufferGetImageBuffer(decoded.sample) != nil && CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(decoded.sample)) == 1.25)
                case .failure(let error): continuation.resume(throwing: error)
                }
            } } catch { continuation.resume(throwing: error) }
        }
        precondition(success, "successful native decode must preserve exact frame metadata")
        // A valid compressed format with an invalid slice must never report success.
        let corrupt = try (hevc ? factory.hevcAccessUnit([Data([0x26,1,0])], presentationSeconds: 2) : factory.h264AccessUnit(Data([0,0,0,1,0x65,0]), presentationSeconds: 2))!
        let rejected = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            do { try decoder.enqueue(corrupt) { result in
                if case .failure = result { continuation.resume(returning: true) }
                else { continuation.resume(returning: false) }
            } } catch { continuation.resume(throwing: error) }
        }
        precondition(rejected, "decode failure must not acknowledge a frame")
        decoder.reset()
        var prepared = 0; var decoded = 0
        let ordered = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            do {
                try decoder.enqueue(video, prepare: { prepared += 1; return decoded == 0 }) { result in
                    if case .success = result { decoded += 1 }
                }
                try decoder.enqueue(video, prepare: { prepared += 1; return decoded == 1 }) { result in
                    if case .success = result { decoded += 1 }
                    continuation.resume(returning: prepared == 2 && decoded == 2)
                }
            } catch { continuation.resume(throwing: error) }
        }
        precondition(ordered, "next reference validation must follow previous native decode completion")
        // Reset while main actor is occupied; completion from the old generation is suppressed.
        var staleCallbacks = 0
        try decoder.enqueue(video) { _ in staleCallbacks += 1 }
        decoder.reset()
        try await Task.sleep(for: .milliseconds(100))
        precondition(staleCallbacks == 0)
        print("Native successful decode, corrupt slice rejection, exact PTS and stale-generation suppression passed")
    }
}
