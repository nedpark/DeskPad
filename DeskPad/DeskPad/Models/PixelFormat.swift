import Foundation

struct RFBPixelFormat {
    var bitsPerPixel: UInt8
    var depth: UInt8
    var bigEndian: UInt8
    var trueColour: UInt8
    var redMax: UInt16
    var greenMax: UInt16
    var blueMax: UInt16
    var redShift: UInt8
    var greenShift: UInt8
    var blueShift: UInt8

    var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    /// 32-bit XRGB matching CGBitmapInfo.byteOrder32Little | noneSkipFirst
    static let clientPreferred = RFBPixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: 0,
        trueColour: 1,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    /// Encode to 16-byte RFB wire format
    func encode() -> Data {
        var data = Data(count: 16)
        data[0] = bitsPerPixel
        data[1] = depth
        data[2] = bigEndian
        data[3] = trueColour
        data[4] = UInt8(redMax >> 8)
        data[5] = UInt8(redMax & 0xFF)
        data[6] = UInt8(greenMax >> 8)
        data[7] = UInt8(greenMax & 0xFF)
        data[8] = UInt8(blueMax >> 8)
        data[9] = UInt8(blueMax & 0xFF)
        data[10] = redShift
        data[11] = greenShift
        data[12] = blueShift
        // bytes 13-15 are padding
        data[13] = 0
        data[14] = 0
        data[15] = 0
        return data
    }

    /// Decode from 16-byte RFB wire format
    static func decode(from data: Data) -> RFBPixelFormat {
        RFBPixelFormat(
            bitsPerPixel: data[0],
            depth: data[1],
            bigEndian: data[2],
            trueColour: data[3],
            redMax: UInt16(data[4]) << 8 | UInt16(data[5]),
            greenMax: UInt16(data[6]) << 8 | UInt16(data[7]),
            blueMax: UInt16(data[8]) << 8 | UInt16(data[9]),
            redShift: data[10],
            greenShift: data[11],
            blueShift: data[12]
        )
    }
}
