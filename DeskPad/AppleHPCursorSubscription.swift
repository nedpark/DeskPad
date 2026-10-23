import Foundation

/// Sent only inside the authenticated record channel, after encryption setup.
/// Cursor geometry remains in desktop coordinates, independently of video scaling.
struct AppleHPCursorSubscription {
    static func messages(width: UInt16, height: UInt16) throws -> [Data] {
        let encodings = try AppleHPMirrorHandshake(encodings: [1010, 1103, 1104, -223]).setEncodings
        var request = Data([3, 0, 0, 0, 0, 0])
        append(width, to: &request); append(height, to: &request)
        var automatic = Data([9, 0, 0, 1, 255, 255, 255, 255, 0, 0, 0, 0])
        append(width, to: &automatic); append(height, to: &automatic)
        return [encodings, request, automatic]
    }
    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8)); data.append(UInt8(truncatingIfNeeded: value))
    }
}
