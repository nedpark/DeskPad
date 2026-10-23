import Foundation
#if DEBUG
import os
#endif

/// Bounded single-SSRC HEVC receiver. Apple places DONL after every single-NAL
/// header and every FU header, and once in AP (without per-unit DOND).
struct AppleHPHEVCDepacketizer {
    enum Packetization { case automatic, rfc7798NoDON, appleDON }
    enum Failure: Error { case malformed, limitExceeded }
    var packetization: Packetization = .automatic
    private(set) var detectedPacketization: Packetization?
    init(packetization: Packetization = .automatic) { self.packetization = packetization }
    /// Valid only for the most recently completed access unit; nil for no-DON RTP.
    private(set) var lastCompletedDON: UInt16?
    private var accessUnitDON: UInt16?
    private var timestamp: UInt32?
    private var expected: UInt16?
    private var units: [Data] = []
    private var fragment = Data()
    private var fragmentHeader: [UInt8]?
    private var fragmentDON: UInt16?
    private var bytes = 0
    private var packets = 0
    private var damaged = false
    private var completed = false
    #if DEBUG
    private var diagnosticAPCount = 0
    private var diagnosticFUProbe = AppleHPFUDONProbe()
    private var diagnosticFUReports = 0
    #endif

    mutating func append(sequence: UInt16, timestamp incoming: UInt32, marker: Bool, payload: Data) throws -> [Data]? {
        #if DEBUG
        if let summary = diagnosticFUProbe.observe(sequence: sequence, timestamp: incoming, payload: payload) {
            diagnosticFUReports += 1
            if diagnosticFUReports <= 12 || diagnosticFUReports % 100 == 0 {
                let report = diagnosticFUReports
                VNCControlDiagnostics.logger.notice("HP FU candidate report=\(report) fragments=\(summary.fragments) consistent=\(summary.consistent) contiguous=\(summary.contiguous) nalType=\(summary.nalType)")
            }
        }
        #endif
        lastCompletedDON = nil
        if timestamp != incoming {
            accessUnitDON = nil
            timestamp = incoming; expected = nil; units = []; fragment = Data()
            fragmentHeader = nil; fragmentDON = nil; bytes = 0; packets = 0; damaged = false; completed = false
        }
        guard !completed else { return nil }
        if let expected, expected != sequence { damaged = true }
        expected = sequence &+ 1; packets += 1
        guard packets <= 8192 else { damaged = true; throw Failure.limitExceeded }
        guard !damaged else { return nil }
        do {
            let b = [UInt8](payload)
            #if DEBUG
            if b.count >= 2, (b[0] >> 1) & 63 == 48 {
                diagnosticAPCount += 1
                if diagnosticAPCount <= 3 {
                    let temporalID = b[1] & 7
                    let forbidden = b[0] & 128 != 0
                    let layerID = Int(b[0] & 1) << 5 | Int(b[1] >> 3)
                    VNCControlDiagnostics.logger.notice("HP HEVC AP header forbidden=\(forbidden) temporal_id_plus1=\(temporalID) layer=\(layerID)")
                }
            }
            #endif
            guard (3...65535).contains(b.count), b[0] & 128 == 0, b[1] & 7 != 0 else { throw Failure.malformed }
            let type = (b[0] >> 1) & 63
            if packetization == .automatic && detectedPacketization == nil {
                // Only a complete parameter-set AP may establish framing. Never
                // infer DON presence from arbitrary compressed slice bytes.
                guard type == 48 else { throw Failure.malformed }
                let noDON = Self.parameterAP(b, start: 2)
                let appleDON = Self.parameterAP(b, start: 4)
                guard noDON != appleDON else { throw Failure.malformed }
                detectedPacketization = noDON ? .rfc7798NoDON : .appleDON
                #if DEBUG
                let hasDON = detectedPacketization == .appleDON
                VNCControlDiagnostics.logger.notice("HP HEVC packetization selected apple_don=\(hasDON)")
                #endif
            }
            let selected = packetization == .automatic ? detectedPacketization! : packetization
            let donBytes = selected == .appleDON ? 2 : 0
            if donBytes == 2 {
                let offset = type == 49 ? 3 : 2
                guard b.count >= offset + 2 else { throw Failure.malformed }
                let don = UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
                if let accessUnitDON, accessUnitDON != don { throw Failure.malformed }
                accessUnitDON = don
            }
            switch type {
            case 0...47:
                guard fragmentHeader == nil, b.count > 2 + donBytes else { throw Failure.malformed }
                try add(Data(b.prefix(2)) + Data(b.dropFirst(2 + donBytes)))
            case 48:
                #if DEBUG
                if diagnosticAPCount <= 3 {
                    // Structural metadata only: positions, declared sizes, NAL types.
                    // Compare negotiated Apple DON placement with no-DON framing.
                    for start in [2, 4] {
                        var cursor = start
                        var shape: [String] = []
                        for _ in 0..<8 {
                            guard cursor + 2 <= b.count else { break }
                            let size = Int(b[cursor]) << 8 | Int(b[cursor+1])
                            let type = cursor + 2 < b.count ? Int((b[cursor+2] >> 1) & 63) : -1
                            shape.append("\(cursor):\(size):\(type)")
                            guard size >= 2, size <= b.count - cursor - 2 else { break }
                            cursor += size + 2
                        }
                        let description = shape.joined(separator: ",")
                        VNCControlDiagnostics.logger.notice("HP HEVC AP structure bytes=\(b.count) offset=\(start) entries_pos_size_type=\(description, privacy: .public) end=\(cursor)")
                    }
                }
                #endif
                guard fragmentHeader == nil else { throw Failure.malformed }
                var p = 2 + donBytes
                var count = 0
                while p < b.count {
                    guard p + 2 <= b.count else { throw Failure.malformed }
                    let n = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
                    guard n >= 3, n <= b.count - p else { throw Failure.malformed }
                    try add(Data(b[p..<(p + n)])); p += n; count += 1
                }
                guard count >= 2 else { throw Failure.malformed }
            case 49:
                guard b.count > 3 + donBytes else { throw Failure.malformed }
                let start = b[2] & 128 != 0, end = b[2] & 64 != 0, inner = b[2] & 63
                guard inner < 48, !(start && end) else { throw Failure.malformed }
                let header = [(b[0] & 0x81) | (inner << 1), b[1]]
                let don: UInt16? = donBytes == 2 ? UInt16(b[3]) << 8 | UInt16(b[4]) : nil
                if start {
                    guard fragmentHeader == nil else { throw Failure.malformed }
                    fragmentHeader = header; fragmentDON = don; fragment = Data(header)
                } else {
                    guard fragmentHeader == header, fragmentDON == don else { throw Failure.malformed }
                }
                guard bytes + fragment.count + b.count - 3 - donBytes <= 8 * 1024 * 1024 else { throw Failure.limitExceeded }
                fragment.append(contentsOf: b.dropFirst(3 + donBytes))
                if end { try add(fragment); fragment = Data(); fragmentHeader = nil; fragmentDON = nil }
            default: throw Failure.malformed
            }
            guard marker else { return nil }
            guard fragmentHeader == nil, !units.isEmpty else { throw Failure.malformed }
            completed = true
            lastCompletedDON = accessUnitDON
            return units
        } catch { damaged = true; units = []; fragment = Data(); throw error }
    }
    /// Require one complete VPS/SPS/PPS set and exact AP extent. Duplicate,
    /// incomplete, foreign-layer or truncated parameter sets cannot select mode.
    private static func parameterAP(_ b: [UInt8], start: Int) -> Bool {
        var cursor = start
        var types = Set<UInt8>()
        while cursor < b.count {
            guard cursor + 2 <= b.count else { return false }
            let count = Int(b[cursor]) << 8 | Int(b[cursor + 1]); cursor += 2
            guard count >= 3, count <= b.count - cursor else { return false }
            let header = b[cursor], second = b[cursor + 1]
            let type = (header >> 1) & 63
            guard (32...34).contains(type), header & 0x81 == 0,
                  second & 0xf8 == 0, second & 7 != 0,
                  types.insert(type).inserted else { return false }
            cursor += count
        }
        return cursor == b.count && types == Set([32, 33, 34])
    }

    private mutating func add(_ nal: Data) throws {
        let b = [UInt8](nal.prefix(2))
        guard nal.count >= 3, b[0] & 128 == 0, b[1] & 7 != 0, (b[0] >> 1) & 63 < 48 else { throw Failure.malformed }
        guard units.count < 256, bytes + nal.count <= 8 * 1024 * 1024 else { throw Failure.limitExceeded }
        bytes += nal.count; units.append(nal)
    }
}
