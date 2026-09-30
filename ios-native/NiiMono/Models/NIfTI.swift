//
//  NIfTI.swift
//  Pure-Foundation NIfTI-1 reader. No Metal/UIKit imports so it can also run
//  as a command-line self-check (see spike/nifti_check.swift).
//
//  Scope: NIfTI-1 single-file (.nii / .nii.gz), the formats the app actually
//  loads. NIfTI-2 and separate .hdr/.img are out of scope for the spike.
//

import Accelerate
import Compression
import Foundation

/// Voxels are reoriented to the closest RAS+ layout at load time (x → Right,
/// y → Anterior, z → Superior), so nothing downstream deals with orientation.
struct NiftiVolume: @unchecked Sendable {
    var dims: (Int, Int, Int)          // voxel counts x,y,z (RAS)
    var voxelSize: (Float, Float, Float) // mm per voxel
    var data: [Float]                  // length = nx*ny*nz, scl_slope/inter applied
    var dataMin: Float                 // full intensity range
    var dataMax: Float
    var displayMin: Float              // suggested window low (cal_min or 2nd percentile)
    var displayMax: Float              // suggested window high (cal_max or 98th percentile)

    var voxelCount: Int { dims.0 * dims.1 * dims.2 }

    /// Slice count along axis 0 (sagittal), 1 (coronal), 2 (axial).
    func count(axis: Int) -> Int { [dims.0, dims.1, dims.2][axis] }

    /// 8-bit windowed slice perpendicular to `axis`, row 0 at the top.
    /// Neurological convention (patient left on screen left), superior/anterior up,
    /// sagittal nose right — niivue's defaults.
    func slice(axis: Int, index: Int, lo: Float, hi: Float) -> (width: Int, height: Int, pixels: [UInt8]) {
        let (nx, ny, nz) = dims
        let (w, h) = axis == 0 ? (ny, nz) : axis == 1 ? (nx, nz) : (nx, ny)
        let k = max(0, min(count(axis: axis) - 1, index))
        let scale = 255 / max(hi - lo, .leastNonzeroMagnitude)
        var px = [UInt8](repeating: 0, count: w * h)
        for r in 0..<h {
            let v = h - 1 - r
            for c in 0..<w {
                let i = axis == 0 ? k + nx * (c + ny * v) : axis == 1 ? c + nx * (k + ny * v) : c + nx * (v + ny * k)
                px[r * w + c] = UInt8(max(0, min(255, (data[i] - lo) * scale)))
            }
        }
        return (w, h, px)
    }

    /// Physical size (mm) of a slice perpendicular to `axis`, for aspect-correct display.
    func sliceExtent(axis: Int) -> (Float, Float) {
        let e = (Float(dims.0) * voxelSize.0, Float(dims.1) * voxelSize.1, Float(dims.2) * voxelSize.2)
        return axis == 0 ? (e.1, e.2) : axis == 1 ? (e.0, e.2) : (e.0, e.1)
    }
}

/// A segmentation on the same grid as a NiftiVolume: one 8-bit label per voxel, 0 = none.
struct LabelVolume: @unchecked Sendable {
    var dims: (Int, Int, Int)
    var data: [UInt8]
    var maxLabel: Int
}

enum NiftiError: LocalizedError, CustomStringConvertible {
    var errorDescription: String? { description }

    case tooSmall
    case badMagic
    case unsupportedDatatype(Int16)
    case truncated(expected: Int, got: Int)
    case gridMismatch((Int, Int, Int), (Int, Int, Int))

    var description: String {
        switch self {
        case .tooSmall: return "file smaller than a NIfTI-1 header (348 bytes)"
        case .badMagic: return "sizeof_hdr is not 348 in either endianness — not NIfTI-1"
        case .unsupportedDatatype(let d): return "unsupported NIfTI datatype code \(d)"
        case .truncated(let e, let g): return "voxel data truncated: expected \(e) bytes, got \(g)"
        case .gridMismatch(let a, let b): return "segmentation grid \(a.0)×\(a.1)×\(a.2) doesn’t match the scan’s \(b.0)×\(b.1)×\(b.2)"
        }
    }
}

enum NIfTI {

    /// Load a NIfTI-1 volume from a .nii or .nii.gz file.
    static func load(contentsOf url: URL) throws -> NiftiVolume {
        let raw = try Data(contentsOf: url)
        let bytes = isGzip(raw) ? try gunzip(raw) : raw
        return try parse(bytes)
    }

    // MARK: - Header + voxel parsing

    /// Everything needed to walk a file's voxels in RAS order.
    private struct Layout {
        var od: [Int]            // output (RAS) dims
        var stride: [Int]        // file-index step per RAS axis
        var flip: [Bool]
        var pix: [Float]         // voxel size per RAS axis
        var voxOffset: Int
        var reader: (UnsafeRawPointer, Int) -> Float
        var datatype: Int16, bigEndian: Bool
        var sclSlope: Float, sclInter: Float, calMin: Float, calMax: Float
        var count: Int { od[0] * od[1] * od[2] }

        /// Whole rows along RAS x are contiguous in the file when x is the file's fastest axis
        /// (true for practically every NIfTI): then each row converts with one vDSP call.
        var rowsAreContiguous: Bool { stride[0] == 1 }

        /// Calls `body(outputRowStart, rawRow)` for every x-row in RAS order, with the row
        /// already converted to Float (byte-swapped, flipped if needed). Requires
        /// `rowsAreContiguous`. `scratch` must hold `od[0]` floats.
        func forEachRow(in d: Data, scratch: inout [Float], _ body: (Int, UnsafeMutableBufferPointer<Float>) -> Void) {
            let n = od[0], nv = vDSP_Length(n)
            d.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                let base = buf.baseAddress!.advanced(by: voxOffset)
                scratch.withUnsafeMutableBufferPointer { row in
                    let out = row.baseAddress!
                    var o = 0
                    for z in 0..<od[2] {
                        let sz = (flip[2] ? od[2] - 1 - z : z) * stride[2]
                        for y in 0..<od[1] {
                            let src = base.advanced(by: (sz + (flip[1] ? od[1] - 1 - y : y) * stride[1]) * bytesPerVoxel)
                            convertRow(src, out, nv)
                            if flip[0] { vDSP_vrvrs(out, 1, nv) }
                            body(o, row)
                            o += n
                        }
                    }
                }
            }
        }

        var bytesPerVoxel: Int { [2: 1, 256: 1, 4: 2, 512: 2, 8: 4, 768: 4, 16: 4, 64: 8][Int(datatype)] ?? 1 }

        /// One row of raw voxels → Float, via vDSP where a conversion exists.
        private func convertRow(_ src: UnsafeRawPointer, _ out: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
            let count = Int(n)
            switch (datatype, bigEndian) {
            case (2, _): vDSP_vfltu8(src.assumingMemoryBound(to: UInt8.self), 1, out, 1, n)
            case (256, _): vDSP_vflt8(src.assumingMemoryBound(to: Int8.self), 1, out, 1, n)
            case (4, false): vDSP_vflt16(src.assumingMemoryBound(to: Int16.self), 1, out, 1, n)
            case (512, false): vDSP_vfltu16(src.assumingMemoryBound(to: UInt16.self), 1, out, 1, n)
            case (8, false): vDSP_vflt32(src.assumingMemoryBound(to: Int32.self), 1, out, 1, n)
            case (768, false): vDSP_vfltu32(src.assumingMemoryBound(to: UInt32.self), 1, out, 1, n)
            case (16, false): out.update(from: src.assumingMemoryBound(to: Float.self), count: count)
            case (64, false): vDSP_vdpsp(src.assumingMemoryBound(to: Double.self), 1, out, 1, n)
            default: for i in 0..<count { out[i] = reader(src, i) } // big-endian: rare, scalar path
            }
        }

        /// Calls `body(outputIndex, rawValue)` for every voxel in RAS order.
        func forEachVoxel(in d: Data, _ body: (Int, Float) -> Void) {
            d.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                let base = buf.baseAddress!.advanced(by: voxOffset)
                var o = 0
                for z in 0..<od[2] {
                    let sz = (flip[2] ? od[2] - 1 - z : z) * stride[2]
                    for y in 0..<od[1] {
                        let sy = sz + (flip[1] ? od[1] - 1 - y : y) * stride[1]
                        for x in 0..<od[0] {
                            body(o, reader(base, sy + (flip[0] ? od[0] - 1 - x : x) * stride[0]))
                            o += 1
                        }
                    }
                }
            }
        }
    }

    private static func layout(_ d: Data) throws -> Layout {
        guard d.count >= 348 else { throw NiftiError.tooSmall }

        // Endianness: sizeof_hdr (@0, Int32) must read as 348.
        let hdrLE: Int32 = d.readLE(0)
        let bigEndian: Bool
        if hdrLE == 348 { bigEndian = false }
        else if Int32(bigEndian: hdrLE) == 348 { bigEndian = true }
        else { throw NiftiError.badMagic }

        func i16(_ off: Int) -> Int16 { bigEndian ? d.readBE(off) : d.readLE(off) }
        func f32(_ off: Int) -> Float {
            let u: UInt32 = bigEndian ? d.readBE(off) : d.readLE(off)
            return Float(bitPattern: u)
        }

        let dim = [Int(i16(42)), Int(i16(44)), Int(i16(46))] // dim[1..3], file order
        let (nx, ny) = (dim[0], dim[1])
        let datatype = i16(70)
        // Header is untrusted: Int(NaN) traps, so validate before converting.
        let vo = f32(108)
        guard vo.isFinite, vo >= 0, vo < Float(Int32.max) else { throw NiftiError.truncated(expected: 352, got: d.count) }
        let voxOffset = vo == 0 ? 352 : Int(vo) // .nii default
        var sclSlope = f32(112); if sclSlope == 0 || !sclSlope.isFinite { sclSlope = 1 }
        var sclInter = f32(116); if !sclInter.isFinite { sclInter = 0 }
        let pix = [f32(80), f32(84), f32(88)].map { $0.isFinite && $0 != 0 ? abs($0) : 1 } // pixdim[1..3]

        guard dim.allSatisfy({ $0 > 0 }) else { throw NiftiError.truncated(expected: 1, got: 0) }
        let count = dim[0] * dim[1] * dim[2]

        let (bytesPerVox, reader) = try voxelReader(datatype: datatype, bigEndian: bigEndian)
        let needed = voxOffset + count * bytesPerVox
        guard d.count >= needed else { throw NiftiError.truncated(expected: needed, got: d.count) }

        // Voxel→world rotation, m[world][voxelAxis]: sform if set, else qform, else identity.
        var m: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        if i16(254) > 0 {
            m = (0..<3).map { w in (0..<3).map { a in f32(280 + 16 * w + 4 * a) } }
            for a in 0..<3 { // strip voxel-size scaling so anisotropy can't skew the axis match
                let n = (m[0][a] * m[0][a] + m[1][a] * m[1][a] + m[2][a] * m[2][a]).squareRoot()
                if n > 0 { for w in 0..<3 { m[w][a] /= n } }
            }
        } else if i16(252) > 0 {
            let b = f32(256), c = f32(260), q = f32(264)
            let a = max(0, 1 - b * b - c * c - q * q).squareRoot()
            let f: Float = f32(76) < 0 ? -1 : 1 // qfac
            m = [[a*a + b*b - c*c - q*q, 2 * (b*c - a*q), 2 * (b*q + a*c) * f],
                 [2 * (b*c + a*q), a*a + c*c - b*b - q*q, 2 * (c*q - a*b) * f],
                 [2 * (b*q - a*c), 2 * (c*q + a*b), (a*a + q*q - c*c - b*b) * f]]
        }
        // Closest axis-aligned orientation: perm[w] = file axis that best matches world axis w.
        // ponytail: snaps oblique acquisitions to the nearest axes (no resampling), like
        // niivue's default; resample through the affine if true-world geometry matters.
        var perm = [0, 1, 2], best: Float = -1
        for p in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let score = abs(m[0][p[0]]) + abs(m[1][p[1]]) + abs(m[2][p[2]])
            if score > best { best = score; perm = p }
        }
        return Layout(od: perm.map { dim[$0] }, stride: perm.map { [1, nx, nx * ny][$0] },
                      flip: (0..<3).map { m[$0][perm[$0]] < 0 }, pix: perm.map { pix[$0] },
                      voxOffset: voxOffset, reader: reader, datatype: datatype, bigEndian: bigEndian,
                      sclSlope: sclSlope, sclInter: sclInter, calMin: f32(128), calMax: f32(124))
    }

    static func parse(_ d: Data) throws -> NiftiVolume {
        let L = try layout(d)
        let count = L.count
        var out = [Float](repeating: 0, count: count)
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        if L.rowsAreContiguous {
            var scratch = [Float](repeating: 0, count: L.od[0])
            var slope = L.sclSlope, inter = L.sclInter
            let n = vDSP_Length(L.od[0])
            let isFloat = L.datatype == 16 || L.datatype == 64
            out.withUnsafeMutableBufferPointer { dst in
                L.forEachRow(in: d, scratch: &scratch) { o, row in
                    let p = dst.baseAddress!.advanced(by: o)
                    vDSP_vsmsa(row.baseAddress!, 1, &slope, &inter, p, 1, n)
                    if isFloat { // NaN/inf poison a sum, so only rows that need it get the scalar scrub
                        var sum: Float = 0
                        vDSP_sve(p, 1, &sum, n)
                        if !sum.isFinite { for i in 0..<Int(n) where !p[i].isFinite { p[i] = 0 } }
                    }
                    var rlo: Float = 0, rhi: Float = 0
                    vDSP_minv(p, 1, &rlo, n); vDSP_maxv(p, 1, &rhi, n)
                    lo = min(lo, rlo); hi = max(hi, rhi)
                }
            }
        } else {
            L.forEachVoxel(in: d) { o, raw in
                var v = raw * L.sclSlope + L.sclInter
                if !v.isFinite { v = 0 }
                out[o] = v
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }

        // Default window: the file's cal_min/cal_max if set, else the 2nd–98th percentile
        // (raw min/max is dominated by a few outlier voxels and renders MRI too dark).
        var winLo = lo, winHi = hi
        if L.calMax > L.calMin, L.calMin.isFinite, L.calMax.isFinite {
            (winLo, winHi) = (L.calMin, L.calMax)
        } else if hi > lo {
            let bins = 1024, s = Float(bins - 1) / (hi - lo)
            // Every 7th voxel is plenty for a display window (and 7× faster in Debug builds).
            var hist = [Int](repeating: 0, count: bins), sampled = 0
            out.withUnsafeBufferPointer { p in
                var i = 0
                while i < count { hist[min(bins - 1, Int((p[i] - lo) * s))] += 1; sampled += 1; i += 7 }
            }
            // Percentiles over the foreground only: the lowest bin is background air,
            // often half the volume, and would drag the 98th percentile into the tissue.
            let fg = sampled - hist[0]
            var acc = 0, loBin = -1, hiBin = bins - 1
            for (b, n) in hist.enumerated().dropFirst() {
                acc += n
                if loBin < 0, acc > fg / 50 { loBin = b }
                if acc >= fg - fg / 50 { hiBin = b; break }
            }
            let a = lo + Float(max(loBin, 0)) / s, b = lo + Float(hiBin + 1) / s
            if b > a { (winLo, winHi) = (a, min(b, hi)) }
        }

        return NiftiVolume(
            dims: (L.od[0], L.od[1], L.od[2]),
            voxelSize: (L.pix[0], L.pix[1], L.pix[2]),
            data: out,
            dataMin: lo, dataMax: hi,
            displayMin: winLo, displayMax: winHi
        )
    }

    /// Parse an integer label map (a segmentation): same reorientation as `parse`, values
    /// kept as 8-bit labels (0 = background). scl_slope/inter are ignored, as for any label file.
    static func parseLabels(_ d: Data) throws -> LabelVolume {
        let L = try layout(d)
        var out = [UInt8](repeating: 0, count: L.count)
        var maxLabel: UInt8 = 0
        if L.rowsAreContiguous {
            var scratch = [Float](repeating: 0, count: L.od[0])
            var zero: Float = 0, top: Float = 255
            let n = vDSP_Length(L.od[0])
            out.withUnsafeMutableBufferPointer { dst in
                L.forEachRow(in: d, scratch: &scratch) { o, row in
                    // Clip to 0...255 (NaN clips to 0 through the comparisons), round, narrow.
                    vDSP_vclip(row.baseAddress!, 1, &zero, &top, row.baseAddress!, 1, n)
                    vDSP_vfixru8(row.baseAddress!, 1, dst.baseAddress!.advanced(by: o), 1, n)
                    var rhi: Float = 0
                    vDSP_maxv(row.baseAddress!, 1, &rhi, n)
                    maxLabel = max(maxLabel, UInt8(min(255, max(0, rhi.rounded()))))
                }
            }
        } else {
            L.forEachVoxel(in: d) { o, raw in
                let v: UInt8 = raw.isFinite && raw >= 0 ? UInt8(min(raw.rounded(), 255)) : 0
                out[o] = v
                if v > maxLabel { maxLabel = v }
            }
        }
        return LabelVolume(dims: (L.od[0], L.od[1], L.od[2]), data: out, maxLabel: Int(maxLabel))
    }

    /// Returns (bytesPerVoxel, (base, index) -> Float).
    private static func voxelReader(datatype: Int16, bigEndian: Bool)
        throws -> (Int, (UnsafeRawPointer, Int) -> Float) {
        func swap16(_ x: UInt16) -> UInt16 { bigEndian ? x.byteSwapped : x }
        func swap32(_ x: UInt32) -> UInt32 { bigEndian ? x.byteSwapped : x }
        func swap64(_ x: UInt64) -> UInt64 { bigEndian ? x.byteSwapped : x }
        switch datatype {
        case 2:   return (1, { b, i in Float(b.load(fromByteOffset: i, as: UInt8.self)) })
        case 256: return (1, { b, i in Float(b.load(fromByteOffset: i, as: Int8.self)) })
        case 4:   return (2, { b, i in Float(Int16(bitPattern: swap16(b.loadUnaligned(fromByteOffset: i*2, as: UInt16.self)))) })
        case 512: return (2, { b, i in Float(swap16(b.loadUnaligned(fromByteOffset: i*2, as: UInt16.self))) })
        case 8:   return (4, { b, i in Float(Int32(bitPattern: swap32(b.loadUnaligned(fromByteOffset: i*4, as: UInt32.self)))) })
        case 768: return (4, { b, i in Float(swap32(b.loadUnaligned(fromByteOffset: i*4, as: UInt32.self))) })
        case 16:  return (4, { b, i in Float(bitPattern: swap32(b.loadUnaligned(fromByteOffset: i*4, as: UInt32.self))) })
        case 64:  return (8, { b, i in Float(Double(bitPattern: swap64(b.loadUnaligned(fromByteOffset: i*8, as: UInt64.self)))) })
        default:  throw NiftiError.unsupportedDatatype(datatype)
        }
    }

    // MARK: - gzip

    static func isGzip(_ d: Data) -> Bool { d.count > 2 && d[d.startIndex] == 0x1f && d[d.startIndex+1] == 0x8b }

    /// Minimal gunzip: strip the gzip wrapper, inflate the raw DEFLATE body with
    /// the Compression framework. Handles FEXTRA/FNAME/FCOMMENT/FHCRC flags.
    /// ponytail: trusts ISIZE trailer for output size (fine for <4GB volumes,
    /// which is all of medical imaging in practice); switch to streaming inflate
    /// if you ever load a volume larger than that.
    static func gunzip(_ d: Data) throws -> Data {
        let bytes = [UInt8](d)
        let bad = NiftiError.truncated(expected: 18, got: bytes.count)
        guard bytes.count >= 18 else { throw bad }  // header + trailer
        var p = 10                              // fixed header
        let flg = bytes[3]
        if flg & 0x04 != 0 {                    // FEXTRA
            let xlen = Int(bytes[p]) | (Int(bytes[p+1]) << 8); p += 2 + xlen
        }
        for bit: UInt8 in [0x08, 0x10] where flg & bit != 0 { // FNAME, FCOMMENT
            while p < bytes.count, bytes[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x02 != 0 { p += 2 }           // FHCRC
        guard p < bytes.count - 8 else { throw bad } // malformed header ran past the body

        let isize = Int(bytes[bytes.count-4]) | (Int(bytes[bytes.count-3]) << 8)
                  | (Int(bytes[bytes.count-2]) << 16) | (Int(bytes[bytes.count-1]) << 24)
        let bodyStart = p, bodyCount = bytes.count - 8 - bodyStart
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: isize)
        defer { dst.deallocate() }

        let n = bytes.withUnsafeBufferPointer { src -> Int in
            compression_decode_buffer(dst, isize,
                                      src.baseAddress!.advanced(by: bodyStart), bodyCount,
                                      nil, COMPRESSION_ZLIB)
        }
        guard n > 0 else { throw NiftiError.truncated(expected: isize, got: 0) }
        return Data(bytes: dst, count: n)
    }
}

// Little/big-endian scalar reads from Data at an absolute offset.
private extension Data {
    func readLE<T: FixedWidthInteger>(_ off: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: off, as: T.self)) }
    }
    func readBE<T: FixedWidthInteger>(_ off: Int) -> T {
        withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: off, as: T.self)) }
    }
}
