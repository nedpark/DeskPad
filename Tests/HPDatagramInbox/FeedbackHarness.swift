import Foundation
@main struct Harness {
 static func main() throws {
  let bytes = AppleHPFeedback.pictureLoss(sender: 0x01020304, media: 0xaabbccdd)
  precondition(bytes == Data([0x80,201,0,1,1,2,3,4,0x81,206,0,2,1,2,3,4,0xaa,0xbb,0xcc,0xdd,0x80,192,0,1,0xaa,0xbb,0xcc,0xdd]))
  let key = Data(repeating: 42, count: 46)
  let sender = try HighPerformanceSRTCPSender(masterKeyBlob: key, ssrc: 0x01020304)
  var receiver = try HighPerformanceSRTCPReceiver(masterKeyBlob: key)
  let protected = try sender.protect(bytes)
  let decoded = try receiver.receive(protected)
  precondition(decoded == bytes)
  print("PASS RTCP PLI framing")
 }
}
