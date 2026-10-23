import Foundation

/// Immutable mirror-only bootstrap. There is intentionally no display geometry,
/// curtain switch, alternate-user login command, or SetDisplayConfiguration API.
/// Wire profile identifiers describe protocol compatibility, not DeskPad's version.
struct AppleHPMirrorHandshake {
    enum Failure: Error { case invalidEncodings }
    let clientInit = Data([0xC1])
    let viewerInfo: Data
    let encryptionRequest = Data([0x12, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 1])
    let setEncodings: Data
    let encryptionReady = Data([0x12, 0, 0, 2, 0, 1, 0, 0])

    /// Caller advertises only encodings its bounded control parser can consume.
    init(encodings: [Int32]) throws {
        guard !encodings.isEmpty, encodings.count <= 64,
              Set(encodings).count == encodings.count else { throw Failure.invalidEncodings }
        var viewer = Data([0x21, 0, 0, 62, 0, 1])
        for value: UInt32 in [2, 6, 1, 0, 15, 3, 0] {
            Self.append(value, to: &viewer)
        }
        var capabilities = Data(repeating: 0, count: 32)
        capabilities[0] = 0xB0
        capabilities[2] = 0x0C
        capabilities[3] = 0x03
        capabilities[4] = 0x90
        capabilities[10] = 0x40
        viewer.append(capabilities)
        viewerInfo = viewer
        var encodingMessage = Data([2, 0, 0, UInt8(encodings.count)])
        for encoding in encodings { Self.append(UInt32(bitPattern: encoding), to: &encodingMessage) }
        setEncodings = encodingMessage
    }

    /// Send after ServerInit, before receiving encryption key setup (encoding1103).
    /// Boundaries are retained so the caller can enforce phase-specific ordering.
    var cleartextPrelude: [Data] { [viewerInfo, encryptionRequest, setEncodings] }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}
