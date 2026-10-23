import Foundation
import UIKit
import Network
import Observation
import CryptoKit
import CommonCrypto
import Security
#if DEBUG
import os

// Counts and protocol sizes only: never log key values, pointer positions,
// credentials, clipboard contents, host names, or server-provided text.
nonisolated enum VNCControlDiagnostics {
    static let logger = Logger(subsystem: "com.africastart.DeskPad", category: "ControlDiagnostics")
    static func stateTag(_ state: VNCConnectionState) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .handshaking: "handshaking"
        case .authenticating: "authenticating"
        case .initializing: "initializing"
        case .connected: "connected"
        case .failed: "failed"
        case .ended: "ended"
        case .paused: "paused"
        case .reconnecting: "reconnecting"
        }
    }
}
#endif

private struct RFBAppleBlackFirstFrame: Error {}
private struct RFBRendererResumeRequired: LocalizedError {
    var errorDescription: String? { "앱 복귀 후 화면과 소리 재생을 다시 연결해야 합니다." }
}

enum VNCConnectionState: Equatable {
    case disconnected
    case connecting
    case handshaking
    case authenticating
    case initializing
    case connected
    case failed(String)
    case ended
    case paused
    case reconnecting(Int)

    var title: String {
        switch self {
        case .disconnected: "연결 해제됨"
        case .connecting: "서버 연결 중…"
        case .handshaking: "RFB 협상 중…"
        case .authenticating: "보안 확인 중…"
        case .initializing: "화면 초기화 중…"
        case .connected: "연결됨"
        case .failed(let message): message
        case .ended: "Mac과의 연결이 종료되었습니다"
        case .paused: "연결 일시 정지됨"
        case .reconnecting(let attempt): "다시 연결 중 (\(attempt)/3)…"
        }
    }
}

@Observable
@MainActor
final class VNCSessionModel {
    private(set) var state: VNCConnectionState = .disconnected {
        didSet {
            #if DEBUG
            if state != oldValue {
                VNCControlDiagnostics.logger.notice("state=\(VNCControlDiagnostics.stateTag(self.state), privacy: .public)")
            }
            #endif
        }
    }
    private let hpServerTrust = AppleHPServerTrust()
    private(set) var hpTrustChallenge: AppleHPServerTrust.Challenge?
    private var hpTrustReply: CheckedContinuation<Bool, Never>?

    func answerHPTrust(_ approved: Bool) {
        let reply = hpTrustReply
        hpTrustReply = nil
        hpTrustChallenge = nil
        reply?.resume(returning: approved)
    }

    func verifyHPServerKey(_ der: Data, host: String, port: UInt16, generation: UUID) async throws {
        guard self.generation == generation else { throw CancellationError() }
        let decision = try await hpServerTrust.inspect(der: der, host: host, port: Int(port))
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        switch decision {
        case .trusted: return
        case .approvalRequired(let challenge):
            let approved = await withTaskCancellationHandler {
                await withCheckedContinuation { reply in
                    hpTrustReply = reply
                    hpTrustChallenge = challenge
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.hpTrustChallenge?.id == challenge.id else { return }
                    self?.answerHPTrust(false)
                }
            }
            guard self.generation == generation, !Task.isCancelled else {
                await hpServerTrust.cancel(challenge)
                throw CancellationError()
            }
            guard approved else {
                await hpServerTrust.cancel(challenge)
                throw NSError(domain: "DeskPad.ServerTrust", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Mac 서버 신뢰 확인이 취소되었습니다."])
            }
            try await hpServerTrust.approve(challenge)
        }
    }

    private(set) var highPerformancePlayback: HighPerformancePlayback?
    func attachHighPerformance(_ playback: HighPerformancePlayback, width: Int, height: Int, generation: UUID) {
        guard self.generation == generation else { return }
        playback.setMuted(!recovery.foreground)
        highPerformancePlayback = playback
        screenWidth = width; screenHeight = height
        if state != .connected { state = .initializing }
    }
    private(set) var framebuffer = Data()
    private(set) var remoteCursor: RFBCursorShape?
    private(set) var framebufferRevision: UInt64 = 0
    private(set) var screenWidth = 0
    private(set) var screenHeight = 0
    private(set) var errorDetails: String?
    private(set) var usingCompatibleColor = false

    private(set) var receivedClipboard: String?
    private(set) var clipboardError: String?
    private var generation = UUID()
    private let inputQueue = RFBInputQueue()
    #if DEBUG
    private var inputCallbacks = 0
    private var inputAccepted = 0
    private var inputDropped = 0
    private var inputCompleted = 0
    #endif
    private var client: RFBClient?
    private var sessionTask: Task<Void, Never>?

    private struct Intent {
        let connection: SavedConnection
        let password: String?
        let quality: VNCColorQuality
        let mode: DeskPadConnectionMode
    }
    private var intent: Intent?
    private var recovery = SessionRecoveryPolicy()
    private var resumeTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func sceneActive() {
        lifecycleLog("foreground")
        endGrace()
        highPerformancePlayback?.setMuted(false)
        switch recovery.activate() {
        case .resume: scheduleResume(delay: 0, attempt: 0)
        case .retry(let attempt, let delay): scheduleResume(delay: delay, attempt: attempt)
        case .stop: disconnect()
        case nil:
            if highPerformancePlayback?.needsRecovery == true {
                lifecycleLog("foreground renderer requires recovery")
                fail(RFBRendererResumeRequired(), generation: generation)
            }
        default: break
        }
    }

    func sceneInactive() {
        recovery.background()
        highPerformancePlayback?.setMuted(true)
    }

    func sceneBackground() {
        sceneInactive()
        guard intent != nil, backgroundTask == .invalid else { return }
        lifecycleLog("background grace started")
        let token = recovery.generation
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DeskPad session grace") { [weak self] in
            Task { @MainActor in
                guard let self, self.recovery.generation == token, !self.recovery.foreground else { return }
                self.pauseSession()
            }
        }
        guard backgroundTask != .invalid else { pauseSession(); return }
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.recovery.generation == token else { return }
            self.pauseSession()
        }
    }

    private func lifecycleLog(_ event: String) {
        #if DEBUG
        VNCControlDiagnostics.logger.notice("lifecycle: \(event, privacy: .public)")
        #endif
    }

    private func endGrace() {
        graceTask?.cancel(); graceTask = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func retireTransport() {
        generation = UUID()
        answerHPTrust(false)
        sessionTask?.cancel(); sessionTask = nil
        resumeTask?.cancel(); resumeTask = nil
        inputQueue.cancel()
        let previous = closeTask
        let old = client
        client = nil
        closeTask = Task { await previous?.value; await old?.closeForStartupRetry() }
        highPerformancePlayback?.reset(); highPerformancePlayback = nil
        framebuffer = Data(); framebufferRevision &+= 1
        remoteCursor = nil; screenWidth = 0; screenHeight = 0
    }

    private func pauseSession() {
        guard intent != nil else { return }
        lifecycleLog("paused; transport retired")
        recovery.pause()
        retireTransport()
        endGrace()
        state = .paused
    }

    private func scheduleResume(delay: Double, attempt: Int) {
        guard intent != nil else { return }
        retireTransport()
        let token = generation
        lifecycleLog("reconnect attempt \(attempt), delay \(delay)")
        state = attempt == 0 ? .connecting : .reconnecting(attempt)
        resumeTask = Task { [weak self] in
            guard let self else { return }
            await self.closeTask?.value
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard self.generation == token, let intent = self.intent else { return }
            guard self.recovery.foreground else { self.pauseSession(); return }
            self.startAttempt(to: intent.connection, password: intent.password,
                colorQuality: intent.quality, connectionMode: intent.mode)
        }
    }

    func connect(to savedConnection: SavedConnection, password: String? = nil, colorQuality: VNCColorQuality = .fullColor, connectionMode: DeskPadConnectionMode = .standard) {
        disconnect()
        recovery = SessionRecoveryPolicy()
        intent = Intent(connection: savedConnection, password: password, quality: colorQuality, mode: connectionMode)
        scheduleResume(delay: 0, attempt: 0)
    }

    private func startAttempt(to savedConnection: SavedConnection, password: String?, colorQuality: VNCColorQuality, connectionMode: DeskPadConnectionMode) {
        let generation = self.generation
        let client = RFBClient(
            host: savedConnection.host,
            port: savedConnection.port,
            username: savedConnection.username,
            password: password,
            pixelFormat: colorQuality.pixelFormat,
            connectionMode: connectionMode,
            model: self,
            generation: generation
        )
        self.client = client
        state = .connecting
        sessionTask = Task { [weak self] in
            var activeClient = client
            var didRetry = false
            var startupRetry = AppleHPStartupRetry()
            while !Task.isCancelled {
                do {
                    try await activeClient.run()
                    await activeClient.close()
                    return
                } catch is RFBAppleBlackFirstFrame {
                    if self?.generation == generation {
                        // Retire queued input before closing its transport so a
                        // stale write failure cannot terminate the replacement.
                        self?.inputQueue.cancel()
                    }
                    await activeClient.close()
                    guard !didRetry, !Task.isCancelled, let model = self, model.generation == generation else { return }
                    didRetry = true
                    let replacement = RFBClient(host: savedConnection.host, port: savedConnection.port,
                        username: savedConnection.username, password: password, pixelFormat: .rgb888,
                        model: model, generation: generation)
                    self?.remoteCursor = nil
                    self?.usingCompatibleColor = true
                    self?.client = replacement
                    self?.state = .connecting
                    activeClient = replacement
                } catch is CancellationError {
                    await activeClient.close()
                    return
                } catch {
                    let startupExpired = await activeClient.canRetryHPStartup
                    if self?.recovery.established == false, startupRetry.consume(firstFrameExpired: startupExpired,
                        cancelled: Task.isCancelled, currentGeneration: self?.generation == generation) {
                        #if DEBUG
                        VNCControlDiagnostics.logger.notice("HP initial frame timed out; retrying once with a fresh session")
                        #endif
                        self?.inputQueue.cancel()
                        // Release UDP ports before creating the replacement session.
                        await activeClient.closeForStartupRetry()
                        guard !Task.isCancelled, let model = self, model.generation == generation else { return }
                        model.highPerformancePlayback?.reset()
                        model.highPerformancePlayback = nil
                        model.remoteCursor = nil
                        model.screenWidth = 0; model.screenHeight = 0
                        let replacement = RFBClient(host: savedConnection.host, port: savedConnection.port,
                            username: savedConnection.username, password: password,
                            pixelFormat: colorQuality.pixelFormat, connectionMode: connectionMode,
                            model: model, generation: generation)
                        model.client = replacement
                        model.state = .connecting
                        activeClient = replacement
                        continue
                    }
                    self?.fail(error, generation: generation)
                    await activeClient.close()
                    return
                }
            }
            await activeClient.close()
        }
    }

    isolated deinit {
        sessionTask?.cancel()
        resumeTask?.cancel()
        graceTask?.cancel()
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        inputQueue.cancel()
        if let client { Task { await client.close() } }
    }

    func disconnect() {
        intent = nil
        recovery.close()
        endGrace()
        retireTransport()
        answerHPTrust(false)
        highPerformancePlayback?.reset(); highPerformancePlayback = nil
        generation = UUID()
        sessionTask?.cancel()
        sessionTask = nil
        inputQueue.cancel()
        if let client { Task { await client.close() } }
        client = nil
        framebuffer = Data()
        framebufferRevision &+= 1
        remoteCursor = nil
        screenWidth = 0
        screenHeight = 0
        errorDetails = nil
        usingCompatibleColor = false
        receivedClipboard = nil
        clipboardError = nil
        state = .disconnected
    }

    private func fail(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        #if DEBUG
        VNCControlDiagnostics.logger.error("session failure: \(String(describing: error), privacy: .public)")
        #endif
        let recoverable: Bool
        if error is RFBConnectionClosed || error is RFBRendererResumeRequired { recoverable = true }
        else if let network = error as? NWError {
            switch network { case .posix, .dns: recoverable = true; default: recoverable = false }
        } else if case RFBClient.ClientError.connection = error { recoverable = true }
        else if let media = error as? AppleHPFailure {
            switch media {
            case .mediaIdleTimeout, .videoStalled: recoverable = true
            case .playbackFailure:
                // A suspended native renderer may fail before foreground checks run.
                // Malformed media with healthy renderers remains terminal.
                recoverable = !recovery.foreground && highPerformancePlayback?.needsRecovery == true
            default: recoverable = false
            }
        } else { recoverable = false }
        switch recovery.failure(recoverable: recoverable, generation: recovery.generation, cancelled: error is CancellationError) {
        case .retry(let attempt, let delay): scheduleResume(delay: delay, attempt: attempt); return
        case .paused: pauseSession(); return
        default: break
        }
        let remoteTermination = error is RFBConnectionClosed && (state == .connected || state == .initializing)
        disconnect()
        state = remoteTermination ? .ended : .failed(error.localizedDescription)
        errorDetails = String(describing: error)
    }

    func reportError(_ message: String) {
        disconnect()
        state = .failed(message)
        errorDetails = message
    }

    private func enqueueInput(_ command: RFBInputCommand, allowReleaseWhenInitializing: Bool = false) {
        let canRelease = allowReleaseWhenInitializing && state == .initializing && screenWidth > 0 && screenHeight > 0
        #if DEBUG
        inputCallbacks += 1
        #endif
        guard state == .connected || canRelease, let client else {
            #if DEBUG
            inputDropped += 1
            VNCControlDiagnostics.logger.notice("input dropped callbacks=\(self.inputCallbacks) dropped=\(self.inputDropped) state=\(VNCControlDiagnostics.stateTag(self.state), privacy: .public)")
            #endif
            return
        }
        #if DEBUG
        inputAccepted += 1
        VNCControlDiagnostics.logger.notice("input accepted callbacks=\(self.inputCallbacks) accepted=\(self.inputAccepted)")
        #endif
        let generation = self.generation
        inputQueue.enqueue(command, send: { [weak self] command in
            switch command {
            case .pointer(let x, let y, let mask):
                try await client.sendPointer(x: x, y: y, buttonMask: mask)
            case .key(let keysym, let pressed):
                try await client.sendKey(keysym: keysym, pressed: pressed)
            case .clipboard(let bytes):
                try await client.sendClipboard(bytes: bytes)
            }
            #if DEBUG
            await self?.recordCompletedInput(generation: generation)
            #endif
        }, onError: { [weak self] error in
            self?.fail(error, generation: generation)
        })
    }

    #if DEBUG
    private func recordCompletedInput(generation: UUID) {
        guard self.generation == generation else { return }
        inputCompleted += 1
        VNCControlDiagnostics.logger.notice("input send completed=\(self.inputCompleted)")
    }
    #endif

    func sendPointer(x: Int, y: Int, buttonMask: UInt8) {
        let boundedX = min(max(x, 0), max(screenWidth - 1, 0))
        let boundedY = min(max(y, 0), max(screenHeight - 1, 0))
        enqueueInput(.pointer(x: UInt16(boundedX), y: UInt16(boundedY), mask: buttonMask),
                     allowReleaseWhenInitializing: buttonMask == 0)
    }

    func sendKey(keysym: UInt32, pressed: Bool) {
        enqueueInput(.key(keysym: keysym, pressed: pressed), allowReleaseWhenInitializing: !pressed)
    }

    func sendClipboard(text: String) {
        guard let bytes = text.data(using: .isoLatin1, allowLossyConversion: false), bytes.count <= 1_048_576 else {
            clipboardError = "서버는 Latin-1 클립보드만 지원합니다. Latin-1 문자로 1 MiB 이하의 텍스트를 보내세요."
            return
        }
        clipboardError = nil
        enqueueInput(.clipboard(bytes))
    }

    fileprivate func setState(_ state: VNCConnectionState, generation: UUID) {
        guard self.generation == generation else { return }
        self.state = state
        if state == .connected { recovery.connected() }
    }

    fileprivate func setScreen(width: Int, height: Int, framebuffer: Data, generation: UUID) {
        guard self.generation == generation else { return }
        state = .initializing
        screenWidth = width
        screenHeight = height
        self.framebuffer = framebuffer
        framebufferRevision &+= 1
    }

    fileprivate func setFramebuffer(_ framebuffer: Data, generation: UUID) {
        guard self.generation == generation else { return }
        #if DEBUG
        if state == .initializing {
            let containsColor = framebuffer.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                return stride(from: 0, to: max(0, bytes.count - 3), by: 4).contains {
                    bytes[$0] != 0 || bytes[$0 + 1] != 0 || bytes[$0 + 2] != 0
                }
            }
            VNCControlDiagnostics.logger.notice("first framebuffer bytes=\(framebuffer.count) nonblack=\(containsColor)")
        }
        #endif
        self.framebuffer = framebuffer
        framebufferRevision &+= 1
        state = .connected
        recovery.connected()
    }

    fileprivate func setCursor(_ cursor: RFBCursorShape, generation: UUID) {
        guard self.generation == generation else { return }
        remoteCursor = cursor
    }

    fileprivate func setClipboard(_ text: String, generation: UUID) {
        guard self.generation == generation else { return }
        receivedClipboard = text
    }

}

// Raw frames can be tens of MiB. Budget the whole payload at 1 MiB/s,
// with fixed latency allowance and a hard cap; incoming chunks never reset it.
nonisolated enum RFBReceiveBudget {
    static func rawSeconds(byteCount: Int) -> Int {
        let mebibyte = 1024 * 1024
        return 20 + min(100, max(0, byteCount) / mebibyte + (byteCount % mebibyte > 0 ? 1 : 0))
    }
}

nonisolated private struct RFBConnectionClosed: LocalizedError {
    let detail: String
    var errorDescription: String? {
        "Mac과의 연결이 종료되었습니다. 화면 공유 설정과 네트워크 상태를 확인한 뒤 다시 연결해 주세요."
    }
}

// The first-frame task and Network callbacks run on different executors.
// Record local timeouts before canceling so their EOF/error callbacks cannot
// be mistaken for a server-initiated termination.
nonisolated private final class RFBTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func markExpired() { lock.lock(); defer { lock.unlock() }; expired = true }
    var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }
}

private actor RFBClient {
    fileprivate enum ClientError: LocalizedError {
        case connection(String)
        case invalidServerMessage(String)
        case unsupportedSecurity([UInt8])
        case passwordRequired
        case usernameRequired
        case invalidCredentialLength
        case authenticationFailed
        case encryptionFailed
        case invalidDHParameters
        case serverRejected(String)
        case invalidScreenSize
        case unsupportedPixelFormat

        var errorDescription: String? {
            switch self {
            case .connection(let message): return "네트워크 연결 오류: \(message)"
            case .invalidServerMessage(let message): return "잘못된 RFB 응답: \(message)"
            case .unsupportedSecurity(let types):
                let offered = types.map(String.init).joined(separator: ", ")
                return "서버가 지원하지 않는 VNC 보안 방식(유형: \(offered))만 제공합니다. Apple 화면 공유 유형 30과 표준 VNC 인증 유형 1·2를 지원합니다."
            case .passwordRequired:
                return "이 VNC 서버는 암호가 필요합니다. 연결 설정에 암호를 입력하세요."
            case .usernameRequired:
                return "Apple 화면 공유 인증에는 Mac 계정 사용자 이름이 필요합니다. 연결 설정에 사용자 이름과 Mac 계정 암호를 입력하세요."
            case .invalidCredentialLength:
                return "Mac 계정 사용자 이름과 암호는 각각 UTF-8 기준 63바이트 이하이며 NUL 문자를 포함하지 않아야 합니다."
            case .authenticationFailed:
                return "화면 공유 인증에 실패했습니다. Mac 계정 사용자 이름과 암호를 확인하세요."
            case .encryptionFailed:
                return "Apple 화면 공유 인증 응답을 생성하지 못했습니다."
            case .invalidDHParameters:
                return "서버가 잘못된 Apple Diffie–Hellman 인증 데이터를 보냈습니다."
            case .serverRejected(let reason): return "서버가 연결을 거부했습니다: \(reason)"
            case .invalidScreenSize: return "전체 화면 크기가 지원 한도(한 변 32,768픽셀, 총 6,400만 픽셀)를 넘었습니다."
            case .unsupportedPixelFormat: return "서버 픽셀 형식 협상에 실패했습니다."
            }
        }
    }

    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String?
    private weak var model: VNCSessionModel?
    private let generation: UUID
    private let timeoutState = RFBTimeoutState()
    private let hpTerminalFailure = AppleHPTerminalFailure()
    private var usesAppleExtensions = false
    private let appleCursorCache = RFBAppleCursorCache()
    private let pixelFormat: RFBPixelFormat
    private let zrleDecoder: RFBZRLEDecoder
    private var hpCipher: AppleHPRecordCipher?
    private var hpDatagrams: AppleHPDatagramTransport?
    private var hpPresentationTask: Task<Void, Never>?
    private let requestsHighPerformance: Bool
    private var usesHighPerformance = false
    private var hasFrame = false
    private var firstFrameTimeout: Task<Void, Never>?
    private var hpFirstFrameExpired = false
    private let queue = DispatchQueue(label: "DeskPad.RFBTransport")
    private var connection: NWConnection?
    private var pixels = Data()
    private var publishedFrame = false
    private var width = 0
    private var height = 0
    private let maximumPixels = RFBFramebufferLimits.maximumPixels
    private let responseTimeout: DispatchTimeInterval = .seconds(20)

    init(host: String, port: UInt16, username: String, password: String?, pixelFormat: RFBPixelFormat, connectionMode: DeskPadConnectionMode = .standard, model: VNCSessionModel, generation: UUID) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.pixelFormat = pixelFormat
        #if DEBUG
        self.requestsHighPerformance = connectionMode.usesHighPerformance || ProcessInfo.processInfo.arguments.contains("--deskpad-hp-mirror")
        #else
        self.requestsHighPerformance = connectionMode.usesHighPerformance
        #endif
        self.zrleDecoder = RFBZRLEDecoder(pixelFormat: pixelFormat)
        self.model = model
        self.generation = generation
    }

    func run() async throws {
        #if DEBUG
        // Quarantine the live probe until display-state restoration and visible
        // first-frame playback have been verified. Reject before opening TCP:
        // even negotiating an HP session can change the host display state.
        if ProcessInfo.processInfo.arguments.contains("--deskpad-hp-probe") {
            throw ClientError.connection("고성능 실험은 디스플레이 복원 검증 전까지 비활성화되어 있습니다.")
        }
        #endif
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ClientError.connection("포트 번호가 올바르지 않습니다.")
        }
        let tcpOptions = NWProtocolTCP.Options()
        // Input events are small interactive messages; do not hold them for
        // Nagle coalescing while screen updates are in flight.
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        var resolvedHost = host
        if requestsHighPerformance {
            resolvedHost = try await AppleHPUDPSocket.resolveIPv4(host: host)
        }
        let connection = NWConnection(host: NWEndpoint.Host(resolvedHost), port: endpointPort, using: parameters)
        self.connection = connection
        try await start(connection)

        await model?.setState(.handshaking, generation: generation)
        let serverVersion = try await readExactly(12)
        guard serverVersion.starts(with: Data("RFB ".utf8)),
              serverVersion.suffix(1) == Data([10]),
              let serverVersionString = String(data: serverVersion, encoding: .ascii),
              let serverMinor = UInt16(serverVersionString.dropFirst(8).prefix(3)),
              serverVersionString.dropFirst(4).prefix(3) == "003",
              serverMinor >= 3 else {
            throw ClientError.invalidServerMessage("버전 문자열이 올바르지 않습니다.")
        }
        usesAppleExtensions = serverMinor == 889
        guard !requestsHighPerformance || usesAppleExtensions else {
            throw ClientError.invalidServerMessage("이 서버는 고성능 화면·소리 공유를 지원하지 않습니다.")
        }
        let negotiatedMinor: UInt16 = usesAppleExtensions ? 889 : (serverMinor >= 8 ? 8 : (serverMinor >= 7 ? 7 : 3))
        let version = String(format: "RFB 003.%03d\n", negotiatedMinor)
        try await send(Data(version.utf8))

        await model?.setState(.authenticating, generation: generation)
        let selectedSecurityType: UInt32
        if negotiatedMinor == 3 {
            selectedSecurityType = try await readUInt32()
            guard selectedSecurityType != 0 else {
                let reasonLength = try await readUInt32()
                guard reasonLength <= 4096 else {
                    throw ClientError.invalidServerMessage("거부 사유가 너무 깁니다.")
                }
                let reason = String(decoding: try await readExactly(Int(reasonLength)), as: UTF8.self)
                throw ClientError.serverRejected(reason)
            }
            guard selectedSecurityType == 1 || selectedSecurityType == 2 || selectedSecurityType == 30 else {
                throw ClientError.unsupportedSecurity([UInt8(truncatingIfNeeded: selectedSecurityType)])
            }
            if selectedSecurityType == 2, password == nil {
                throw ClientError.passwordRequired
            }
            if selectedSecurityType == 30 {
                guard !username.isEmpty else { throw ClientError.usernameRequired }
                guard password != nil else { throw ClientError.passwordRequired }
            }
        } else {
            let securityCount = Int(try await readExactly(1)[0])
            guard securityCount > 0 else {
                let reasonLength = try await readUInt32()
                guard reasonLength <= 4096 else {
                    throw ClientError.invalidServerMessage("거부 사유가 너무 깁니다.")
                }
                let reason = String(decoding: try await readExactly(Int(reasonLength)), as: UTF8.self)
                throw ClientError.serverRejected(reason)
            }
            let securityTypes = try await readExactly(securityCount)
            if requestsHighPerformance {
                guard usesAppleExtensions, securityTypes.contains(33), let password else {
                    throw ClientError.invalidServerMessage("고성능 실험 인증을 지원하지 않습니다.")
                }
                usesHighPerformance = true
                try await connectHighPerformance(password: password)
                return
            }
            if securityTypes.contains(30), !username.isEmpty, password != nil {
                selectedSecurityType = 30
            } else if securityTypes.contains(2), password != nil {
                selectedSecurityType = 2
            } else if securityTypes.contains(1) {
                selectedSecurityType = 1
            } else if securityTypes.contains(30) {
                if username.isEmpty { throw ClientError.usernameRequired }
                throw ClientError.passwordRequired
            } else if securityTypes.contains(2) {
                throw ClientError.passwordRequired
            } else {
                throw ClientError.unsupportedSecurity(Array(securityTypes))
            }
            try await send(Data([UInt8(selectedSecurityType)]))
        }

        if selectedSecurityType == 2 {
            let challenge = try await readExactly(16)
            guard let password else { throw ClientError.passwordRequired }
            try await send(vncAuthenticationResponse(challenge: challenge, password: password))
        } else if selectedSecurityType == 30 {
            guard let password else { throw ClientError.passwordRequired }
            try await authenticateAppleDiffieHellman(username: username, password: password)
        }

        if negotiatedMinor >= 8 || selectedSecurityType == 2 || selectedSecurityType == 30 {
            let securityResult = try await readUInt32()
            guard securityResult == 0 else {
                // Apple Screen Sharing type 30 omits the RFB 3.8 reason string.
                if selectedSecurityType == 30 { throw ClientError.authenticationFailed }
                if negotiatedMinor >= 8 {
                    let reasonLength = try await readUInt32()
                    guard reasonLength <= 4096 else {
                        throw ClientError.invalidServerMessage("보안 오류 사유가 너무 깁니다.")
                    }
                    let reason = String(decoding: try await readExactly(Int(reasonLength)), as: UTF8.self)
                    throw ClientError.serverRejected(reason.isEmpty ? "보안 협상 실패" : reason)
                }
                throw ClientError.authenticationFailed
            }
        }

        await model?.setState(.initializing, generation: generation)
        try await send(Data([usesAppleExtensions ? 0xC1 : 1]))
        let dimensions = try await readExactly(4)
        width = Int(dimensions.readUInt16(at: 0))
        height = Int(dimensions.readUInt16(at: 2))
        try validateDimensions(width: width, height: height)
        #if DEBUG
        VNCControlDiagnostics.logger.notice("server dimensions width=\(self.width) height=\(self.height)")
        #endif

        let serverPixelFormat = try await readExactly(16)
        guard serverPixelFormat.count == 16 else {
            throw ClientError.invalidServerMessage("픽셀 형식 필드가 잘렸습니다.")
        }
        let nameLength = try await readUInt32()
        guard nameLength <= 4096 else {
            throw ClientError.invalidServerMessage("서버 이름이 너무 깁니다.")
        }
        _ = try await readExactly(Int(nameLength))

        pixels = Data(repeating: 0, count: width * height * 4)
        if usesAppleExtensions {
            var viewerInfo = Data([0x21, 0, 0, 62, 0, 1])
            for value: UInt32 in [2, 6, 1, 0, 15, 3, 0] { viewerInfo.appendUInt32(value) }
            var mask = [UInt8](repeating: 0, count: 32)
            mask[0] = 0xB0; mask[2] = 0x0C; mask[3] = 0x03; mask[4] = 0x90; mask[10] = 0x40
            viewerInfo.append(contentsOf: mask)
            try await send(viewerInfo)
            #if DEBUG
            VNCControlDiagnostics.logger.notice("Apple cursor extensions enabled")
            #endif
        }
        try await sendPixelFormat()
        try await sendEncodings()
        try await requestUpdate(incremental: false)
        await model?.setScreen(width: width, height: height, framebuffer: Data(), generation: generation)
        armFirstFrameTimeout()

        while !Task.isCancelled {
            try await readServerMessage()
        }
    }

    private func connectHighPerformance(password: String) async throws {
        try AppleHPSessionLifecycle.validateDisplayPolicy(changesHostDisplay: false)
        let key = try await AppleHPAuthentication.authenticate(username: username, password: password,
            read: { count in try await self.readExactly(count) },
            write: { data in try await self.send(data) }, verifyKey: { der in
                guard let model = self.model else { throw CancellationError() }
                try await model.verifyHPServerKey(der, host: self.host, port: self.port, generation: self.generation)
            })
        #if DEBUG
        VNCControlDiagnostics.logger.notice("HP probe RSA1 authentication accepted")
        #endif
        armFirstFrameTimeout(seconds: 15)
        let bootstrap = try AppleHPMirrorHandshake(encodings: [1010, 1103, -223])
        try await send(bootstrap.clientInit)
        let header = try await readExactly(24)
        let nameLength = Int(header.readUInt32(at: 20))
        guard nameLength <= 4096 else { throw ClientError.invalidServerMessage("HP 서버 이름 길이 오류") }
        _ = try await readExactly(nameLength)
        for message in bootstrap.cleartextPrelude { try await send(message) }
        let subscription = try AppleHPCursorSubscription.messages(width: header.readUInt16(at: 0), height: header.readUInt16(at: 2))
        let request = subscription[0]
        for _ in 0..<16 {
            let message = try await readExactly(1)[0]
            if message == 0x14 {
                let status = try await readExactly(3)
                let length = Int(status.readUInt16(at: 1))
                guard (4...4096).contains(length) else { throw ClientError.invalidServerMessage("HP 상태 길이 오류") }
                _ = try await readExactly(length)
                continue
            }
            guard message == 0 else { throw ClientError.invalidServerMessage("HP 실험 메시지 \(message)") }
            let update = try await readExactly(3)
            let count = Int(update.readUInt16(at: 1))
            guard count <= 64 else { throw ClientError.invalidServerMessage("HP 사각형 수 오류") }
            for index in 0..<count {
                let rect = try await readExactly(12)
                let encoding = rect.readInt32(at: 8)
                if encoding == 1103 {
                    guard index == count - 1 else {
                        throw ClientError.invalidServerMessage("HP 암호화 전환 경계 오류")
                    }
                    let payload = try await readExactly(36)
                    guard key.count == 16, payload.count == 36 else { throw ClientError.authenticationFailed }
                    let cipher = try AppleHPRecordCipher(wrapKey: key)
                    try cipher.installRekey(payload: payload)
                    #if DEBUG
                    VNCControlDiagnostics.logger.notice("HP probe encrypted channel key received")
                    #endif
                    let offer = try AppleHPMediaOffer.make(videoProfile: .hevcSinglePicture, enableLTR: true)
                    hpCipher = cipher
                    let playback = await HighPerformancePlayback()
                    let pipeline = try await HighPerformanceMediaPipeline(output: playback, videoPayloadType: 100, videoCodec: .hevc)
                    width = Int(header.readUInt16(at: 0)); height = Int(header.readUInt16(at: 2))
                    try validateDimensions(width: width, height: height)
                    await model?.attachHighPerformance(playback, width: width, height: height, generation: generation)
                    let media = try AppleHPDatagramTransport(offer: offer, videoPayloadType: 100, pipeline: pipeline, onPlaying: { [weak self] in
                        await self?.awaitHighPerformancePresentation(playback)
                    }, onFailure: { [weak self] reason in
                        await self?.expireHighPerformanceMedia(reason)
                    })
                    hpDatagrams = media
                    await MainActor.run {
                        pipeline.onCleanHEVCFrame = { [weak media] don in
                            Task { await media?.acknowledgeCleanFrame(don: don) }
                        }
                        pipeline.onNeedsKeyframe = { [weak media] in
                            Task { await media?.requestKeyframe() }
                        }
                    }
                    try await media.start(host: AppleHPUDPSocket.resolveIPv4(host: host), port: port)
                    try await send(bootstrap.encryptionReady)
                    try await send(cipher.encode(body: request))
                    try await send(cipher.encode(body: offer.message))
                    for message in subscription.dropFirst() { try await send(cipher.encode(body: message)) }
                    #if DEBUG
                    VNCControlDiagnostics.logger.notice("HP native media offer sent")
                    #endif
                    var parser = AppleHPControlParser()
                    while !Task.isCancelled {
                        let prefix = try await readExactly(2, timeoutEnabled: false)
                        let length = Int(prefix.readUInt16(at: 0))
                        guard length >= 32, length <= 65520, length % 16 == 0 else {
                            throw ClientError.invalidServerMessage("HP 암호화 레코드 길이 오류")
                        }
                        let bodies = try cipher.receive(bytes: prefix + (try await readExactly(length)))
                        for body in bodies {
                            for event in try parser.append(body) {
                                switch event {
                                case .mediaAnswer(let answer):
                                    guard let w = answer.video.width, let h = answer.video.height else {
                                        throw ClientError.invalidServerMessage("고성능 영상 크기가 없습니다.")
                                    }
                                    try validateDimensions(width: w, height: h)
                                    // Encoded pixel dimensions can be smaller than the
                                    // remote desktop. Input coordinates remain in the
                                    // ServerInit/DesktopSize coordinate space.
                                    try await media.accept(answer)
                                case .rekey(let payload): try cipher.installRekey(payload: payload)
                                case .rectangle(let encoding, let x, let y, let w, let h, let payload):
                                    if encoding == 1104 {
                                        guard payload.count >= 8 else { throw RFBCursorShape.DecodeError.invalidLength }
                                        let cacheID = payload.readUInt32(at: 0)
                                        let compressedLength = Int(payload.readUInt32(at: 4))
                                        guard compressedLength == payload.count - 8 else { throw RFBCursorShape.DecodeError.invalidLength }
                                        if let cursor = try appleCursorCache.decode(cacheID: cacheID,
                                            compressed: Data(payload.dropFirst(8)), width: Int(w), height: Int(h),
                                            hotspotX: Int(x), hotspotY: Int(y)) {
                                            await model?.setCursor(cursor, generation: generation)
                                        }
                                        continue
                                    }
                                    guard encoding == -223 else {
                                        throw ClientError.invalidServerMessage("미지원 고성능 화면 정보")
                                    }
                                    try validateDimensions(width: Int(w), height: Int(h))
                                    width = Int(w); height = Int(h)
                                    await model?.attachHighPerformance(playback, width: width, height: height, generation: generation)
                                case .clipboard, .clipboardArchive, .bell, .mediaAnnouncement, .status: break
                                }
                            }
                        }
                    }
                    throw CancellationError()
                } else if encoding == 1010 || encoding == 1011 {
                    let length = Int(try await readExactly(2).readUInt16(at: 0))
                    _ = try await readExactly(length)
                } else {
                    throw ClientError.invalidServerMessage("HP 실험 인코딩 \(encoding)")
                }
            }
        }
        throw ClientError.invalidServerMessage("HP 암호화 연결 응답 없음")
    }


    private func expireHighPerformanceMedia(_ reason: AppleHPFailure) {
        hpTerminalFailure.record(reason)
        connection?.forceCancel()
    }

    private func awaitHighPerformancePresentation(_ playback: HighPerformancePlayback) {
        guard hpPresentationTask == nil else { return }
        hpPresentationTask = Task { [weak self] in
            while !Task.isCancelled {
                if await playback.hasDisplayedVideoFrame {
                    await self?.highPerformanceBeganPlaying()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    private func highPerformanceBeganPlaying() async {
        guard !hasFrame, connection != nil else { return }
        hasFrame = true
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        await model?.setState(.connected, generation: generation)
        #if DEBUG
        VNCControlDiagnostics.logger.notice("HP first decoded video frame presented")
        #endif
    }

    private func armFirstFrameTimeout(seconds: Int = 20) {
        // Empty updates and repeated DesktopSize messages cannot extend this deadline.
        guard firstFrameTimeout == nil else { return }
        firstFrameTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.expireFirstFrame()
        }
    }

    private func expireFirstFrame() {
        guard !hasFrame else { return }
        #if DEBUG
        VNCControlDiagnostics.logger.notice("first frame deadline expired")
        #endif
        hpFirstFrameExpired = usesHighPerformance
        timeoutState.markExpired()
        if usesHighPerformance { connection?.forceCancel() }
        else { connection?.cancel() }
    }

    var canRetryHPStartup: Bool {
        // Only the authenticated media first-frame deadline qualifies. Network,
        // credentials, server trust, and explicit media failures never retry.
        hpFirstFrameExpired && !hasFrame && hpTerminalFailure.value == nil
    }

    func closeForStartupRetry() async {
        let datagrams = hpDatagrams
        hpDatagrams = nil
        close()
        await datagrams?.closeForRestart()
    }

    func close() {
        hpPresentationTask?.cancel(); hpPresentationTask = nil
        hpCipher = nil
        if let hpDatagrams { Task { await hpDatagrams.close() } }
        hpDatagrams = nil
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        if usesHighPerformance { connection?.forceCancel() }
        else { connection?.cancel() }
        connection = nil
        pixels.removeAll(keepingCapacity: false)
    }

    func sendPointer(x: UInt16, y: UInt16, buttonMask: UInt8) async throws {
        if let hpCipher {
            try await send(hpCipher.encodePointer(x: x, y: y, buttonMask: buttonMask))
        } else {
            var message = Data([5, buttonMask])
            message.appendUInt16(x)
            message.appendUInt16(y)
            try await send(message)
        }
    }

    func sendKey(keysym: UInt32, pressed: Bool) async throws {
        var message = Data([4, pressed ? 1 : 0, 0, 0])
        message.appendUInt32(keysym)
        try await send(hpCipher.map { try $0.encode(body: message) } ?? message)
    }

    func sendClipboard(bytes: Data) async throws {
        guard bytes.count <= 1_048_576 else {
            throw ClientError.invalidServerMessage("클립보드 데이터가 너무 깁니다.")
        }
        var message = Data([6, 0, 0, 0])
        message.appendUInt32(UInt32(bytes.count))
        message.append(bytes)
        try await send(hpCipher.map { try $0.encode(body: message) } ?? message)
    }

    private func start(_ connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            let timeout = DispatchWorkItem { [timeoutState] in
                timeoutState.markExpired()
                connection.cancel()
            }
            queue.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
            defer { timeout.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = ResumeOnce()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resumed.resume(continuation, returning: ())
                    case .failed(let error):
                        resumed.resume(continuation, throwing: ClientError.connection(error.localizedDescription))
                    case .cancelled:
                        resumed.resume(continuation, throwing: ClientError.connection("연결이 취소되었거나 서버 응답 시간이 초과되었습니다."))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
            try Task.checkCancellation()
        } onCancel: { connection.cancel() }
    }

    private nonisolated func receiveError(_ detail: String) -> Error {
        if let failure = hpTerminalFailure.value { return failure }
        return timeoutState.didExpire
            ? ClientError.connection("서버 응답 시간이 초과되었습니다.")
            : RFBConnectionClosed(detail: detail)
    }

    private func readExactly(_ count: Int, timeoutEnabled: Bool = true, receiveTimeout: DispatchTimeInterval = .seconds(20)) async throws -> Data {
        guard count >= 0, count <= RFBFramebufferLimits.maximumPayloadBytes else {
            throw ClientError.invalidServerMessage("요청된 데이터 길이가 허용 범위를 벗어났습니다.")
        }
        try Task.checkCancellation()
        guard let connection else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            let timeout = DispatchWorkItem { [timeoutState] in
                timeoutState.markExpired()
                connection.cancel()
            }
            if timeoutEnabled { queue.asyncAfter(deadline: .now() + receiveTimeout, execute: timeout) }
            defer { timeout.cancel() }
            var result = Data()
            result.reserveCapacity(count)
            while result.count < count {
                try Task.checkCancellation()
                let remaining = count - result.count
                let chunk: Data = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: self.receiveError(error.localizedDescription))
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: isComplete ? self.receiveError("서버가 연결을 종료했습니다.") : ClientError.connection("서버에서 데이터를 받지 못했습니다."))
                        }
                    }
                }
                result.append(chunk)
            }
            try Task.checkCancellation()
            return result
        } onCancel: { connection.cancel() }
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let connection else { throw CancellationError() }
        try await withTaskCancellationHandler {
            let timeout = DispatchWorkItem { [timeoutState] in
                timeoutState.markExpired()
                connection.cancel()
            }
            queue.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
            defer { timeout.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: self.receiveError(error.localizedDescription))
                    } else { continuation.resume(returning: ()) }
                })
            }
            try Task.checkCancellation()
        } onCancel: { connection.cancel() }
    }

    private func readUInt32() async throws -> UInt32 {
        try await readExactly(4).readUInt32(at: 0)
    }

    private func vncAuthenticationResponse(challenge: Data, password: String) throws -> Data {
        // RFB VNC authentication uses DES-ECB with each password byte's bits reversed.
        var key = [UInt8](repeating: 0, count: kCCKeySizeDES)
        for (index, byte) in password.utf8.prefix(key.count).enumerated() {
            key[index] = (0...7).reduce(UInt8(0)) { result, bit in
                result | (((byte >> bit) & 1) << (7 - bit))
            }
        }

        var response = Data(count: challenge.count)
        let responseCount = response.count
        var bytesWritten = 0
        let status = key.withUnsafeBytes { keyBytes in
            challenge.withUnsafeBytes { challengeBytes in
                response.withUnsafeMutableBytes { responseBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        kCCKeySizeDES,
                        nil,
                        challengeBytes.baseAddress,
                        challenge.count,
                        responseBytes.baseAddress,
                        responseCount,
                        &bytesWritten
                    )
                }
            }
        }
        guard status == kCCSuccess, bytesWritten == challenge.count else {
            throw ClientError.encryptionFailed
        }
        return response
    }

    private func authenticateAppleDiffieHellman(username: String, password: String) async throws {
        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        guard usernameBytes.count < 64, passwordBytes.count < 64,
              !usernameBytes.contains(0), !passwordBytes.contains(0) else {
            throw ClientError.invalidCredentialLength
        }
        let parameters = try await readExactly(4)
        let generator = UInt32(parameters.readUInt16(at: 0))
        let keyLength = Int(parameters.readUInt16(at: 2))
        guard (128...1024).contains(keyLength), (2...255).contains(generator) else {
            throw ClientError.invalidDHParameters
        }

        let modulus = try await readExactly(keyLength)
        let serverPublicKey = try await readExactly(keyLength)
        let modulusInteger = DHInteger(bigEndian: modulus)
        let serverPublicInteger = DHInteger(bigEndian: serverPublicKey)
        guard !modulusInteger.isZero,
              modulus.first.map({ $0 & 0x80 != 0 }) == true,
              modulus.last.map({ $0 & 1 == 1 }) == true,
              serverPublicInteger > .one,
              serverPublicInteger < modulusInteger - .one,
              DHInteger(value: generator, wordCount: modulusInteger.words.count) < modulusInteger - .one else {
            throw ClientError.invalidDHParameters
        }

        var privateBytes = Data(count: 32)
        let privateByteCount = privateBytes.count
        let randomStatus = privateBytes.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, privateByteCount, baseAddress)
        }
        guard randomStatus == errSecSuccess else { throw ClientError.encryptionFailed }
        privateBytes[0] |= 0x80
        privateBytes[privateBytes.count - 1] |= 1
        let privateKey = DHInteger(bigEndian: privateBytes)
        try Task.checkCancellation()
        let clientPublicKey = try DHInteger.power(UInt32(generator), exponent: privateKey, modulus: modulusInteger)
        let sharedSecret = try DHInteger.power(serverPublicInteger, exponent: privateKey, modulus: modulusInteger)
        let sharedBytes = sharedSecret.bigEndianData(length: keyLength)
        let digest = Array(Insecure.MD5.hash(data: sharedBytes))

        var credentials = Data(count: 128)
        let credentialCount = credentials.count
        let credentialRandomStatus = credentials.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, credentialCount, baseAddress)
        }
        guard credentialRandomStatus == errSecSuccess else { throw ClientError.encryptionFailed }
        credentials.replaceSubrange(0..<usernameBytes.count, with: usernameBytes)
        credentials[usernameBytes.count] = 0
        credentials.replaceSubrange(64..<(64 + passwordBytes.count), with: passwordBytes)
        credentials[64 + passwordBytes.count] = 0

        var encryptedCredentials = Data(count: credentials.count)
        let encryptedCredentialCount = encryptedCredentials.count
        var bytesWritten = 0
        let encryptionStatus = digest.withUnsafeBytes { keyBytes in
            credentials.withUnsafeBytes { inputBytes in
                encryptedCredentials.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        kCCKeySizeAES128,
                        nil,
                        inputBytes.baseAddress,
                        credentialCount,
                        outputBytes.baseAddress,
                        encryptedCredentialCount,
                        &bytesWritten
                    )
                }
            }
        }
        guard encryptionStatus == kCCSuccess, bytesWritten == credentialCount else {
            throw ClientError.encryptionFailed
        }
        encryptedCredentials.append(clientPublicKey.bigEndianData(length: keyLength))
        try await send(encryptedCredentials)
    }

    private func sendPixelFormat() async throws {
        var message = Data([0, 0, 0, 0])
        message.append(pixelFormat.wireBytes)
        #if DEBUG
        VNCControlDiagnostics.logger.notice("pixel format=\(self.pixelFormat.rawValue, privacy: .public) bytes_per_pixel=\(self.pixelFormat.bytesPerPixel)")
        #endif
        try await send(message)
    }

    private func sendEncodings() async throws {
        var message = Data([2, 0])
        message.appendUInt16(usesAppleExtensions ? 5 : 6)
        message.appendInt32(16)
        message.appendInt32(0)
        message.appendInt32(1)
        message.appendInt32(-223)
        if usesAppleExtensions {
            // Match native Apple clients: use cached cursor shapes exclusively.
            // Mixed legacy/Apple advertisement did not yield shapes in live QA.
            message.appendInt32(0x450)
        } else {
            message.appendInt32(-239)
            message.appendInt32(-240)
        }
        try await send(message)
    }

    private func requestUpdate(incremental: Bool) async throws {
        var message = Data([3, incremental ? 1 : 0])
        message.appendUInt16(0)
        message.appendUInt16(0)
        message.appendUInt16(UInt16(width))
        message.appendUInt16(UInt16(height))
        try await send(message)
    }

    private func readServerMessage() async throws {
        let messageType = try await readExactly(1, timeoutEnabled: !hasFrame)[0]
        switch messageType {
        case 0:
            let resized = try await readFramebufferUpdate()
            try await requestUpdate(incremental: !resized)
        case 0x14:
            guard usesAppleExtensions else {
                throw ClientError.invalidServerMessage("협상하지 않은 Apple 상태 메시지입니다.")
            }
            let header = try await readExactly(3)
            let length = Int(header.readUInt16(at: 1))
            guard length >= 4, length <= 4096 else {
                throw ClientError.invalidServerMessage("Apple 상태 메시지 길이가 허용 범위를 벗어났습니다.")
            }
            let status = try await readExactly(length)
            #if DEBUG
            let command = status.readUInt16(at: 2)
            VNCControlDiagnostics.logger.notice("Apple status command=\(command) bytes=\(length)")
            #else
            _ = status
            #endif
        case 2:
            break
        case 3:
            _ = try await readExactly(3)
            let length = try await readUInt32()
            guard length <= 1_048_576 else {
                throw ClientError.invalidServerMessage("클립보드 데이터가 너무 깁니다.")
            }
            let clipboard = try await readExactly(Int(length))
            await model?.setClipboard(String(data: clipboard, encoding: .isoLatin1) ?? "", generation: generation)
        default:
            throw ClientError.invalidServerMessage("지원하지 않는 서버 메시지 유형 \(messageType).")
        }
    }

    private func readFramebufferUpdate() async throws -> Bool {
        #if DEBUG
        let updateStarted = Date()
        #endif
        var resized = false
        var pixelsChanged = false
        var completeDesktopDecoded = false
        let header = try await readExactly(3)
        let rectangleCount = Int(header.readUInt16(at: 1))
        guard rectangleCount <= 4096 else {
            throw ClientError.invalidServerMessage("업데이트 사각형 수가 허용 범위를 넘었습니다.")
        }

        for _ in 0..<rectangleCount {
            let rectangle = try await readExactly(12)
            let x = Int(rectangle.readUInt16(at: 0))
            let y = Int(rectangle.readUInt16(at: 2))
            let rectWidth = Int(rectangle.readUInt16(at: 4))
            let rectHeight = Int(rectangle.readUInt16(at: 6))
            let encoding = rectangle.readInt32(at: 8)

            switch encoding {
            case 0:
                guard rectWidth <= width, rectHeight <= height,
                      x <= width - rectWidth, y <= height - rectHeight else {
                    throw ClientError.invalidServerMessage("Raw 사각형이 화면 경계를 벗어났습니다.")
                }
                let pixelCount = rectWidth.multipliedReportingOverflow(by: rectHeight)
                guard !pixelCount.overflow, pixelCount.partialValue <= maximumPixels else {
                    throw ClientError.invalidServerMessage("Raw 사각형 크기가 허용 범위를 넘었습니다.")
                }
                let dataLength = pixelCount.partialValue.multipliedReportingOverflow(by: pixelFormat.bytesPerPixel)
                guard !dataLength.overflow else {
                    throw ClientError.invalidServerMessage("Raw 데이터 길이 overflow.")
                }
                #if DEBUG
                let rawReadStarted = Date()
                VNCControlDiagnostics.logger.notice("raw read begin bytes=\(dataLength.partialValue) width=\(rectWidth) height=\(rectHeight)")
                #endif
                let receiveSeconds = RFBReceiveBudget.rawSeconds(byteCount: dataLength.partialValue)
                if !hasFrame, dataLength.partialValue > 0 {
                    // Only a validated, nonempty Raw payload earns transfer time.
                    // The next operation must finish this payload before another
                    // header can be read, so repeated messages cannot renew it.
                    firstFrameTimeout?.cancel()
                    firstFrameTimeout = nil
                    armFirstFrameTimeout(seconds: receiveSeconds)
                }
                try await receiveRawRows(x: x, y: y, width: rectWidth, height: rectHeight, receiveSeconds: receiveSeconds)
                #if DEBUG
                let elapsedMilliseconds = Int(Date().timeIntervalSince(rawReadStarted) * 1_000)
                VNCControlDiagnostics.logger.notice("raw read complete bytes=\(dataLength.partialValue) elapsed_ms=\(elapsedMilliseconds)")
                #endif
                if rectWidth > 0 && rectHeight > 0 {
                    hasFrame = true
                    firstFrameTimeout?.cancel()
                    firstFrameTimeout = nil
                }
                pixelsChanged = pixelsChanged || (rectWidth > 0 && rectHeight > 0)
            case 16:
                guard rectWidth > 0, rectHeight > 0, rectWidth <= width, rectHeight <= height,
                      x <= width - rectWidth, y <= height - rectHeight else {
                    throw ClientError.invalidServerMessage("ZRLE 사각형이 화면 경계를 벗어났습니다.")
                }
                let compressedLength = Int(try await readUInt32())
                let maximumCompressed = try RFBZRLEDecoder.maximumCompressedLength(width: rectWidth, height: rectHeight, pixelFormat: pixelFormat)
                guard compressedLength > 0, compressedLength <= maximumCompressed else {
                    throw ClientError.invalidServerMessage("ZRLE 압축 길이가 허용 범위를 넘었습니다.")
                }
                let receiveSeconds = RFBReceiveBudget.rawSeconds(byteCount: compressedLength)
                let deadline = ContinuousClock.now + .seconds(receiveSeconds)
                if !hasFrame {
                    firstFrameTimeout?.cancel()
                    firstFrameTimeout = nil
                    armFirstFrameTimeout(seconds: receiveSeconds)
                }
                #if DEBUG
                let zrleStarted = Date()
                VNCControlDiagnostics.logger.notice("zrle read begin bytes=\(compressedLength) width=\(rectWidth) height=\(rectHeight)")
                #endif
                let compressed = try await readExactly(compressedLength, receiveTimeout: .seconds(receiveSeconds))
                #if DEBUG
                let decodeStarted = Date()
                VNCControlDiagnostics.logger.notice("zrle read complete bytes=\(compressedLength) elapsed_ms=\(Int(decodeStarted.timeIntervalSince(zrleStarted) * 1_000))")
                #endif
                let rgba = try zrleDecoder.decode(compressed, width: rectWidth, height: rectHeight, deadline: deadline)
                #if DEBUG
                VNCControlDiagnostics.logger.notice("zrle decode complete elapsed_ms=\(Int(Date().timeIntervalSince(decodeStarted) * 1_000))")
                #endif
                if x == 0, y == 0, rectWidth == width, rectHeight == height {
                    // Adopt full-frame decoder storage instead of duplicating a
                    // large desktop while the previous UI snapshot is alive.
                    pixels = rgba
                } else {
                    RFBPixelCopy.copy(rgba, into: &pixels, destinationWidth: width, x: x, y: y,
                                      width: rectWidth, height: rectHeight, sourceIsRGBA: true)
                }
                hasFrame = true
                pixelsChanged = true
                firstFrameTimeout?.cancel()
                firstFrameTimeout = nil
                #if DEBUG
                VNCControlDiagnostics.logger.notice("zrle frame complete bytes=\(compressedLength) elapsed_ms=\(Int(Date().timeIntervalSince(zrleStarted) * 1_000))")
                #endif
            case 1:
                let source = try await readExactly(4)
                let sourceX = Int(source.readUInt16(at: 0))
                let sourceY = Int(source.readUInt16(at: 2))
                guard rectWidth <= width, rectHeight <= height,
                      x <= width - rectWidth, y <= height - rectHeight,
                      sourceX <= width - rectWidth, sourceY <= height - rectHeight else {
                    throw ClientError.invalidServerMessage("CopyRect가 화면 경계를 벗어났습니다.")
                }
                pixelsChanged = pixelsChanged || (rectWidth > 0 && rectHeight > 0)
                copyRectangle(sourceX: sourceX, sourceY: sourceY, x: x, y: y, width: rectWidth, height: rectHeight)
            case 0x450:
                guard usesAppleExtensions else {
                    throw ClientError.invalidServerMessage("협상하지 않은 Apple 커서 메시지입니다.")
                }
                let cacheID = try await readUInt32()
                let compressedLength = Int(try await readUInt32())
                if compressedLength > 0 {
                    let maximum = try RFBAppleCursorCache.maximumCompressedLength(width: rectWidth,
                        height: rectHeight, hotspotX: x, hotspotY: y)
                    guard compressedLength <= maximum else { throw RFBCursorShape.DecodeError.invalidLength }
                }
                let compressed = try await readExactly(compressedLength)
                if let cursor = try appleCursorCache.decode(cacheID: cacheID, compressed: compressed,
                    width: rectWidth, height: rectHeight, hotspotX: x, hotspotY: y) {
                    await model?.setCursor(cursor, generation: generation)
                }
                #if DEBUG
                VNCControlDiagnostics.logger.notice("cursor shape encoding=1104 width=\(rectWidth) height=\(rectHeight) compressed_bytes=\(compressedLength)")
                #endif
            case -239, -240:
                let length = try RFBCursorShape.payloadLength(width: rectWidth, height: rectHeight,
                    hotspotX: x, hotspotY: y, encoding: encoding, pixelFormat: pixelFormat)
                let payload = try await readExactly(length)
                let cursor = try RFBCursorShape.decode(payload, width: rectWidth, height: rectHeight,
                    hotspotX: x, hotspotY: y, encoding: encoding, pixelFormat: pixelFormat)
                #if DEBUG
                VNCControlDiagnostics.logger.notice("cursor shape encoding=\(encoding) width=\(rectWidth) height=\(rectHeight) hotspot_x=\(x) hotspot_y=\(y)")
                #endif
                await model?.setCursor(cursor, generation: generation)
            case -223:
                let newWidth = rectWidth
                let newHeight = rectHeight
                try validateDimensions(width: newWidth, height: newHeight)
                width = newWidth
                height = newHeight
                pixels = Data(repeating: 0, count: width * height * 4)
                hasFrame = false
                completeDesktopDecoded = false
                resized = true
                armFirstFrameTimeout()
                await model?.setScreen(width: width, height: height, framebuffer: Data(), generation: generation)
            default:
                throw ClientError.invalidServerMessage("지원하지 않는 인코딩 \(encoding).")
            }
        }
        if hasFrame && pixelsChanged {
            if !publishedFrame, completeDesktopDecoded, usesAppleExtensions, pixelFormat == .rgb565,
               pixels.withUnsafeBytes({ raw in
                   let bytes = raw.bindMemory(to: UInt8.self)
                   return stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                       bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 0
                   }
               }) {
                throw RFBAppleBlackFirstFrame()
            }
            publishedFrame = true
            await model?.setFramebuffer(pixels, generation: generation)
        }
        #if DEBUG
        VNCControlDiagnostics.logger.notice("frame update complete rectangles=\(rectangleCount) elapsed_ms=\(Int(Date().timeIntervalSince(updateStarted) * 1_000))")
        #endif
        return resized
    }

    private func validateDimensions(width: Int, height: Int) throws {
        guard RFBFramebufferLimits.contains(width: width, height: height) else {
            throw ClientError.invalidScreenSize
        }
    }

    /// Decode bounded row groups into the framebuffer rather than allocating the
    /// entire Raw rectangle. A single deadline covers every chunk and pixel copy.
    private func receiveRawRows(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int,
                                receiveSeconds: Int) async throws {
        guard rectWidth > 0, rectHeight > 0 else { return }
        let rowBytes = rectWidth * pixelFormat.bytesPerPixel
        let chunkByteLimit = 1024 * 1024
        guard rowBytes > 0, rowBytes <= chunkByteLimit else {
            throw ClientError.invalidServerMessage("Raw 행 크기가 허용 범위를 넘었습니다.")
        }
        let rowsPerChunk = chunkByteLimit / rowBytes
        let deadline = ContinuousClock.now + .seconds(receiveSeconds)
        let timeout = DispatchWorkItem { [timeoutState, connection] in
            timeoutState.markExpired()
            connection?.cancel()
        }
        queue.asyncAfter(deadline: .now() + .seconds(receiveSeconds), execute: timeout)
        defer { timeout.cancel() }
        var row = 0
        while row < rectHeight {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ClientError.connection("서버 응답 시간이 초과되었습니다.")
            }
            let count = min(rowsPerChunk, rectHeight - row)
            // The outer timer owns the whole rectangle deadline; chunk reads
            // must not each gain a fresh transfer allowance.
            let raw = try await readExactly(count * rowBytes, timeoutEnabled: false)
            copyRaw(raw, x: x, y: y + row, width: rectWidth, height: count)
            row += count
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw ClientError.connection("서버 응답 시간이 초과되었습니다.")
        }
    }

    private func copyRaw(_ source: Data, x: Int, y: Int, width rectWidth: Int, height rectHeight: Int) {
        RFBPixelCopy.copy(source, into: &pixels, destinationWidth: width, x: x, y: y,
                          width: rectWidth, height: rectHeight, pixelFormat: pixelFormat)
    }

    private func copyRectangle(sourceX: Int, sourceY: Int, x: Int, y: Int, width rectWidth: Int, height rectHeight: Int) {
        guard rectWidth > 0, rectHeight > 0 else { return }
        let rowBytes = rectWidth * 4
        var copy = Data(count: rowBytes * rectHeight)
        for row in 0..<rectHeight {
            let sourceStart = ((sourceY + row) * width + sourceX) * 4
            let targetStart = row * rowBytes
            copy.replaceSubrange(targetStart..<(targetStart + rowBytes),
                                 with: pixels[sourceStart..<(sourceStart + rowBytes)])
        }
        for row in 0..<rectHeight {
            let targetStart = ((y + row) * width + x) * 4
            let sourceStart = row * rowBytes
            pixels.replaceSubrange(targetStart..<(targetStart + rowBytes),
                                   with: copy[sourceStart..<(sourceStart + rowBytes)])
        }
    }
}

nonisolated private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    nonisolated func resume<T>(_ continuation: CheckedContinuation<T, Error>, returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }

    nonisolated func resume<T>(_ continuation: CheckedContinuation<T, Error>, throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }
}

nonisolated private struct DHInteger: Comparable, Sendable {
    private(set) var words: [UInt32]

    static let one = DHInteger(value: 1, wordCount: 1)

    var isZero: Bool {
        words.allSatisfy { $0 == 0 }
    }

    private var bitWidth: Int {
        words.count * 32
    }

    init(bigEndian data: Data) {
        words = Array(repeating: 0, count: (data.count + 3) / 4)
        for (index, byte) in data.enumerated() {
            let significance = data.count - 1 - index
            words[significance / 4] |= UInt32(byte) << ((significance % 4) * 8)
        }
    }

    init(value: UInt32, wordCount: Int) {
        words = Array(repeating: 0, count: wordCount)
        if !words.isEmpty {
            words[0] = value
        }
    }

    static func < (lhs: DHInteger, rhs: DHInteger) -> Bool {
        let count = max(lhs.words.count, rhs.words.count)
        for index in (0..<count).reversed() {
            let left = index < lhs.words.count ? lhs.words[index] : 0
            let right = index < rhs.words.count ? rhs.words[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: DHInteger, rhs: DHInteger) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func - (lhs: DHInteger, rhs: DHInteger) -> DHInteger {
        let count = max(lhs.words.count, rhs.words.count)
        let left = DHInteger(words: lhs.words, wordCount: count)
        let right = DHInteger(words: rhs.words, wordCount: count)
        var difference = Array(repeating: UInt32(0), count: count)
        var borrow: UInt64 = 0
        for index in 0..<count {
            let leftWord = UInt64(left.words[index])
            let rightWord = UInt64(right.words[index]) + borrow
            if leftWord >= rightWord {
                difference[index] = UInt32(leftWord - rightWord)
                borrow = 0
            } else {
                difference[index] = UInt32((UInt64(1) << 32) + leftWord - rightWord)
                borrow = 1
            }
        }
        return DHInteger(words: difference, wordCount: count)
    }

    static func power(_ base: UInt32, exponent: DHInteger, modulus: DHInteger) throws -> DHInteger {
        try power(DHInteger(value: base, wordCount: modulus.words.count), exponent: exponent, modulus: modulus)
    }

    static func power(_ base: DHInteger, exponent: DHInteger, modulus: DHInteger) throws -> DHInteger {
        let wordCount = modulus.words.count
        let one = DHInteger(value: 1, wordCount: wordCount)
        var rSquared = one
        for step in 0..<(wordCount * 64) {
            if step % 64 == 0 { try Task.checkCancellation() }
            rSquared = addModulo(rSquared, rSquared, modulus: modulus)
        }
        var result = montgomeryMultiply(one, rSquared, modulus: modulus)
        let normalizedBase = montgomeryMultiply(
            DHInteger(words: base.words, wordCount: wordCount),
            rSquared,
            modulus: modulus
        )
        guard exponent.bitWidth > 0 else { return one }
        for bit in (0..<exponent.bitWidth).reversed() {
            try Task.checkCancellation()
            result = montgomeryMultiply(result, result, modulus: modulus)
            if exponent.bit(at: bit) {
                result = montgomeryMultiply(result, normalizedBase, modulus: modulus)
            }
        }
        return montgomeryMultiply(result, one, modulus: modulus)
    }

    func bigEndianData(length: Int) -> Data {
        var result = Data(count: length)
        for significance in 0..<length {
            let wordIndex = significance / 4
            let byteIndex = length - 1 - significance
            let word = wordIndex < words.count ? words[wordIndex] : 0
            result[byteIndex] = UInt8(truncatingIfNeeded: word >> ((significance % 4) * 8))
        }
        return result
    }

    private init(words: [UInt32], wordCount: Int) {
        self.words = Array(words.prefix(wordCount))
        if self.words.count < wordCount {
            self.words.append(contentsOf: repeatElement(0, count: wordCount - self.words.count))
        }
    }

    private func bit(at index: Int) -> Bool {
        let wordIndex = index / 32
        guard wordIndex < words.count else { return false }
        return (words[wordIndex] & (UInt32(1) << (index % 32))) != 0
    }

    private static func montgomeryMultiply(
        _ lhs: DHInteger,
        _ rhs: DHInteger,
        modulus: DHInteger
    ) -> DHInteger {
        let count = modulus.words.count
        var inverse: UInt32 = 1
        for _ in 0..<5 {
            inverse = inverse &* (2 &- modulus.words[0] &* inverse)
        }
        let negativeInverse = 0 &- inverse
        var temporary = Array(repeating: UInt32(0), count: count + 2)

        for index in 0..<count {
            var carry: UInt64 = 0
            for word in 0..<count {
                let product = UInt64(temporary[word])
                    + UInt64(lhs.words[word]) * UInt64(rhs.words[index])
                    + carry
                temporary[word] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            let high = UInt64(temporary[count]) + carry
            temporary[count] = UInt32(truncatingIfNeeded: high)
            temporary[count + 1] = UInt32(high >> 32)

            let factor = temporary[0] &* negativeInverse
            let first = UInt64(temporary[0]) + UInt64(factor) * UInt64(modulus.words[0])
            carry = first >> 32
            for word in 1..<count {
                let value = UInt64(temporary[word])
                    + UInt64(factor) * UInt64(modulus.words[word])
                    + carry
                temporary[word - 1] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
            }
            let highValue = UInt64(temporary[count]) + carry
            temporary[count - 1] = UInt32(truncatingIfNeeded: highValue)
            temporary[count] = temporary[count + 1] + UInt32(highValue >> 32)
            temporary[count + 1] = 0
        }

        var result = DHInteger(words: Array(temporary[0...count]), wordCount: count + 1)
        let extendedModulus = DHInteger(words: modulus.words, wordCount: count + 1)
        if !(result < extendedModulus) {
            result = result - extendedModulus
        }
        return DHInteger(words: result.words, wordCount: count)
    }

    private static func addModulo(_ lhs: DHInteger, _ rhs: DHInteger, modulus: DHInteger) -> DHInteger {
        let count = modulus.words.count
        var sum = Array(repeating: UInt32(0), count: count)
        var carry: UInt64 = 0
        for index in 0..<count {
            let value = UInt64(lhs.words[index]) + UInt64(rhs.words[index]) + carry
            sum[index] = UInt32(truncatingIfNeeded: value)
            carry = value >> 32
        }
        let sumValue = DHInteger(words: sum, wordCount: count)
        guard carry > 0 || !(sumValue < modulus) else { return sumValue }

        var difference = Array(repeating: UInt32(0), count: count)
        var borrow: UInt64 = 0
        for index in 0..<count {
            let left = UInt64(sum[index])
            let right = UInt64(modulus.words[index]) + borrow
            if left >= right {
                difference[index] = UInt32(left - right)
                borrow = 0
            } else {
                difference[index] = UInt32((UInt64(1) << 32) + left - right)
                borrow = 1
            }
        }
        return DHInteger(words: difference, wordCount: count)
    }
}

private extension Data {
    nonisolated func readUInt16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    nonisolated func readUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    nonisolated func readInt32(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(at: offset))
    }

    nonisolated mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xff))
    }

    nonisolated mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    nonisolated mutating func appendInt32(_ value: Int32) {
        let bits = UInt32(bitPattern: value)
        append(UInt8(bits >> 24))
        append(UInt8((bits >> 16) & 0xff))
        append(UInt8((bits >> 8) & 0xff))
        append(UInt8(bits & 0xff))
    }
}
