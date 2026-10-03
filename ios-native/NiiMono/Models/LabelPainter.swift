//
//  LabelPainter.swift — brush, line and flood fill on one slice of a label grid, for drawing
//  a segmentation by hand. Pure functions on the grid; DrawingViewModel owns undo and timing.
//

import Accelerate
import Foundation

/// A box of voxels, `lo` inclusive to `hi` exclusive (x, y, z): an undo step's extent.
struct VoxelBox: Equatable {
    var lo: SIMD3<Int>, hi: SIMD3<Int>
    var size: SIMD3<Int> { hi &- lo }
    var count: Int { size.x * size.y * size.z }
    var z: Range<Int> { lo.z..<hi.z }
}

/// One slice of a grid, addressed like the slice views: `c` along the column axis and `v`
/// along the row axis (bottom-up), in voxels (see ViewerViewModel.sliceAxes).
struct SlicePlane: Equatable {
    let axis: Int, index: Int
    let dims: (Int, Int, Int)

    var col: Int { axis == 0 ? 1 : 0 }
    var row: Int { axis == 2 ? 1 : 2 }
    var width: Int { [dims.0, dims.1, dims.2][col] }
    var height: Int { [dims.0, dims.1, dims.2][row] }

    func voxel(_ c: Int, _ v: Int) -> Int {
        let (nx, ny, _) = dims
        switch axis {
        case 0: return index + nx * (c + ny * v)
        case 1: return c + nx * (index + ny * v)
        default: return c + nx * (v + ny * index)
        }
    }

    /// The whole slice as a box.
    var box: VoxelBox {
        var lo = SIMD3(0, 0, 0), hi = SIMD3(dims.0, dims.1, dims.2)
        lo[axis] = index; hi[axis] = index + 1
        return VoxelBox(lo: lo, hi: hi)
    }

    /// The z slices that rows `rows` of this plane lie in.
    func z(rows: ClosedRange<Int>) -> Range<Int> { axis == 2 ? index..<index + 1 : rows.lowerBound..<rows.upperBound + 1 }

    static func == (a: SlicePlane, b: SlicePlane) -> Bool { a.axis == b.axis && a.index == b.index && a.dims == b.dims }
}

enum LabelPainter {
    /// Sets the voxels inside an ellipse (centre `p`, radii `r`, both in voxels) to `value`,
    /// always including the voxel under the centre. Returns the rows touched.
    @discardableResult
    static func stamp(_ grid: LabelGrid, plane: SlicePlane, at p: SIMD2<Float>, radius r: SIMD2<Float>, value: UInt8) -> ClosedRange<Int>? {
        let (w, h) = (plane.width, plane.height)
        let c0 = max(0, Int((p.x - r.x).rounded(.down))), c1 = min(w - 1, Int((p.x + r.x).rounded(.down)))
        let v0 = max(0, Int((p.y - r.y).rounded(.down))), v1 = min(h - 1, Int((p.y + r.y).rounded(.down)))
        guard c0 <= c1, v0 <= v1 else { return nil }
        grid.data.withUnsafeMutableBufferPointer { d in
            for v in v0...v1 {
                let dy = (Float(v) + 0.5 - p.y) / max(r.y, 0.01)
                for c in c0...c1 {
                    let dx = (Float(c) + 0.5 - p.x) / max(r.x, 0.01)
                    if dx * dx + dy * dy <= 1 { d[plane.voxel(c, v)] = value }
                }
            }
            let (c, v) = (Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
            if (0..<w).contains(c), (0..<h).contains(v) { d[plane.voxel(c, v)] = value }
        }
        return v0...v1
    }

    /// Stamps along the segment a → b, close enough that a fast stroke leaves no gaps.
    @discardableResult
    static func line(_ grid: LabelGrid, plane: SlicePlane, from a: SIMD2<Float>, to b: SIMD2<Float>, radius r: SIMD2<Float>, value: UInt8) -> ClosedRange<Int>? {
        let d = b - a
        let steps = max(1, Int((max(abs(d.x) / max(r.x, 0.5), abs(d.y) / max(r.y, 0.5)) * 2).rounded(.up)))
        var rows: ClosedRange<Int>?
        for i in 0...steps {
            if let t = stamp(grid, plane: plane, at: a + d * (Float(i) / Float(steps)), radius: r, value: value) { rows = rows.map { min($0.lowerBound, t.lowerBound)...max($0.upperBound, t.upperBound) } ?? t }
        }
        return rows
    }

    /// Flood fill (4-connected) of the region with the seed's label. Returns the rows touched.
    /// ponytail: fills whatever is connected, so an unclosed outline fills the whole slice
    /// (undo puts it back); bound by intensity if that turns out to bite.
    @discardableResult
    static func fill(_ grid: LabelGrid, plane: SlicePlane, at c: Int, _ v: Int, value: UInt8) -> ClosedRange<Int>? {
        let (w, h) = (plane.width, plane.height)
        guard (0..<w).contains(c), (0..<h).contains(v) else { return nil }
        return grid.data.withUnsafeMutableBufferPointer { d -> ClosedRange<Int>? in
            let target = d[plane.voxel(c, v)]
            guard target != value else { return nil }
            var stack = [(c, v)], lo = v, hi = v
            d[plane.voxel(c, v)] = value
            while let (x, y) = stack.popLast() {
                lo = min(lo, y); hi = max(hi, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < w && ny >= 0 && ny < h && d[plane.voxel(nx, ny)] == target {
                    d[plane.voxel(nx, ny)] = value
                    stack.append((nx, ny))
                }
            }
            return lo...hi
        }
    }

    /// The labels in a box, x fastest (for undo).
    static func read(_ data: [UInt8], dims: (Int, Int, Int), box b: VoxelBox) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: b.count)
        let (nx, ny, _) = dims, w = b.size.x
        data.withUnsafeBytes { d in out.withUnsafeMutableBytes { o in
            var i = 0
            for z in b.lo.z..<b.hi.z { for y in b.lo.y..<b.hi.y {
                (o.baseAddress! + i).copyMemory(from: d.baseAddress! + b.lo.x + nx * (y + ny * z), byteCount: w)
                i += w
            } }
        } }
        return out
    }

    static func read(_ grid: LabelGrid, box: VoxelBox) -> [UInt8] { read(grid.data, dims: grid.dims, box: box) }

    static func write(_ grid: LabelGrid, box b: VoxelBox, _ values: [UInt8]) {
        let (nx, ny, _) = grid.dims, w = b.size.x
        values.withUnsafeBytes { v in grid.data.withUnsafeMutableBytes { d in
            var i = 0
            for z in b.lo.z..<b.hi.z { for y in b.lo.y..<b.hi.y {
                (d.baseAddress! + b.lo.x + nx * (y + ny * z)).copyMemory(from: v.baseAddress! + i, byteCount: w)
                i += w
            } }
        } }
    }

    /// `data` relabelled through `mapping` (labels not in it become 0), through one vImage
    /// table lookup rather than a per-voxel loop (64 M voxels).
    static func relabelled(_ data: [UInt8], dims: (Int, Int, Int), mapping: [Int: Int]) -> [UInt8] {
        let table = (0..<256).map { UInt8(clamping: mapping[$0] ?? 0) }
        var out = data
        out.withUnsafeMutableBytes { p in
            var b = vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(dims.1 * dims.2), width: vImagePixelCount(dims.0), rowBytes: dims.0)
            _ = vImageTableLookUp_Planar8(&b, &b, table, vImage_Flags(kvImageNoFlags))
        }
        return out
    }

    /// `base` with its unlabelled voxels taken from `add` (labelled voxels of `base` win).
    /// Rows of `add` with nothing in them are skipped with a memcmp; the rest go through vDSP
    /// (new = base + (1 - min(base, 1)) · add), not a per-voxel loop.
    static func fillingUnlabelled(_ base: [UInt8], from add: [UInt8], rowLength n: Int) -> [UInt8] {
        var out = base
        var b = [Float](repeating: 0, count: n), a = [Float](repeating: 0, count: n), m = [Float](repeating: 0, count: n)
        var zero: Float = 0, one: Float = 1, negOne: Float = -1
        let zeros = [UInt8](repeating: 0, count: n), nw = vDSP_Length(n)
        add.withUnsafeBufferPointer { ad in out.withUnsafeMutableBufferPointer { o in zeros.withUnsafeBufferPointer { z in
        b.withUnsafeMutableBufferPointer { bf in a.withUnsafeMutableBufferPointer { af in m.withUnsafeMutableBufferPointer { mf in
            let bp = bf.baseAddress!, ap = af.baseAddress!, mp = mf.baseAddress!
            for start in stride(from: 0, to: add.count, by: n) {
                let src = ad.baseAddress! + start, dst = o.baseAddress! + start
                guard memcmp(src, z.baseAddress!, n) != 0 else { continue }
                vDSP_vfltu8(dst, 1, bp, 1, nw)                     // base
                vDSP_vfltu8(src, 1, ap, 1, nw)                     // add
                vDSP_vclip(bp, 1, &zero, &one, mp, 1, nw)          // min(base, 1)
                vDSP_vsmsa(mp, 1, &negOne, &one, mp, 1, nw)        // 1 where base is unlabelled
                vDSP_vma(mp, 1, ap, 1, bp, 1, bp, 1, nw)           // base + m · add
                vDSP_vfixu8(bp, 1, dst, 1, nw)
            }
        } } } } } }
        return out
    }

    // MARK: Smoothing

    /// 3D surface smoothing: each label's mask is blurred with a Gaussian of `sigmaMM` (per
    /// axis in voxels, so anisotropic voxels are handled) and keeps the voxels above one half.
    /// Bumps, steps between drawn slices and pinholes smaller than about σ go; structures
    /// thinner than about σ go too. Returns the changed region and its new labels, or nil if
    /// nothing is labelled.
    /// Every step works a row at a time (memcmp, vDSP): per-voxel Swift loops took ~10 s on a
    /// 64 M-voxel grid in a Debug build; this takes well under one.
    /// ponytail: all labels share the box around everything labelled, and a later label wins
    /// where two overlap after blurring (only at their shared boundary). Memory is two Float
    /// buffers the size of that padded box (a whole-body drawing: ~0.5 GB); work in z slabs
    /// if that bites.
    static func smoothed(_ data: [UInt8], dims: (Int, Int, Int), voxelSize: SIMD3<Float>, sigmaMM: Float, labels: [Int]) -> (box: VoxelBox, values: [UInt8])? {
        let n = SIMD3(dims.0, dims.1, dims.2)
        // Box around everything labelled: empty rows are skipped with one memcmp each, and in
        // the rest only the ends are scanned.
        var lo = n, hi = SIMD3<Int>.zero
        let zeros = [UInt8](repeating: 0, count: n.x)
        data.withUnsafeBufferPointer { d in zeros.withUnsafeBufferPointer { zr in
            var row = d.baseAddress!
            for z in 0..<n.z { for y in 0..<n.y {
                defer { row += n.x }
                guard memcmp(row, zr.baseAddress!, n.x) != 0 else { continue }
                var first = 0, last = n.x - 1
                while row[first] == 0 { first += 1 }
                while row[last] == 0 { last -= 1 }
                lo = pointwiseMin(lo, SIMD3(first, y, z)); hi = pointwiseMax(hi, SIMD3(last + 1, y + 1, z + 1))
            } }
        } }
        guard hi.x > 0, !labels.isEmpty else { return nil }

        // Gaussian kernels and their radii, per axis.
        let sigma = SIMD3(sigmaMM / voxelSize.x, sigmaMM / voxelSize.y, sigmaMM / voxelSize.z)
        let r = SIMD3((0..<3).map { max(1, Int((2.5 * sigma[$0]).rounded(.up))) })
        let kernels: [[Float]] = (0..<3).map { a in
            let s2 = 2 * max(sigma[a], 0.3) * max(sigma[a], 0.3)
            let w = (-r[a]...r[a]).map { exp(-Float($0 * $0) / s2) }
            let s = w.reduce(0, +)
            return w.map { $0 / s }
        }

        // The region any label can reach (rlo..<rhi), and around it a further r of padding
        // (zeros outside the volume) for the convolutions.
        let rlo = pointwiseMax(lo &- r, .zero), rhi = pointwiseMin(hi &+ r, n), rs = rhi &- rlo
        let box = VoxelBox(lo: rlo, hi: rhi)
        var result = read(data, dims: dims, box: box)
        let ps = rs &+ r &* 2, plo = rlo &- r
        var a = [Float](repeating: 0, count: ps.x * ps.y * ps.z)
        var b = [Float](repeating: 0, count: a.count)
        var rowF = [Float](repeating: 0, count: max(ps.x, rs.x))
        var tmp = [Float](repeating: 0, count: rs.x)
        // In-volume part of the padded box, per axis.
        let vlo = pointwiseMax(plo, .zero), vhi = pointwiseMin(plo &+ ps, n)

        for l in labels where (1...255).contains(l) {
            var negValue = -Float(l), one: Float = 1, negOne: Float = -1, zero: Float = 0
            // Mask: 1 where the voxel is l, else 0, i.e. 1 - min(|v - l|, 1).
            vDSP_vclr(&a, 1, vDSP_Length(a.count))
            data.withUnsafeBufferPointer { d in a.withUnsafeMutableBufferPointer { m in rowF.withUnsafeMutableBufferPointer { f in
                let w = vhi.x - vlo.x, nw = vDSP_Length(w)
                for z in vlo.z..<vhi.z { for y in vlo.y..<vhi.y {
                    let src = d.baseAddress! + vlo.x + n.x * (y + n.y * z)
                    let dst = m.baseAddress! + (vlo.x - plo.x) + ps.x * ((y - plo.y) + ps.y * (z - plo.z))
                    vDSP_vfltu8(src, 1, f.baseAddress!, 1, nw)
                    vDSP_vsadd(f.baseAddress!, 1, &negValue, f.baseAddress!, 1, nw)
                    vDSP_vabs(f.baseAddress!, 1, f.baseAddress!, 1, nw)
                    vDSP_vclip(f.baseAddress!, 1, &zero, &one, f.baseAddress!, 1, nw)
                    vDSP_vsmsa(f.baseAddress!, 1, &negOne, &one, dst, 1, nw)
                } }
            } } }
            // x: a (ps) → b (rs.x × ps.y × ps.z)
            a.withUnsafeBufferPointer { s in b.withUnsafeMutableBufferPointer { o in kernels[0].withUnsafeBufferPointer { k in
                for row in 0..<(ps.y * ps.z) {
                    vDSP_conv(s.baseAddress! + row * ps.x, 1, k.baseAddress!, 1, o.baseAddress! + row * rs.x, 1, vDSP_Length(rs.x), vDSP_Length(k.count))
                }
            } } }
            // y: b (rs.x × ps.y × ps.z) → a (rs.x × rs.y × ps.z)
            b.withUnsafeBufferPointer { s in a.withUnsafeMutableBufferPointer { o in kernels[1].withUnsafeBufferPointer { k in
                for z in 0..<ps.z { for x in 0..<rs.x {
                    vDSP_conv(s.baseAddress! + x + rs.x * ps.y * z, rs.x, k.baseAddress!, 1,
                              o.baseAddress! + x + rs.x * rs.y * z, rs.x, vDSP_Length(rs.y), vDSP_Length(k.count))
                } }
            } } }
            // z: a (rs.x × rs.y × ps.z) → b (rs)
            a.withUnsafeBufferPointer { s in b.withUnsafeMutableBufferPointer { o in kernels[2].withUnsafeBufferPointer { k in
                for i in 0..<(rs.x * rs.y) {
                    vDSP_conv(s.baseAddress! + i, rs.x * rs.y, k.baseAddress!, 1, o.baseAddress! + i, rs.x * rs.y, vDSP_Length(rs.z), vDSP_Length(k.count))
                }
            } } }
            // Keep l where the blurred mask is over half, clear l elsewhere, leave other labels:
            // cleared = old - isL·l, new = cleared - keep·(cleared - l). The blurred row is
            // used as scratch once read.
            var half: Float = 0.5
            b.withUnsafeMutableBufferPointer { s in result.withUnsafeMutableBufferPointer { out in
            rowF.withUnsafeMutableBufferPointer { old in tmp.withUnsafeMutableBufferPointer { keep in
                let nw = vDSP_Length(rs.x), o = old.baseAddress!, k = keep.baseAddress!
                var blur = s.baseAddress!, dst = out.baseAddress!
                for _ in 0..<(rs.y * rs.z) {
                    vDSP_vfltu8(dst, 1, o, 1, nw)                     // old labels
                    vDSP_vthrsc(blur, 1, &half, &one, k, 1, nw)       // ±1
                    vDSP_vsmsa(k, 1, &half, &half, k, 1, nw)          // keep: 1 or 0
                    vDSP_vsadd(o, 1, &negValue, blur, 1, nw)          // isL = 1 - min(|old - l|, 1)
                    vDSP_vabs(blur, 1, blur, 1, nw)
                    vDSP_vclip(blur, 1, &zero, &one, blur, 1, nw)
                    vDSP_vsmsa(blur, 1, &negOne, &one, blur, 1, nw)
                    vDSP_vsma(blur, 1, &negValue, o, 1, o, 1, nw)     // cleared
                    vDSP_vsadd(o, 1, &negValue, blur, 1, nw)          // cleared - l
                    vDSP_vmul(blur, 1, k, 1, blur, 1, nw)
                    vDSP_vsub(blur, 1, o, 1, o, 1, nw)                // cleared - keep·(cleared - l)
                    vDSP_vfixu8(o, 1, dst, 1, nw)
                    blur += rs.x; dst += rs.x
                }
            } } } }
        }
        return (box, result)
    }
}
