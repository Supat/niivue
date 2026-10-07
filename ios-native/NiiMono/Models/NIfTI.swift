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
import zlib

/// Voxels are reoriented to the closest RAS+ layout at load time (x → Right,
/// y → Anterior, z → Superior), so nothing downstream deals with orientation.
struct NiftiVolume: @unchecked Sendable {
    /// Which loaded image this is (copies share it), so views caching a slice image can tell
    /// two images apart.
    var id = UUID()
    var dims: (Int, Int, Int)          // voxel counts x,y,z (RAS)
    var voxelSize: (Float, Float, Float) // mm per voxel
    var data: [Float]                  // length = nx*ny*nz, scl_slope/inter applied
    var dataMin: Float                 // full intensity range
    var dataMax: Float
    var displayMin: Float              // suggested window low (cal_min or 2nd percentile)
    var displayMax: Float              // suggested window high (cal_max or 98th percentile)
    /// What the file records about the subject (see `SubjectInfo`); fields are nil when absent.
    var subject = SubjectInfo()
    /// How the file's index axes map onto the RAS axes here: RAS axis w is file axis
    /// `filePerm[w]`, reversed when `fileFlip[w]`. Lets voxel coordinates written against
    /// the file (e.g. FOV boxes in a metadata JSON) be placed on the displayed grid.
    var filePerm = [0, 1, 2]
    var fileFlip = [false, false, false]
    /// A JSON document carried in the header extension (the stitching pipeline embeds its
    /// acquisition metadata there), so it travels with the file.
    var embeddedJSON: Data?
    /// The file's own 348-byte header (little-endian files only), so a label map can be written
    /// back on the file's grid and orientation (see `labelFile(_:like:json:)`).
    var header: Data?

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

/// Weight, height and age of the subject, where a file records them. NIfTI has no fields
/// for these, so they are looked for where converters put them: `PatientWeight=80`,
/// `"PatientSize": 1.68`, `PatientAge=045Y`, or plain `weight=` / `height=` / `age=`, in the
/// header's `descrip` text, in a header extension, or in a BIDS JSON beside the scan.
struct SubjectInfo: Equatable {
    var weightKg: Double?
    var heightCm: Double?
    var ageYears: Double?
    var id: String?

    init() {}

    /// From a NIfTI header: `descrip` (80 bytes at 148) plus any extension block.
    init(headerOf d: Data, voxOffset: Int) {
        guard d.count >= 352 else { self.init(); return }
        var text = String(decoding: d[d.startIndex + 148..<d.startIndex + 228], as: UTF8.self)
        if d[d.startIndex + 348] != 0, voxOffset > 352, voxOffset <= d.count {
            text += "\n" + String(decoding: d[d.startIndex + 352..<d.startIndex + voxOffset], as: UTF8.self)
        }
        self.init(text: text)
        // The ANALYZE-era db_name field (18 bytes at 14) is where some tools keep the patient id.
        if id == nil {
            let name = String(decoding: d[d.startIndex + 14..<d.startIndex + 32].prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { id = name }
        }
    }

    /// From free text (header text or a JSON file). Implausible values are ignored.
    init(text: String) {
        func value(_ names: String, unit: String = "") -> Double? {
            let pattern = #"(?i)(?:patient[_ ]?)?(?:"# + names + #")(?:[_ ]?(?:kg|cm|m|years?))?["']?\s*[:=]\s*["']?0*([0-9]+(?:\.[0-9]+)?)"#
            guard let re = try? Regex(pattern), let m = text.firstMatch(of: re), let s = m.output[1].substring else { return nil }
            return Double(s)
        }
        if let kg = value("weight"), (1...500).contains(kg) { weightKg = kg }
        // DICOM/BIDS PatientSize is metres; a bare number under 3 is taken as metres too.
        if let h = value("size|height") {
            let cm = h < 3 ? h * 100 : h
            if (30...250).contains(cm) { heightCm = cm }
        }
        if let a = value("age"), (0...120).contains(a) { ageYears = a } // DICOM "045Y" → 45
        // `PatientID=S_S`, `"PatientID": "S_S"`, `subject_id: 12`.
        if let re = try? Regex(#"(?i)(?:patient|subject)[_ ]?id["']?\s*[:=]\s*["']?([^"';,\s}]+)"#),
           let m = text.firstMatch(of: re), let s = m.output[1].substring { id = String(s) }
    }

    /// Fill the gaps from another source.
    func merging(_ other: SubjectInfo) -> SubjectInfo {
        var out = self
        out.weightKg = weightKg ?? other.weightKg
        out.heightCm = heightCm ?? other.heightCm
        out.ageYears = ageYears ?? other.ageYears
        out.id = id ?? other.id
        return out
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
    /// The first header extension whose body is a JSON object (8-byte esize/ecode, then text).
    static func embeddedJSON(in d: Data, voxOffset: Int) -> Data? {
        let b = d.startIndex
        guard d.count >= 360, d[b + 348] != 0, voxOffset <= d.count else { return nil }
        var at = 352
        while at + 8 <= voxOffset {
            // ponytail: esize read little-endian; a big-endian file just finds no JSON.
            let esize = (0..<4).reduce(0) { $0 | Int(d[b + at + $1]) << (8 * $1) }
            guard esize >= 8, at + esize <= voxOffset else { return nil }
            let body = d[b + at + 8..<b + at + esize]
            if body.first == UInt8(ascii: "{"), let end = body.lastIndex(of: UInt8(ascii: "}")) { return Data(body[...end]) }
            at += esize
        }
        return nil
    }


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
        var perm: [Int]          // file axis for each RAS axis
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
        return Layout(od: perm.map { dim[$0] }, perm: perm, stride: perm.map { [1, nx, nx * ny][$0] },
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
        } else if hi > lo, (Float(1023) / (hi - lo)).isFinite {
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

        // cal_min/cal_max may lie outside the data; the window sliders span the data range.
        winLo = min(max(winLo, lo), hi); winHi = min(max(winHi, lo), hi)
        if winHi <= winLo { (winLo, winHi) = (lo, hi) }
        return NiftiVolume(
            dims: (L.od[0], L.od[1], L.od[2]),
            voxelSize: (L.pix[0], L.pix[1], L.pix[2]),
            data: out,
            dataMin: lo, dataMax: hi,
            displayMin: winLo, displayMax: winHi,
            subject: SubjectInfo(headerOf: d, voxOffset: L.voxOffset),
            filePerm: L.perm, fileFlip: L.flip,
            embeddedJSON: embeddedJSON(in: d, voxOffset: L.voxOffset),
            header: L.bigEndian ? nil : Data(d.prefix(348))
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
                    let p = row.baseAddress!
                    // Labels outside 0...255 (e.g. FreeSurfer's 1000+ ids) become 0 rather than
                    // a false 255; NaN too. Rare, so only rows that need it take the scalar pass.
                    var rhi: Float = 0
                    vDSP_maxv(p, 1, &rhi, n)
                    if !(rhi <= 255.5) { for i in 0..<Int(n) where !(p[i] <= 255.5) { p[i] = 0 }; vDSP_maxv(p, 1, &rhi, n) }
                    vDSP_vclip(p, 1, &zero, &top, p, 1, n) // negatives / NaN → 0
                    vDSP_vfixru8(p, 1, dst.baseAddress!.advanced(by: o), 1, n)
                    maxLabel = max(maxLabel, UInt8(min(255, max(0, rhi.rounded()))))
                }
            }
        } else {
            L.forEachVoxel(in: d) { o, raw in
                let v: UInt8 = raw.isFinite && raw >= 0 && raw <= 255.5 ? UInt8(raw.rounded()) : 0
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

    // MARK: - Writing

    /// Serialise an 8-bit label map as NIfTI-1 (RAS+, sform = voxel size on the diagonal),
    /// gzipped. Reads back through `parseLabels` unchanged.
    static func labelFile(_ labels: LabelVolume, voxelSize: (Float, Float, Float)) -> Data {
        var h = Data(count: 352)
        func put<T: FixedWidthInteger>(_ off: Int, _ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.replaceSubrange(off..<off + MemoryLayout<T>.size, with: $0) } }
        func putF(_ off: Int, _ v: Float) { put(off, v.bitPattern) }
        put(0, Int32(348))
        put(40, Int16(3)); put(42, Int16(labels.dims.0)); put(44, Int16(labels.dims.1)); put(46, Int16(labels.dims.2))
        for off in stride(from: 48, through: 54, by: 2) { put(off, Int16(1)) }
        put(70, Int16(2)); put(72, Int16(8))                       // DT_UINT8, bitpix
        putF(76, 1); putF(80, voxelSize.0); putF(84, voxelSize.1); putF(88, voxelSize.2)
        for off in stride(from: 92, through: 104, by: 4) { putF(off, 1) }
        putF(108, 352); putF(112, 1)                               // vox_offset, scl_slope
        put(123, UInt8(2))                                         // xyzt_units: mm
        put(254, Int16(1))                                         // sform_code: scanner
        putF(280, voxelSize.0); putF(300, voxelSize.1); putF(320, voxelSize.2) // srow diagonals
        h.replaceSubrange(344..<348, with: [0x6e, 0x2b, 0x31, 0x00]) // "n+1\0"
        return gzip(h + Data(labels.data))
    }

    /// A label map on `volume`'s original grid: voxels back in the file's index order and its
    /// header (so its qform/sform), with `json` in a header extension (ecode 6). Other tools
    /// then overlay it on the scan; the app reads it back through `parseLabels`. Falls back to
    /// the RAS layout of `labelFile(_:voxelSize:)` when the scan's header wasn't kept.
    static func labelFile(_ labels: LabelVolume, like volume: NiftiVolume, json: Data?) -> Data {
        guard let src = volume.header, src.count >= 348 else { return labelFile(labels, voxelSize: volume.voxelSize) }
        let od = [labels.dims.0, labels.dims.1, labels.dims.2]
        var fd = [0, 0, 0]
        for w in 0..<3 { fd[volume.filePerm[w]] = od[w] }
        let fs = [1, fd[0], fd[0] * fd[1]]
        // File offset of each RAS coordinate, per axis: RAS axis w is file axis filePerm[w],
        // reversed when fileFlip[w].
        let off = (0..<3).map { w in (0..<od[w]).map { i in (volume.fileFlip[w] ? od[w] - 1 - i : i) * fs[volume.filePerm[w]] } }
        var body = [UInt8](repeating: 0, count: labels.data.count)
        if volume.filePerm[0] == 0 {
            // RAS x is the file's fastest axis (practically every file): whole rows move with one
            // copy each, mirrored first in one vImage pass if x is reversed. A per-voxel loop
            // took ~8 s for a 64 M-voxel scan in a Debug build.
            var src = labels.data
            if volume.fileFlip[0] {
                src.withUnsafeMutableBytes { p in
                    var b = vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(od[1] * od[2]), width: vImagePixelCount(od[0]), rowBytes: od[0])
                    _ = vImageHorizontalReflect_Planar8(&b, &b, vImage_Flags(kvImageNoFlags))
                }
            }
            src.withUnsafeBytes { s in body.withUnsafeMutableBytes { d in
                var row = 0
                for z in 0..<od[2] { for y in 0..<od[1] {
                    (d.baseAddress! + off[1][y] + off[2][z]).copyMemory(from: s.baseAddress! + row * od[0], byteCount: od[0])
                    row += 1
                } }
            } }
        } else {
            labels.data.withUnsafeBufferPointer { src in body.withUnsafeMutableBufferPointer { dst in
                var i = 0
                for z in 0..<od[2] { for y in 0..<od[1] {
                    let base = off[1][y] + off[2][z]
                    for x in 0..<od[0] { dst[base + off[0][x]] = src[i]; i += 1 }
                } }
            } }
        }

        return gzip(orientedHeader(src, fileDims: fd, datatype: 2, bitpix: 8, json: json) + Data(body))
    }

    /// The scan's own header for a file on its grid (fileDims in file order): 3D, the given
    /// datatype, no scaling or display range, `json` as a header extension (ecode 6).
    private static func orientedHeader(_ src: Data, fileDims fd: [Int], datatype: Int16, bitpix: Int16, json: Data?) -> Data {
        var h = Data(src.prefix(348))
        func put<T: FixedWidthInteger>(_ o: Int, _ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.replaceSubrange(o..<o + MemoryLayout<T>.size, with: $0) } }
        func putF(_ o: Int, _ v: Float) { put(o, v.bitPattern) }
        put(0, Int32(348))
        put(40, Int16(3)); put(42, Int16(fd[0])); put(44, Int16(fd[1])); put(46, Int16(fd[2]))
        for o in stride(from: 48, through: 54, by: 2) { put(o, Int16(1)) }
        put(70, datatype); put(72, bitpix)
        putF(112, 1); putF(116, 0)                            // scl_slope, scl_inter
        putF(124, 0); putF(128, 0)                            // cal_max, cal_min
        h.replaceSubrange(344..<348, with: [0x6e, 0x2b, 0x31, 0x00]) // "n+1\0"
        var ext = Data([json == nil ? 0 : 1, 0, 0, 0])
        if let json {
            let esize = (8 + json.count + 15) / 16 * 16
            var e = Data(); var size = Int32(esize).littleEndian, code = Int32(6).littleEndian
            withUnsafeBytes(of: &size) { e.append(contentsOf: $0) }; withUnsafeBytes(of: &code) { e.append(contentsOf: $0) }
            e.append(json); e.append(Data(count: esize - e.count))
            ext.append(e)
        }
        putF(108, Float(348 + ext.count))                     // vox_offset
        return h + ext
    }

    /// The scan's intensities (`volume.data`, scaling applied) as float32 on its own grid and
    /// orientation, with voxels `mask` marks set to `background`: the cleaned scan, ready for
    /// other tools. Its header (affine) and any embedded JSON are the scan's. Built row by row
    /// with vDSP straight into the output; nil when the scan's header wasn't kept.
    static func floatFile(_ volume: NiftiVolume, mask: [UInt8]?, background: Float) -> Data? {
        guard let src = volume.header, src.count >= 348 else { return nil }
        let od = [volume.dims.0, volume.dims.1, volume.dims.2]
        var fd = [0, 0, 0]
        for w in 0..<3 { fd[volume.filePerm[w]] = od[w] }
        let fs = [1, fd[0], fd[0] * fd[1]]
        let off = (0..<3).map { w in (0..<od[w]).map { i in (volume.fileFlip[w] ? od[w] - 1 - i : i) * fs[volume.filePerm[w]] } }
        let header = orientedHeader(src, fileDims: fd, datatype: 16, bitpix: 32, json: volume.embeddedJSON)
        let n = od[0], count = volume.data.count
        var out = Data(count: header.count + count * 4)
        out.replaceSubrange(0..<header.count, with: header)
        var row = [Float](repeating: 0, count: n), keep = [Float](repeating: 0, count: n)
        var zero: Float = 0, one: Float = 1, negOne: Float = -1, bg = background, negBg = -background
        out.withUnsafeMutableBytes { o in volume.data.withUnsafeBufferPointer { d in row.withUnsafeMutableBufferPointer { r in keep.withUnsafeMutableBufferPointer { k in
            let body = (o.baseAddress! + header.count).assumingMemoryBound(to: Float.self)
            let nw = vDSP_Length(n)
            var i = 0
            for z in 0..<od[2] { for y in 0..<od[1] {
                defer { i += n }
                let rp = r.baseAddress!
                rp.update(from: d.baseAddress! + i, count: n)
                if let mask {
                    mask.withUnsafeBufferPointer { m in
                        vDSP_vfltu8(m.baseAddress! + i, 1, k.baseAddress!, 1, nw)            // marked → ≥1
                        vDSP_vclip(k.baseAddress!, 1, &zero, &one, k.baseAddress!, 1, nw)
                        vDSP_vsmsa(k.baseAddress!, 1, &negOne, &one, k.baseAddress!, 1, nw)  // keep = 1 - marked
                        vDSP_vsadd(rp, 1, &negBg, rp, 1, nw)                                 // (v - bg) · keep + bg
                        vDSP_vmul(rp, 1, k.baseAddress!, 1, rp, 1, nw)
                        vDSP_vsadd(rp, 1, &bg, rp, 1, nw)
                    }
                }
                if volume.filePerm[0] == 0 {
                    if volume.fileFlip[0] { vDSP_vrvrs(rp, 1, nw) }
                    (body + off[1][y] + off[2][z]).update(from: rp, count: n)
                } else {
                    let base = off[1][y] + off[2][z]
                    for x in 0..<n { body[base + off[0][x]] = rp[x] }
                }
            } }
        } } } }
        return gzip(out)
    }

    /// gzip-wrap raw deflate from the Compression framework (header, body, CRC-32, size).
    static func gzip(_ d: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0x03])
        let cap = d.count + d.count / 100 + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = d.withUnsafeBytes { src in
            compression_encode_buffer(dst, cap, src.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count, nil, COMPRESSION_ZLIB)
        }
        if n > 0 { out.append(dst, count: n) } else { // incompressible: a stored block would be needed; fall back to level 0 via zlib
            out.append(contentsOf: [1, UInt8(d.count & 0xff), UInt8((d.count >> 8) & 0xff), UInt8(~d.count & 0xff), UInt8((~d.count >> 8) & 0xff)])
            out.append(d) // ponytail: single stored block, valid only below 64 KiB; deflate never fails on real volumes
        }
        var crc = d.withUnsafeBytes { UInt32(crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt(d.count))) }.littleEndian
        var size = UInt32(truncatingIfNeeded: d.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
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
