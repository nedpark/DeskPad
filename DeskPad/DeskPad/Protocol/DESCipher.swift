import Foundation
import CommonCrypto

enum DESCipher {

    /// VNC DES encrypt: password is truncated/padded to 8 bytes,
    /// each byte's bits are reversed, then used as DES key to
    /// encrypt the 16-byte challenge in 8-byte ECB blocks.
    static func vncEncrypt(challenge: Data, password: String) -> Data {
        var keyBytes = [UInt8](repeating: 0, count: 8)
        let passwordBytes = Array(password.utf8)
        for i in 0..<min(8, passwordBytes.count) {
            keyBytes[i] = passwordBytes[i]
        }

        // VNC quirk: reverse bits in each byte of the key
        for i in 0..<8 {
            keyBytes[i] = reverseBits(keyBytes[i])
        }

        var result = Data()
        for blockStart in stride(from: 0, to: challenge.count, by: 8) {
            let end = min(blockStart + 8, challenge.count)
            let block = Data(challenge[blockStart..<end])
            let encrypted = desECBEncrypt(block: block, key: Data(keyBytes))
            result.append(encrypted)
        }
        return result
    }

    private static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }

    private static func desECBEncrypt(block: Data, key: Data) -> Data {
        var outputBuffer = [UInt8](repeating: 0, count: block.count + kCCBlockSizeDES)
        var numBytesEncrypted: size_t = 0

        let status = key.withUnsafeBytes { keyPtr in
            block.withUnsafeBytes { dataPtr in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmDES),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress, kCCKeySizeDES,
                    nil,
                    dataPtr.baseAddress, block.count,
                    &outputBuffer, outputBuffer.count,
                    &numBytesEncrypted
                )
            }
        }

        if status == kCCSuccess {
            return Data(outputBuffer.prefix(block.count))
        }
        return Data(count: block.count)
    }
}
