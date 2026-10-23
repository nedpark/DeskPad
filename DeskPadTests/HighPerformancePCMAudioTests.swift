import Testing
import AVFoundation
import CoreMedia
@testable import DeskPad

@MainActor struct HighPerformancePCMAudioTests {
    @Test func nativeAACToPCMWithGapRendersOnSharedClock() async throws {
        let bytes = [UInt8](Data(base64Encoded: "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")!)
        let factory = HighPerformanceSampleFactory()
        try factory.configureAAC(audioSpecificConfig: Data([0xf8,0xe6,0x40,0]))
        let delivery = HighPerformancePCMAudioDelivery()
        let renderer = AVSampleBufferAudioRenderer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(renderer)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        defer { synchronizer.setRate(0,time:.zero);renderer.flush();delivery.reset() }
        var cursor = 0, index = 0, emittedPTS: [Double] = []
        while cursor < bytes.count {
            let count = Int(bytes[cursor]) << 8 | Int(bytes[cursor+1]); cursor += 2
            let au = Data(bytes[cursor..<cursor+count]); cursor += count
            defer { index += 1 }
            if index == 10 || index == 11 { continue }
            let sample = try factory.aacAccessUnit(au,presentationSeconds:Double(index*512)/48000)
            try delivery.enqueue(sample,isReady:{renderer.isReadyForMoreMediaData},emit:{ pcm in
                emittedPTS.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(pcm)))
                renderer.enqueue(pcm)
            })
        }
        #expect(delivery.decodedFrames == 28*512)
        #expect(delivery.concealedFrames == 1024)
        #expect(emittedPTS.count == 29)
        #expect(abs(emittedPTS.last! - Double(29*512)/48000) < 0.000002)
        synchronizer.setRate(1,time:.zero)
        try await Task.sleep(for:.milliseconds(180))
        #expect(renderer.status == .rendering)
        #expect(renderer.error == nil)
        #expect(CMTimeGetSeconds(synchronizer.currentTime()) > 0.1)
        try await Task.sleep(for:.milliseconds(180))
    }
}
