import Foundation
@main struct MirrorHarness {
    static func main() throws {
        let mirror = try AppleHPMirrorHandshake(encodings: [1010, 1104, -223])
        precondition(mirror.clientInit == Data([193]))
        precondition(mirror.viewerInfo.count == 66)
        precondition(mirror.viewerInfo.prefix(6) == Data([33, 0, 0, 62, 0, 1]))
        precondition(mirror.viewerInfo[34] == 0xB0)
        precondition(mirror.viewerInfo[44] == 0x40)
        precondition(mirror.setEncodings == Data([2,0,0,3,0,0,3,242,0,0,4,80,255,255,255,33]))
        precondition(mirror.encryptionRequest == Data([18,0,0,1,0,1,0,1,0,0,0,1]))
        precondition(mirror.encryptionReady == Data([18,0,0,2,0,1,0,0]))
        precondition(mirror.cleartextPrelude.map { $0.first! } == [33,18,2])
        for invalid: [Int32] in [[], [1,1], Array(0...64)] {
            do { _ = try AppleHPMirrorHandshake(encodings: invalid); fatalError("Invalid encoding offer") }
            catch AppleHPMirrorHandshake.Failure.invalidEncodings {}
        }
        print("Mirror bootstrap fixtures passed; no display-configuration message")
    }
}
