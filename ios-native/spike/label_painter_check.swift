//
//  label_painter_check.swift — self-check for the drawing tools (LabelPainter).
//  Build & run: mkdir -p /tmp/lp && cp spike/label_painter_check.swift /tmp/lp/main.swift &&
//    swiftc NiiMono/Models/{NIfTI,SegmentationMap,LabelTable,LabelPainter}.swift /tmp/lp/main.swift -o /tmp/lp/check && /tmp/lp/check
//

import Foundation

let dims = (20, 30, 10)
func grid() -> LabelGrid { LabelGrid(LabelVolume(dims: dims, data: [UInt8](repeating: 0, count: 20 * 30 * 10), maxLabel: 0)) }
func count(_ g: LabelGrid, _ v: UInt8) -> Int { g.data.reduce(0) { $0 + ($1 == v ? 1 : 0) } }

// Plane addressing matches the slice views: axial (z fixed) c = x, v = y.
let axial = SlicePlane(axis: 2, index: 4, dims: dims)
precondition(axial.voxel(3, 5) == 3 + 20 * (5 + 30 * 4))
let coronal = SlicePlane(axis: 1, index: 7, dims: dims) // c = x, v = z
precondition(coronal.voxel(3, 5) == 3 + 20 * (7 + 30 * 5) && coronal.z(rows: 2...5) == 2..<6)
let sagittal = SlicePlane(axis: 0, index: 2, dims: dims) // c = y, v = z
precondition(sagittal.voxel(3, 5) == 2 + 20 * (3 + 30 * 5) && (sagittal.width, sagittal.height) == (30, 10))

// Stamp: a radius-2 disk is 12–13 voxels (pixel centres within the circle), on one slice only;
// the rows reported are its bounding box.
var g = grid()
let rows = LabelPainter.stamp(g, plane: axial, at: SIMD2(10, 10), radius: SIMD2(2, 2), value: 3)
precondition(rows == 8...12, "\(String(describing: rows))")
let disk = count(g, 3)
precondition((12...13).contains(disk), "disk \(disk)")
precondition(LabelPainter.read(g, plane: SlicePlane(axis: 2, index: 5, dims: dims)).allSatisfy { $0 == 0 })
// A tiny brush still paints the voxel under the tip.
g = grid(); LabelPainter.stamp(g, plane: axial, at: SIMD2(0.2, 0.2), radius: SIMD2(0.1, 0.1), value: 1)
precondition(count(g, 1) == 1 && g.data[axial.voxel(0, 0)] == 1)

// Line: a fast stroke leaves no gaps (every column along the row is painted).
g = grid(); LabelPainter.line(g, plane: axial, from: SIMD2(1, 15), to: SIMD2(18, 15), radius: SIMD2(0.6, 0.6), value: 2)
precondition((1...18).allSatisfy { g.data[axial.voxel($0, 15)] == 2 })

// Fill inside a closed square outline: interior only, outside untouched.
g = grid()
for i in 5...15 { for (c, v) in [(i, 5), (i, 15), (5, i), (15, i)] { g.data[axial.voxel(c, v)] = 1 } }
LabelPainter.fill(g, plane: axial, at: 10, 10, value: 1)
precondition(count(g, 1) == 11 * 11, "filled \(count(g, 1))")
precondition(g.data[axial.voxel(2, 2)] == 0)
// Filling with the seed's own value does nothing.
precondition(LabelPainter.fill(g, plane: axial, at: 10, 10, value: 1) == nil)

// Undo round trip: read → paint → write restores the slice exactly.
g = grid(); let before = LabelPainter.read(g, plane: coronal)
LabelPainter.stamp(g, plane: coronal, at: SIMD2(5, 5), radius: SIMD2(3, 3), value: 4)
precondition(count(g, 4) > 0)
LabelPainter.write(g, plane: coronal, before)
precondition(count(g, 4) == 0)

print("label painter ok")
