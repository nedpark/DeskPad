import Testing
import UIKit
import Foundation
import CoreMedia
@testable import DeskPad

@MainActor struct HighPerformanceNativeVideoTests {
    @Test func nativeH264ProducesDecodedOutput() async throws {
        let factory = HighPerformanceSampleFactory()
        let data = Data(base64Encoded: "AAAAAWdCwAraEJsBEAAAAwAQAAADACjxImoAAAABaM4PyAAAAQYF//9P3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAAFliIQ6JigACQLJycnXXXXXXXXXXXXg")!
        let sample = try #require(try factory.h264AccessUnit(data, presentationSeconds: 0))
        let playback = HighPerformancePlayback()
        defer { playback.reset() }
        var completed: Bool?
        try playback.enqueueVideo(sample, prepare: { true }) { completed = $0 }
        for _ in 0..<100 {
            if completed != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(completed == true)
    }

    @Test func cleanNativeHEVCFrameDisplaysAndCorruptFrameCannotAcknowledge() async throws {
        let data = Data(base64Encoded: "AAAAAUABDAH//wQIAAADAJ4IAAADAAAelZgJAAAAAUIBAQQIAAADAJ4IAAADAAAekAQQILLKzSSZXgLQEAAAAwAQAAADAeCAAAAAAUQBwXKGDEIkAAAAASgBrwhg+e6Xf/aVn9oFLijUaQcu")!
        let b = [UInt8](data)
        var starts: [(Int,Int)] = []; var i = 0
        while i + 3 < b.count {
            if Array(b[i..<i+4]) == [0,0,0,1] { starts.append((i,4)); i += 4 }
            else if Array(b[i..<i+3]) == [0,0,1] { starts.append((i,3)); i += 3 }
            else { i += 1 }
        }
        let units = starts.enumerated().map { n,p in Data(b[(p.0+p.1)..<(n+1 < starts.count ? starts[n+1].0 : b.count)]) }
        let factory = HighPerformanceSampleFactory()
        let sample = try #require(try factory.hevcAccessUnit(units, presentationSeconds: 0))
        let playback = HighPerformancePlayback()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        playback.videoLayer.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        window.rootViewController!.view.layer.addSublayer(playback.videoLayer)
        defer { playback.reset(); window.isHidden = true }
        var acknowledged: [UInt16] = []
        let don: UInt16 = 65535
        try playback.enqueueVideo(sample, prepare: { true }) { decoded in
            if decoded { acknowledged.append(don) }
        }
        try playback.start(at: 0)
        for _ in 0..<100 {
            if playback.hasDisplayedVideoFrame { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(acknowledged == [65535])
        #expect(playback.hasDisplayedVideoFrame)
        let corrupt = try #require(try factory.hevcAccessUnit([Data([0x26,1,0])], presentationSeconds: 0.1))
        let rejected = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            do {
                try playback.enqueueVideo(corrupt, prepare: { true }) { decoded in
                    if decoded { acknowledged.append(0) }
                    continuation.resume(returning: !decoded)
                }
            } catch { continuation.resume(throwing: error) }
        }
        #expect(rejected)
        #expect(acknowledged == [65535])
        playback.reset()
    }
}
