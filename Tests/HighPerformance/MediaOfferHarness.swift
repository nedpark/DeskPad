import Foundation
@main struct MediaOfferHarness {
    static func main() throws {
        let first = try AppleHPMediaOffer.make(), second = try AppleHPMediaOffer.make()
        precondition(first.message != second.message)
        let keys = [first.audioKeys.viewerToServer, first.audioKeys.serverToViewer, first.videoKeys.viewerToServer, first.videoKeys.serverToViewer,
                    second.audioKeys.viewerToServer, second.audioKeys.serverToViewer, second.videoKeys.viewerToServer, second.videoKeys.serverToViewer]
        precondition(Set(keys).count == 8 && keys.allSatisfy { $0.count == 46 })
        do {
            _ = try AppleHPMediaOffer.make(videoProfile: .h264SinglePicture, enableLTR: true)
            preconditionFailure("AVC cannot advertise LTR")
        } catch AppleHPMediaOffer.Failure.unsupportedLTR {}
        for profile in AppleHPMediaOffer.VideoProfile.allCases {
            let offer = try AppleHPMediaOffer.make(videoProfile: profile)
            print(offer.message.base64EncodedString())
            print(offer.audioSSRC)
            print(offer.videoSSRC)
        }
        let ltr = try AppleHPMediaOffer.make(videoProfile: .hevcSinglePicture, enableLTR: true)
        precondition(ltr.ltrEnabled)
        print(ltr.message.base64EncodedString())
        print(ltr.audioSSRC)
        print(ltr.videoSSRC)
        let dual = try AppleHPMediaOffer.make(videoProfile: .hevcSinglePicture, enableLTR: true, nativeCodecBanks: true)
        print(dual.message.base64EncodedString())
        print(dual.audioSSRC)
        print(dual.videoSSRC)
        do {
            _ = try AppleHPMediaOffer.make(videoProfile: .hevcSinglePicture, nativeCodecBanks: true)
            preconditionFailure("native banks require explicit LTR")
        } catch AppleHPMediaOffer.Failure.unsupportedLTR {}
    }
}
