import Foundation

// MARK: - Data Cursor

enum RFBDecodeError: Error {
    case insufficientData
    case invalidVersion
    case invalidSecurityType
    case invalidMessageType
    case invalidEncoding
    case authenticationFailed(String)
    case protocolError(String)
}

final class RFBDataCursor {
    private let data: Data
    private(set) var position: Int

    var remaining: Int { data.count - position }
    var consumedCount: Int { position }

    init(data: Data) {
        self.data = data
        self.position = 0
    }

    func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw RFBDecodeError.insufficientData }
        let value = data[data.startIndex + position]
        position += 1
        return value
    }

    func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else { throw RFBDecodeError.insufficientData }
        let offset = data.startIndex + position
        let value = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        position += 2
        return value
    }

    func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw RFBDecodeError.insufficientData }
        let offset = data.startIndex + position
        let value = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        position += 4
        return value
    }

    func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    func readData(count: Int) throws -> Data {
        guard remaining >= count else { throw RFBDecodeError.insufficientData }
        let start = data.startIndex + position
        let result = data[start..<(start + count)]
        position += count
        return Data(result)
    }

    func readString(length: Int) throws -> String {
        let bytes = try readData(count: length)
        return String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .isoLatin1)
            ?? ""
    }

    func skip(_ count: Int) throws {
        guard remaining >= count else { throw RFBDecodeError.insufficientData }
        position += count
    }
}

// MARK: - Server Messages

enum ServerMessage {
    case framebufferUpdate([RFBRectangle])
    case bell
    case serverCutText(String)
    case setColourMapEntries
}

// MARK: - Decoder

enum RFBMessageDecoder {

    static func decodeVersion(from data: Data) throws -> RFBVersion {
        guard data.count >= 12 else { throw RFBDecodeError.insufficientData }
        let versionString = String(data: data.prefix(12), encoding: .ascii) ?? ""
        if versionString.hasPrefix("RFB 003.008") {
            return .rfb38
        } else if versionString.hasPrefix("RFB 003.007") {
            return .rfb37
        } else if versionString.hasPrefix("RFB 003.003") {
            return .rfb33
        }
        // Default to 3.8 for compatible servers
        return .rfb38
    }

    static func decodeSecurityTypes(from cursor: RFBDataCursor) throws -> [RFBSecurityType] {
        let count = try cursor.readUInt8()
        if count == 0 {
            // Error message follows
            let reasonLength = try cursor.readUInt32()
            let reason = try cursor.readString(length: Int(reasonLength))
            throw RFBDecodeError.authenticationFailed(reason)
        }
        var types: [RFBSecurityType] = []
        for _ in 0..<count {
            let typeValue = try cursor.readUInt8()
            if let type = RFBSecurityType(rawValue: typeValue) {
                types.append(type)
            }
        }
        return types
    }

    static func decodeSecurityResult(from data: Data) throws -> Bool {
        guard data.count >= 4 else { throw RFBDecodeError.insufficientData }
        let cursor = RFBDataCursor(data: data)
        let result = try cursor.readUInt32()
        return result == 0
    }

    static func decodeSecurityResultWithReason(from cursor: RFBDataCursor) throws -> (Bool, String?) {
        let result = try cursor.readUInt32()
        if result != 0 && cursor.remaining >= 4 {
            let reasonLength = try cursor.readUInt32()
            if reasonLength > 0 && cursor.remaining >= Int(reasonLength) {
                let reason = try cursor.readString(length: Int(reasonLength))
                return (false, reason)
            }
            return (false, nil)
        }
        return (result == 0, nil)
    }

    static func decodeServerInit(from cursor: RFBDataCursor) throws -> RFBServerInit {
        let width = try cursor.readUInt16()
        let height = try cursor.readUInt16()
        let pixelFormatData = try cursor.readData(count: 16)
        let pixelFormat = RFBPixelFormat.decode(from: pixelFormatData)
        let nameLength = try cursor.readUInt32()
        let name = try cursor.readString(length: Int(nameLength))
        return RFBServerInit(
            framebufferWidth: width,
            framebufferHeight: height,
            pixelFormat: pixelFormat,
            desktopName: name
        )
    }

    static func decodeServerMessage(
        from cursor: RFBDataCursor,
        pixelFormat: RFBPixelFormat
    ) throws -> ServerMessage {
        let messageType = try cursor.readUInt8()

        switch messageType {
        case RFBServerMessageType.framebufferUpdate.rawValue:
            try cursor.skip(1) // padding
            let numberOfRects = try cursor.readUInt16()
            let rects = try decodeFramebufferUpdate(
                from: cursor,
                numberOfRectangles: numberOfRects,
                pixelFormat: pixelFormat
            )
            return .framebufferUpdate(rects)

        case RFBServerMessageType.bell.rawValue:
            return .bell

        case RFBServerMessageType.serverCutText.rawValue:
            try cursor.skip(3) // padding
            let length = try cursor.readUInt32()
            let text = try cursor.readString(length: Int(length))
            return .serverCutText(text)

        case RFBServerMessageType.setColourMapEntries.rawValue:
            try cursor.skip(1) // padding
            let firstColour = try cursor.readUInt16()
            let numberOfColours = try cursor.readUInt16()
            _ = firstColour
            // Each colour entry is 6 bytes (R, G, B as UInt16 each)
            try cursor.skip(Int(numberOfColours) * 6)
            return .setColourMapEntries

        default:
            throw RFBDecodeError.invalidMessageType
        }
    }

    static func decodeFramebufferUpdate(
        from cursor: RFBDataCursor,
        numberOfRectangles: UInt16,
        pixelFormat: RFBPixelFormat
    ) throws -> [RFBRectangle] {
        var rectangles: [RFBRectangle] = []
        rectangles.reserveCapacity(Int(numberOfRectangles))

        for _ in 0..<numberOfRectangles {
            let x = try cursor.readUInt16()
            let y = try cursor.readUInt16()
            let width = try cursor.readUInt16()
            let height = try cursor.readUInt16()
            let encodingValue = try cursor.readInt32()

            guard let encoding = RFBEncodingType(rawValue: encodingValue) else {
                throw RFBDecodeError.invalidEncoding
            }

            let pixelData: Data

            switch encoding {
            case .raw:
                let byteCount = Int(width) * Int(height) * pixelFormat.bytesPerPixel
                pixelData = try cursor.readData(count: byteCount)

            case .copyRect:
                // CopyRect: 4 bytes (srcX: UInt16, srcY: UInt16)
                pixelData = try cursor.readData(count: 4)

            case .cursor:
                // Cursor pseudo-encoding: it has the actual cursor data if width/height > 0
                // For now, we skip the pixel data and bitmask
                if width > 0 && height > 0 {
                    let pixelCount = Int(width) * Int(height) * pixelFormat.bytesPerPixel
                    let maskCount = Int((width + 7) / 8) * Int(height)
                    try cursor.skip(pixelCount + maskCount)
                }
                pixelData = Data()

            case .desktopSize:
                // DesktopSize pseudo-encoding: width and height are the new desktop size
                // We could update the UI here, but for now we just acknowledge it
                pixelData = Data()

            default:
                // Unsupported encodings are skipped
                pixelData = Data()
            }

            rectangles.append(RFBRectangle(
                x: x, y: y,
                width: width, height: height,
                encodingType: encoding,
                pixelData: pixelData
            ))
        }

        return rectangles
    }
}
