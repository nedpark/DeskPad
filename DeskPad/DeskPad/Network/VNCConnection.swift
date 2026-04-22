import Foundation
import Network
import CoreGraphics
import Observation

@MainActor
@Observable
final class VNCConnection {

    // MARK: - Observable State

    private(set) var state: VNCConnectionState = .disconnected
    private(set) var framebufferImage: CGImage?
    private(set) var desktopName: String = ""
    private(set) var desktopSize: CGSize = .zero
    private(set) var framebufferWarning: String?

    // MARK: - Private Properties

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.deskpad.vnc", qos: .userInteractive)
    private var framebuffer: Framebuffer?
    private var activePixelFormat: RFBPixelFormat = .clientPreferred
    private var username: String = ""
    private var password: String = ""
    private var fbWidth: UInt16 = 0
    private var fbHeight: UInt16 = 0
    private var serverVersion: RFBVersion = .rfb38
    private var hasReceivedFirstFrame = false
    private var consecutiveDecodeErrors = 0
    private var framebufferTimeoutTask: Task<Void, Never>?
    private static let maxConsecutiveDecodeErrors = 5
    private static let framebufferTimeoutSeconds: UInt64 = 10

    // MARK: - Connection Lifecycle

    func connect(host: String, port: UInt16 = 5900, username: String = "", password: String = "") {
        disconnect()
        self.username = username
        self.password = password
        state = .connecting

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("Invalid port")
            return
        }

        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(newState)
            }
        }

        conn.start(queue: queue)
    }

    func disconnect() {
        framebufferTimeoutTask?.cancel()
        framebufferTimeoutTask = nil
        connection?.cancel()
        connection = nil
        framebuffer = nil
        framebufferImage = nil
        state = .disconnected
        desktopName = ""
        desktopSize = .zero
        framebufferWarning = nil
        hasReceivedFirstFrame = false
        consecutiveDecodeErrors = 0
    }

    // MARK: - Input Forwarding

    func sendKeyEvent(downFlag: Bool, keysym: UInt32) {
        guard state == .connected else { return }
        let data = RFBMessageEncoder.encodeKeyEvent(downFlag: downFlag, key: keysym)
        sendData(data)
    }

    func sendPointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) {
        guard state == .connected else { return }
        let data = RFBMessageEncoder.encodePointerEvent(buttonMask: buttonMask, x: x, y: y)
        sendData(data)
    }

    // MARK: - Connection State Handler

    private func handleConnectionState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            state = .handshaking
            receiveVersionString()
        case .failed(let error):
            state = .failed(error.localizedDescription)
        case .cancelled:
            if case .failed = state { return }
            state = .disconnected
        default:
            break
        }
    }

    // MARK: - RFB Handshake

    private func receiveVersionString() {
        receiveExact(count: 12) { [weak self] data in
            guard let self else { return }
            do {
                let version = try RFBMessageDecoder.decodeVersion(from: data)
                self.serverVersion = version
                let response = RFBMessageEncoder.encodeVersion(version)
                self.sendData(response)

                if version == .rfb33 {
                    self.receiveRFB33Security()
                } else {
                    self.receiveSecurityTypes()
                }
            } catch {
                self.state = .failed("Version handshake failed: \(error)")
            }
        }
    }

    private func receiveRFB33Security() {
        // RFB 3.3: 서버는 자신이 선택한 단 하나의 보안 타입을 4바이트로 보냅니다.
        receiveExact(count: 4) { [weak self] data in
            guard let self else { return }
            let cursor = RFBDataCursor(data: data)
            do {
                let typeValue = try cursor.readUInt32()
                if typeValue == 0 {
                    // 접속 거부된 경우: 4바이트 이유 길이 + 이유 문자열이 뒤따릅니다.
                    self.receiveExact(count: 4) { lenData in
                        let lenCursor = RFBDataCursor(data: lenData)
                        let length = (try? lenCursor.readUInt32()) ?? 0
                        if length > 0 {
                            self.receiveExact(count: Int(length)) { reasonData in
                                let reason = String(data: reasonData, encoding: .utf8) ?? "Unknown"
                                self.state = .failed("Connection refused: \(reason)")
                            }
                        } else {
                            self.state = .failed("Connection refused (No reason given)")
                        }
                    }
                    return
                }
                
                if typeValue == UInt32(RFBSecurityType.none.rawValue) {
                    self.sendClientInit()
                } else if typeValue == UInt32(RFBSecurityType.vncAuthentication.rawValue) {
                    self.state = .authenticating
                    self.receiveVNCAuthChallenge()
                } else if typeValue == UInt32(RFBSecurityType.plain.rawValue) || typeValue == 30 || typeValue == 33 || typeValue == 35 {
                    // macOS 등에서 제안하는 다양한 Plain 인증 시도
                    self.sendPlainAuth()
                } else {
                    self.state = .failed("Unsupported security type (\(typeValue)). Please enable 'VNC Password' in Mac Sharing settings.")
                }
            } catch {
                self.state = .failed("Security handshake failed")
            }
        }
    }

    private func receiveSecurityTypes() {
        state = .authenticating
        // First read the count byte
        receiveExact(count: 1) { [weak self] countData in
            guard let self else { return }
            let count = countData[countData.startIndex]

            if count == 0 {
                // Error: read 4-byte reason length then reason string
                self.receiveExact(count: 4) { lengthData in
                    let cursor = RFBDataCursor(data: lengthData)
                    let length = (try? cursor.readUInt32()) ?? 0
                    if length > 0 {
                        self.receiveExact(count: Int(length)) { reasonData in
                            let reason = String(data: reasonData, encoding: .utf8) ?? "Unknown"
                            self.state = .failed("Connection refused: \(reason)")
                        }
                    } else {
                        self.state = .failed("Connection refused")
                    }
                }
                return
            }

            self.receiveExact(count: Int(count)) { typesData in
                var types: [RFBSecurityType] = []
                var rawTypes: [UInt8] = []
                for i in 0..<Int(count) {
                    let rawType = typesData[typesData.startIndex + i]
                    rawTypes.append(rawType)
                    if let t = RFBSecurityType(rawValue: rawType) {
                        types.append(t)
                    }
                }

                if types.contains(.vncAuthentication) {
                    self.sendData(RFBMessageEncoder.encodeSecurityType(.vncAuthentication))
                    self.receiveVNCAuthChallenge()
                } else if types.contains(.plain) || types.contains(.x509Plain) || types.contains(.x509Vnc) {
                    // 서버가 Plain(35) 또는 Apple SASL 호환(30, 33) 타입을 제안하면 Plain 인증 시도
                    let selectedType: RFBSecurityType = types.contains(.plain) ? .plain : (types.contains(.x509Plain) ? .x509Plain : .x509Vnc)
                    self.sendData(RFBMessageEncoder.encodeSecurityType(selectedType))
                    self.sendPlainAuth()
                } else if types.contains(.none) {
                    self.sendData(RFBMessageEncoder.encodeSecurityType(.none))
                    if self.serverVersion == .rfb38 {
                        self.receiveSecurityResult()
                    } else {
                        self.sendClientInit()
                    }
                } else {
                    let typeList = rawTypes.map { "\($0)" }.joined(separator: ", ")
                    self.state = .failed("No supported security type (Server offered: \(typeList))")
                }
            }
        }
    }

    private func sendPlainAuth() {
        state = .authenticating
        
        let userBytes = Array(username.utf8)
        let passBytes = Array(password.utf8)
        
        var data = Data()
        // Username: 4-byte length + content
        let uCount = UInt32(userBytes.count)
        data.append(UInt8(uCount >> 24))
        data.append(UInt8(uCount >> 16))
        data.append(UInt8(uCount >> 8))
        data.append(UInt8(uCount & 0xFF))
        data.append(contentsOf: userBytes)
        
        // Password: 4-byte length + content
        let pCount = UInt32(passBytes.count)
        data.append(UInt8(pCount >> 24))
        data.append(UInt8(pCount >> 16))
        data.append(UInt8(pCount >> 8))
        data.append(UInt8(pCount & 0xFF))
        data.append(contentsOf: passBytes)
        
        sendData(data)
        receiveSecurityResult()
    }

    private func receiveVNCAuthChallenge() {
        receiveExact(count: 16) { [weak self] challenge in
            guard let self else { return }
            let response = DESCipher.vncEncrypt(challenge: challenge, password: self.password)
            self.sendData(response)
            self.receiveSecurityResult()
        }
    }

    private func receiveSecurityResult() {
        receiveExact(count: 4) { [weak self] data in
            guard let self else { return }
            do {
                let success = try RFBMessageDecoder.decodeSecurityResult(from: data)
                if success {
                    self.sendClientInit()
                } else {
                    self.state = .failed("Authentication failed")
                }
            } catch {
                self.state = .failed("Auth result decode failed")
            }
        }
    }

    private func sendClientInit() {
        state = .initializing
        sendData(RFBMessageEncoder.encodeClientInit(shared: true))
        receiveServerInit()
    }

    private func receiveServerInit() {
        // ServerInit: 2 + 2 + 16 + 4 = 24 bytes minimum, then name
        receiveExact(count: 24) { [weak self] headerData in
            guard let self else { return }
            let cursor = RFBDataCursor(data: headerData)
            do {
                let width = try cursor.readUInt16()
                let height = try cursor.readUInt16()
                let pfData = try cursor.readData(count: 16)
                let pixelFormat = RFBPixelFormat.decode(from: pfData)
                let nameLength = try cursor.readUInt32()

                self.receiveExact(count: Int(nameLength)) { nameData in
                    let name = String(data: nameData, encoding: .utf8) ?? "Remote Desktop"

                    let serverInit = RFBServerInit(
                        framebufferWidth: width,
                        framebufferHeight: height,
                        pixelFormat: pixelFormat,
                        desktopName: name
                    )
                    self.handleServerInit(serverInit)
                }
            } catch {
                self.state = .failed("ServerInit decode failed")
            }
        }
    }

    private func handleServerInit(_ serverInit: RFBServerInit) {
        fbWidth = serverInit.framebufferWidth
        fbHeight = serverInit.framebufferHeight
        desktopName = serverInit.desktopName
        desktopSize = CGSize(width: CGFloat(fbWidth), height: CGFloat(fbHeight))

        framebuffer = Framebuffer(width: Int(fbWidth), height: Int(fbHeight))

        // Set our preferred pixel format
        sendData(RFBMessageEncoder.encodeSetPixelFormat(.clientPreferred))
        activePixelFormat = .clientPreferred

        // Set supported encodings
        sendData(RFBMessageEncoder.encodeSetEncodings([.copyRect, .raw, .cursor, .desktopSize]))

        // Request full framebuffer update
        sendData(RFBMessageEncoder.encodeFramebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0,
            width: fbWidth, height: fbHeight
        ))

        // Send initial input events to wake the remote display.
        // macOS screensaver/lock screen requires user interaction to reveal
        // the login window and password field.
        sendWakeEvents()

        state = .connected

        // Start timeout for initial framebuffer update
        framebufferTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.framebufferTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.hasReceivedFirstFrame && self.state == .connected {
                self.framebufferWarning = "No screen data received from the server. The remote desktop may not be sending display updates."
            }
        }

        // Start the receive loop
        startReceiveLoop()
    }

    /// Send initial input events to wake a sleeping display or screensaver.
    /// A pointer move followed by a click at the screen center dismisses the
    /// macOS screensaver and focuses the login password field.
    private func sendWakeEvents() {
        let centerX = fbWidth / 2
        let centerY = fbHeight / 2

        // Move pointer to center of screen
        sendData(RFBMessageEncoder.encodePointerEvent(buttonMask: 0, x: centerX, y: centerY))

        // Click to dismiss screensaver and/or focus the password field
        sendData(RFBMessageEncoder.encodePointerEvent(buttonMask: 1, x: centerX, y: centerY))
        sendData(RFBMessageEncoder.encodePointerEvent(buttonMask: 0, x: centerX, y: centerY))
    }

    // MARK: - Receive Loop

    private var receiveBuffer = Data()

    private func startReceiveLoop() {
        guard let connection, state == .connected else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let data = content, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processReceiveBuffer()
                }

                if isComplete || error != nil {
                    if case .connected = self.state {
                        self.state = error.map { .failed($0.localizedDescription) } ?? .disconnected
                    }
                    return
                }

                // Continue receiving
                self.startReceiveLoop()
            }
        }
    }

    private func processReceiveBuffer() {
        while !receiveBuffer.isEmpty {
            let cursor = RFBDataCursor(data: receiveBuffer)
            do {
                let message = try RFBMessageDecoder.decodeServerMessage(
                    from: cursor,
                    pixelFormat: activePixelFormat
                )
                // Successfully parsed - remove consumed bytes
                let consumed = cursor.consumedCount
                receiveBuffer.removeFirst(consumed)
                consecutiveDecodeErrors = 0

                handleServerMessage(message)
            } catch RFBDecodeError.insufficientData {
                // Need more data
                break
            } catch {
                consecutiveDecodeErrors += 1

                // Once desynced, byte-by-byte skipping cannot recover RFB protocol.
                // Clear the buffer and request a fresh full framebuffer update.
                receiveBuffer.removeAll()

                if consecutiveDecodeErrors >= Self.maxConsecutiveDecodeErrors {
                    framebufferWarning = "Repeated display protocol errors. The server may be using an unsupported encoding."
                }

                // Re-request full framebuffer update to try to re-sync
                if state == .connected {
                    sendData(RFBMessageEncoder.encodeFramebufferUpdateRequest(
                        incremental: false,
                        x: 0, y: 0,
                        width: fbWidth, height: fbHeight
                    ))
                }
                break
            }
        }
    }

    private func handleServerMessage(_ message: ServerMessage) {
        switch message {
        case .framebufferUpdate(let rectangles):
            let desktopSizeChanged = applyRectangles(rectangles)

            // After a desktop size change, request a full (non-incremental)
            // update to get the new screen contents.
            sendData(RFBMessageEncoder.encodeFramebufferUpdateRequest(
                incremental: !desktopSizeChanged,
                x: 0, y: 0,
                width: fbWidth, height: fbHeight
            ))

        case .bell:
            // Could play a sound
            break

        case .serverCutText:
            // Could update clipboard
            break

        case .setColourMapEntries:
            break
        }
    }

    /// Apply received rectangles to the framebuffer.
    /// Returns `true` if a desktopSize pseudo-encoding was received
    /// (the caller should request a full non-incremental update).
    @discardableResult
    private func applyRectangles(_ rectangles: [RFBRectangle]) -> Bool {
        guard !rectangles.isEmpty else { return false }

        if !hasReceivedFirstFrame {
            hasReceivedFirstFrame = true
            framebufferTimeoutTask?.cancel()
            framebufferTimeoutTask = nil
            framebufferWarning = nil
        }

        // Check for desktopSize pseudo-encoding first.
        // When the remote desktop resizes (e.g. login → desktop transition),
        // we must recreate the framebuffer before applying any pixel data.
        for rect in rectangles where rect.encodingType == .desktopSize {
            let newWidth = rect.width
            let newHeight = rect.height
            if newWidth > 0 && newHeight > 0 && (newWidth != fbWidth || newHeight != fbHeight) {
                fbWidth = newWidth
                fbHeight = newHeight
                desktopSize = CGSize(width: CGFloat(fbWidth), height: CGFloat(fbHeight))
                framebuffer = Framebuffer(width: Int(fbWidth), height: Int(fbHeight))
                framebufferImage = framebuffer?.createImage()
                return true
            }
        }

        guard let framebuffer else { return false }

        for rect in rectangles {
            switch rect.encodingType {
            case .raw:
                framebuffer.applyRawRect(
                    x: Int(rect.x), y: Int(rect.y),
                    width: Int(rect.width), height: Int(rect.height),
                    data: rect.pixelData
                )
            case .copyRect:
                if rect.pixelData.count >= 4 {
                    let cursor = RFBDataCursor(data: rect.pixelData)
                    if let srcX = try? cursor.readUInt16(),
                       let srcY = try? cursor.readUInt16() {
                        framebuffer.applyCopyRect(
                            dstX: Int(rect.x), dstY: Int(rect.y),
                            width: Int(rect.width), height: Int(rect.height),
                            srcX: Int(srcX), srcY: Int(srcY)
                        )
                    }
                }
            default:
                break
            }
        }

        framebufferImage = framebuffer.createImage()
        return false
    }

    // MARK: - Network Helpers

    private func sendData(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.state = .failed("Send failed: \(error.localizedDescription)")
                }
            }
        })
    }

    private func receiveExact(count: Int, handler: @escaping (Data) -> Void) {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) {
            [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data = content, data.count >= count {
                    handler(data)
                } else if isComplete || error != nil {
                    self.state = .failed(error?.localizedDescription ?? "Connection closed")
                } else if let data = content {
                    // Got partial data, need more
                    self.receiveRemaining(
                        accumulated: data,
                        totalNeeded: count,
                        handler: handler
                    )
                }
            }
        }
    }

    private func receiveRemaining(accumulated: Data, totalNeeded: Int,
                                  handler: @escaping (Data) -> Void) {
        guard let connection else { return }
        let remaining = totalNeeded - accumulated.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
            [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data = content {
                    var combined = accumulated
                    combined.append(data)
                    if combined.count >= totalNeeded {
                        handler(combined)
                    } else {
                        self.receiveRemaining(
                            accumulated: combined,
                            totalNeeded: totalNeeded,
                            handler: handler
                        )
                    }
                } else if isComplete || error != nil {
                    self.state = .failed(error?.localizedDescription ?? "Connection closed")
                }
            }
        }
    }
}
