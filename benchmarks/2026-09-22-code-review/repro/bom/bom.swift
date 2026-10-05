import Foundation
let bom = Data([0xEF,0xBB,0xBF,0x41])
let s = String(data: bom, encoding: .utf8)!
print("data:", s.unicodeScalars.map{String($0.value,radix:16)}, Array(s.utf8).count)
let s2 = String(bytes: [0xEF,0xBB,0xBF] as [UInt8], encoding: .utf8)
print("bytes-only-bom:", s2.map{ Array($0.utf8) } as Any, s2?.isEmpty as Any)
print("UInt8 +f:", UInt8("+f", radix:16) as Any, "UInt8 -1:", UInt8("-1", radix:16) as Any)
