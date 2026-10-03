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
precondition(LabelPainter.read(g, box: SlicePlane(axis: 2, index: 5, dims: dims).box).allSatisfy { $0 == 0 })
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
g = grid(); let before = LabelPainter.read(g, box: coronal.box)
LabelPainter.stamp(g, plane: coronal, at: SIMD2(5, 5), radius: SIMD2(3, 3), value: 4)
precondition(count(g, 4) > 0)
LabelPainter.write(g, box: coronal.box, before)
precondition(count(g, 4) == 0)

print("label painter ok")

// Box read/write round trip, and a slice's box matches its plane.
g = grid()
LabelPainter.stamp(g, plane: coronal, at: SIMD2(5, 5), radius: SIMD2(3, 3), value: 4)
let box = coronal.box
precondition(box.lo == SIMD3(0, 7, 0) && box.hi == SIMD3(20, 8, 10))
let saved = LabelPainter.read(g, box: box)
LabelPainter.write(g, box: box, [UInt8](repeating: 0, count: box.count))
precondition(count(g, 4) == 0)
LabelPainter.write(g, box: box, saved)
precondition(count(g, 4) > 0)

// Smoothing: a 1-voxel spike on a cube goes, the cube stays (about the same volume), and a
// second label elsewhere keeps its own voxels.
let sd = (40, 40, 40)
var vol = [UInt8](repeating: 0, count: 40 * 40 * 40)
func at(_ x: Int, _ y: Int, _ z: Int) -> Int { x + 40 * (y + 40 * z) }
for z in 10..<26 { for y in 10..<26 { for x in 10..<26 { vol[at(x, y, z)] = 1 } } }
vol[at(26, 17, 17)] = 1; vol[at(27, 17, 17)] = 1 // spike
for z in 30..<38 { for y in 30..<38 { for x in 30..<38 { vol[at(x, y, z)] = 2 } } }
let cubeBefore = vol.filter { $0 == 1 }.count
let sm = LabelPainter.smoothed(vol, dims: sd, voxelSize: SIMD3(1, 1, 1), sigmaMM: 1, labels: [1, 2])!
var after = vol
let sg = LabelGrid(LabelVolume(dims: sd, data: after, maxLabel: 2))
LabelPainter.write(sg, box: sm.box, sm.values)
after = sg.data
precondition(after[at(27, 17, 17)] == 0 && after[at(26, 17, 17)] == 0, "spike survived")
precondition(after[at(17, 17, 17)] == 1 && after[at(33, 33, 33)] == 2, "interiors lost")
let cubeAfter = after.filter { $0 == 1 }.count
precondition(Double(cubeAfter) > 0.85 * Double(cubeBefore) && cubeAfter <= cubeBefore, "cube \(cubeBefore) → \(cubeAfter)")
precondition(after[at(5, 5, 5)] == 0 && after.filter { $0 == 2 }.count > 300)
// Anisotropic voxels: σ in mm, so 3 mm slices blur less along z than 1 mm pixels along x.
precondition(LabelPainter.smoothed([UInt8](repeating: 0, count: 8), dims: (2, 2, 2), voxelSize: SIMD3(1, 1, 3), sigmaMM: 1, labels: [1]) == nil)
print("smoothing ok: cube \(cubeBefore) → \(cubeAfter)")

// Copying labels into the drawing: relabel (others become 0), then fill only the drawing's
// unlabelled voxels.
let copied = LabelPainter.relabelled([0, 1, 2, 3, 2, 1, 255, 3], dims: (4, 2, 1), mapping: [1: 5, 3: 6])
precondition(copied == [0, 5, 0, 6, 0, 5, 0, 6], "\(copied)")
let merged = LabelPainter.fillingUnlabelled([0, 0, 9, 9, 0, 0, 0, 0], from: copied, rowLength: 4)
precondition(merged == [0, 5, 9, 9, 0, 5, 0, 6], "\(merged)")
precondition(LabelPainter.fillingUnlabelled([1, 2, 3, 4], from: [0, 0, 0, 0], rowLength: 4) == [1, 2, 3, 4])
print("copy ok")

// Smoothing one label leaves the others exactly as they were, and doesn't grow into them.
var two = [UInt8](repeating: 0, count: 40 * 40 * 40)
for z in 10..<26 { for y in 10..<26 { for x in 10..<26 { two[at(x, y, z)] = 1 } } }
for z in 10..<26 { for y in 10..<26 { for x in 26..<34 { two[at(x, y, z)] = 2 } } }   // touching block
for z in 14..<22 { for y in 14..<22 { two[at(20, y, z)] = 2 } }                     // a slab of 2 inside 1
two[at(9, 17, 17)] = 1                                                                // a bump on 1
let one = LabelPainter.smoothed(two, dims: sd, voxelSize: SIMD3(1, 1, 1), sigmaMM: 1.5, labels: [1])!
let tg = LabelGrid(LabelVolume(dims: sd, data: two, maxLabel: 2))
LabelPainter.write(tg, box: one.box, one.values)
precondition((0..<two.count).allSatisfy { (two[$0] == 2) == (tg.data[$0] == 2) }, "label 2 changed")
precondition(tg.data[at(9, 17, 17)] == 0 && tg.data[at(15, 15, 15)] == 1, "label 1 not smoothed")
print("single-label smoothing ok")

// Smoothing a region only: outside it (grown by the kernel radius) nothing changes.
var reg = [UInt8](repeating: 0, count: 40 * 40 * 40)
for z in 5..<35 { for y in 10..<26 { for x in 10..<26 { reg[at(x, y, z)] = 1 } } }
reg[at(9, 17, 8)] = 1; reg[at(9, 17, 30)] = 1                            // bumps low and high in z
let region = VoxelBox(lo: SIMD3(0, 0, 25), hi: SIMD3(40, 40, 35))       // the "edited" part, z 25..<35
let part = LabelPainter.smoothed(reg, dims: sd, voxelSize: SIMD3(1, 1, 1), sigmaMM: 1, labels: [1], region: region)!
precondition(part.box.lo.z >= 25 - 3, "box \(part.box)")
let pg = LabelGrid(LabelVolume(dims: sd, data: reg, maxLabel: 1))
LabelPainter.write(pg, box: part.box, part.values)
precondition(pg.data[at(9, 17, 30)] == 0, "bump in the region survived")
precondition(pg.data[at(9, 17, 8)] == 1, "bump outside the region was smoothed")
precondition((0..<(40 * 40 * 20)).allSatisfy { pg.data[$0] == reg[$0] }, "below the region changed")
print("region smoothing ok")
