import Foundation
import CommonCrypto

func ecb(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
    var result = Data(count: data.count), written = 0
    let status = result.withUnsafeMutableBytes { out in data.withUnsafeBytes { src in key.withUnsafeBytes { key in
        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode), key.baseAddress, 16, nil,
                src.baseAddress, data.count, out.baseAddress, data.count, &written)
    } } }
    guard status == kCCSuccess, written == data.count else { throw NSError(domain: "fixture", code: Int(status)) }
    return result
}
func rekey(generation: UInt8, key: Data, iv: Data, wrapping: Data) throws -> Data {
    Data([0, 0, 0, generation]) + (try ecb(key + iv, key: wrapping, encrypt: true))
}
@main struct Harness {
    static func main() throws {
        let initial = Data(repeating: 0x11, count: 16)
        let key1 = Data(repeating: 0x22, count: 16), key2 = Data(repeating: 0x33, count: 16)
        let iv = Data(repeating: 0x44, count: 16)
        let sender = try AppleHPRecordCipher(wrapKey: initial)
        let receiver = try AppleHPRecordCipher(wrapKey: initial)
        let first = try rekey(generation: 1, key: key1, iv: iv, wrapping: initial)
        try sender.installRekey(payload: first); try receiver.installRekey(payload: first)
        for (x, y, mask): (UInt16, UInt16, UInt8) in [(0, 65535, 0), (65535, 0, 255), (6015, 3383, 1)] {
            let wire = try sender.encodePointer(x: x, y: y, buttonMask: mask)
            let decoded = try receiver.receive(bytes: wire)
            precondition(decoded.count == 1 && decoded[0].count == 18 && decoded[0].prefix(2) == Data([16, 0]))
            let plain = try ecb(Data(decoded[0].dropFirst(2)), key: key1, encrypt: false)
            let expected = Data(repeating: 0, count: 10) + Data([255, mask, UInt8(x >> 8), UInt8(truncatingIfNeeded: x), UInt8(y >> 8), UInt8(truncatingIfNeeded: y)])
            precondition(plain == expected)
        }
        let second = try rekey(generation: 2, key: key2, iv: iv, wrapping: key1)
        try sender.installRekey(payload: second); try receiver.installRekey(payload: second)
        let decoded = try receiver.receive(bytes: sender.encodePointer(x: 42, y: 84, buttonMask: 2))
        let inner = Data(decoded[0].dropFirst(2))
        let plain = try ecb(inner, key: key2, encrypt: false)
        precondition(plain == Data(repeating: 0, count: 10) + Data([255, 2, 0, 42, 0, 84]))
        let old = try ecb(inner, key: key1, encrypt: false)
        precondition(old != plain)
        let inactive = try AppleHPRecordCipher(wrapKey: initial)
        do { _ = try inactive.encodePointer(x: 0, y: 0, buttonMask: 0); fatalError("Inactive key used") }
        catch AppleHPRecordCipher.Failure.inactive {}
        print("HP pointer inner ECB/outer authenticated record, unsigned bounds and rekey passed")
    }
}
