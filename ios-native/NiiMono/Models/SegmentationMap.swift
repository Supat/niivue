//
//  SegmentationMap.swift — a label map on the scan's grid, with what's known about it.
//

import Accelerate
import Foundation

struct SegmentationMap: Identifiable, @unchecked Sendable {
    let id = UUID()
    let labels: LabelVolume
    let name: String
    var table: LabelTable // replaced for a drawn map once its label names are known
    /// Voxel counts per label ([0] = unlabelled), and how many of those unlabelled voxels are
    /// inside the body (non-zero intensity) — for the body-composition estimate.
    let counts: [Int]
    let unlabelledBodyVoxels: Int
    let voxelML: Double

    /// The map drawn in the app (its label names live in the sidecar).
    var isCustom: Bool { name == LabelTable.customMapName }

    /// Labels a file may carry; empty for a map with nothing labelled.
    var labelRange: Range<Int> { 1..<(labels.maxLabel + 1) }

    /// `volume` is the scan the labels sit on; counting is one pass, do it off the main thread.
    init(labels: LabelVolume, name: String, volume: NiftiVolume, table: LabelTable? = nil) {
        self.labels = labels
        self.name = name
        self.table = table ?? LabelTable.forFile(named: name)
        var counts = [Int](repeating: 0, count: 256), body = 0
        labels.data.withUnsafeBufferPointer { l in volume.data.withUnsafeBufferPointer { v in
            for i in 0..<l.count {
                counts[Int(l[i])] += 1
                if l[i] == 0 && v[i] != 0 { body += 1 }
            }
        } }
        self.counts = counts
        unlabelledBodyVoxels = body
        voxelML = Double(volume.voxelSize.0 * volume.voxelSize.1 * volume.voxelSize.2) / 1000
    }
}

/// What the renderers need to draw a segmentation: the labels, a colour per label
/// (alpha 0 = hidden) and the blend settings.
struct SegmentationOverlay {
    let mapID: UUID
    let labels: LabelGrid
    let lut: [SIMD4<UInt8>] // 256 entries
    let opacity: Float
    let ghost: Bool         // 3D: fade unlabelled tissue so labelled structures show through
    var hideScan = false    // 3D: draw the labels alone
    var mask = false        // slices: black outside the shown labels (3D: with hideScan)
    /// Bumped when a drawing changes the voxels in place; `dirtyZ` is the z slices changed
    /// since the previous revision (nil = unknown, upload everything).
    var revision = 0
    var dirtyZ: Range<Int>? = nil
}

/// Label voxels held by reference, so a drawing can change them in place while views hold
/// the overlay (an array inside a struct would be copied whole, 60+ MB, on every stroke).
final class LabelGrid: @unchecked Sendable {
    let dims: (Int, Int, Int)
    var data: [UInt8]
    init(_ v: LabelVolume) { dims = v.dims; data = v.data } // shares the array until written
}

/// A label the user drew: id 1...255, a name and a colour (0...1 RGB).
struct CustomLabel: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var color: [Float]
    /// Smoothing bookkeeping, so the wand doesn't smooth the same surface twice: whether the
    /// label has been smoothed, and the bricks (LabelPainter.brick³ voxels) edited since.
    var smoothed: Bool? = nil
    var unsmoothedBricks: [Int]? = nil
    /// Locked in the editor: nothing draws over, erases or fills its voxels.
    var locked: Bool? = nil
    /// Hidden in the editor's panes (its voxels stay, and drawing with it still works).
    var hidden: Bool? = nil

}

extension LabelTable {
    /// Name of a map drawn in the app; its label names come from the sidecar, not the file.
    static let customMapName = "Custom drawing"

    static func custom(_ labels: [CustomLabel]) -> LabelTable {
        LabelTable(names: Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) }),
                   colors: Dictionary(uniqueKeysWithValues: labels.filter { $0.color.count == 3 }.map { ($0.id, SIMD3($0.color[0], $0.color[1], $0.color[2])) }))
    }
}

extension NiftiVolume {
    /// A copy with the voxels `mask` marks set to the background (`dataMin`): removed noise,
    /// for the segmentation models. vDSP in 1 M-voxel pieces.
    func removing(_ mask: [UInt8]) -> NiftiVolume {
        var copy = self
        let chunk = 1 << 20
        var k = [Float](repeating: 0, count: chunk)
        var zero: Float = 0, one: Float = 1, negOne: Float = -1, bg = dataMin, negBg = -dataMin
        copy.data.withUnsafeMutableBufferPointer { d in mask.withUnsafeBufferPointer { m in k.withUnsafeMutableBufferPointer { kf in
            for start in stride(from: 0, to: d.count, by: chunk) {
                let n = vDSP_Length(min(chunk, d.count - start)), p = d.baseAddress! + start
                vDSP_vfltu8(m.baseAddress! + start, 1, kf.baseAddress!, 1, n)
                vDSP_vclip(kf.baseAddress!, 1, &zero, &one, kf.baseAddress!, 1, n)
                vDSP_vsmsa(kf.baseAddress!, 1, &negOne, &one, kf.baseAddress!, 1, n)   // keep
                vDSP_vsadd(p, 1, &negBg, p, 1, n)                                     // (v - bg) · keep + bg
                vDSP_vmul(p, 1, kf.baseAddress!, 1, p, 1, n)
                vDSP_vsadd(p, 1, &bg, p, 1, n)
            }
        } } }
        return copy
    }

    /// Removed noise: pixels of slice `index` whose voxel `mask` marks go black. Rows with
    /// nothing marked are skipped with a memcmp where the slice's rows run along x.
    func cutOut(_ px: inout [UInt8], width w: Int, height h: Int, bytesPerPixel bpp: Int, axis: Int, index: Int, mask: LabelGrid) {
        let (nx, ny, _) = dims
        let k = max(0, min(count(axis: axis) - 1, index))
        let zeros = [UInt8](repeating: 0, count: w)
        mask.data.withUnsafeBufferPointer { m in px.withUnsafeMutableBufferPointer { p in zeros.withUnsafeBufferPointer { z in
            for r in 0..<h {
                let v = h - 1 - r
                if axis != 0 { // rows run along x: one memcmp for an empty row
                    let start = axis == 1 ? nx * (k + ny * v) : nx * (v + ny * k)
                    guard memcmp(m.baseAddress! + start, z.baseAddress!, w) != 0 else { continue }
                }
                for c in 0..<w {
                    let i = axis == 0 ? k + nx * (c + ny * v) : axis == 1 ? c + nx * (k + ny * v) : c + nx * (v + ny * k)
                    if m[i] != 0 { let o = (r * w + c) * bpp; for b in 0..<min(bpp, 3) { p[o + b] = 0 } }
                }
            }
        } } }
    }

    /// Grey slice with the segmentation blended in (RGBX, 4 bytes/pixel): pixels whose label
    /// is shown get `opacity` of the label colour, the rest stay grey (black with `mask`).
    func sliceRGBX(axis: Int, index: Int, lo: Float, hi: Float, overlay: SegmentationOverlay) -> (width: Int, height: Int, pixels: [UInt8]) {
        let s = slice(axis: axis, index: index, lo: lo, hi: hi)
        let (nx, ny, _) = dims, (w, h) = (s.width, s.height)
        let k = max(0, min(count(axis: axis) - 1, index))
        let a = Int(overlay.opacity * 256), ia = 256 - a
        let lut = overlay.lut
        var px = [UInt8](repeating: 255, count: w * h * 4)
        overlay.labels.data.withUnsafeBufferPointer { lab in
            px.withUnsafeMutableBufferPointer { px in
                for r in 0..<h {
                    let v = h - 1 - r
                    for c in 0..<w {
                        let i = axis == 0 ? k + nx * (c + ny * v) : axis == 1 ? c + nx * (k + ny * v) : c + nx * (v + ny * k)
                        let g = Int(s.pixels[r * w + c]), o = (r * w + c) * 4
                        let color = lut[Int(lab[i])]
                        if overlay.mask && color.w == 0 {
                            px[o] = 0; px[o + 1] = 0; px[o + 2] = 0
                        } else if color.w > 0 {
                            px[o] = UInt8((g * ia + Int(color.x) * a) >> 8)
                            px[o + 1] = UInt8((g * ia + Int(color.y) * a) >> 8)
                            px[o + 2] = UInt8((g * ia + Int(color.z) * a) >> 8)
                        } else {
                            px[o] = UInt8(g); px[o + 1] = UInt8(g); px[o + 2] = UInt8(g)
                        }
                    }
                }
            }
        }
        return (w, h, px)
    }
}
