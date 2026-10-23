import Foundation

@main struct Harness {
    static func main() async {
        let inbox = AppleHPDatagramInbox(capacity: 2)
        precondition(inbox.submit(Data([1]), stream: 0))
        precondition(inbox.submit(Data([2]), stream: 1))
        precondition(!inbox.submit(Data([3]), stream: 0))
        precondition(!inbox.submit(Data(), stream: 0))
        precondition(!inbox.submit(Data(repeating: 0, count: 65536), stream: 0))
        precondition(!inbox.submit(Data([4]), stream: 2))
        precondition(inbox.droppedPackets == 1)
        inbox.finish()
        var packets: [UInt8] = []
        var streams: [Int] = []
        for await packet in inbox.packets {
            packets.append(packet.data[0]); streams.append(packet.stream)
        }
        precondition(packets == [1, 2] && streams == [0, 1])
        precondition(!inbox.submit(Data([5]), stream: 0))
        print("PASS bounded UDP queue: overflow, ordering, bounds, finish")
    }
}
