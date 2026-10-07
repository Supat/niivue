//
//  BandRepair.swift — hand repair of thin banding (e.g. a too-bright or too-dark slab where
//  stitched stations meet): painted voxels get values interpolated along z (head–foot) from
//  the nearest unpainted voxels above and below in the same column.
//

import Foundation

enum BandRepair {
    /// For every voxel `mask` marks: its index and a value interpolated linearly along z
    /// between the nearest unmarked voxels of its column (the one present if only one is;
    /// left out if the whole column is marked). z-slices and rows with nothing marked are
    /// skipped with a memcmp each, so the cost follows the painted voxels.
    static func repaired(data: [Float], mask: [UInt8], dims: (Int, Int, Int)) -> (indices: [Int32], values: [Float]) {
        let (nx, ny, nz) = dims, plane = nx * ny
        var indices: [Int32] = [], values: [Float] = []
        let zeros = [UInt8](repeating: 0, count: plane)
        data.withUnsafeBufferPointer { d in mask.withUnsafeBufferPointer { m in zeros.withUnsafeBufferPointer { z0 in
            let mp = m.baseAddress!
            for z in 0..<nz {
                guard memcmp(mp + z * plane, z0.baseAddress!, plane) != 0 else { continue }
                for y in 0..<ny {
                    let row = z * plane + y * nx
                    guard memcmp(mp + row, z0.baseAddress!, nx) != 0 else { continue }
                    for x in 0..<nx where mp[row + x] != 0 {
                        let i = row + x
                        var below = z - 1, above = z + 1
                        while below >= 0, mp[i - (z - below) * plane] != 0 { below -= 1 }
                        while above < nz, mp[i + (above - z) * plane] != 0 { above += 1 }
                        let v: Float
                        switch (below >= 0, above < nz) {
                        case (true, true):
                            let a = d[i - (z - below) * plane], b = d[i + (above - z) * plane]
                            v = a + (b - a) * Float(z - below) / Float(above - below)
                        case (true, false): v = d[i - (z - below) * plane]
                        case (false, true): v = d[i + (above - z) * plane]
                        case (false, false): continue
                        }
                        indices.append(Int32(i)); values.append(v)
                    }
                }
            }
        } } }
        return (indices, values)
    }
}
