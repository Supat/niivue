//
//  nifti_check.swift — runnable self-check for the NIfTI reader (money path).
//  Build & run:  swiftc NiiMono/NIfTI.swift spike/nifti_check.swift -O -o /tmp/ncheck && /tmp/ncheck <file.nii.gz>
//

import Foundation

// 1. Synthetic in-memory NIfTI-1 (little-endian, INT16) — exercises header
//    parsing, datatype decode and scl_slope/inter with a known answer.
func makeSyntheticNifti(flipXSwapYZ: Bool = false, bigEndian: Bool = false) -> Data {
    var d = Data(count: 352)
    func putI32(_ off: Int, _ v: Int32) { var x = bigEndian ? v.bigEndian : v.littleEndian; withUnsafeBytes(of: &x) { d.replaceSubrange(off..<off+4, with: $0) } }
    func putI16(_ off: Int, _ v: Int16) { var x = bigEndian ? v.bigEndian : v.littleEndian; withUnsafeBytes(of: &x) { d.replaceSubrange(off..<off+2, with: $0) } }
    func putF32(_ off: Int, _ v: Float) { var x = bigEndian ? v.bitPattern.bigEndian : v.bitPattern.littleEndian; withUnsafeBytes(of: &x) { d.replaceSubrange(off..<off+4, with: $0) } }
    putI32(0, 348)            // sizeof_hdr
    putI16(40, 3)             // dim[0] = ndim
    putI16(42, 2); putI16(44, 2); putI16(46, 2) // 2x2x2
    putI16(70, 4)             // datatype INT16
    putI16(72, 16)            // bitpix
    putF32(80, 1); putF32(84, 1); putF32(88, 1) // pixdim
    putF32(108, 352)          // vox_offset
    putF32(112, 2); putF32(116, 10) // scl_slope=2, scl_inter=10
    if flipXSwapYZ {          // sform: file x → Left, file y → Superior, file z → Anterior
        putI16(254, 1)
        putF32(280, -1); putF32(296 + 8, 1); putF32(312 + 4, 1)
    }
    // 8 voxels, raw int16 values 0..7 -> scaled = raw*2+10 = 10..24
    for i in 0..<8 { var v = bigEndian ? Int16(i).bigEndian : Int16(i).littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
    return d
}

func assert(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL: \(msg)"); exit(1) }
    print("  ok: \(msg)")
}

print("== synthetic NIfTI ==")
let syn = try NIfTI.parse(makeSyntheticNifti())
assert(syn.dims == (2,2,2), "dims parsed = \(syn.dims)")
assert(syn.voxelCount == 8, "voxelCount = \(syn.voxelCount)")
assert(syn.data.first == 10, "scl applied to v0: \(syn.data.first ?? -1) == 10")          // 0*2+10
assert(syn.data.last == 24, "scl applied to v7: \(syn.data.last ?? -1) == 24")            // 7*2+10
assert(syn.dataMin == 10 && syn.dataMax == 24, "data range = [\(syn.dataMin),\(syn.dataMax)]")

// Reorientation to RAS: file voxel (i,j,k) has raw value i+2j+4k and must land at
// RAS (1-i, k, j), so RAS (x,y,z) holds raw (1-x) + 2z + 4y.
print("== reorientation ==")
let ras = try NIfTI.parse(makeSyntheticNifti(flipXSwapYZ: true))
for z in 0..<2 { for y in 0..<2 { for x in 0..<2 {
    let want = Float((1 - x) + 2 * z + 4 * y) * 2 + 10
    assert(ras.data[x + 2 * (y + 2 * z)] == want, "RAS(\(x),\(y),\(z)) == \(want)")
} } }
// Axial slice z=0, window = raw range: row 0 is anterior (y=1), column 0 is left (x=0).
let ax = ras.slice(axis: 2, index: 0, lo: 10, hi: 24)
assert(ax.width == 2 && ax.height == 2, "axial slice is 2x2")
assert(ax.pixels == [UInt8(255 * 5 / 7), UInt8(255 * 4 / 7), UInt8(255 * 1 / 7), 0].map { $0 }, "axial pixels oriented: \(ax.pixels)")

// 2. Real file (gzip + real header) if a path is given.
if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    print("== real file: \(url.lastPathComponent) ==")
    let t = Date()
    let vol = try NIfTI.load(contentsOf: url)
    let ms = Int(Date().timeIntervalSince(t) * 1000)
    print("  dims        = \(vol.dims)")
    print("  voxelSize   = \(vol.voxelSize) mm")
    print("  voxelCount  = \(vol.voxelCount)")
    print("  range       = [\(vol.displayMin), \(vol.displayMax)]")
    print("  load+gunzip = \(ms) ms")
    assert(vol.voxelCount == vol.data.count, "data length matches voxel count")
    assert(vol.dims.0 > 1 && vol.dims.1 > 1 && vol.dims.2 > 1, "plausible 3D dims")
    assert(vol.displayMax > vol.displayMin, "non-degenerate intensity range")
}

// 2b. Big-endian file: the scalar (byte-swapping) path must agree with the vDSP row path.
print("== big-endian ==")
let be = try NIfTI.parse(makeSyntheticNifti(flipXSwapYZ: true, bigEndian: true))
assert(be.data == ras.data, "big-endian parse equals little-endian parse")

// 3. Label parsing shares the reorientation: same synthetic file read as labels.
print("== labels ==")
let lab = try NIfTI.parseLabels(makeSyntheticNifti(flipXSwapYZ: true))
assert(lab.maxLabel == 7, "max label = \(lab.maxLabel)")
assert(lab.data[1 + 2 * (0 + 2 * 0)] == 0, "RAS(1,0,0) holds raw 0")
assert(lab.data[0 + 2 * (1 + 2 * 1)] == 7, "RAS(0,1,1) holds raw 7")
// Labels above 255 (FreeSurfer-style ids) become 0, not 255: scl_slope=2/inter=10 is ignored
// for labels, so scale the raw values up through a wider synthetic: reuse the int16 file with
// raw 0...7 → values are the raw ints; craft one voxel at 300 by patching the bytes.
var big = makeSyntheticNifti()
big[352 + 2 * 7] = UInt8(300 & 0xff); big[352 + 2 * 7 + 1] = UInt8(300 >> 8)
let labBig = try NIfTI.parseLabels(big)
assert(labBig.data[7] == 0 && labBig.maxLabel == 6, "label 300 → 0, max label \(labBig.maxLabel)")

print("ALL CHECKS PASSED")
