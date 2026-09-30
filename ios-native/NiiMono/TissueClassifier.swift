//
//  TissueClassifier.swift — the 14 tissue classes of the body-composition pipeline
//  (muscle.py + tissue_render.py), from the Dixon water and fat images and the total_mr
//  structure labels: skeletal muscle and fat from the fat fraction plus morphology, the
//  organ/bone/vessel classes from the labels, visceral vs subcutaneous fat by the per-slice
//  convex hull of the trunk wall.
//  Morphology passes run on the GPU (Accumulate.metal `morph`); the rest is CPU.
//

import Foundation
import Metal

/// TotalSegmentator's `total_mr` label ids and names (organs part 1...29, muscles/bones part 30...50).
enum TotalMR {
    static let names: [Int: String] = Dictionary(uniqueKeysWithValues: """
        spleen kidney_right kidney_left gallbladder liver stomach pancreas adrenal_gland_right \
        adrenal_gland_left lung_left lung_right esophagus small_bowel duodenum colon urinary_bladder prostate \
        sacrum vertebrae intervertebral_discs spinal_cord heart aorta inferior_vena_cava \
        portal_vein_and_splenic_vein iliac_artery_left iliac_artery_right iliac_vena_left iliac_vena_right \
        humerus_left humerus_right scapula_left scapula_right clavicula_left clavicula_right femur_left \
        femur_right hip_left hip_right gluteus_maximus_left gluteus_maximus_right gluteus_medius_left \
        gluteus_medius_right gluteus_minimus_left gluteus_minimus_right autochthon_left autochthon_right \
        iliopsoas_left iliopsoas_right brain
        """.split(separator: " ").enumerated().map { ($0.offset + 1, String($0.element)) })
    static let organCount = 29 // the organ model's classes; the muscle model's ids are offset by this
}

/// A 0/1 mask on the volume grid, [z][y][x].
struct Mask {
    let nx: Int, ny: Int, nz: Int
    var v: [UInt8]
    var count: Int { nx * ny * nz }

    init(nx: Int, ny: Int, nz: Int, fill: UInt8 = 0) {
        self.nx = nx; self.ny = ny; self.nz = nz
        v = [UInt8](repeating: fill, count: nx * ny * nz)
    }

    init(nx: Int, ny: Int, nz: Int, _ predicate: (Int) -> Bool) {
        self.init(nx: nx, ny: ny, nz: nz)
        v.withUnsafeMutableBufferPointer { p in for i in 0..<p.count where predicate(i) { p[i] = 1 } }
    }

    static func & (a: Mask, b: Mask) -> Mask { a.combine(b) { $0 & $1 } }
    static func | (a: Mask, b: Mask) -> Mask { a.combine(b) { $0 | $1 } }
    /// a & ~b
    func minus(_ b: Mask) -> Mask { combine(b) { $0 & ($1 ^ 1) } }
    private func combine(_ b: Mask, _ op: (UInt8, UInt8) -> UInt8) -> Mask {
        var out = self
        out.v.withUnsafeMutableBufferPointer { o in b.v.withUnsafeBufferPointer { q in
            for i in 0..<o.count { o[i] = op(o[i], q[i]) }
        } }
        return out
    }
    var population: Int { v.withUnsafeBufferPointer { p in var n = 0; for i in 0..<p.count { n += Int(p[i]) }; return n } }

    /// Every second voxel along each axis (numpy `[::2, ::2, ::2]`).
    func downsampled2() -> Mask {
        var d = Mask(nx: (nx + 1) / 2, ny: (ny + 1) / 2, nz: (nz + 1) / 2)
        for z in 0..<d.nz { for y in 0..<d.ny { for x in 0..<d.nx {
            d.v[(z * d.ny + y) * d.nx + x] = v[(2 * z * ny + 2 * y) * nx + 2 * x]
        } } }
        return d
    }

    /// Each voxel repeated twice along each axis, cropped to the given size (numpy `repeat`).
    func upsampled2(nx tx: Int, ny ty: Int, nz tz: Int) -> Mask {
        var u = Mask(nx: tx, ny: ty, nz: tz)
        for z in 0..<tz { for y in 0..<ty {
            let src = ((z / 2) * ny + y / 2) * nx, dst = (z * ty + y) * tx
            for x in 0..<tx { u.v[dst + x] = v[src + x / 2] }
        } }
        return u
    }

    /// Set every background voxel that is not 6-connected to the volume border (scipy
    /// binary_fill_holes).
    func holesFilled() -> Mask {
        var out = self
        var seen = [UInt8](repeating: 0, count: count)
        var stack = [Int]()
        stack.reserveCapacity(1 << 20)
        func seed(_ i: Int) { if v[i] == 0 && seen[i] == 0 { seen[i] = 1; stack.append(i) } }
        for z in 0..<nz { for y in 0..<ny {
            seed((z * ny + y) * nx); seed((z * ny + y) * nx + nx - 1)
            if y == 0 || y == ny - 1 || z == 0 || z == nz - 1 { for x in 0..<nx { seed((z * ny + y) * nx + x) } }
        } }
        floodFill(&seen, &stack)
        out.v.withUnsafeMutableBufferPointer { o in for i in 0..<o.count where o[i] == 0 && seen[i] == 0 { o[i] = 1 } }
        return out
    }

    /// Drop 6-connected components smaller than `minVoxels` (scipy label + size filter).
    func withoutComponents(smallerThan minVoxels: Int) -> Mask {
        var out = self
        var seen = [UInt8](repeating: 0, count: count)
        var stack = [Int](), members = [Int]()
        for start in 0..<count where v[start] == 1 && seen[start] == 0 {
            seen[start] = 1; stack = [start]; members.removeAll(keepingCapacity: true)
            while let i = stack.popLast() {
                members.append(i)
                for n in neighbours(of: i) where v[n] == 1 && seen[n] == 0 { seen[n] = 1; stack.append(n) }
            }
            if members.count < minVoxels { for i in members { out.v[i] = 0 } }
        }
        return out
    }

    /// Grow `seen` from the queued voxels through voxels with the same value as the seeds' (0).
    private func floodFill(_ seen: inout [UInt8], _ stack: inout [Int]) {
        while let i = stack.popLast() {
            for n in neighbours(of: i) where v[n] == 0 && seen[n] == 0 { seen[n] = 1; stack.append(n) }
        }
    }

    @inline(__always) private func neighbours(of i: Int) -> [Int] {
        let x = i % nx, y = (i / nx) % ny, z = i / (nx * ny)
        var n = [Int](); n.reserveCapacity(6)
        if x > 0 { n.append(i - 1) }; if x + 1 < nx { n.append(i + 1) }
        if y > 0 { n.append(i - nx) }; if y + 1 < ny { n.append(i + nx) }
        if z > 0 { n.append(i - nx * ny) }; if z + 1 < nz { n.append(i + nx * ny) }
        return n
    }

    /// Opening along z with a line of `length` voxels (scipy binary_opening with a
    /// (1, length, 1) structure on the S–I axis): erode by half the length, then dilate.
    func openedAlongZ(length: Int) -> Mask {
        let r = length / 2
        func pass(_ m: Mask, keepIfAll: Bool) -> Mask {
            var out = Mask(nx: nx, ny: ny, nz: nz)
            let plane = nx * ny
            for z in 0..<nz { for i in 0..<plane {
                var all = true, any = false
                for dz in -r...r {
                    let zz = z + dz
                    let on = zz >= 0 && zz < nz && m.v[zz * plane + i] == 1
                    all = all && on; any = any || on
                }
                out.v[z * plane + i] = (keepIfAll ? all : any) ? 1 : 0
            } }
            return out
        }
        return pass(pass(self, keepIfAll: true), keepIfAll: false)
    }
}

/// 6-connected erosion/dilation on the GPU.
final class Morphology {
    private let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLComputePipelineState

    init(library: MTLLibrary) throws {
        device = library.device
        guard let q = device.makeCommandQueue(), let f = library.makeFunction(name: "morph") else { throw SegmenterError.missingKernel("morph") }
        queue = q
        pipeline = try device.makeComputePipelineState(function: f)
    }

    func erode(_ m: Mask, _ iterations: Int) -> Mask { run(m, iterations, dilate: false) }
    func dilate(_ m: Mask, _ iterations: Int) -> Mask { run(m, iterations, dilate: true) }
    func open(_ m: Mask, _ n: Int) -> Mask { dilate(erode(m, n), n) }
    func close(_ m: Mask, _ n: Int) -> Mask { erode(dilate(m, n), n) }

    private func run(_ m: Mask, _ iterations: Int, dilate: Bool) -> Mask {
        guard iterations > 0 else { return m }
        var out = m
        guard var a = device.makeBuffer(bytes: m.v, length: m.count, options: .storageModeShared),
              var b = device.makeBuffer(length: m.count, options: .storageModeShared) else { return m }
        var p = (UInt32(m.nx), UInt32(m.ny), UInt32(m.nz), UInt32(dilate ? 1 : 0))
        for _ in 0..<iterations {
            guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return m }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(a, offset: 0, index: 0); enc.setBuffer(b, offset: 0, index: 1)
            enc.setBytes(&p, length: MemoryLayout.stride(ofValue: p), index: 2)
            let w = pipeline.threadExecutionWidth
            enc.dispatchThreads(MTLSize(width: m.nx, height: m.ny, depth: m.nz),
                                threadsPerThreadgroup: MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
            enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
            swap(&a, &b)
        }
        out.v.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: a.contents(), byteCount: m.count) }
        return out
    }
}

enum TissueClassifier {
    /// total_mr ids whose names contain any of the substrings (muscle.py's `ids()`).
    static func ids(_ subs: String...) -> Set<Int> {
        Set(TotalMR.names.filter { n in subs.contains { n.value.contains($0) } }.keys)
    }

    /// 99th percentile of the values where `include` holds, by histogram.
    static func percentile99(_ a: [Float], _ b: [Float]?, include: (Int) -> Bool) -> Float {
        var hi: Float = 0
        for i in 0..<a.count where include(i) { hi = max(hi, a[i] + (b?[i] ?? 0)) }
        guard hi > 0 else { return 0 }
        let bins = 4096
        var hist = [Int](repeating: 0, count: bins), n = 0
        for i in 0..<a.count where include(i) {
            hist[min(bins - 1, Int((a[i] + (b?[i] ?? 0)) / hi * Float(bins - 1)))] += 1; n += 1
        }
        var acc = 0
        for (k, c) in hist.enumerated() { acc += c; if acc >= Int(Double(n) * 0.99) { return Float(k + 1) / Float(bins) * hi } }
        return hi
    }

    /// `labels` are total_mr ids (1...50) on the scan grid; returns the 14-class tissue map.
    static func classify(water w: NiftiVolume, fat f: NiftiVolume, labels lab: LabelVolume,
                         library: MTLLibrary, progress: (Double) -> Void = { _ in }) throws -> LabelVolume {
        let (nx, ny, nz) = w.dims
        let morph = try Morphology(library: library)
        let W = w.data, F = f.data, L = lab.data
        let voxelML = Double(w.voxelSize.0 * w.voxelSize.1 * w.voxelSize.2) / 1000

        // Body: W+F above 12% of its 99th percentile, opened, holes filled.
        let s99 = percentile99(W, F) { W[$0] + F[$0] > 0 }
        var body = Mask(nx: nx, ny: ny, nz: nz) { W[$0] + F[$0] > 0.12 * s99 }
        body = morph.open(body, 2).holesFilled()
        progress(0.1)

        // Skeletal-muscle candidate: inside the eroded body (drops the water-bright skin),
        // water-dominant (fat fraction < 0.5 ⇔ F < W), above noise.
        let w99 = percentile99(W, nil) { body.v[$0] == 1 }
        let thresh = 0.25 * w99
        var musc = morph.erode(body, 2) & Mask(nx: nx, ny: ny, nz: nz) { F[$0] < W[$0] && W[$0] > thresh }
        let muscleLabels = ids("gluteus", "autochthon", "iliopsoas")
        let boneLabels = ids("vertebrae", "sacrum", "humerus", "scapula", "clavicula", "femur", "hip", "intervertebral")
        let organLabels = Set(1...50).subtracting(muscleLabels).subtracting(boneLabels)
        let exclude = morph.dilate(Mask(nx: nx, ny: ny, nz: nz) { organLabels.contains(Int(L[$0])) }, 3)
        // Thoraco-abdominal cavity: close the gaps between organs (~20 mm) at half resolution.
        let cavityLabels = ids("liver", "spleen", "stomach", "bowel", "duodenum", "colon", "kidney", "pancreas", "bladder", "heart", "lung", "prostate")
        let cavHalf = morph.close(Mask(nx: nx, ny: ny, nz: nz) { cavityLabels.contains(Int(L[$0])) }.downsampled2(), 14)
        let cav = cavHalf.upsampled2(nx: nx, ny: ny, nz: nz).holesFilled()
        progress(0.35)
        musc = musc.minus(exclude).minus(cav).minus(Mask(nx: nx, ny: ny, nz: nz) { boneLabels.contains(Int(L[$0])) })
        musc = musc | Mask(nx: nx, ny: ny, nz: nz) { muscleLabels.contains(Int(L[$0])) && F[$0] < W[$0] }
        musc = morph.open(musc, 1).withoutComponents(smallerThan: Int(2.0 / voxelML))
        progress(0.55)

        // Organ / bone / vessel classes from the labels (later groups overwrite earlier).
        let groups: [(Int, Set<Int>)] = [
            (4, ids("liver")), (5, ids("spleen")), (6, ids("kidney")), (7, ids("pancreas", "adrenal", "gallbladder")),
            (8, ids("stomach", "bowel", "duodenum", "colon", "esophagus")), (9, ids("bladder", "prostate")),
            (10, ids("heart")), (11, ids("lung")), (12, ids("aorta", "vena", "vein", "artery")),
            (13, ids("vertebrae", "sacrum", "humerus", "scapula", "clavicula", "femur", "hip", "discs")),
            (14, ids("spinal_cord", "brain")),
        ]
        var classOf = [UInt8](repeating: 0, count: 51)
        for (cls, set) in groups { for l in set { classOf[l] = UInt8(cls) } }
        var tissue = [UInt8](repeating: 0, count: nx * ny * nz)
        for i in 0..<tissue.count { tissue[i] = classOf[Int(L[i])] }

        // Fat: fat-dominant body voxels not already an organ. Visceral fat lies inside the
        // per-slice convex hull of the trunk wall (muscle within the eroded body, plus every
        // labelled structure), on trunk slices only.
        let fat = body & Mask(nx: nx, ny: ny, nz: nz) { F[$0] > W[$0] && tissue[$0] == 0 }
        let wall = (musc & morph.erode(body, 4)) | Mask(nx: nx, ny: ny, nz: nz) { tissue[$0] != 0 }
        let trunkLabels = ids("liver", "spleen", "stomach", "bowel", "colon", "kidney", "bladder", "heart", "lung", "prostate")
        let plane = nx * ny
        var interior = Mask(nx: nx, ny: ny, nz: nz)
        for z in 0..<nz {
            var isTrunk = false
            for i in 0..<plane where trunkLabels.contains(Int(L[z * plane + i])) { isTrunk = true; break }
            guard isTrunk else { continue }
            let big = largestComponent2D(body, z: z)
            var pts = [SIMD2<Int>]()
            for y in 0..<ny { for x in 0..<nx where wall.v[z * plane + y * nx + x] == 1 && big[y * nx + x] == 1 { pts.append(SIMD2(x, y)) } }
            guard pts.count >= 200 else { continue }
            fillConvexHull(of: pts, into: &interior.v, z: z, nx: nx, ny: ny)
        }
        // Drop hull jumps thinner than ~20 mm along S–I (station seams).
        interior = interior.openedAlongZ(length: 15)
        progress(0.9)
        let visc = fat & interior
        for i in 0..<tissue.count {
            if fat.v[i] == 1 { tissue[i] = visc.v[i] == 1 ? 3 : 2 }
            if musc.v[i] == 1 && tissue[i] == 0 { tissue[i] = 1 }
        }
        progress(1)
        return LabelVolume(dims: w.dims, data: tissue, maxLabel: 14)
    }

    /// The largest 4-connected component of the mask's z slice, as a 2D 0/1 array.
    static func largestComponent2D(_ m: Mask, z: Int) -> [UInt8] {
        let nx = m.nx, ny = m.ny, base = z * nx * ny
        var comp = [Int32](repeating: 0, count: nx * ny), sizes = [Int]()
        var stack = [Int]()
        for s in 0..<(nx * ny) where m.v[base + s] == 1 && comp[s] == 0 {
            let id = Int32(sizes.count + 1); var n = 0
            comp[s] = id; stack = [s]
            while let i = stack.popLast() {
                n += 1
                let x = i % nx, y = i / nx
                for j in [x > 0 ? i - 1 : -1, x + 1 < nx ? i + 1 : -1, y > 0 ? i - nx : -1, y + 1 < ny ? i + nx : -1]
                    where j >= 0 && m.v[base + j] == 1 && comp[j] == 0 { comp[j] = id; stack.append(j) }
            }
            sizes.append(n)
        }
        guard let bigIdx = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) else { return [UInt8](repeating: 0, count: nx * ny) }
        let big = Int32(bigIdx + 1)
        return comp.map { $0 == big ? 1 : 0 }
    }

    /// Rasterise the convex hull of `pts` (monotone chain) into slice z of `out`.
    static func fillConvexHull(of pts: [SIMD2<Int>], into out: inout [UInt8], z: Int, nx: Int, ny: Int) {
        let p = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        func cross(_ o: SIMD2<Int>, _ a: SIMD2<Int>, _ b: SIMD2<Int>) -> Int { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower = [SIMD2<Int>](), upper = [SIMD2<Int>]()
        for q in p { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        for q in p.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        let hull = Array(lower.dropLast()) + Array(upper.dropLast())
        guard hull.count >= 3 else { return }
        // Scanline fill: for each y, the x range between the hull's edge crossings.
        let yMin = hull.map(\.y).min()!, yMax = hull.map(\.y).max()!
        for y in max(0, yMin)...min(ny - 1, yMax) {
            var xs = [Double]()
            for k in 0..<hull.count {
                let a = hull[k], b = hull[(k + 1) % hull.count]
                if (a.y <= y && y < b.y) || (b.y <= y && y < a.y) {
                    xs.append(Double(a.x) + Double(y - a.y) * Double(b.x - a.x) / Double(b.y - a.y))
                } else if a.y == b.y && a.y == y { xs.append(Double(a.x)); xs.append(Double(b.x)) }
            }
            guard let lo = xs.min(), let hi = xs.max() else { continue }
            let row = z * nx * ny + y * nx
            for x in max(0, Int(lo.rounded(.up)))...min(nx - 1, Int(hi.rounded(.down))) { out[row + x] = 1 }
        }
    }
}
