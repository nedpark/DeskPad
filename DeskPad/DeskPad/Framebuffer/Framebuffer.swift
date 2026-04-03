import Foundation
import CoreGraphics

final class Framebuffer {
    let width: Int
    let height: Int
    let bytesPerPixel: Int = 4
    let bytesPerRow: Int
    private var pixelData: UnsafeMutableRawPointer
    private let colorSpace: CGColorSpace
    private let bitmapInfo: CGBitmapInfo

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height
        self.pixelData = UnsafeMutableRawPointer.allocate(
            byteCount: totalBytes,
            alignment: 16
        )
        pixelData.initializeMemory(as: UInt8.self, repeating: 0, count: totalBytes)
        self.colorSpace = CGColorSpaceCreateDeviceRGB()
        self.bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.noneSkipFirst.rawValue
        )
    }

    deinit {
        pixelData.deallocate()
    }

    /// Apply a Raw-encoded rectangle to the framebuffer
    func applyRawRect(x: Int, y: Int, width rectW: Int, height rectH: Int, data: Data) {
        data.withUnsafeBytes { srcPtr in
            guard let base = srcPtr.baseAddress else { return }
            for row in 0..<rectH {
                let srcOffset = row * rectW * bytesPerPixel
                let dstY = y + row
                guard dstY >= 0 && dstY < height else { continue }
                let clippedX = max(0, x)
                let clippedW = min(rectW, width - clippedX)
                guard clippedW > 0 else { continue }
                let dstOffset = (dstY * self.width + clippedX) * bytesPerPixel
                let srcAdjust = (clippedX - x) * bytesPerPixel
                (pixelData + dstOffset).copyMemory(
                    from: base + srcOffset + srcAdjust,
                    byteCount: clippedW * bytesPerPixel
                )
            }
        }
    }

    /// Apply a CopyRect-encoded rectangle
    func applyCopyRect(dstX: Int, dstY: Int, width rectW: Int, height rectH: Int,
                       srcX: Int, srcY: Int) {
        let rowBytes = rectW * bytesPerPixel
        // Use temp buffer to handle overlapping regions
        let tempSize = rowBytes * rectH
        let temp = UnsafeMutableRawPointer.allocate(byteCount: tempSize, alignment: 16)
        defer { temp.deallocate() }

        for row in 0..<rectH {
            let sy = srcY + row
            guard sy >= 0 && sy < height else { continue }
            let srcOffset = (sy * width + srcX) * bytesPerPixel
            let tmpOffset = row * rowBytes
            (temp + tmpOffset).copyMemory(from: pixelData + srcOffset, byteCount: rowBytes)
        }

        for row in 0..<rectH {
            let dy = dstY + row
            guard dy >= 0 && dy < height else { continue }
            let dstOffset = (dy * width + dstX) * bytesPerPixel
            let tmpOffset = row * rowBytes
            (pixelData + dstOffset).copyMemory(from: temp + tmpOffset, byteCount: rowBytes)
        }
    }

    /// Create an immutable CGImage snapshot of the current framebuffer
    func createImage() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        if let contextData = context.data {
            contextData.copyMemory(from: pixelData, byteCount: bytesPerRow * height)
        }

        return context.makeImage()
    }
}
