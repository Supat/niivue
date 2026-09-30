//
//  SegmentationMap.swift — a label map on the scan's grid, with what's known about it.
//

import Foundation

struct SegmentationMap: Identifiable, @unchecked Sendable {
    let id = UUID()
    let labels: LabelVolume
    let name: String
    let table: LabelTable
    /// Voxel counts per label ([0] = unlabelled), and how many of those unlabelled voxels are
    /// inside the body (non-zero intensity) — for the body-composition estimate.
    let counts: [Int]
    let unlabelledBodyVoxels: Int
    let voxelML: Double

    /// Labels a file may carry; empty for a map with nothing labelled.
    var labelRange: Range<Int> { 1..<(labels.maxLabel + 1) }

    /// `volume` is the scan the labels sit on; counting is one pass, do it off the main thread.
    init(labels: LabelVolume, name: String, volume: NiftiVolume) {
        self.labels = labels
        self.name = name
        table = LabelTable.forFile(named: name)
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
    let labels: LabelVolume
    let lut: [SIMD4<UInt8>] // 256 entries
    let opacity: Float
    let ghost: Bool         // 3D: fade unlabelled tissue so labelled structures show through
}

extension NiftiVolume {
    /// Grey slice with the segmentation blended in (RGBX, 4 bytes/pixel): pixels whose label
    /// is shown get `opacity` of the label colour, the rest stay grey.
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
                        if color.w > 0 {
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
