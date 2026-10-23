import Foundation

/// Detects a stalled active stream, not a silent/static desktop. Authentication
/// and complete native decode must be checked by the caller before reporting.
nonisolated struct AppleHPVideoProgressWatchdog {
    private var busySince: Double?
    private var lastPacket: Double?
    private var lastTimestamp: UInt32?
    private var advancingPictures = 0
    let deadline: Double = 8
    let maximumIdleGap: Double = 2

    mutating func observeVideo(timestamp: UInt32, now: Double) {
        if lastPacket == nil || now - lastPacket! > maximumIdleGap {
            busySince = now
            advancingPictures = 0
            lastTimestamp = nil
        }
        if timestamp != lastTimestamp { advancingPictures = min(2, advancingPictures + 1); lastTimestamp = timestamp }
        lastPacket = now
    }

    func stalled(now: Double, lastCleanDecode: Double?) -> Bool {
        // Startup has a separate bounded first-frame timer. Never retry a
        // stream which has not yet demonstrated successful native decoding.
        guard let lastCleanDecode, let busySince, let lastPacket,
              advancingPictures >= 2, now - lastPacket <= maximumIdleGap else { return false }
        return now - max(busySince, lastCleanDecode) >= deadline
    }
}

#if DEBUG
import os
/// One process-wide loss window survives client replacements. Only local
/// received datagrams are discarded; no host/network configuration changes.
nonisolated final class AppleHPDebugMediaLoss: @unchecked Sendable {
    static let shared = AppleHPDebugMediaLoss(arguments: ProcessInfo.processInfo.arguments)
    private let lock = NSLock()
    private let after: Double?
    private let duration: Double?
    private var began: Double?
    private var loggedStart = false
    private var loggedEnd = false
    private let logger = Logger(subsystem: "kr.co.codegrove.DeskPad", category: "HPDebugMediaLoss")

    init(arguments: [String]) {
        func value(_ prefix: String) -> Double? {
            guard let raw = arguments.first(where: { $0.hasPrefix(prefix) }),
                  let result = Double(raw.dropFirst(prefix.count)), result.isFinite,
                  (0...60).contains(result) else { return nil }
            return result
        }
        after = value("--deskpad-hp-drop-after=")
        duration = value("--deskpad-hp-drop-for=")
    }
    func shouldDrop(now: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let after, let duration, duration > 0 else { return false }
        if began == nil { began = now }
        let elapsed = now - began!
        if elapsed >= after, !loggedStart {
            loggedStart = true
            logger.notice("HP debug media loss started elapsed=\(elapsed) duration=\(duration)")
        }
        if elapsed >= after + duration, !loggedEnd {
            loggedEnd = true
            logger.notice("HP debug media loss ended elapsed=\(elapsed) duration=\(duration)")
        }
        return elapsed >= after && elapsed < after + duration
    }
}
#endif
