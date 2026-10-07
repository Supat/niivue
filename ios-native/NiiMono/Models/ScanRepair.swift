//
//  ScanRepair.swift — hand repair of the scan's intensities. Two paints: a band (value 1,
//  e.g. a too-bright or too-dark slab where stitched stations meet) gets values interpolated
//  along z (head–foot) from the nearest unpainted voxels above and below in its column; a
//  blemish (values 2–4: a streak or spot, painted on a sagittal / coronal / axial slice) is
//  filled in from the unpainted voxels around it within that slice (a smooth fill: Laplace's
//  equation solved over the paint, the voxels around it fixed). In-plane, because the slices
//  either side often carry the same streak and would feed it back in. A cut (value 5) is set
//  to the scan's background, as noise removal does, but written into the repaired scan.
//

import Foundation

enum ScanRepair {
    static let band: UInt8 = 1
    /// Blemish painted on a slice of `axis` (0 sagittal, 1 coronal, 2 axial): filled in within
    /// that plane.
    static func blemish(axis: Int) -> UInt8 { UInt8(2 + axis) }
    static func isBlemish(_ v: UInt8) -> Bool { v >= 2 && v <= 4 }
    static let blemishValues: [UInt8] = [2, 3, 4]
    static let cut: UInt8 = 5

    /// The whole repair: band voxels interpolated along z, cut voxels set to `background`,
    /// then blemish voxels filled from around them (band and cut already in place). Indices
    /// and new values of every voxel that changes.
    static func repaired(data: [Float], mask: [UInt8], dims: (Int, Int, Int), background: Float) -> (indices: [Int32], values: [Float]) {
        var r = banded(data: data, mask: mask, dims: dims)
        mask.withUnsafeBufferPointer { m in for i in m.indices where m[i] == cut { r.indices.append(Int32(i)); r.values.append(background) } }
        var v = data
        for (i, value) in zip(r.indices, r.values) { v[Int(i)] = value }
        let box = VoxelBox(lo: .zero, hi: SIMD3(dims.0, dims.1, dims.2))
        let h = healed(data: v, mask: mask, dims: dims, in: box)
        r.indices += h.indices; r.values += h.values
        return r
    }

    /// For every band voxel (`mask` == band; other paint counts as painted too): its index
    /// and a value interpolated linearly along z between the nearest unpainted voxels of its
    /// column (the one present if only one is; left out if the whole column is painted).
    /// z-slices and rows with nothing painted are skipped with a memcmp each, so the cost
    /// follows the painted voxels.
    static func banded(data: [Float], mask: [UInt8], dims: (Int, Int, Int)) -> (indices: [Int32], values: [Float]) {
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
                    for x in 0..<nx where mp[row + x] == band {
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

    /// Blemish voxels (`mask` 2–4) inside `box`, filled in from the voxels around them in
    /// their own plane: each takes the average of its 4 in-plane neighbours, repeated until
    /// it settles (Laplace's equation, Gauss–Seidel with over-relaxation), with unpainted
    /// neighbours fixed at their values in `data` and band paint treated as fixed too.
    /// Blemish voxels outside `box` keep their values and act as fixed neighbours. Returns
    /// the index and new value of every blemish voxel in the box.
    static func healed(data: [Float], mask: [UInt8], dims: (Int, Int, Int), in box: VoxelBox) -> (indices: [Int32], values: [Float]) {
        let (nx, ny, nz) = dims, plane = nx * ny
        let lo = pointwiseMax(box.lo, .zero), hi = pointwiseMin(box.hi, SIMD3(nx, ny, nz))
        guard all(lo .< hi) else { return ([], []) }
        // The cells: blemish voxels in the box, with a box-local lookup of their slot.
        let bs = hi &- lo, bn = bs.x * bs.y * bs.z
        var slot = [Int32](repeating: -1, count: bn)
        var cells: [Int] = []
        let zeros = [UInt8](repeating: 0, count: bs.x)
        mask.withUnsafeBufferPointer { m in zeros.withUnsafeBufferPointer { z0 in
            for z in lo.z..<hi.z { for y in lo.y..<hi.y {
                let row = z * plane + y * nx + lo.x
                guard memcmp(m.baseAddress! + row, z0.baseAddress!, bs.x) != 0 else { continue }
                for x in lo.x..<hi.x where isBlemish(m[row + x - lo.x]) {
                    slot[(x - lo.x) + bs.x * ((y - lo.y) + bs.y * (z - lo.z))] = Int32(cells.count)
                    cells.append(row + x - lo.x)
                }
            } }
        } }
        guard !cells.isEmpty else { return ([], []) }
        // Neighbour lists: fixed values summed, and the slots of blemish neighbours.
        var fixedSum = [Float](repeating: 0, count: cells.count), degree = [Float](repeating: 0, count: cells.count)
        var links: [[Int32]] = Array(repeating: [], count: cells.count)
        var cur = [Float](repeating: 0, count: cells.count)
        var fixedLo = Float.greatestFiniteMagnitude, fixedHi = -Float.greatestFiniteMagnitude
        data.withUnsafeBufferPointer { d in mask.withUnsafeBufferPointer { m in
            for (c, i) in cells.enumerated() {
                let x = i % nx, y = (i / nx) % ny, z = i / plane
                var seed: Float = 0, seeds: Float = 0
                // The 4 directions within the slice the voxel was painted on.
                let axis = Int(m[i]) - 2
                let dirs: [(Int, Int, Int)] = [(-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)]
                    .filter { axis == 0 ? $0.0 == 0 : axis == 1 ? $0.1 == 0 : $0.2 == 0 }
                for (dx, dy, dz) in dirs {
                    let X = x + dx, Y = y + dy, Z = z + dz
                    guard X >= 0, X < nx, Y >= 0, Y < ny, Z >= 0, Z < nz else { continue }
                    let j = X + nx * (Y + ny * Z)
                    degree[c] += 1
                    let inBox = X >= lo.x && X < hi.x && Y >= lo.y && Y < hi.y && Z >= lo.z && Z < hi.z
                    if isBlemish(m[j]), inBox, case let s = slot[(X - lo.x) + bs.x * ((Y - lo.y) + bs.y * (Z - lo.z))], s >= 0 {
                        links[c].append(s)
                    } else {
                        fixedSum[c] += d[j]; seed += d[j]; seeds += 1
                        fixedLo = min(fixedLo, d[j]); fixedHi = max(fixedHi, d[j])
                    }
                }
                cur[c] = seeds > 0 ? seed / seeds : d[i] // start from the surroundings where there are any
            }
        } }
        // A cell with no neighbours at all (1-voxel volume) keeps its value.
        for c in cells.indices where degree[c] == 0 { degree[c] = 1; fixedSum[c] = cur[c] }
        // Gauss–Seidel with over-relaxation until the largest change is tiny relative to the
        // spread of the surrounding values (the whole scan's range would cost a pass over it).
        let eps = max(1e-4 * (fixedHi - fixedLo), 1e-6), omega: Float = 1.5
        for _ in 0..<2000 {
            var worst: Float = 0
            for c in cells.indices {
                var sum = fixedSum[c]
                for s in links[c] { sum += cur[Int(s)] }
                let v = sum / degree[c]
                let next = cur[c] + omega * (v - cur[c])
                worst = max(worst, abs(next - cur[c]))
                cur[c] = next
            }
            if worst < eps { break }
        }
        return (cells.map { Int32($0) }, cur)
    }
}
