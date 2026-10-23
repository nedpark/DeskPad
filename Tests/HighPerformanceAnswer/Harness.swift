import Foundation
@main struct Harness {
    static func rejected(_ body: () throws -> Void) { do { try body(); fatalError("accepted malformed input") } catch {} }
    static func main() throws {
        let offer = try AppleHPMediaOffer.make()
        precondition(Array(offer.message[6..<10]) == [0, 0, 0, 5], "offer flags use big endian across the agent IPC boundary")
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var parser = AppleHPControlParser()
        var events: [AppleHPControlParser.Event] = []
        for byte in fixture { events += try parser.append(Data([byte])) }
        guard events.count == 1, case .mediaAnswer(let answer) = events[0] else { fatalError("answer missing") }
        precondition(answer.status == 1 && answer.audio.ssrc > 0)
        precondition(answer.video.codecPayloadType == 123 && answer.video.width == 1280 && answer.video.height == 720)
        precondition(answer.secondVideo == nil && answer.audio.opaqueField12?.count == 4)
        try parser.finish()
        // Multiple messages coalesced; status immediately before a fragmented FBU.
        var mixed = AppleHPControlParser()
        let status = Data([20,0,0,4,0,1,0,12])
        let all = try mixed.append(status + fixture + Data([2]))
        precondition(all.count == 3 && mixed.isAtMessageBoundary)
        let archive = Data([0x1f,0,1,0,0,0,0,0,0,0,0,0,0,0,0,7,120,156,0,0,0,255,255])
        var clipboard = AppleHPControlParser()
        var clipboardEvents: [AppleHPControlParser.Event] = []
        for byte in archive { clipboardEvents += try clipboard.append(Data([byte])) }
        guard case .clipboardArchive(let promise, let size, let compressed) = clipboardEvents.first else { fatalError("archive missing") }
        precondition(promise == 1 && size == 0 && compressed.count == 7)
        precondition(clipboard.isAtMessageBoundary)
        let afterClipboard = try clipboard.append(Data([2]))
        precondition(afterClipboard.count == 1)
        rejected { var p = AppleHPControlParser(); _ = try p.append(Data(archive.dropLast())); try p.finish() }
        rejected { var p = AppleHPControlParser(); var a = archive; a[8] = 255; _ = try p.append(a) }
        rejected { var p = AppleHPControlParser(); var a = archive; a[12] = 255; _ = try p.append(a) }
        let cursorSelect = Data([0,0,0,1]) + Data(repeating: 0, count: 8) + Data([0,0,4,80,0,0,3,232,0,0,0,0])
        var cursor = AppleHPControlParser()
        let cursorEvents = try cursor.append(cursorSelect + Data([2]))
        guard case .rectangle(let encoding, _, _, _, _, let cursorPayload) = cursorEvents.first else { fatalError("cursor missing") }
        precondition(encoding == 1104 && cursorPayload.count == 8 && cursorEvents.count == 2)
        var rekey = AppleHPControlParser()
        let keyMessage = Data([0,0,0,1]) + Data(repeating: 0, count: 8) + Data([0,0,4,79]) + Data(repeating: 0, count: 36)
        let changed = try rekey.append(keyMessage)
        guard case .rekey(let payload) = changed.first else { fatalError("rekey missing") }
        precondition(payload.count == 36 && rekey.isAtMessageBoundary)
        rejected { var p = AppleHPControlParser(); _ = try p.append(keyMessage + Data([2])) }
        rejected { var p = AppleHPControlParser(); _ = try p.append(Data([0xff])) }
        rejected { var p = AppleHPControlParser(); _ = try p.append(Data(repeating: 0, count: 1_048_577)) }
        rejected { var p = AppleHPControlParser(); _ = try p.append(Data(fixture.dropLast())); try p.finish() }
        rejected { _ = try AppleHPMediaAnswer(Data(fixture.dropFirst(16).dropLast())) }
        rejected { _ = try AppleHPProtoValue.parse(Data([8] + Array(repeating: UInt8(255), count: 10))) }
        rejected { _ = try AppleHPProtoValue.oneNumber(AppleHPProtoValue.parse(Data([8,1,8,2])), 1) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
        let dual = try AppleHPMediaAnswer(Data(contentsOf: directory.appendingPathComponent("dual")))
        precondition(dual.video.supportedVideoPayloadTypes == Set([100,123]) && dual.video.codecPayloadType == nil)
        precondition(answer.video.supportedVideoPayloadTypes == Set([123]) && answer.audio.supportedVideoPayloadTypes.isEmpty)
        for name in ["duplicate", "unknown", "excess", "empty"] {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            rejected { _ = try AppleHPMediaAnswer(bytes) }
        }
        print("PASS HP answer: validated stream metadata, fragmentation/coalescing, strict bounds, rekey barrier, malformed protobuf")
    }
}
