//
//  LabelPainter.swift — brush, line and flood fill on one slice of a label grid, for drawing
//  a segmentation by hand. Pure functions on the grid; DrawingViewModel owns undo and timing.
//

import Foundation

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

    /// The slice's labels, row by row (for undo).
    static func read(_ grid: LabelGrid, plane: SlicePlane) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: plane.width * plane.height)
        grid.data.withUnsafeBufferPointer { d in
            for v in 0..<plane.height { for c in 0..<plane.width { out[v * plane.width + c] = d[plane.voxel(c, v)] } }
        }
        return out
    }

    static func write(_ grid: LabelGrid, plane: SlicePlane, _ values: [UInt8]) {
        grid.data.withUnsafeMutableBufferPointer { d in
            for v in 0..<plane.height { for c in 0..<plane.width { d[plane.voxel(c, v)] = values[v * plane.width + c] } }
        }
    }
}
