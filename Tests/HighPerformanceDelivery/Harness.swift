import Foundation
actor Gate {
    var waiting: CheckedContinuation<Void, Never>?
    var values: [Int] = []
    func receive(_ value: Int) async {
        values.append(value)
        if value == 1 { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { waiting?.resume(); waiting = nil }
    var blocked: Bool { waiting != nil }
}
@main struct Harness {
    static func main() async {
        let gate = Gate()
        let queue = AppleHPVideoDeliveryQueue<Int>(packetLimit: 3, byteLimit: 6) { await gate.receive($0) }
        let initial = await queue.enqueue([(1, 2)])
        precondition(initial)
        while !(await gate.blocked) { await Task.yield() }
        // Decoder is deliberately blocked; ingress must still accept repair data.
        let enqueued = await queue.enqueue([(2, 2), (3, 2), (4, 2)])
        let overflow = await queue.enqueue([(5, 1)])
        precondition(enqueued && !overflow)
        await gate.release()
        while (await gate.values).count != 4 { await Task.yield() }
        let ordered = await gate.values
        precondition(ordered == [1, 2, 3, 4])
        await queue.close()
        let closed = await queue.enqueue([(6, 1)])
        precondition(!closed)
        let secondGate = Gate()
        let closing = AppleHPVideoDeliveryQueue<Int>(packetLimit: 3, byteLimit: 6) { await secondGate.receive($0) }
        _ = await closing.enqueue([(1,2)])
        while !(await secondGate.blocked) { await Task.yield() }
        _ = await closing.enqueue([(2,2)])
        await closing.close(); await secondGate.release()
        for _ in 0..<20 { await Task.yield() }
        let canceled = await secondGate.values
        precondition(canceled == [1])
        print("Delivery: blocked decoder does not block ingress; FIFO, limits and close cancellation passed")
    }
}
