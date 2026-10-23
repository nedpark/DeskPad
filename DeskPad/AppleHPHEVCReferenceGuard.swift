import Foundation

/// Conservative single-picture HEVC reference validation. Unsupported syntax
/// never produces an eligible acknowledgement. Decoder success is still required.
nonisolated struct AppleHPHEVCReferenceGuard {
    enum Failure: Error { case malformed, unsupported, missingReference }
    struct Picture: Sendable {
        let poc: Int
        let references: Set<Int>
        let idr: Bool
        fileprivate let epoch: Int
        fileprivate let retained: Set<Int>
    }
    private struct Reference { let delta: Int; let used: Bool }
    private struct SPS {
        let id: Int, pocBits: Int, separate: Bool
        let sets: [[Reference]]
        let longTerm: [(Int, Bool)]
        let hasLongTerm: Bool
    }
    private struct PPS { let sps: Int; let output: Bool; let extra: Int }
    private var sps: [Int:SPS] = [:]
    private var pps: [Int:PPS] = [:]
    private var parameterBytes: [Int:Data] = [:]
    private var clean: Set<Int> = []
    private var previousPOC = 0
    private var epoch = 0

    mutating func reset() {
        let nextEpoch = epoch + 1
        self = Self()
        epoch = nextEpoch
    }
    /// Retain clean references after loss: an LTR recovery picture can still use them.
    mutating func prepare(_ units: [Data]) throws -> Picture {
        guard units.count <= 256 else { throw Failure.malformed }
        var slices: [Data] = []
        for unit in units {
            guard unit.count >= 3, unit.count <= 8 * 1024 * 1024 else { throw Failure.malformed }
            let type = (unit[unit.startIndex] >> 1) & 63
            switch type {
            case 32:
                guard unit.count <= 65536 else { throw Failure.malformed }
                var bits = try Bits(unit)
                rememberParameter(key: 128 + (try bits.read(4)), bytes: unit)
            case 33:
                guard unit.count <= 65536 else { throw Failure.malformed }
                let value = try Self.parseSPS(unit)
                rememberParameter(key: value.id, bytes: unit)
                sps[value.id] = value
            case 34:
                guard unit.count <= 65536 else { throw Failure.malformed }
                var bits = try Bits(unit)
                let id = try bits.ue(63), spsID = try bits.ue(15)
                _ = try bits.bit() // dependent_slice_segments_enabled_flag
                let output = try bits.bit(), extra = try bits.read(3)
                rememberParameter(key: 64 + id, bytes: unit)
                pps[id] = PPS(sps:spsID, output:output, extra:extra)
            case 0...31: slices.append(unit)
            default: break
            }
        }
        // Multiple slice headers require segment-address parsing and identical
        // RPS verification; decline rather than acknowledge unchecked references.
        guard slices.count == 1 else { throw Failure.unsupported }
        let unit = slices[0], type = Int((unit[unit.startIndex] >> 1) & 63)
        guard unit[unit.startIndex] & 1 == 0, unit[unit.startIndex + 1] & 0xf8 == 0,
              unit[unit.startIndex + 1] & 7 == 1 else { throw Failure.unsupported }
        var bits = try Bits(unit)
        guard try bits.bit() else { throw Failure.unsupported }
        if (16...23).contains(type) { _ = try bits.bit() }
        let ppsID = try bits.ue(63)
        guard let config = pps[ppsID], let sequence = sps[config.sps] else { throw Failure.malformed }
        _ = try bits.read(config.extra)
        let sliceType = try bits.ue(2)
        if config.output { _ = try bits.bit() }
        if sequence.separate { _ = try bits.read(2) }
        if type == 19 || type == 20 {
            epoch += 1; clean.removeAll(); previousPOC = 0
            return Picture(poc:0, references:[], idr:true, epoch:epoch, retained:[])
        }
        // CRA/BLA need leading-picture handling beyond this single-chain guard.
        guard type < 16 else { throw Failure.unsupported }
        let lsb = try bits.read(sequence.pocBits), modulus = 1 << sequence.pocBits
        let priorLSB = (previousPOC % modulus + modulus) % modulus
        var msb = previousPOC - priorLSB
        if lsb < priorLSB && priorLSB - lsb >= modulus / 2 { msb += modulus }
        else if lsb > priorLSB && lsb - priorLSB > modulus / 2 { msb -= modulus }
        let poc = msb + lsb
        let rps: [Reference]
        if try bits.bit() {
            guard !sequence.sets.isEmpty else { throw Failure.malformed }
            let index = sequence.sets.count > 1 ? try bits.read(Self.width(sequence.sets.count)) : 0
            guard index < sequence.sets.count else { throw Failure.malformed }
            rps = sequence.sets[index]
        } else { rps = try Self.referenceSet(&bits, previous:sequence.sets, inline:true) }
        var references = Set(rps.filter(\.used).map { poc + $0.delta })
        var retained = Set(rps.map { poc + $0.delta })
        if sequence.hasLongTerm {
            let fromSPS = sequence.longTerm.isEmpty ? 0 : try bits.ue(sequence.longTerm.count)
            let explicit = try bits.ue(32)
            guard fromSPS + explicit <= 32 else { throw Failure.malformed }
            var priorCycle = 0
            for index in 0..<(fromSPS + explicit) {
                let longLSB: Int, used: Bool
                if index < fromSPS {
                    let entry = sequence.longTerm.count > 1 ? try bits.read(Self.width(sequence.longTerm.count)) : 0
                    guard entry < sequence.longTerm.count else { throw Failure.malformed }
                    (longLSB, used) = sequence.longTerm[entry]
                } else { longLSB = try bits.read(sequence.pocBits); used = try bits.bit() }
                let hasCycle = try bits.bit()
                if hasCycle {
                    let delta = try bits.ue(65535)
                    let cycle = (index == 0 || index == fromSPS) ? delta : priorCycle + delta
                    priorCycle = cycle
                    let target = poc - cycle * modulus - lsb + longLSB
                    retained.insert(target)
                    if used { references.insert(target) }
                } else {
                    let candidates = clean.filter { ($0 % modulus + modulus) % modulus == longLSB }
                    if candidates.count == 1, let resolved = candidates.first {
                        retained.insert(resolved)
                        if used { references.insert(resolved) }
                    } else if used { throw Failure.missingReference }
                }
            }
        }
        if sliceType == 2 { references.removeAll() }
        guard references.isSubset(of: clean) else { throw Failure.missingReference }
        return Picture(poc:poc, references:references, idr:false, epoch:epoch, retained:retained)
    }
    /// Called only for an actual successful, non-dropped native decode callback.
    @discardableResult mutating func decoded(_ picture: Picture) -> Bool {
        guard picture.epoch == epoch, picture.references.isSubset(of: clean) else { return false }
        clean.formIntersection(picture.retained)
        clean.insert(picture.poc); previousPOC = picture.poc
        // Conservative bound: retiring an old reference may suppress recovery,
        // but never permits an acknowledgement of an unverified reference.
        if clean.count > 64, let oldest = clean.min() { clean.remove(oldest) }
        return true
    }
    private mutating func rememberParameter(key: Int, bytes: Data) {
        if let prior = parameterBytes[key], prior != bytes {
            epoch += 1; clean.removeAll(); previousPOC = 0
        }
        parameterBytes[key] = bytes
    }
    private static func width(_ count: Int) -> Int { count <= 1 ? 0 : Int.bitWidth - (count - 1).leadingZeroBitCount }
    private static func referenceSet(_ bits: inout Bits, previous: [[Reference]], inline: Bool) throws -> [Reference] {
        if !previous.isEmpty, try bits.bit() {
            let distance = inline ? try bits.ue(previous.count - 1) + 1 : 1
            let sign = try bits.bit() ? -1 : 1
            let delta = sign * (try bits.ue(65535) + 1)
            let source = previous[previous.count - distance]
            var result: [Reference] = []
            for original in source.map(\.delta) + [0] {
                let used = try bits.bit()
                let retained = used ? true : try bits.bit()
                if retained, original + delta != 0 { result.append(Reference(delta:original + delta, used:used)) }
            }
            guard result.count <= 32 else { throw Failure.malformed }
            return result.sorted { a,b in
                if (a.delta < 0) != (b.delta < 0) { return a.delta < 0 }
                return a.delta < 0 ? a.delta > b.delta : a.delta < b.delta
            }
        }
        let negative = try bits.ue(32), positive = try bits.ue(32)
        guard negative + positive <= 32 else { throw Failure.malformed }
        var result: [Reference] = [], value = 0
        for _ in 0..<negative { value -= try bits.ue(65535) + 1; result.append(Reference(delta:value, used:try bits.bit())) }
        value = 0
        for _ in 0..<positive { value += try bits.ue(65535) + 1; result.append(Reference(delta:value, used:try bits.bit())) }
        return result
    }
    private static func parseSPS(_ unit: Data) throws -> SPS {
        var bits = try Bits(unit)
        _ = try bits.read(4)
        let layers = try bits.read(3)
        guard layers <= 6 else { throw Failure.malformed }
        _ = try bits.bit(); try bits.skip(96)
        var sublayers: [(Bool,Bool)] = []
        for _ in 0..<layers { sublayers.append((try bits.bit(),try bits.bit())) }
        if layers > 0 { try bits.skip((8 - layers) * 2) }
        for (profile,level) in sublayers { if profile { try bits.skip(88) }; if level { try bits.skip(8) } }
        let id = try bits.ue(15), chroma = try bits.ue(3)
        let separate = chroma == 3 ? try bits.bit() : false
        _ = try bits.ue(32768); _ = try bits.ue(32768)
        if try bits.bit() { for _ in 0..<4 { _ = try bits.ue(32768) } }
        _ = try bits.ue(8); _ = try bits.ue(8)
        let pocBits = try bits.ue(12) + 4
        let ordering = try bits.bit()
        for _ in 0..<(ordering ? layers + 1 : 1) { _ = try bits.ue(32); _ = try bits.ue(32); _ = try bits.ue(65535) }
        for _ in 0..<6 { _ = try bits.ue(32) }
        if try bits.bit(), try bits.bit() { throw Failure.unsupported } // scaling_list_data
        _ = try bits.bit(); _ = try bits.bit()
        if try bits.bit() { try bits.skip(8); _ = try bits.ue(32); _ = try bits.ue(32); _ = try bits.bit() }
        let count = try bits.ue(64)
        var sets: [[Reference]] = []
        for _ in 0..<count { sets.append(try referenceSet(&bits, previous:sets, inline:false)) }
        let hasLongTerm = try bits.bit()
        var longTerm: [(Int,Bool)] = []
        if hasLongTerm { for _ in 0..<(try bits.ue(32)) { longTerm.append((try bits.read(pocBits),try bits.bit())) } }
        return SPS(id:id,pocBits:pocBits,separate:separate,sets:sets,longTerm:longTerm,hasLongTerm:hasLongTerm)
    }
    private struct Bits {
        var bytes: [UInt8] = []; var position = 0
        init(_ nal: Data) throws {
            guard nal.count >= 3 else { throw Failure.malformed }
            var zeros = 0
            // Header syntax is bounded independently of a multi-megabyte slice.
            for byte in nal.dropFirst(2).prefix(65536) {
                if zeros == 2 && byte == 3 { zeros = 0; continue }
                bytes.append(byte); zeros = byte == 0 ? zeros + 1 : 0
            }
        }
        mutating func bit() throws -> Bool { try read(1) != 0 }
        mutating func read(_ count: Int) throws -> Int {
            guard (0...32).contains(count), position + count <= bytes.count * 8 else { throw Failure.malformed }
            var value = 0
            for _ in 0..<count { value = value << 1 | Int((bytes[position / 8] >> (7 - position % 8)) & 1); position += 1 }
            return value
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, position + count <= bytes.count * 8 else { throw Failure.malformed }; position += count
        }
        mutating func ue(_ maximum: Int) throws -> Int {
            var zeros = 0
            while try !bit() { zeros += 1; guard zeros <= 16 else { throw Failure.malformed } }
            let value = (1 << zeros) - 1 + (try read(zeros))
            guard value <= maximum else { throw Failure.malformed }; return value
        }
    }
}
