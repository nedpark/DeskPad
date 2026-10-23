import Foundation

/// Native captures mux video RTCP on the video port; other interoperable peers
/// use the control port. Duplicate the protected datagram, not its encryption:
/// both routes must carry the same SRTCP index/tag so a shared receiver accepts
/// it once and its replay filter rejects the duplicate.
nonisolated enum AppleHPVideoFeedbackRoute {
    static func send(_ plaintext: Data,
                     protect: (Data) throws -> Data,
                     transmit: (Int, Data) -> Void) rethrows {
        let protected = try protect(plaintext)
        transmit(0, protected)
        transmit(1, protected)
    }
}
