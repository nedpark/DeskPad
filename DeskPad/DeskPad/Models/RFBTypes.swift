import Foundation

// MARK: - Protocol Version

enum RFBVersion: String {
    case rfb33 = "RFB 003.003\n"
    case rfb37 = "RFB 003.007\n"
    case rfb38 = "RFB 003.008\n"
}

// MARK: - Security Types

enum RFBSecurityType: UInt8 {
    case invalid = 0
    case none = 1
    case vncAuthentication = 2
    case ra2 = 5
    case ra2ne = 6
    case tight = 16
    case ultra = 17
    case tls = 18
    case venCrypt = 19
    case x509Vnc = 30
    case x509Plain = 33
    case plain = 35
    case x509None = 36
}

// MARK: - Client Message Types

enum RFBClientMessageType: UInt8 {
    case setPixelFormat = 0
    case setEncodings = 2
    case framebufferUpdateRequest = 3
    case keyEvent = 4
    case pointerEvent = 5
    case clientCutText = 6
}

// MARK: - Server Message Types

enum RFBServerMessageType: UInt8 {
    case framebufferUpdate = 0
    case setColourMapEntries = 1
    case bell = 2
    case serverCutText = 3
}

// MARK: - Encoding Types

enum RFBEncodingType: Int32 {
    case raw = 0
    case copyRect = 1
    case rre = 2
    case hextile = 5
    case tight = 7
    case zrle = 16
    case cursor = -239
    case desktopSize = -223
}

// MARK: - Server Init

struct RFBServerInit {
    let framebufferWidth: UInt16
    let framebufferHeight: UInt16
    let pixelFormat: RFBPixelFormat
    let desktopName: String
}

// MARK: - Framebuffer Update Rectangle

struct RFBRectangle {
    let x: UInt16
    let y: UInt16
    let width: UInt16
    let height: UInt16
    let encodingType: RFBEncodingType
    let pixelData: Data
}

// MARK: - Connection State

enum VNCConnectionState: Equatable {
    case disconnected
    case connecting
    case handshaking
    case authenticating
    case initializing
    case connected
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isDisconnected: Bool {
        switch self {
        case .disconnected, .failed: return true
        default: return false
        }
    }
}
