//
//  band_repair_check.swift — self-check for the banding repair (BandRepair.repaired).
//  Build & run: mkdir -p /tmp/br && cp spike/band_repair_check.swift /tmp/br/main.swift &&
//    swiftc NiiMono/Models/BandRepair.swift /tmp/br/main.swift -o /tmp/br/check && /tmp/br/check
//

import Foundation

let dims = (3, 2, 8), plane = 6
func at(_ x: Int, _ y: Int, _ z: Int) -> Int { x + 3 * (y + 2 * z) }
// Intensity rises 10 per slice; slices 3 and 4 are a bright band (+500).
var data = [Float](repeating: 0, count: 48)
for z in 0..<8 { for y in 0..<2 { for x in 0..<3 { data[at(x, y, z)] = Float(10 * z + x) + (z == 3 || z == 4 ? 500 : 0) } } }
var mask = [UInt8](repeating: 0, count: 48)
for y in 0..<2 { for x in 0..<2 { mask[at(x, y, 3)] = 1; mask[at(x, y, 4)] = 1 } } // column x = 2 left unpainted

let r = BandRepair.repaired(data: data, mask: mask, dims: dims)
precondition(r.indices.count == 8, "\(r.indices.count) repaired")
for (i, v) in zip(r.indices, r.values) {
    let x = Int(i) % 3, z = Int(i) / plane
    precondition(abs(v - Float(10 * z + x)) < 1e-4, "voxel \(i): \(v), expected \(10 * z + x)") // the line through z 2 and 5
}
precondition(!r.indices.contains(Int32(at(2, 0, 3))), "an unpainted voxel was repaired")

// Edges: a band touching the bottom copies the slice above; a fully painted column is left alone.
var edge = [UInt8](repeating: 0, count: 48)
edge[at(0, 0, 0)] = 1
for z in 0..<8 { edge[at(1, 1, z)] = 1 }
let e = BandRepair.repaired(data: data, mask: edge, dims: dims)
precondition(e.indices == [Int32(at(0, 0, 0))] && e.values == [data[at(0, 0, 1)]], "\(e)")
print("band repair ok")
