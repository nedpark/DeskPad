import Foundation

/// Separates authenticated packet ingress from slow decoder work. One bounded
/// queue and one consumer task preserve order while enqueue remains reentrant.
actor AppleHPVideoDeliveryQueue<Element: Sendable> {
    private struct Entry { let value: Element; let bytes: Int }
    private var queue: [Entry?] = []
    private var head = 0
    private var bytes = 0
    private var peakPackets = 0
    private var peakBytes = 0
    struct Statistics: Sendable {
        let queuedPackets: Int
        let queuedBytes: Int
        let peakPackets: Int
        let peakBytes: Int
    }
    var statistics: Statistics {
        Statistics(queuedPackets: queue.count - head, queuedBytes: bytes,
                   peakPackets: peakPackets, peakBytes: peakBytes)
    }
    private var closed = false
    private var worker: Task<Void, Never>?
    private let packetLimit: Int
    private let byteLimit: Int
    private let consume: @Sendable (Element) async -> Void

    init(packetLimit: Int = 8192, byteLimit: Int = 12 * 1024 * 1024,
         consume: @escaping @Sendable (Element) async -> Void) {
        precondition((1...8192).contains(packetLimit) && (1...(12 * 1024 * 1024)).contains(byteLimit))
        self.packetLimit = packetLimit; self.byteLimit = byteLimit; self.consume = consume
    }
    func enqueue(_ values: [(Element, Int)]) -> Bool {
        guard !closed, values.count <= packetLimit - (queue.count - head) else { return false }
        var additional = 0
        for (_, size) in values {
            guard size >= 0, size <= byteLimit - additional else { return false }
            additional += size
        }
        guard additional <= byteLimit - bytes else { return false }
        queue.append(contentsOf: values.map { Entry(value: $0.0, bytes: $0.1) })
        bytes += additional
        peakPackets = max(peakPackets, queue.count - head)
        peakBytes = max(peakBytes, bytes)
        if worker == nil, head < queue.count {
            worker = Task { [weak self] in await self?.drain() }
        }
        return true
    }
    func close() {
        closed = true
        worker?.cancel(); worker = nil
        queue.removeAll(); head = 0; bytes = 0
    }
    private func drain() async {
        while !closed, !Task.isCancelled, head < queue.count {
            let entry = queue[head]!
            queue[head] = nil
            head += 1; bytes -= entry.bytes
            // Periodic compaction keeps removal O(1) amortized, not O(n)/packet.
            if head >= 256 { queue.removeFirst(head); head = 0 }
            await consume(entry.value)
        }
        if !closed { queue.removeAll(keepingCapacity: true); head = 0; bytes = 0 }
        worker = nil
    }
}
