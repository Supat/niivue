//
//  oblique_check.swift — self-check for the oblique slice (ObliquePlane, NiftiVolume.obliqueSlice).
//  Build & run: mkdir -p /tmp/ob && cp spike/oblique_check.swift /tmp/ob/main.swift &&
//    swiftc NiiMono/Models/{NIfTI,ViewerTypes}.swift /tmp/ob/main.swift -O -o /tmp/ob/check && /tmp/ob/check
//

import Foundation
import simd

func volume(_ dims: (Int, Int, Int), voxel: (Float, Float, Float)) -> NiftiVolume {
    var d = [Float](repeating: 0, count: dims.0 * dims.1 * dims.2)
    for z in 0..<dims.2 { for y in 0..<dims.1 { for x in 0..<dims.0 { d[x + dims.0 * (y + dims.1 * z)] = Float(x + 100 * y + 10000 * z) } } }
    return NiftiVolume(dims: dims, voxelSize: voxel, data: d, dataMin: 0, dataMax: 1e5, displayMin: 0, displayMax: 1e5)
}
func oblique(_ v: NiftiVolume, _ p: ObliquePlane) -> (width: Int, height: Int, pixels: [UInt8], voxel: [Int32]) {
    let f = p.frame(dims: v.dims, voxelSize: v.voxelSize)
    return v.obliqueSlice(centre: f.centre, u: f.u, v: f.v, pitch: f.pitch, width: f.width, height: f.height, lo: 0, hi: 1e5)
}
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { length(a - b) < 1e-4 }

let v = volume((30, 20, 10), voxel: (1, 1, 1))
// 1. Untilted axial at slice 7 = the axial slice, voxel for voxel.
let k = 7
let ax = oblique(v, ObliquePlane(base: .axial, pos: (Float(k) + 0.5) / 10)), ref = v.slice(axis: 2, index: k, lo: 0, hi: 1e5)
assert((ax.width, ax.height) == (ref.width, ref.height) && ax.pixels == ref.pixels, "untilted axial ≠ axial slice")
assert(ax.voxel[0] == Int32(0 + 30 * (19 + 20 * k)), "top-left voxel: row 0 is the top (y = ny − 1)")
// 2. Sagittal turned 90° about S–I faces anterior: the coronal slice, mirrored across.
let j = 4
let co = oblique(v, ObliquePlane(base: .sagittal, tilt: SIMD2(0, 90), pos: (Float(j) + 0.5) / 20)), cref = v.slice(axis: 1, index: j, lo: 0, hi: 1e5)
assert((co.width, co.height) == (cref.width, cref.height), "turned sagittal size \(co.width)×\(co.height) ≠ coronal \(cref.width)×\(cref.height)")
for r in 0..<co.height { assert(Array(co.pixels[r * co.width..<(r + 1) * co.width]) == Array(cref.pixels[r * co.width..<(r + 1) * co.width]).reversed(), "turned sagittal ≠ mirrored coronal, row \(r)") }
// 3. Outside the volume is black and unlabelled; a 45° tilt still covers the whole volume.
let t = oblique(v, ObliquePlane(base: .axial, tilt: SIMD2(45, 0)))
assert(t.voxel.contains(-1) && t.voxel.contains { $0 >= 0 }, "tilted plane: some pixels in, some out")
assert(zip(t.pixels, t.voxel).allSatisfy { $0.1 >= 0 || $0.0 == 0 }, "outside pixels are black")
let f45 = ObliquePlane(base: .axial, tilt: SIMD2(45, 0)).frame(dims: v.dims, voxelSize: v.voxelSize)
assert(abs(f45.depth - (20 + 10) / Float(2).squareRoot()) < 1e-3, "depth along a 45° normal = (ny + nz)/√2")
// 4. Anisotropic voxels: pixels are the smallest voxel side, so the image is in mm.
let fa = ObliquePlane(base: .sagittal).frame(dims: (30, 20, 10), voxelSize: (1, 1, 2))
assert(fa.pitch == 1 && (fa.width, fa.height) == (20, 20), "sagittal of 1×1×2 mm voxels: 20 × 20 pixels of 1 mm")

// 5. A plane through a line holds the line, with the line laid out as documented.
/// `lineUp`: the line runs up the image (else across); `other` is the image's other axis.
func check(_ a: SIMD3<Float>, _ b: SIMD3<Float>, view: Int, lineUp: Bool, other: SIMD3<Float>) {
    let p = ObliquePlane.through(a, b, viewAxis: view, dims: v.dims, voxelSize: v.voxelSize)!
    let f = p.frame(dims: v.dims, voxelSize: v.voxelSize)
    assert(abs(dot(a - f.centre, f.normal)) < 1e-3 && abs(dot(b - f.centre, f.normal)) < 1e-3, "view \(view): plane misses the line")
    let s = normalize(b - a), along = lineUp ? f.v : f.u
    assert(near(along, s) || near(along, -s), "view \(view): line not along the expected image axis")
    assert(near(other, lineUp ? f.u : f.v), "view \(view): other image axis ≠ expected")
    assert(abs(p.tilt.x) <= 90 && abs(p.tilt.y) <= 90, "tilts within the sliders' ±90°")
}
check([2, 3, 5], [12, 13, 5], view: 2, lineUp: false, other: [0, 0, 1])   // axial line: across, superior up
check([12, 13, 5], [2, 3, 5], view: 2, lineUp: false, other: [0, 0, 1])   // drawn the other way: the same plane
check([2, 5, 1], [12, 5, 9], view: 1, lineUp: true, other: [0, 1, 0])     // coronal line: up, A–P across
check([5, 2, 1], [5, 12, 9], view: 0, lineUp: true, other: [1, 0, 0])     // sagittal line: up, L–R across
let up = ObliquePlane.through([2, 5, 9], [12, 5, 1], viewAxis: 1, dims: v.dims, voxelSize: v.voxelSize)!.frame(dims: v.dims, voxelSize: v.voxelSize)
assert(up.v.z > 0, "the line's superior end is up")
assert(ObliquePlane.through([1, 1, 1], [1, 1, 1], viewAxis: 2, dims: v.dims, voxelSize: v.voxelSize) == nil, "a dot is no line")

// 6. Speed on a whole-body-sized volume, tilted.
let big = volume((256, 192, 640), voxel: (1.5, 1.5, 1.5))
let t0 = Date()
let bs = oblique(big, ObliquePlane(base: .coronal, tilt: SIMD2(20, 10)))
let ms = Date().timeIntervalSince(t0) * 1000
print("oblique ok: \(bs.width)×\(bs.height) px of a 256×192×640 volume in \(Int(ms)) ms")
