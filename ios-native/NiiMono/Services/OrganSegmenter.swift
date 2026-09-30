//
//  OrganSegmenter.swift — runs TotalSegmentator's `total_mr` organ network (a Core ML
//  conversion of the nnU-Net checkpoint) on a scan, reproducing the TotalSegmentator /
//  nnU-Net inference chain:
//    RAS volume → resample to 1.5 mm (linear, corner-aligned like scipy.ndimage.zoom, cast
//    to int) → crop to the non-zero box → z-score → pad to ≥ patch → sliding window
//    (step 0.8·patch, Gaussian σ = patch/8, no mirroring) → argmax → un-pad/un-crop →
//    nearest-neighbour back to the scan grid.
//  Accumulation and argmax run in Metal (Accumulate.metal); the network runs in Core ML.
//  No UIKit/SwiftUI, so the same file drives the macOS check harness.
//

import Accelerate
import CoreML
import Foundation
import Metal

enum SegmenterError: LocalizedError {
    case noMetal, missingKernel(String), missingModel(String), modelOutput, simulator
    var errorDescription: String? {
        switch self {
        case .noMetal: return "Metal is unavailable"
        case .missingModel(let n): return "the \(n) model is missing from the app bundle"
        case .simulator: return "organ segmentation needs a real device (the simulator runs Core ML on the CPU and runs out of memory)"
        case .missingKernel(let n): return "Metal kernel \(n) is missing"
        case .modelOutput: return "the model returned an unexpected output"
        }
    }
}

final class OrganSegmenter {
    /// Network patch in nnU-Net order (z, y, x) — the volume's memory order is [z][y][x].
    static let patch = (z: 112, y: 128, x: 160)
    static let spacing: Float = 1.5
    static let stepFraction: Float = 0.8   // TotalSegmentator's tile_step_size for total_mr
    /// Network outputs: background + structures. 30 for the organs part, 22 for muscles/bones.
    let classes: Int

    private let model: MLModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let accumulate: MTLComputePipelineState
    private let finalize: MTLComputePipelineState

    /// `modelURL` is a compiled `.mlmodelc`; `library` holds Accumulate.metal's kernels.
    init(modelURL: URL, library: MTLLibrary, classes: Int = 30, computeUnits: MLComputeUnits = .all) throws {
        self.classes = classes
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: config)
        guard let device = library.device as MTLDevice?, let queue = device.makeCommandQueue() else { throw SegmenterError.noMetal }
        self.device = device
        self.queue = queue
        guard let a = library.makeFunction(name: "accumulate") else { throw SegmenterError.missingKernel("accumulate") }
        guard let f = library.makeFunction(name: "finalize") else { throw SegmenterError.missingKernel("finalize") }
        accumulate = try device.makeComputePipelineState(function: a)
        finalize = try device.makeComputePipelineState(function: f)
    }

    /// Peak memory is roughly: three float copies of the 1.5 mm volume, the logit ring
    /// (patch depth × classes × slice, fp16) and one patch of logits — ~1 GB for a whole body.
    /// Segment `volume`; the result has the scan's dims and the model's ids (0 = none).
    /// `progress` gets 0...1; return true from `isCancelled` to stop early (throws CancellationError).
    func segment(_ volume: NiftiVolume, progress: (Double) -> Void = { _ in },
                 isCancelled: () -> Bool = { false }) throws -> LabelVolume {
        #if targetEnvironment(simulator)
        throw SegmenterError.simulator
        #endif
        let P = Self.patch
        // 1. Resample to 1.5 mm.
        let (rd, resampled) = Self.resample(volume, to: Self.spacing)
        progress(0.03)
        // 2. Crop to the non-zero bounding box.
        let (lo, hi) = Self.nonZeroBox(resampled, dims: rd)
        let cd = (x: hi.x - lo.x + 1, y: hi.y - lo.y + 1, z: hi.z - lo.z + 1)
        var cropped = [Float](repeating: 0, count: cd.x * cd.y * cd.z)
        resampled.withUnsafeBufferPointer { s in cropped.withUnsafeMutableBufferPointer { d in
            for z in 0..<cd.z { for y in 0..<cd.y {
                let src: Int = lo.x + rd.x * ((lo.y + y) + rd.y * (lo.z + z))
                let dst: Int = cd.x * (y + cd.y * z)
                d.baseAddress!.advanced(by: dst).update(from: s.baseAddress!.advanced(by: src), count: cd.x)
            } }
        } }
        // 3. Z-score over the cropped image.
        var mean: Float = 0, meanSq: Float = 0
        vDSP_meanv(cropped, 1, &mean, vDSP_Length(cropped.count))
        vDSP_measqv(cropped, 1, &meanSq, vDSP_Length(cropped.count))
        var negMean = -mean, invSd = 1 / max((meanSq - mean * mean).squareRoot(), 1e-8) // population std, like np.std
        vDSP_vsadd(cropped, 1, &negMean, &cropped, 1, vDSP_Length(cropped.count))
        vDSP_vsmul(cropped, 1, &invSd, &cropped, 1, vDSP_Length(cropped.count))
        // 4. Pad to at least the patch (centred, zeros), like nnU-Net's pad_nd_image.
        let pd = (x: max(cd.x, P.x), y: max(cd.y, P.y), z: max(cd.z, P.z))
        let pad = (x: (pd.x - cd.x) / 2, y: (pd.y - cd.y) / 2, z: (pd.z - cd.z) / 2)
        var padded = [Float](repeating: 0, count: pd.x * pd.y * pd.z)
        cropped.withUnsafeBufferPointer { s in padded.withUnsafeMutableBufferPointer { d in
            for z in 0..<cd.z { for y in 0..<cd.y {
                let src: Int = cd.x * (y + cd.y * z)
                let dst: Int = pad.x + pd.x * ((pad.y + y) + pd.y * (pad.z + z))
                d.baseAddress!.advanced(by: dst).update(from: s.baseAddress!.advanced(by: src), count: cd.x)
            } }
        } }
        progress(0.05)

        // 5. Sliding window over the padded image.
        let stepsZ = Self.steps(size: pd.z, patch: P.z), stepsY = Self.steps(size: pd.y, patch: P.y), stepsX = Self.steps(size: pd.x, patch: P.x)
        let total = stepsZ.count * stepsY.count * stepsX.count
        let C = classes
        guard let ring = device.makeBuffer(length: P.z * C * pd.y * pd.x * MemoryLayout<UInt16>.stride, options: .storageModeShared),
              let logitsBuf = device.makeBuffer(length: C * P.z * P.y * P.x * MemoryLayout<UInt16>.stride, options: .storageModeShared),
              let gaussBuf = device.makeBuffer(bytes: Self.gaussian(), length: P.z * P.y * P.x * 4, options: .storageModeShared),
              let labelsBuf = device.makeBuffer(length: pd.x * pd.y * pd.z, options: .storageModeShared) else { throw SegmenterError.noMetal }
        memset(ring.contents(), 0, ring.length)
        let input = try MLMultiArray(shape: [1, 1, P.z, P.y, P.x] as [NSNumber], dataType: .float32)
        let inPtr = input.dataPointer.assumingMemoryBound(to: Float.self)
        var done = 0
        for (j, z0) in stepsZ.enumerated() {
            for y0 in stepsY { for x0 in stepsX {
                if isCancelled() { throw CancellationError() }
                // Copy the patch out of the padded image.
                padded.withUnsafeBufferPointer { src in
                    for z in 0..<P.z { for y in 0..<P.y {
                        let s: Int = x0 + pd.x * ((y0 + y) + pd.y * (z0 + z))
                        let d: Int = P.x * (y + P.y * z)
                        inPtr.advanced(by: d).update(from: src.baseAddress!.advanced(by: s), count: P.x)
                    } }
                }
                let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["patch": MLFeatureValue(multiArray: input)]))
                guard let logits = out.featureValue(for: "logits")?.multiArrayValue, logits.dataType == .float16,
                      logits.count == C * P.z * P.y * P.x else { throw SegmenterError.modelOutput }
                logits.withUnsafeBytes { _ = memcpy(logitsBuf.contents(), $0.baseAddress!, logitsBuf.length) }
                // Accumulate on the GPU.
                var ap = AccParams(pz: UInt32(P.z), py: UInt32(P.y), px: UInt32(P.x), z0: UInt32(z0), y0: UInt32(y0), x0: UInt32(x0),
                                   Z: UInt32(pd.z), Y: UInt32(pd.y), X: UInt32(pd.x), classes: UInt32(C))
                try run(accumulate, grid: MTLSize(width: P.x, height: P.z * P.y, depth: C)) { enc in
                    enc.setBuffer(ring, offset: 0, index: 0); enc.setBuffer(logitsBuf, offset: 0, index: 1)
                    enc.setBuffer(gaussBuf, offset: 0, index: 2); enc.setBytes(&ap, length: MemoryLayout<AccParams>.stride, index: 3)
                }
                done += 1
                progress(0.05 + 0.9 * Double(done) / Double(total))
            } }
            // Slabs no later patch touches are final: up to the next z step, or the window end.
            let first = z0, end = j + 1 < stepsZ.count ? stepsZ[j + 1] : z0 + P.z
            var fp = FinParams(Z: UInt32(pd.z), Y: UInt32(pd.y), X: UInt32(pd.x), classes: UInt32(C), ringSlabs: UInt32(P.z),
                               firstSlab: UInt32(first), slabCount: UInt32(end - first))
            try run(finalize, grid: MTLSize(width: pd.x, height: pd.y, depth: end - first)) { enc in
                enc.setBuffer(ring, offset: 0, index: 0); enc.setBuffer(labelsBuf, offset: 0, index: 1)
                enc.setBytes(&fp, length: MemoryLayout<FinParams>.stride, index: 2)
            }
        }

        // 6. Back to the scan grid: un-pad, un-crop, nearest neighbour through the zoom map.
        let labels = labelsBuf.contents().assumingMemoryBound(to: UInt8.self)
        let (nx, ny, nz) = volume.dims
        var out = [UInt8](repeating: 0, count: nx * ny * nz)
        let mapX = Self.nearestMap(from: nx, to: rd.x), mapY = Self.nearestMap(from: ny, to: rd.y), mapZ = Self.nearestMap(from: nz, to: rd.z)
        var maxLabel: UInt8 = 0
        for z in 0..<nz {
            let rz = mapZ[z] - lo.z + pad.z
            guard rz >= pad.z, rz < pad.z + cd.z else { continue }
            for y in 0..<ny {
                let ry = mapY[y] - lo.y + pad.y
                guard ry >= pad.y, ry < pad.y + cd.y else { continue }
                let rowBase = pd.x * (ry + pd.y * rz), o = nx * (y + ny * z)
                for x in 0..<nx {
                    let rx = mapX[x] - lo.x + pad.x
                    guard rx >= pad.x, rx < pad.x + cd.x else { continue }
                    let v = labels[rowBase + rx]
                    out[o + x] = v
                    if v > maxLabel { maxLabel = v }
                }
            }
        }
        progress(1)
        return LabelVolume(dims: volume.dims, data: out, maxLabel: Int(maxLabel))
    }

    // MARK: - Pieces

    private struct AccParams { var pz, py, px, z0, y0, x0, Z, Y, X, classes: UInt32 }
    private struct FinParams { var Z, Y, X, classes, ringSlabs, firstSlab, slabCount: UInt32 }

    private func run(_ pipeline: MTLComputePipelineState, grid: MTLSize, _ bind: (MTLComputeCommandEncoder) -> Void) throws {
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw SegmenterError.noMetal }
        enc.setComputePipelineState(pipeline)
        bind(enc)
        let w = pipeline.threadExecutionWidth
        enc.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// Trilinear resample to isotropic `spacing`, matching scipy.ndimage.zoom (output size
    /// round(n·zoom), corners aligned, edge clamp) and TotalSegmentator's int32 cast.
    static func resample(_ v: NiftiVolume, to spacing: Float) -> ((x: Int, y: Int, z: Int), [Float]) {
        let (nx, ny, nz) = v.dims, pix = [v.voxelSize.0, v.voxelSize.1, v.voxelSize.2]
        let n = [nx, ny, nz], r = (0..<3).map { max(1, Int((Float(n[$0]) * pix[$0] / spacing).rounded())) }
        // Per-axis source index and weight (corner-aligned mapping).
        func map(_ nIn: Int, _ nOut: Int) -> ([Int], [Float]) {
            (0..<nOut).map { o -> (Int, Float) in
                let s = nOut > 1 ? Float(o) * Float(nIn - 1) / Float(nOut - 1) : 0
                let i = min(Int(s), nIn - 2 < 0 ? 0 : nIn - 2)
                return (i, nIn > 1 ? s - Float(i) : 0)
            }.reduce(into: ([Int](), [Float]())) { $0.0.append($1.0); $0.1.append($1.1) }
        }
        let (ix, wx) = map(nx, r[0]), (iy, wy) = map(ny, r[1]), (iz, wz) = map(nz, r[2])
        var out = [Float](repeating: 0, count: r[0] * r[1] * r[2])
        v.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var row0 = [Float](repeating: 0, count: r[0]), row1 = row0, r00 = row0, r01 = row0
                for z in 0..<r[2] {
                    let z0 = iz[z], z1 = min(z0 + 1, nz - 1), fz = wz[z]
                    for y in 0..<r[1] {
                        let y0 = iy[y], y1 = min(y0 + 1, ny - 1), fy = wy[y]
                        // Interpolate along x for the four (y,z) corner rows, then blend.
                        func lerpRow(_ yy: Int, _ zz: Int, into row: inout [Float]) {
                            let base = nx * (yy + ny * zz)
                            for x in 0..<r[0] {
                                let x0 = ix[x], x1 = min(x0 + 1, nx - 1)
                                row[x] = src[base + x0] + (src[base + x1] - src[base + x0]) * wx[x]
                            }
                        }
                        lerpRow(y0, z0, into: &row0); lerpRow(y1, z0, into: &row1)
                        lerpRow(y0, z1, into: &r00); lerpRow(y1, z1, into: &r01)
                        let o = r[0] * (y + r[1] * z)
                        for x in 0..<r[0] {
                            let a = row0[x] + (row1[x] - row0[x]) * fy, b = r00[x] + (r01[x] - r00[x]) * fy
                            dst[o + x] = (a + (b - a) * fz).rounded(.towardZero) // int32 cast
                        }
                    }
                }
            }
        }
        return ((r[0], r[1], r[2]), out)
    }

    /// Inverse of the resampling's coordinate map, rounded to the nearest source voxel.
    static func nearestMap(from nOrig: Int, to nRes: Int) -> [Int] {
        (0..<nOrig).map { nOrig > 1 ? min(nRes - 1, max(0, Int((Float($0) * Float(nRes - 1) / Float(nOrig - 1)).rounded()))) : 0 }
    }

    static func nonZeroBox(_ v: [Float], dims d: (x: Int, y: Int, z: Int)) -> ((x: Int, y: Int, z: Int), (x: Int, y: Int, z: Int)) {
        var lo = (x: d.x, y: d.y, z: d.z), hi = (x: -1, y: -1, z: -1)
        v.withUnsafeBufferPointer { p in
            for z in 0..<d.z { for y in 0..<d.y {
                let base = d.x * (y + d.y * z)
                var first = -1, last = -1
                for x in 0..<d.x where p[base + x] != 0 { if first < 0 { first = x }; last = x }
                if first >= 0 {
                    lo = (min(lo.x, first), min(lo.y, y), min(lo.z, z)); hi = (max(hi.x, last), max(hi.y, y), max(hi.z, z))
                }
            } }
        }
        return hi.x < 0 ? ((0, 0, 0), (d.x - 1, d.y - 1, d.z - 1)) : (lo, hi)
    }

    /// nnU-Net's compute_steps_for_sliding_window.
    static func steps(size: Int, patch: Int) -> [Int] {
        let target = Float(patch) * stepFraction
        let n = Int((Float(size - patch) / target).rounded(.up)) + 1
        guard n > 1 else { return [0] }
        let actual = Float(size - patch) / Float(n - 1)
        return (0..<n).map { Int((actual * Float($0)).rounded(.toNearestOrEven)) }
    }

    /// nnU-Net's Gaussian importance map: σ = patch/8 per axis, peak 1 at the centre.
    static func gaussian() -> [Float] {
        let P = patch
        func axis(_ n: Int) -> [Float] {
            let c = n / 2, s = Float(n) / 8
            return (0..<n).map { exp(-Float(($0 - c) * ($0 - c)) / (2 * s * s)) }
        }
        let gz = axis(P.z), gy = axis(P.y), gx = axis(P.x)
        var g = [Float](repeating: 0, count: P.z * P.y * P.x)
        for z in 0..<P.z { for y in 0..<P.y { for x in 0..<P.x { g[(z * P.y + y) * P.x + x] = gz[z] * gy[y] * gx[x] } } }
        return g
    }
}
