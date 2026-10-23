@main struct Harness {
    static func main() {
        var retry = AppleHPStartupRetry()
        // Auth, trust, transport and explicit media errors are not first-frame expiry.
        precondition(!retry.consume(firstFrameExpired: false, cancelled: false, currentGeneration: true))
        precondition(!retry.consumed)
        precondition(!retry.consume(firstFrameExpired: true, cancelled: true, currentGeneration: true))
        precondition(!retry.consume(firstFrameExpired: true, cancelled: false, currentGeneration: false))
        precondition(!retry.consumed)
        precondition(retry.consume(firstFrameExpired: true, cancelled: false, currentGeneration: true))
        precondition(!retry.consume(firstFrameExpired: true, cancelled: false, currentGeneration: true))
        var nextUserConnection = AppleHPStartupRetry()
        precondition(nextUserConnection.consume(firstFrameExpired: true, cancelled: false, currentGeneration: true))
        print("HP startup retry budget, cancellation, generation, and error exclusions PASS")
    }
}
