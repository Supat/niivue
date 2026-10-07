//
//  scan_repair_check.swift — self-check for the scan repair (ScanRepair: band and blemish fills).
//  Build & run: mkdir -p /tmp/br && cp spike/scan_repair_check.swift /tmp/br/main.swift &&
//    swiftc NiiMono/Models/LabelPainter.swift NiiMono/Models/ScanRepair.swift /tmp/br/main.swift -o /tmp/br/check && /tmp/br/check
//

import Foundation

let dims = (3, 2, 8), plane = 6
func at(_ x: Int, _ y: Int, _ z: Int) -> Int { x + 3 * (y + 2 * z) }
// Intensity rises 10 per slice; slices 3 and 4 are a bright band (+500).
var data = [Float](repeating: 0, count: 48)
for z in 0..<8 { for y in 0..<2 { for x in 0..<3 { data[at(x, y, z)] = Float(10 * z + x) + (z == 3 || z == 4 ? 500 : 0) } } }
var mask = [UInt8](repeating: 0, count: 48)
for y in 0..<2 { for x in 0..<2 { mask[at(x, y, 3)] = 1; mask[at(x, y, 4)] = 1 } } // column x = 2 left unpainted

let r = ScanRepair.repaired(data: data, mask: mask, dims: dims, background: 0)
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
let e = ScanRepair.repaired(data: data, mask: edge, dims: dims, background: 0)
precondition(e.indices == [Int32(at(0, 0, 0))] && e.values == [data[at(0, 0, 1)]], "\(e)")
print("band repair ok")

// Blemish: a bright streak inside a smooth gradient is filled back to the gradient from its
// own slice; the voxels around it don't change.
let hd = (4, 3, 8)
func hat(_ x: Int, _ y: Int, _ z: Int) -> Int { x + 4 * (y + 3 * z) }
var vol = [Float](repeating: 0, count: 96)
for z in 0..<8 { for y in 0..<3 { for x in 0..<4 { vol[hat(x, y, z)] = Float(10 * z + 3 * x + y) } } }
var bl = [UInt8](repeating: 0, count: 96)
for x in 1..<3 { vol[hat(x, 1, 4)] += 400; bl[hat(x, 1, 4)] = ScanRepair.blemish(axis: 2) } // a streak along x at y 1, painted on axial slice z 4
let fixed = ScanRepair.repaired(data: vol, mask: bl, dims: hd, background: 0)
precondition(fixed.indices.count == 2, "\(fixed.indices.count) healed")
for (i, v) in zip(fixed.indices, fixed.values) {
    let x = Int(i) % 4
    let want = Float(10 * 4 + 3 * x + 1) // the gradient's own value
    precondition(abs(v - want) < 0.05, "voxel \(i): \(v), expected \(want)")
}
// Band and blemish together: the band rule only reads unpainted voxels, so a blemish next
// to a band isn't used as a band's source; both get repaired.
var both = bl
for x in 1..<3 { both[hat(x, 0, 4)] = ScanRepair.band }
let r2 = ScanRepair.repaired(data: vol, mask: both, dims: hd, background: 0)
precondition(r2.indices.count == 4, "\(r2.indices.count)")
print("scan repair ok")

// In-plane: the slices either side carry the same streak, and the fill ignores them.
var slab = vol
for z in 3...5 { for x in 1..<3 { slab[hat(x, 1, z)] += 400 } }
var one = [UInt8](repeating: 0, count: 96)
for x in 1..<3 { one[hat(x, 1, 4)] = ScanRepair.blemish(axis: 2) }
let inPlane = ScanRepair.repaired(data: slab, mask: one, dims: hd, background: 0)
for (i, v) in zip(inPlane.indices, inPlane.values) {
    let x = Int(i) % 4
    precondition(abs(v - Float(10 * 4 + 3 * x + 1)) < 0.05, "voxel \(i): \(v) — the neighbouring slices' streak leaked in")
}
print("in-plane blemish ok")

// Cut: painted voxels go to the background value, and a blemish next to a cut is filled from
// the cut (background) on that side.
var cm = [UInt8](repeating: 0, count: 96)
cm[hat(1, 1, 4)] = ScanRepair.cut; cm[hat(2, 1, 4)] = ScanRepair.blemish(axis: 2)
let cr = ScanRepair.repaired(data: vol, mask: cm, dims: hd, background: -7)
precondition(cr.indices.count == 2)
precondition(cr.values[cr.indices.firstIndex(of: Int32(hat(1, 1, 4)))!] == -7, "cut voxel not background")
print("cut ok")
