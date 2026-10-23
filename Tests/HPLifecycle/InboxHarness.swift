import Foundation
@main struct InboxHarness {
    static func main() async {
        let inbox = AppleHPDatagramInbox(capacity: 3, byteCapacity: 5)
        precondition(inbox.submit(Data([1, 1]), stream: 0))
        precondition(inbox.submit(Data([2, 2]), stream: 1))
        precondition(!inbox.submit(Data([3, 3]), stream: 0))
        precondition(inbox.queuedBytes == 4 && inbox.droppedPackets == 1)
        var iterator = inbox.packets.makeAsyncIterator()
        let first = await iterator.next()
        precondition(first?.data == Data([1, 1]) && inbox.queuedBytes == 2)
        precondition(inbox.submit(Data([3, 3, 3]), stream: 0))
        inbox.finish()
        precondition(!inbox.submit(Data([9]), stream: 0))
        let second = await iterator.next(), third = await iterator.next(), end = await iterator.next()
        precondition(second?.data == Data([2, 2]) && third?.data == Data([3, 3, 3]) && end == nil)
        precondition(inbox.queuedBytes == 0 && inbox.queuedPackets == 0)
        let burst = AppleHPDatagramInbox(capacity: 8192, byteCapacity: 12000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 { group.addTask { burst.submit(Data(repeating: UInt8(i % 256), count: 1200), stream: i % 2) } }
        }
        precondition(burst.queuedPackets == 10 && burst.queuedBytes == 12000 && burst.droppedPackets == 990)
        burst.finish()
        var count = 0
        for await _ in burst.packets { count += 1 }
        precondition(count == 10 && burst.queuedBytes == 0)
        let racing = AppleHPDatagramInbox(capacity: 8192, byteCapacity: 12000)
        let consumer = Task { () -> Int in
            var received = 0
            for await packet in racing.packets {
                precondition(packet.data.count == 1200)
                received += 1
            }
            return received
        }
        let accepted = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<1000 {
                group.addTask { racing.submit(Data(repeating: 7, count: 1200), stream: 0) ? 1 : 0 }
            }
            var count = 0
            for await n in group { count += n }
            return count
        }
        racing.finish()
        let received = await consumer.value
        precondition(received == accepted && racing.queuedBytes == 0 && racing.queuedPackets == 0)
        precondition(accepted + racing.droppedPackets == 1000)
        let capped = AppleHPDatagramInbox(capacity: 2, byteCapacity: 100)
        precondition(capped.submit(Data([1]), stream: 0) && capped.submit(Data([2]), stream: 0))
        precondition(!capped.submit(Data([3]), stream: 0))
        capped.finish()
        print("Inbox: FIFO, byte and packet limits, dequeue accounting, concurrent producers, finish passed")
    }
}
