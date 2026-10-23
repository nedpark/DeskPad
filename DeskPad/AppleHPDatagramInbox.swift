import Foundation
import os

/// A burst-sized queue with independent packet and byte limits. One consumer
/// drains it in arrival order; no task is allocated per socket callback.
final class AppleHPDatagramInbox: Sendable {
    struct Packet: Sendable { let data: Data; let stream: Int }
    fileprivate struct Accounting {
        var packets = 0
        var bytes = 0
        var dropped = 0
        var finished = false
    }
    struct Packets: AsyncSequence, Sendable {
        typealias Element = Packet
        nonisolated struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate var iterator: AsyncStream<Packet>.Iterator
            fileprivate let accounting: OSAllocatedUnfairLock<Accounting>
            mutating func next() async -> Packet? {
                guard let packet = await iterator.next() else { return nil }
                accounting.withLock {
                    $0.packets -= 1
                    $0.bytes -= packet.data.count
                }
                return packet
            }
        }
        fileprivate let stream: AsyncStream<Packet>
        fileprivate let accounting: OSAllocatedUnfairLock<Accounting>
        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: stream.makeAsyncIterator(), accounting: accounting)
        }
    }
    private let accounting = OSAllocatedUnfairLock(initialState: Accounting())
    private let capacity: Int
    private let byteCapacity: Int
    let packets: Packets
    private let continuation: AsyncStream<Packet>.Continuation
    var droppedPackets: Int { accounting.withLock { $0.dropped } }
    var queuedBytes: Int { accounting.withLock { $0.bytes } }
    var queuedPackets: Int { accounting.withLock { $0.packets } }

    init(capacity: Int = 8192, byteCapacity: Int = 12 * 1024 * 1024) {
        precondition((1...8192).contains(capacity))
        precondition((1...(12 * 1024 * 1024)).contains(byteCapacity))
        self.capacity = capacity
        self.byteCapacity = byteCapacity
        let pair = AsyncStream<Packet>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        packets = Packets(stream: pair.stream, accounting: accounting)
        continuation = pair.continuation
    }

    @discardableResult func submit(_ data: Data, stream: Int) -> Bool {
        guard !data.isEmpty, data.count <= 65535, (0...1).contains(stream) else { return false }
        return accounting.withLock { state in
            guard !state.finished else { return false }
            guard state.packets < capacity, data.count <= byteCapacity - state.bytes else {
                state.dropped += 1
                return false
            }
            state.packets += 1
            state.bytes += data.count
            switch continuation.yield(Packet(data: data, stream: stream)) {
            case .enqueued: return true
            case .dropped:
                state.dropped += 1
                state.packets -= 1; state.bytes -= data.count
                return false
            case .terminated:
                state.packets -= 1; state.bytes -= data.count
                return false
            @unknown default:
                state.packets -= 1; state.bytes -= data.count
                return false
            }
        }
    }

    /// Stops producers. Already queued packets remain available to the consumer;
    /// the transport cancels its consumer task when it wants to discard them.
    func finish() {
        accounting.withLock { state in
            guard !state.finished else { return }
            state.finished = true
            continuation.finish()
        }
    }
    deinit { continuation.finish() }
}
