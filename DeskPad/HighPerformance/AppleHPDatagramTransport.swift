import os
import Foundation


/// Experimental media receiver. Owned by a single RFB session and closed with it.
actor AppleHPDatagramTransport {
    private var sockets: [AppleHPUDPSocket] = []
    private var audio: HighPerformanceSRTPReceiver
    private var video: HighPerformanceSRTPReceiver
    private var audioControl: HighPerformanceSRTCPReceiver
    private var videoControl: HighPerformanceSRTCPReceiver
    private let pipeline: HighPerformanceMediaPipeline
    private let onPlaying: () async -> Void
    private let onFailure: (AppleHPFailure) async -> Void
    private var lastAuthenticatedPacket = ProcessInfo.processInfo.systemUptime
    private var didStart = false
    private var videoProgress = AppleHPVideoProgressWatchdog()
    private var negotiated = false
    private let requestedLTR: Bool
    private var acceptedLTR = false
    private var lastAcknowledgedDON: UInt16?
    private var acknowledgementCount = 0
    private let expectedVideoPayloadType: UInt8
    private var remoteVideoSSRC: UInt32?
    private var remoteAudioSSRC: UInt32?
    private var lastPictureLossRequest = -Double.infinity
    private var counts = [0, 0]
    private var rejected = [0, 0]
    private var active = true
    private let heartbeat: HighPerformanceSRTPSender
    private let audioFeedback: HighPerformanceSRTCPSender
    private let audioSSRC: UInt32
    private var audioReorder = HighPerformanceRTPReorderBuffer(packetLimit: 32, byteLimit: 65536, forwardLimit: 64)
    private var audioWorker: AppleHPVideoDeliveryQueue<HighPerformanceRTPPacket>?
    private var audioNackCount = 0
    private let videoFeedback: HighPerformanceSRTCPSender
    private let videoSSRC: UInt32
    private var heartbeatTask: Task<Void, Never>?
    private let inbox = AppleHPDatagramInbox()
    private var receiverTask: Task<Void, Never>?
    private var reorderTask: Task<Void, Never>?
    private var videoReorder = HighPerformanceRTPReorderBuffer()
    private var videoWorker: AppleHPVideoDeliveryQueue<HighPerformanceRTPPacket>?
    private var nackCount = 0
    private var receptionReport = AppleHPReceptionReport()
    private var audioReceptionReport = AppleHPReceptionReport(clockRate: 48_000)
    private var reportTicks = 0
    private var rejectionCounts: [String: Int] = [:]

    init(offer: AppleHPMediaOffer, videoPayloadType: UInt8 = 123, pipeline: HighPerformanceMediaPipeline, onPlaying: @escaping () async -> Void, onFailure: @escaping (AppleHPFailure) async -> Void) throws {
        self.requestedLTR = offer.ltrEnabled
        self.expectedVideoPayloadType = videoPayloadType
        self.pipeline = pipeline; self.onPlaying = onPlaying; self.onFailure = onFailure
        heartbeat = try .init(masterKeyBlob: offer.audioKeys.viewerToServer, ssrc: offer.audioSSRC)
        videoFeedback = try .init(masterKeyBlob: offer.videoKeys.viewerToServer, ssrc: offer.videoSSRC)
        audioFeedback = try .init(masterKeyBlob: offer.audioKeys.viewerToServer, ssrc: offer.audioSSRC)
        audioSSRC = offer.audioSSRC
        videoSSRC = offer.videoSSRC
        audio = try .init(masterKeyBlob: offer.audioKeys.serverToViewer)
        video = try .init(masterKeyBlob: offer.videoKeys.serverToViewer)
        audioControl = try .init(masterKeyBlob: offer.audioKeys.serverToViewer)
        videoControl = try .init(masterKeyBlob: offer.videoKeys.serverToViewer)
    }
    func start(host: String, port: UInt16) throws {
        guard port < UInt16.max else { throw HighPerformanceSRTPError.malformedPacket }
        guard active, sockets.isEmpty, receiverTask == nil else { throw HighPerformanceSRTPError.malformedPacket }
        do {
            for i in 0..<2 {
                let inbox = self.inbox
                let socket = try AppleHPUDPSocket(remoteIPv4: host, port: port + UInt16(i)) { data in
                    inbox.submit(data, stream: i)
                }
                sockets.append(socket)
            }
        } catch {
            close()
            throw error
        }
        let packets = inbox.packets
        receiverTask = Task { [weak self] in
            for await packet in packets {
                guard !Task.isCancelled else { break }
                await self?.consume(packet.data, stream: packet.stream)
            }
        }
        reorderTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled else { break }
                await self?.flushVideoReorder()
            }
        }
        heartbeatTask = Task {
            while !Task.isCancelled {
                await pulse()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private func pulse() async {
        guard active, sockets.count == 2 else { return }
        let cleanDecode = await pipeline.lastCleanVideoDecodeTime
        guard active, sockets.count == 2 else { return }
        if videoProgress.stalled(now: ProcessInfo.processInfo.systemUptime, lastCleanDecode: cleanDecode) {
            failMedia(.videoStalled)
            return
        }
        if negotiated, !didStart { requestKeyframe() }
        if negotiated, ProcessInfo.processInfo.systemUptime - lastAuthenticatedPacket > 15 {
            failMedia(.mediaIdleTimeout)
            return
        }
        do {
            // Keep the separate video return path open even though all
            // RTCP feedback is muxed on the control/audio port.
            sockets[1].send(Data([0]))
            let timestamp = UInt32(truncatingIfNeeded: UInt64(ProcessInfo.processInfo.systemUptime * 48_000))
            let packet = try heartbeat.protect(payload: Data([0, 0x68, 0x34, 0]), payloadType: 101, timestamp: timestamp)
            sockets[0].send(packet)
            if let remoteAudioSSRC {
                // Audio has its own RTP clock, SR timing, SSRC and SRTCP key.
                // Report authenticated arrivals before local reordering/decoding
                // so concealment or local playback policy cannot hide wire loss.
                let rr = audioReceptionReport.receiverReport(sender: audioSSRC, media: remoteAudioSSRC, now: ProcessInfo.processInfo.systemUptime)
                sockets[0].send(try audioFeedback.protect(rr))
            }
            if let remoteVideoSSRC {
                var rr = receptionReport.receiverReport(sender: videoSSRC, media: remoteVideoSSRC, now: ProcessInfo.processInfo.systemUptime)
                reportTicks += 1
                if reportTicks % 10 == 0 {
                    rr = AppleHPReceptionReport.senderReport(sender: videoSSRC, unixTime: Date().timeIntervalSince1970) + rr
                }
                try sendVideoFeedback(rr)
            }
        } catch { failMedia(.playbackFailure) }
    }
    func accept(_ answer: AppleHPMediaAnswer) async throws {
        guard active, !negotiated, answer.secondVideo == nil, answer.video.supportedVideoPayloadTypes.contains(expectedVideoPayloadType) else {
            throw AppleHPFailure.unsupportedVideoLayout
        }
        #if DEBUG
        VNCControlDiagnostics.logger.notice("HP answer status=\(answer.status) videoPT=\(answer.video.codecPayloadType ?? 0) width=\(answer.video.width ?? 0) height=\(answer.video.height ?? 0)")
        let feedbackAllowed = try? AppleHPProtoValue.oneNumber(answer.video.descriptionFields, 2)
        VNCControlDiagnostics.logger.notice("HP answer videoFeedback=\(feedbackAllowed.map(String.init) ?? "absent", privacy: .public)")
        #endif
        // Some servers omit the optional tile count in their answer. The offer
        // requests one picture; depacketization independently rejects a second SSRC.
        if answer.video.descriptionFields[6] != nil {
            let tiles = try AppleHPProtoValue.oneNumber(answer.video.descriptionFields, 6)
            guard tiles <= 1 else { throw AppleHPFailure.unsupportedVideoLayout }
        }
        let ltr = answer.video.descriptionFields[7] == nil ? 0 : try AppleHPProtoValue.oneNumber(answer.video.descriptionFields, 7)
        guard ltr <= 1, ltr == 0 || requestedLTR else { throw AppleHPFailure.unsupportedVideoLayout }
        try await pipeline.configureLTR(enabled: ltr == 1)
        guard active else { throw AppleHPFailure.playbackFailure }
        acceptedLTR = ltr == 1
        #if DEBUG
        VNCControlDiagnostics.logger.notice("HP negotiated LTR=\(self.acceptedLTR)")
        #endif
        remoteVideoSSRC = answer.video.ssrc
        remoteAudioSSRC = answer.audio.ssrc
        negotiated = true
        lastAuthenticatedPacket = ProcessInfo.processInfo.systemUptime
        requestKeyframe()
    }

    func acknowledgeCleanFrame(don: UInt16) {
        guard active, negotiated, acceptedLTR, sockets.count == 2, lastAcknowledgedDON != don else { return }
        do {
            let packet = AppleHPLTRAcknowledgement.packet(sender: videoSSRC, don: don)
            sockets[1].send(try videoFeedback.protect(packet))
            lastAcknowledgedDON = don
            acknowledgementCount += 1
            #if DEBUG
            if acknowledgementCount <= 3 || acknowledgementCount % 120 == 0 {
                VNCControlDiagnostics.logger.notice("HP clean frame ACK count=\(self.acknowledgementCount) don=\(don)")
            }
            #endif
        } catch { failMedia(.playbackFailure) }
    }

    private func sendVideoFeedback(_ plaintext: Data) throws {
        guard active, sockets.count == 2 else { return }
        try AppleHPVideoFeedbackRoute.send(plaintext, protect: { try videoFeedback.protect($0) }) {
            sockets[$0].send($1)
        }
    }

    func requestKeyframe() {
        let now = ProcessInfo.processInfo.systemUptime
        guard active, sockets.count == 2, let remoteVideoSSRC, now - lastPictureLossRequest >= 0.5 else { return }
        do {
            let packet = AppleHPFeedback.pictureLoss(sender: videoSSRC, media: remoteVideoSSRC)
            try sendVideoFeedback(packet)
            lastPictureLossRequest = now
        } catch { failMedia(.playbackFailure) }
    }

    private func failMedia(_ reason: AppleHPFailure) {
        guard active else { return }
        close()
        Task { await onFailure(reason) }
    }

    func closeForRestart() async {
        let retiringSockets = sockets
        close()
        for socket in retiringSockets { await socket.waitUntilClosed() }
    }

    func close() {
        active = false
        inbox.finish()
        receiverTask?.cancel(); receiverTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        reorderTask?.cancel(); reorderTask = nil
        if let videoWorker { Task { await videoWorker.close() } }
        videoWorker = nil
        if let audioWorker { Task { await audioWorker.close() } }
        audioWorker = nil
        audioReorder = HighPerformanceRTPReorderBuffer(packetLimit: 32, byteLimit: 65536, forwardLimit: 64)
        videoReorder = HighPerformanceRTPReorderBuffer()
        for socket in sockets { socket.close() }
        sockets.removeAll()
    }
    private func flushVideoReorder() async {
        guard active, negotiated else { return }
        if audioReorder.hasPending { await deliverAudio(audioReorder.flush(now: ProcessInfo.processInfo.systemUptime)) }
        if active, videoReorder.hasPending { await deliverVideo(videoReorder.flush(now: ProcessInfo.processInfo.systemUptime)) }
    }

    // Audio uses its negotiated SRTCP key and SSRC. A peer that ignores Generic
    // NACK costs at most the existing 60 ms repair deadline, never an unbounded wait.
    private func deliverAudio(_ output: HighPerformanceRTPReorderBuffer.Output) async {
        guard active else { return }
        if let remoteAudioSSRC, !output.missing.isEmpty,
           let nack = HighPerformanceNACK.compound(sender: audioSSRC, media: remoteAudioSSRC, sequences: output.missing) {
            do { sockets[0].send(try audioFeedback.protect(nack)); audioNackCount += 1 }
            catch { failMedia(.playbackFailure); return }
        }
        if audioWorker == nil {
            audioWorker = AppleHPVideoDeliveryQueue(packetLimit: 64, byteLimit: 131072) { [weak self] packet in
                await self?.deliverOneAudio(packet)
            }
        }
        guard let audioWorker, await audioWorker.enqueue(output.packets.map { ($0, $0.payload.count) }) else {
            if active { failMedia(.playbackFailure) }; return
        }
    }
    private func deliverOneAudio(_ packet: HighPerformanceRTPPacket) async {
        guard active, !Task.isCancelled else { return }
        do { try await pipeline.consumeAudioAccessUnit(packet) }
        catch HighPerformancePlaybackError.backpressure { /* Pipeline retains this AU. */ }
        catch { failMedia(.playbackFailure); return }
        if active, !didStart {
            let playing = await pipeline.isPlaying
            if active, !didStart, playing { didStart = true; await onPlaying() }
        }
    }

    private func deliverVideo(_ output: HighPerformanceRTPReorderBuffer.Output) async {
        guard active else { return }
        if let remoteVideoSSRC, !output.missing.isEmpty,
           let nack = HighPerformanceNACK.compound(sender: videoSSRC, media: remoteVideoSSRC, sequences: output.missing) {
            do {
                try sendVideoFeedback(nack)
                nackCount += 1
                #if DEBUG
                if nackCount <= 3 || nackCount % 100 == 0 {
                    VNCControlDiagnostics.logger.notice("HP video NACK count=\(self.nackCount) missing=\(output.missing.count)")
                }
                #endif
            }
            catch { failMedia(.playbackFailure); return }
        }
        if videoWorker == nil {
            videoWorker = AppleHPVideoDeliveryQueue { [weak self] packet in
                await self?.deliverOneVideo(packet)
            }
        }
        guard let videoWorker, await videoWorker.enqueue(output.packets.map { ($0, $0.payload.count) }) else {
            if active { failMedia(.playbackFailure) }
            return
        }
    }

    private func deliverOneVideo(_ packet: HighPerformanceRTPPacket) async {
        guard active, !Task.isCancelled else { return }
        do { try await pipeline.consumeVideo(packet) }
        catch let error as HighPerformancePlaybackError {
            if case .backpressure = error { requestKeyframe() }
            else { failMedia(.playbackFailure); return }
        } catch { requestKeyframe() }
        // Fragment packets cannot produce a complete frame. Avoid an extra main
        // actor hop for every packet in a multi-thousand-packet keyframe burst.
        if packet.marker, active, !didStart {
            let playing = await pipeline.isPlaying
            if active, !didStart, playing {
                didStart = true; await onPlaying()
            }
        }
    }

    private func decodeControl(_ data: Data, stream: Int) throws -> Data {
        guard data.count >= 8 else { throw HighPerformanceSRTPError.malformedPacket }
        let ssrc = data.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // Video control uses the audio/control UDP port. This header only
        // selects a verifier; no report is used before its tag is checked.
        if ssrc == remoteVideoSSRC { return try videoControl.receive(data) }
        if ssrc == remoteAudioSSRC { return try audioControl.receive(data) }
        throw HighPerformanceSRTPError.malformedPacket
    }
    private func decodeMedia(_ data: Data, stream: Int) throws -> HighPerformanceRTPPacket {
        if stream == 0 { return try audio.receive(data) }
        return try video.receive(data)
    }
    private func consume(_ data: Data, stream: Int) async {
        guard active, negotiated, data.count >= 2 else { return }
        #if DEBUG
        if AppleHPDebugMediaLoss.shared.shouldDrop(now: ProcessInfo.processInfo.systemUptime) { return }
        #endif
        do {
            let isControl = (192...223).contains(data[data.startIndex + 1])
            if isControl {
                let plain = try decodeControl(data, stream: stream)
                lastAuthenticatedPacket = ProcessInfo.processInfo.systemUptime
                let reports = try HighPerformanceSenderReport.parseCompound(plain)
                for report in reports {
                    guard report.ssrc == remoteAudioSSRC || report.ssrc == remoteVideoSSRC else {
                        throw HighPerformanceSRTPError.malformedPacket
                    }
                    if report.ssrc == remoteVideoSSRC {
                        receptionReport.observe(report, now: ProcessInfo.processInfo.systemUptime)
                    } else if report.ssrc == remoteAudioSSRC {
                        audioReceptionReport.observe(report, now: ProcessInfo.processInfo.systemUptime)
                    }
                    try await pipeline.observe([report], clockRate: report.ssrc == remoteAudioSSRC ? 48000 : 90000)
                }
                #if DEBUG
                if !reports.isEmpty { VNCControlDiagnostics.logger.notice("HP sender reports stream=\(stream) count=\(reports.count)") }
                #endif
            } else {
                let packet = try decodeMedia(data, stream: stream)
                lastAuthenticatedPacket = ProcessInfo.processInfo.systemUptime
                guard packet.ssrc == (stream == 0 ? remoteAudioSSRC : remoteVideoSSRC) else {
                    // Authentication has succeeded. A second video SSRC is an
                    // unsupported tiled session, not an unauthenticated stray packet.
                    if stream == 1 { failMedia(.unsupportedVideoLayout); return }
                    throw HighPerformanceMediaError.malformedPacket
                }
                if stream == 1, packet.payloadType != expectedVideoPayloadType {
                    failMedia(.unsupportedVideoLayout)
                    return
                }
                if stream == 0 {
                    audioReceptionReport.observe(packet, now: ProcessInfo.processInfo.systemUptime)
                    await deliverAudio(audioReorder.insert(packet, now: ProcessInfo.processInfo.systemUptime))
                } else {
                    videoProgress.observeVideo(timestamp: packet.timestamp, now: ProcessInfo.processInfo.systemUptime)
                    receptionReport.observe(packet, now: ProcessInfo.processInfo.systemUptime)
                    await deliverVideo(videoReorder.insert(packet, now: ProcessInfo.processInfo.systemUptime))
                }
                counts[stream] += 1
                if counts[stream] == 1 || counts[stream] % 500 == 0 {
                    #if DEBUG
                    if stream == 0 {
                        let repair = audioReorder.statistics
                        VNCControlDiagnostics.logger.notice("HP audio repair nacks=\(self.audioNackCount) recovered=\(repair.repairedHeads) expired=\(repair.deadlineExpirations) late=\(repair.latePackets) capacity=\(repair.capacityFlushes) pending=\(self.audioReorder.bufferedPacketCount)")
                    }
                    if stream == 1 {
                        let repair = videoReorder.statistics
                        VNCControlDiagnostics.logger.notice("HP repair recovered=\(repair.repairedHeads) expired=\(repair.deadlineExpirations) capacity=\(repair.capacityFlushes) late=\(repair.latePackets) peak=\(repair.peakPackets) maxRepairMs=\(repair.longestRepairMilliseconds) queued=\(self.videoReorder.bufferedPacketCount)")
                    }
                    if stream == 1, let stats = await videoWorker?.statistics {
                        VNCControlDiagnostics.logger.notice("HP video delivery queued=\(stats.queuedPackets) bytes=\(stats.queuedBytes) peak=\(stats.peakPackets) peakBytes=\(stats.peakBytes)")
                    }
                    VNCControlDiagnostics.logger.notice("HP authenticated media stream=\(stream) packets=\(self.counts[stream]) pt=\(packet.payloadType) bytes=\(packet.payload.count) inboxDrops=\(self.inbox.droppedPackets)")
                    #endif
                }
            }
        } catch {
            if let playbackError = error as? HighPerformancePlaybackError {
                #if DEBUG
                VNCControlDiagnostics.logger.notice("HP playback error=\(String(describing: playbackError), privacy: .public)")
                #endif
                switch playbackError {
                case .backpressure: requestKeyframe()
                default: failMedia(.playbackFailure); return
                }
            }
            #if DEBUG
            let reason = String(describing: error)
            let rejectionKey = "\(stream):\(reason)"
            rejectionCounts[rejectionKey, default: 0] += 1
            let reasonCount = rejectionCounts[rejectionKey]!
            if reasonCount == 1 || reasonCount % 100 == 0 {
                VNCControlDiagnostics.logger.notice("HP UDP rejection stream=\(stream) reason=\(reason, privacy: .public) count=\(reasonCount)")
            }
            #endif
            rejected[stream] += 1
            if rejected[stream] == 1 {
                #if DEBUG
                VNCControlDiagnostics.logger.notice("HP UDP rejected stream=\(stream) reason=\(String(describing: error), privacy: .public)")
                #endif
            }
        }
    }
}
