import Foundation
@main struct Harness {
 static func main() {
  var probe = AppleHPFUDONProbe()
  precondition(probe.observe(sequence:65535,timestamp:1,payload:Data([98,1,129,0,7,9])) == nil)
  let same = probe.observe(sequence:0,timestamp:1,payload:Data([98,1,65,0,7,8]))!
  precondition(same.consistent && same.contiguous && same.fragments == 2)
  _ = probe.observe(sequence:1,timestamp:2,payload:Data([98,1,129,0,7]))
  let differs = probe.observe(sequence:3,timestamp:2,payload:Data([98,1,65,1,8]))!
  precondition(!differs.consistent && !differs.contiguous)
  precondition(probe.observe(sequence:4,timestamp:2,payload:Data([98,1,65,1,8])) == nil)
  print("FU candidate consistency, sequence wrap/gap and orphan end checks passed")
 }
}
