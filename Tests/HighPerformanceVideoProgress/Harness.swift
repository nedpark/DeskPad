import Foundation
@main struct Harness {
    static func main() {
        var stalled = AppleHPVideoProgressWatchdog()
        for second in 0...8 {
            stalled.observeVideo(timestamp: UInt32(second * 90000), now: Double(second))
            precondition(!stalled.stalled(now: Double(second), lastCleanDecode: nil))
            if second < 8 { precondition(!stalled.stalled(now: Double(second), lastCleanDecode: 0)) }
        }
        precondition(stalled.stalled(now: 8, lastCleanDecode: 0))
        precondition(!stalled.stalled(now: 8, lastCleanDecode: 7))
        // A static desktop and an interrupted stream are not active-video stalls.
        precondition(!stalled.stalled(now: 20, lastCleanDecode: 0))
        stalled.observeVideo(timestamp: 123, now: 20)
        precondition(!stalled.stalled(now: 20, lastCleanDecode: 0))
        var duplicates = AppleHPVideoProgressWatchdog()
        for second in 0...20 { duplicates.observeVideo(timestamp: 100, now: Double(second)) }
        precondition(!duplicates.stalled(now: 20, lastCleanDecode: 0))
        var fresh = AppleHPVideoProgressWatchdog()
        fresh.observeVideo(timestamp: 100, now: 100)
        precondition(!fresh.stalled(now: 100, lastCleanDecode: nil))
        #if DEBUG
        let loss = AppleHPDebugMediaLoss(arguments: ["--deskpad-hp-drop-after=5", "--deskpad-hp-drop-for=5"])
        precondition(!loss.shouldDrop(now: 100))
        precondition(!loss.shouldDrop(now: 104.99))
        precondition(loss.shouldDrop(now: 105))
        precondition(loss.shouldDrop(now: 109.99))
        // Same shared injector used by a replacement client never restarts the window.
        precondition(!loss.shouldDrop(now: 110))
        precondition(!loss.shouldDrop(now: 1000))
        for value in ["nan", "inf", "-1", "61", "bad"] {
            let invalid = AppleHPDebugMediaLoss(arguments: ["--deskpad-hp-drop-after=" + value, "--deskpad-hp-drop-for=5"])
            precondition(!invalid.shouldDrop(now: 0))
        }
        #endif
        print("PASS active video stall / native progress / static idle / reconnect / bounded one-shot loss")
    }
}
