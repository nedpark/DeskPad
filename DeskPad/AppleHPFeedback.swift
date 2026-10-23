import Foundation

/// RFC 4585 PSFB Picture Loss Indication, authenticated by SRTCP before send.
enum AppleHPFeedback {
    static func pictureLoss(sender: UInt32, media: UInt32) -> Data {
        var bytes = Data([0x80, 201, 0, 1])
        bytes.append(contentsOf: [UInt8(truncatingIfNeeded: sender >> 24), UInt8(truncatingIfNeeded: sender >> 16),
                                  UInt8(truncatingIfNeeded: sender >> 8), UInt8(truncatingIfNeeded: sender)])
        bytes.append(contentsOf: [0x81, 206, 0, 2])
        for value in [sender, media] {
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        // Apple also recognizes the legacy full-intra request (RTCP PT 192).
        bytes.append(contentsOf: [0x80, 192, 0, 1])
        bytes.append(contentsOf: [UInt8(truncatingIfNeeded: media >> 24), UInt8(truncatingIfNeeded: media >> 16),
                                  UInt8(truncatingIfNeeded: media >> 8), UInt8(truncatingIfNeeded: media)])
        return bytes
    }
}
