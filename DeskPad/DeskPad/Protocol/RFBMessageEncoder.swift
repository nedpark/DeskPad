import Foundation

enum RFBMessageEncoder {

    // MARK: - Handshake

    static func encodeVersion(_ version: RFBVersion) -> Data {
        Data(version.rawValue.utf8)
    }

    static func encodeSecurityType(_ type: RFBSecurityType) -> Data {
        Data([type.rawValue])
    }

    static func encodeClientInit(shared: Bool) -> Data {
        Data([shared ? 1 : 0])
    }

    // MARK: - SetPixelFormat (type 0)

    static func encodeSetPixelFormat(_ format: RFBPixelFormat) -> Data {
        var data = Data(count: 20)
        data[0] = RFBClientMessageType.setPixelFormat.rawValue
        // bytes 1-3 padding
        let formatBytes = format.encode()
        data.replaceSubrange(4..<20, with: formatBytes)
        return data
    }

    // MARK: - SetEncodings (type 2)

    static func encodeSetEncodings(_ encodings: [RFBEncodingType]) -> Data {
        var data = Data(count: 4 + encodings.count * 4)
        data[0] = RFBClientMessageType.setEncodings.rawValue
        // byte 1 padding
        let count = UInt16(encodings.count)
        data[2] = UInt8(count >> 8)
        data[3] = UInt8(count & 0xFF)
        for (i, encoding) in encodings.enumerated() {
            let value = encoding.rawValue
            let offset = 4 + i * 4
            data[offset] = UInt8(truncatingIfNeeded: value >> 24)
            data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
            data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
            data[offset + 3] = UInt8(truncatingIfNeeded: value)
        }
        return data
    }

    // MARK: - FramebufferUpdateRequest (type 3)

    static func encodeFramebufferUpdateRequest(
        incremental: Bool,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) -> Data {
        var data = Data(count: 10)
        data[0] = RFBClientMessageType.framebufferUpdateRequest.rawValue
        data[1] = incremental ? 1 : 0
        data[2] = UInt8(x >> 8)
        data[3] = UInt8(x & 0xFF)
        data[4] = UInt8(y >> 8)
        data[5] = UInt8(y & 0xFF)
        data[6] = UInt8(width >> 8)
        data[7] = UInt8(width & 0xFF)
        data[8] = UInt8(height >> 8)
        data[9] = UInt8(height & 0xFF)
        return data
    }

    // MARK: - KeyEvent (type 4)

    static func encodeKeyEvent(downFlag: Bool, key: UInt32) -> Data {
        var data = Data(count: 8)
        data[0] = RFBClientMessageType.keyEvent.rawValue
        data[1] = downFlag ? 1 : 0
        // bytes 2-3 padding
        data[4] = UInt8(truncatingIfNeeded: key >> 24)
        data[5] = UInt8(truncatingIfNeeded: key >> 16)
        data[6] = UInt8(truncatingIfNeeded: key >> 8)
        data[7] = UInt8(truncatingIfNeeded: key)
        return data
    }

    // MARK: - PointerEvent (type 5)

    static func encodePointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) -> Data {
        var data = Data(count: 6)
        data[0] = RFBClientMessageType.pointerEvent.rawValue
        data[1] = buttonMask
        data[2] = UInt8(x >> 8)
        data[3] = UInt8(x & 0xFF)
        data[4] = UInt8(y >> 8)
        data[5] = UInt8(y & 0xFF)
        return data
    }

    // MARK: - ClientCutText (type 6)

    static func encodeClientCutText(_ text: String) -> Data {
        let textData = Data(text.utf8)
        let length = UInt32(textData.count)
        var data = Data(count: 8 + textData.count)
        data[0] = RFBClientMessageType.clientCutText.rawValue
        // bytes 1-3 padding
        data[4] = UInt8(truncatingIfNeeded: length >> 24)
        data[5] = UInt8(truncatingIfNeeded: length >> 16)
        data[6] = UInt8(truncatingIfNeeded: length >> 8)
        data[7] = UInt8(truncatingIfNeeded: length)
        data.replaceSubrange(8..<(8 + textData.count), with: textData)
        return data
    }
}
