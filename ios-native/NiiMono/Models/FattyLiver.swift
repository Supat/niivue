//
//  FattyLiver.swift — an apparent liver fat fraction from the two-point Dixon water and fat
//  images, over the segmented liver with the spleen as a zero reference.
//
//  Not a validated PDFF: two echoes give no T2* correction, the 10° flip angle biases toward
//  fat (corrected here with assumed 3 T T1s, Kühn 2014), the fat model is single-peak and
//  iron cannot be assessed. Two-point Dixon at this flip angle tracks MRS/PDFF with r ≈ 0.95,
//  a mean bias of about ±1 pp and individual limits of agreement of roughly ±6–7 pp
//  (Kukuk 2015, Elfaal 2023); it is not valid with iron overload or cirrhosis.
//

import Foundation

/// Sequence values the T1 correction needs, from the BIDS JSON beside the scan when it has
/// them, else the whole-body VIBE protocol's (TR 4.07 ms, 10°).
struct DixonAcquisition: Codable, Equatable {
    var trMs = 4.07
    var flipDeg = 10.0
    var fromFile = false

    init() {}
    /// `"RepetitionTime": 0.00407` (seconds) and `"FlipAngle": 10` as dcm2niix writes, or the
    /// stitching pipeline's `"RepetitionTime_ms": "4.07"` / `"FlipAngle_deg": "10"`.
    init(text: String) {
        func value(_ key: String) -> Double? {
            guard let re = try? Regex(#""# + key + #"""?\s*:\s*"?([0-9]+(?:\.[0-9]+)?(?:[eE]-?[0-9]+)?)"#),
                  let m = text.firstMatch(of: re), let s = m.output[1].substring else { return nil }
            return Double(s)
        }
        if let tr = value("RepetitionTime_ms"), tr > 0, tr < 1000 { trMs = tr; fromFile = true }
        else if let tr = value("RepetitionTime"), tr > 0, tr < 1 { trMs = tr * 1000; fromFile = true }
        if let fa = value("FlipAngle(?:_deg)?"), fa > 0, fa < 90 { flipDeg = fa; fromFile = true }
    }

    /// Spoiled-gradient-echo signal weight for a T1 (ms): sin α (1−E) / (1−E cos α).
    func weight(t1Ms: Double) -> Double {
        let a = flipDeg * .pi / 180, e = exp(-trMs / t1Ms)
        return sin(a) * (1 - e) / (1 - e * cos(a))
    }
    /// How much more a fat proton weighs than a water proton in the vendor images.
    var fatOverWater: Double { weight(t1Ms: Self.t1FatMs) / weight(t1Ms: Self.t1LiverMs) }
    static let t1LiverMs = 842.0, t1FatMs = 382.0 // 3 T, Kühn 2014
}

/// Steatosis grade from a fat fraction in percent, at the PDFF bands ≈6 / 17 / 22 %.
enum SteatosisGrade: String, CaseIterable {
    case none = "No steatosis", mild = "Mild", moderate = "Moderate", severe = "Severe"
    init(percent: Double) {
        self = percent < 6 ? .none : percent < 17 ? .mild : percent < 22 ? .moderate : .severe
    }
    /// The grade's band, for the fat map's legend.
    var range: String {
        switch self {
        case .none: return "< 6 %"
        case .mild: return "6–17 %"
        case .moderate: return "17–22 %"
        case .severe: return "≥ 22 %"
        }
    }
    /// The fat map's label for the grade (1...4).
    var label: UInt8 { UInt8(Self.allCases.firstIndex(of: self)! + 1) }
    /// The fat map's colour for the grade (0...1 RGB): blue, yellow, orange, red.
    var color: SIMD3<Float> {
        switch self {
        case .none: return [0.15, 0.35, 1.0]
        case .mild: return [1.0, 0.9, 0.2]
        case .moderate: return [1.0, 0.55, 0.1]
        case .severe: return [1.0, 0.1, 0.1]
        }
    }
}

/// Kept in the sidecar once measured (the measurement is remade only on request).
struct FattyLiverEstimate: Codable, Equatable {
    /// Median F/(W+F) over the eroded liver, in percent, and its interquartile range.
    var liverPercent: Double, iqrLow: Double, iqrHigh: Double
    /// The same over the spleen (which holds no fat: what the method reads where there is none —
    /// the magnitude noise floor), or nil without a spleen label.
    var spleenPercent: Double?
    /// Liver minus spleen (the liver value alone without a spleen), floored at 0.
    var referencedPercent: Double
    /// The referenced value with the T1 bias taken out (assumed T1s), in percent; the grade is from this.
    var correctedPercent: Double
    /// Median (in − opposed) / in over liver and spleen, when both phase images are loaded.
    var liverDrop: Double?, spleenDrop: Double?
    var liverVoxels: Int, spleenVoxels: Int
    var acquisition: DixonAcquisition
    /// The map measured on; absent in older sidecars.
    var mapName: String?
    var grade: SteatosisGrade { SteatosisGrade(percent: correctedPercent) }
    static let uncertaintyPP = 7.0

    /// Label ids in a map whose names say liver / spleen (the tissue map, total_mr, or a drawn label).
    static func labels(in table: LabelTable, named part: String) -> Set<Int> {
        Set(table.names.filter { $0.value.lowercased().contains(part) }.keys)
    }
    static func labelNames(in table: LabelTable, named part: String) -> [String] {
        labels(in: table, named: part).sorted().compactMap { table.names[$0] }
    }

    /// Nil when the map has no liver or the liver erodes away. `water`/`fat`/phase images
    /// share the map's grid. Erosion keeps the median clear of the capsule, vessels at the
    /// edge and partial-volume visceral fat. A few seconds at most; run off the main thread.
    static func compute(water: NiftiVolume, fat: NiftiVolume, inPhase: NiftiVolume?, opposed: NiftiVolume?,
                        map: SegmentationMap, acquisition: DixonAcquisition, erodeVoxels: Int = 2) -> FattyLiverEstimate? {
        let liverIDs = labels(in: map.table, named: "liver"), spleenIDs = labels(in: map.table, named: "spleen")
        guard !liverIDs.isEmpty, map.labels.dims == water.dims, map.labels.dims == fat.dims else { return nil }
        let liver = eroded(map.labels, ids: liverIDs, by: erodeVoxels)
        let spleen = spleenIDs.isEmpty ? [] : eroded(map.labels, ids: spleenIDs, by: erodeVoxels)
        guard liver.count >= 100 else { return nil }
        func percents(_ idx: [Int]) -> [Double] {
            water.data.withUnsafeBufferPointer { w in fat.data.withUnsafeBufferPointer { f in
                idx.compactMap { i -> Double? in let s = Double(w[i]) + Double(f[i]); return s > 0 ? Double(f[i]) / s * 100 : nil }
            } }.sorted()
        }
        let liverFF = percents(liver)
        guard !liverFF.isEmpty else { return nil }
        let spleenFF = percents(spleen)
        let median = liverFF[liverFF.count / 2]
        let referenced = spleenFF.isEmpty ? median : max(median - spleenFF[spleenFF.count / 2], 0)
        let k = acquisition.fatOverWater // F/(F + k·W) with the referenced F:W ratio
        let corrected = referenced / (referenced + k * (100 - referenced)) * 100
        var drops: (Double?, Double?) = (nil, nil)
        if let inPhase, let opposed, inPhase.dims == water.dims, opposed.dims == water.dims {
            func drop(_ idx: [Int]) -> Double? {
                let d = inPhase.data.withUnsafeBufferPointer { i in opposed.data.withUnsafeBufferPointer { o in
                    idx.compactMap { j -> Double? in i[j] > 0 ? Double(i[j] - o[j]) / Double(i[j]) : nil }
                } }.sorted()
                return d.isEmpty ? nil : d[d.count / 2]
            }
            drops = (drop(liver), drop(spleen))
        }
        return FattyLiverEstimate(liverPercent: median, iqrLow: liverFF[liverFF.count / 4], iqrHigh: liverFF[liverFF.count * 3 / 4],
                                  spleenPercent: spleenFF.isEmpty ? nil : spleenFF[spleenFF.count / 2],
                                  referencedPercent: referenced, correctedPercent: corrected, liverDrop: drops.0, spleenDrop: drops.1,
                                  liverVoxels: liver.count, spleenVoxels: spleen.count, acquisition: acquisition,
                                  mapName: map.name)
    }

    /// A label map over the liver whose labels are the steatosis grades (LabelTable.liverFat) of
    /// each voxel's F/(W+F), averaged with its liver neighbours (3×3×3, against the noise speckle),
    /// less `floorPercent` (the spleen's reading). Nil without a liver on the images' grid.
    static func fatMap(water: NiftiVolume, fat: NiftiVolume, map: SegmentationMap, floorPercent: Double) -> LabelVolume? {
        let liverIDs = labels(in: map.table, named: "liver")
        guard !liverIDs.isEmpty, map.labels.dims == water.dims, map.labels.dims == fat.dims else { return nil }
        let liver = eroded(map.labels, ids: liverIDs, by: 0)
        guard !liver.isEmpty else { return nil }
        let (nx, ny, nz) = water.dims
        var lo = (nx, ny, nz), hi = (0, 0, 0)
        for i in liver {
            let x = i % nx, y = (i / nx) % ny, z = i / (nx * ny)
            lo = (min(lo.0, x), min(lo.1, y), min(lo.2, z)); hi = (max(hi.0, x), max(hi.1, y), max(hi.2, z))
        }
        let bx = hi.0 - lo.0 + 1, by = hi.1 - lo.1 + 1, bz = hi.2 - lo.2 + 1
        func local(_ x: Int, _ y: Int, _ z: Int) -> Int { ((z - lo.2) * by + (y - lo.1)) * bx + (x - lo.0) }
        var ff = [Float](repeating: .nan, count: bx * by * bz)
        water.data.withUnsafeBufferPointer { w in fat.data.withUnsafeBufferPointer { f in
            for i in liver {
                let s = w[i] + f[i]
                ff[local(i % nx, (i / nx) % ny, i / (nx * ny))] = s > 0 ? f[i] / s * 100 : 0
            }
        } }
        var out = [UInt8](repeating: 0, count: nx * ny * nz)
        let floorPercent = Float(floorPercent)
        ff.withUnsafeBufferPointer { v in out.withUnsafeMutableBufferPointer { o in
            for i in liver {
                let x = i % nx, y = (i / nx) % ny, z = i / (nx * ny)
                var sum: Float = 0, n = 0
                for dz in max(z - 1, lo.2)...min(z + 1, hi.2) { for dy in max(y - 1, lo.1)...min(y + 1, hi.1) { for dx in max(x - 1, lo.0)...min(x + 1, hi.0) {
                    let p = v[local(dx, dy, dz)]
                    if !p.isNaN { sum += p; n += 1 }
                } } }
                let mean = max(sum / Float(n) - floorPercent, 0)
                o[i] = SteatosisGrade(percent: Double(mean)).label
            }
        } }
        return LabelVolume(dims: water.dims, data: out, maxLabel: SteatosisGrade.allCases.count)
    }

    /// Flat indices of the voxels with one of `ids` that are at least `r` voxels (cube) from any other voxel.
    static func eroded(_ labels: LabelVolume, ids: Set<Int>, by r: Int) -> [Int] {
        let (nx, ny, nz) = labels.dims
        var wanted = [Bool](repeating: false, count: 256)
        for id in ids where (0..<256).contains(id) { wanted[id] = true }
        var mask = [UInt8](repeating: 0, count: nx * ny * nz)
        var lo = (nx, ny, nz), hi = (-1, -1, -1)
        labels.data.withUnsafeBufferPointer { src in mask.withUnsafeMutableBufferPointer { m in
            for z in 0..<nz { for y in 0..<ny {
                let row = (z * ny + y) * nx
                for x in 0..<nx where wanted[Int(src[row + x])] {
                    m[row + x] = 1
                    lo = (min(lo.0, x), min(lo.1, y), min(lo.2, z)); hi = (max(hi.0, x), max(hi.1, y), max(hi.2, z))
                }
            } }
        } }
        guard hi.0 >= 0 else { return [] }
        // Separable: a voxel survives a pass if every neighbour within r along that axis is set.
        var out = mask
        for (stride, lo1, hi1) in [(1, lo.0, hi.0), (nx, lo.1, hi.1), (nx * ny, lo.2, hi.2)] {
            mask.withUnsafeBufferPointer { m in out.withUnsafeMutableBufferPointer { o in
                for z in lo.2...hi.2 { for y in lo.1...hi.1 { for x in lo.0...hi.0 {
                    let i = (z * ny + y) * nx + x
                    guard m[i] != 0 else { continue }
                    let p = stride == 1 ? x : stride == nx ? y : z
                    if p - r < lo1 || p + r > hi1 { o[i] = 0; continue }
                    for d in -r...r where d != 0 && m[i + d * stride] == 0 { o[i] = 0; break }
                } } }
            } }
            mask = out
        }
        var idx = [Int]()
        mask.withUnsafeBufferPointer { m in
            for z in lo.2...hi.2 { for y in lo.1...hi.1 { for x in lo.0...hi.0 {
                let i = (z * ny + y) * nx + x
                if m[i] != 0 { idx.append(i) }
            } } }
        }
        return idx
    }
}
