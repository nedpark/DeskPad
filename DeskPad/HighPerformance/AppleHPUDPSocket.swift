import Foundation
import os
import Darwin

/// Unconnected UDP avoids treating an early host ICMP-port-unreachable as a
/// permanent media-connection failure. Descriptor ownership stays on one queue.
nonisolated final class AppleHPUDPSocket: @unchecked Sendable {
    enum Failure: Error { case resolve(Int32), invalidAddress, system(Int32) }
    private let queue = DispatchQueue(label: "DeskPad.HPUDP")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var descriptor: Int32
    private var peer: sockaddr_in
    private let source: DispatchSourceRead
    private var active = true
    private var sentPackets = 0
    private var failedSends = 0
    private var filteredPackets = 0
    private let receive: @Sendable (Data) -> Void

    static func resolveIPv4(host: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                guard status == 0, let result else { continuation.resume(throwing: Failure.resolve(status)); return }
                defer { freeaddrinfo(result) }
                let address = result.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var ip = address, text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ip, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    continuation.resume(throwing: Failure.invalidAddress); return
                }
                continuation.resume(returning: String(cString: text))
            }
        }
    }

    /// Returns only after bind and nonblocking setup. Use the resolved IPv4
    /// address for TCP as well so server media targets the same address family.
    init(remoteIPv4: String, port: UInt16, localPort: UInt16? = nil,
         receive: @escaping @Sendable (Data) -> Void) throws {
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET); endpoint.sin_port = port.bigEndian
        guard inet_pton(AF_INET, remoteIPv4, &endpoint.sin_addr) == 1 else { throw Failure.invalidAddress }
        peer = endpoint; self.receive = receive
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure.system(errno) }
        var bound = false
        defer { if !bound { Darwin.close(fd) } }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.system(errno) }
        var bufferSize: Int32 = 4 * 1024 * 1024
        let bufferStatus = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        #if DEBUG
        var actualBuffer: Int32 = 0
        var actualSize = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actualBuffer, &actualSize)
        VNCControlDiagnostics.logger.notice("HP UDP receive buffer requested=4194304 actual=\(actualBuffer) status=\(bufferStatus)")
        #endif
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET); local.sin_port = (localPort ?? port).bigEndian
        let bindStatus = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindStatus == 0 else { throw Failure.system(errno) }
        descriptor = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        queue.setSpecific(key: queueKey, value: 1)
        // Only the cancel handler closes an activated descriptor. Capturing the
        // numeric fd here prevents delayed cancellation closing a reused field.
        closed.enter()
        let closed = self.closed
        source.setCancelHandler { Darwin.close(fd); closed.leave() }
        source.setEventHandler { [weak self] in self?.drain() }
        bound = true
        source.resume()
    }

    func send(_ data: Data) {
        guard data.count <= 65_507 else { return }
        queue.async { [weak self] in
            guard let self, self.active else { return }
            var endpoint = self.peer
            let sent = data.withUnsafeBytes { payload in
                withUnsafePointer(to: &endpoint) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(self.descriptor, payload.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == data.count {
                self.sentPackets += 1
                #if DEBUG
                if self.sentPackets == 1 || self.sentPackets % 500 == 0 {
                    VNCControlDiagnostics.logger.notice("HP UDP sent port=\(self.peer.sin_port.bigEndian) count=\(self.sentPackets) failures=\(self.failedSends) filtered=\(self.filteredPackets)")
                }
                #endif
            }
            else {
                let failure = errno
                self.failedSends += 1
                #if DEBUG
                if self.failedSends == 1 || self.failedSends % 100 == 0 {
                    VNCControlDiagnostics.logger.notice("HP UDP send failure port=\(self.peer.sin_port.bigEndian) errno=\(failure) failures=\(self.failedSends) sent=\(self.sentPackets)")
                }
                #endif
            }
            // EAGAIN/ECONNREFUSED are transient datagram loss, never teardown.
        }
    }

    private let closed = DispatchGroup()

    func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            closed.notify(queue: .global()) { continuation.resume() }
        }
    }

    func close() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { closeOnQueue() }
        else { queue.sync { closeOnQueue() } }
    }
    private func closeOnQueue() {
        guard active else { return }
        active = false; source.cancel()
    }
    deinit { close() }

    private func drain() {
        guard active else { return }
        var buffer = [UInt8](repeating: 0, count: 65_535)
        // Bound work per dispatch, allowing close and sends through promptly.
        for _ in 0..<64 {
            var sender = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length)
                }
            }
            if count < 0 {
                if errno == EINTR || errno == ECONNREFUSED { continue }
                return
            }
            guard length == MemoryLayout<sockaddr_in>.size, sender.sin_family == sa_family_t(AF_INET),
                  sender.sin_addr.s_addr == peer.sin_addr.s_addr, sender.sin_port == peer.sin_port else {
                filteredPackets += 1
                #if DEBUG
                if filteredPackets == 1 || filteredPackets % 100 == 0 {
                    VNCControlDiagnostics.logger.notice("HP UDP filtered port=\(self.peer.sin_port.bigEndian) count=\(self.filteredPackets)")
                }
                #endif
                continue
            }
            receive(Data(buffer.prefix(count)))
        }
    }
}
