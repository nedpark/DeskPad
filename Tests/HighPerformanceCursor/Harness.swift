import Foundation
@main struct Harness {
    static func main() throws {
        let baseline = try AppleHPMirrorHandshake(encodings: [1010,1103,-223])
        precondition(baseline.cleartextPrelude.map { $0[0] } == [0x21,0x12,2])
        let messages = try AppleHPCursorSubscription.messages(width: 6016, height: 3384)
        precondition(messages.map { $0[0] } == [2,3,9])
        precondition(messages[0] == Data([2,0,0,4,0,0,3,242,0,0,4,79,0,0,4,80,255,255,255,33]))
        precondition(messages[1] == Data([3,0,0,0,0,0,23,128,13,56]))
        precondition(messages[2] == Data([9,0,0,1,255,255,255,255,0,0,0,0,23,128,13,56]))
        precondition(!messages.contains { $0[0] == 0x1d })
        print("PASS encrypted cursor subscription wire bytes; cleartext baseline; no display configuration opcode")
    }
}
