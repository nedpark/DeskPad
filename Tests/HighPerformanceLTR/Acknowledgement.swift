import Foundation
@main struct AcknowledgementVectors {
    static func main() {
        precondition(AppleHPLTRAcknowledgement.packet(sender: 0x12345678, don: 0xabcd) == Data([0x80,0xcc,0,3,0x12,0x34,0x56,0x78,0,0,0,5,0,0,0xab,0xcd]))
        for don: UInt16 in [0, 1, 65535] {
            let packet = AppleHPLTRAcknowledgement.packet(sender: 1, don: don)
            precondition(packet.count == 16)
            precondition(packet.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } == UInt32(don))
        }
        print("Native APP name5 exact DON acknowledgement vectors passed")
    }
}
