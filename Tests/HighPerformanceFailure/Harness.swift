import Foundation
@main struct Harness {
    static func main() {
        let state = AppleHPTerminalFailure()
        precondition(state.value == nil)
        state.record(.unsupportedVideoLayout)
        state.record(.mediaIdleTimeout)
        precondition(state.value == .unsupportedVideoLayout)
        precondition(AppleHPFailure.mediaIdleTimeout.localizedDescription.contains("초과"))
        precondition(!AppleHPFailure.playbackFailure.localizedDescription.contains("초과"))
        precondition(!AppleHPFailure.unsupportedVideoLayout.localizedDescription.contains("초과"))
        print("PASS first terminal reason preserved; typed user messages distinguish timeout")
    }
}
