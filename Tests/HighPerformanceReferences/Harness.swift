import Foundation
struct Writer {
 var b:[Bool] = []
 mutating func bit(_ value:Bool) { b.append(value) }
 mutating func put(_ value:Int,_ count:Int) { for n in (0..<count).reversed() { bit(value & (1 << n) != 0) } }
 mutating func ue(_ value:Int) { let count = Int.bitWidth - (value + 1).leadingZeroBitCount; put(0,count-1); put(value+1,count) }
 func nal(_ type:Int) -> Data {
    var bits=b; bits.append(true); while bits.count%8 != 0 { bits.append(false) }
    var out=Data([UInt8(type << 1),1]), zeros=0
    for i in stride(from:0,to:bits.count,by:8) {
      let byte=bits[i..<i+8].reduce(UInt8(0)) { ($0 << 1) | ($1 ? 1 : 0) }
      if zeros >= 2 && byte <= 3 { out.append(3); zeros=0 }
      out.append(byte); zeros=byte == 0 ? zeros+1 : 0
    }
    return out
 }
}
func sps() -> Data {
 var w=Writer(); w.put(0,4);w.put(0,3);w.bit(true)
 for _ in 0..<12 { w.put(0,8) }
 w.ue(0);w.ue(1);w.ue(128);w.ue(128);w.bit(false);w.ue(0);w.ue(0);w.ue(4)
 w.bit(false);w.ue(4);w.ue(0);w.ue(0)
 for _ in 0..<6 { w.ue(0) }
 w.bit(false);w.bit(false);w.bit(false);w.bit(false);w.ue(0);w.bit(true);w.ue(0)
 return w.nal(33)
}
func pps() -> Data { var w=Writer(); w.ue(0);w.ue(0);w.bit(false);w.bit(false);w.put(0,3);return w.nal(34) }
func frame(_ poc:Int, idr:Bool=false, delta:Int?=nil, long:Int?=nil) -> Data {
 var w=Writer();w.bit(true);if idr { w.bit(false) };w.ue(0);w.ue(idr ? 2 : 1)
 if !idr {
  w.put(poc,8);w.bit(false);w.ue(delta == nil ? 0 : 1);w.ue(0)
  if let delta { w.ue(delta-1);w.bit(true) }
  w.ue(long == nil ? 0 : 1)
  if let long { w.put(long,8);w.bit(true);w.bit(false) }
 }
 return w.nal(idr ? 19 : 1)
}
@main struct Harness {
 static func main() throws {
  var guarder=AppleHPHEVCReferenceGuard()
  let idr=try guarder.prepare([sps(),pps(),frame(0,idr:true)]);precondition(guarder.decoded(idr))
  let one=try guarder.prepare([frame(1,delta:1)])
  do { _=try guarder.prepare([frame(2,delta:1)]);fatalError("uncommitted picture counted clean") } catch AppleHPHEVCReferenceGuard.Failure.missingReference {}
  precondition(guarder.decoded(one))
  do { _=try guarder.prepare([frame(3,delta:1)]);fatalError("lost reference accepted") } catch AppleHPHEVCReferenceGuard.Failure.missingReference {}
  let recovered=try guarder.prepare([frame(4,long:0)])
  precondition(recovered.references == Set([0]) && guarder.decoded(recovered))
  do { _=try guarder.prepare([frame(5,long:1)]);fatalError("retired DPB reference accepted") } catch AppleHPHEVCReferenceGuard.Failure.missingReference {}
  let next=try guarder.prepare([frame(5,delta:1)]);precondition(guarder.decoded(next))
  var changed = pps(); changed.append(0)
  do { _ = try guarder.prepare([changed,frame(6,delta:1)]); fatalError("PPS change retained old clean references") }
  catch AppleHPHEVCReferenceGuard.Failure.missingReference {}
  precondition(!guarder.decoded(next), "format change must invalidate pending decode callback")
  guarder.reset();precondition(!guarder.decoded(next))
  let fresh = try guarder.prepare([sps(),pps(),frame(0,idr:true)])
  precondition(!guarder.decoded(idr), "old decode callback cannot cross a reset")
  precondition(guarder.decoded(fresh))
  do { _=try guarder.prepare([Data([66,1,0])]);fatalError("truncated SPS accepted") } catch {}
  // Genuine encoded stream validates that the bit parser matches encoder output.
  if CommandLine.arguments.count > 1 {
   let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
   var starts: [(Int,Int)] = []; var index = 0
   while index + 3 < bytes.count {
    if Array(bytes[index..<index+3]) == [0,0,1] { starts.append((index,index+3));index += 3 }
    else if index + 4 < bytes.count && Array(bytes[index..<index+4]) == [0,0,0,1] { starts.append((index,index+4));index += 4 }
    else { index += 1 }
   }
   var actual = AppleHPHEVCReferenceGuard(), pending: [Data] = []; var count = 0
   for n in starts.indices {
    let unit = Data(bytes[starts[n].1..<(n+1 < starts.count ? starts[n+1].0 : bytes.count)])
    guard unit.count >= 3 else { continue }
    if (unit[0] >> 1) & 63 < 32 {
     let picture = try actual.prepare(pending + [unit]); precondition(actual.decoded(picture))
     pending = []; count += 1
    } else { pending.append(unit) }
   }
   precondition(count == 120)
  }
  print("Clean decode commit, missing-reference rejection, LTR P-frame recovery, DPB retirement and reset passed")
 }
}
