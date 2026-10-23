import Foundation
@main struct Harness {
    static func main() throws {
        var calls = 0
        var sent: [(Int, Data)] = []
        let plaintext = Data([0x80,201,0,1,0,0,0,1])
        let protected = plaintext + Data([0x80,0,0,9]) + Data(repeating: 0xaa, count: 10)
        AppleHPVideoFeedbackRoute.send(plaintext, protect: {
            precondition($0 == plaintext); calls += 1; return protected
        }, transmit: { sent.append(($0,$1)) })
        precondition(calls == 1 && sent.map(\.0) == [0,1])
        precondition(sent.allSatisfy { $0.1 == protected })
        enum Failure: Error { case expected }
        do {
            try AppleHPVideoFeedbackRoute.send(plaintext, protect: { _ in throw Failure.expected }, transmit: { sent.append(($0,$1)) })
            preconditionFailure("failure must propagate")
        } catch Failure.expected {}
        precondition(sent.count == 2, "failed protection must transmit nothing")
        print("Dual video feedback routes preserve identical ciphertext/index/tag with one encryption and bounded sends")
    }
}
