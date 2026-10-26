//
//  fatty_liver_check.swift — self-check for the apparent liver fat fraction (FattyLiver).
//  Build & run: mkdir -p /tmp/fl && cp spike/fatty_liver_check.swift /tmp/fl/main.swift &&
//    swiftc NiiMono/Models/{NIfTI,SegmentationMap,LabelTable,LabelPainter,FattyLiver}.swift /tmp/fl/main.swift -o /tmp/fl/check && /tmp/fl/check
//

import Foundation

let dims = (40, 40, 40), n = 40 * 40 * 40
func idx(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * 40 + y) * 40 + x }
var labels = [UInt8](repeating: 0, count: n), w = [Float](repeating: 0, count: n), f = [Float](repeating: 0, count: n)
var inp = [Float](repeating: 0, count: n), opp = [Float](repeating: 0, count: n)
// Liver: a 16³ block (tissue-map label 4) at 22 % fat, with a fatty 50 % rim 1 voxel thick; spleen (5): a 10³ block
// reading 2 % (the noise floor), so the referenced liver value is 20 %.
for z in 0..<40 { for y in 0..<40 { for x in 0..<40 {
    let i = idx(x, y, z)
    if (4..<20).contains(x), (4..<20).contains(y), (4..<20).contains(z) {
        labels[i] = 4
        let edge = [x, y, z].contains { $0 == 4 || $0 == 19 }
        let ff: Float = edge ? 0.5 : 0.22
        w[i] = 100 * (1 - ff); f[i] = 100 * ff
    } else if (25..<35).contains(x), (25..<35).contains(y), (25..<35).contains(z) {
        labels[i] = 5; w[i] = 98; f[i] = 2
    }
    inp[i] = w[i] + f[i]; opp[i] = abs(w[i] - f[i])
} } }
func vol(_ d: [Float]) -> NiftiVolume { NiftiVolume(dims: dims, voxelSize: (1.3, 1.3, 1.3), data: d, dataMin: 0, dataMax: 100, displayMin: 0, displayMax: 100) }
let map = SegmentationMap(labels: LabelVolume(dims: dims, data: labels, maxLabel: 5), name: "S_S_tissues.nii.gz", volume: vol(w))

// Erosion by 2 drops the rim and one more layer: 16³ → 12³.
let liver = FattyLiverEstimate.eroded(map.labels, ids: [4], by: 2)
assert(liver.count == 12 * 12 * 12, "eroded liver \(liver.count)")
assert(FattyLiverEstimate.eroded(map.labels, ids: [5], by: 2).count == 6 * 6 * 6)
assert(FattyLiverEstimate.eroded(map.labels, ids: [9], by: 2).isEmpty)

let acq = DixonAcquisition()
let e = FattyLiverEstimate.compute(water: vol(w), fat: vol(f), inPhase: vol(inp), opposed: vol(opp), map: map, acquisition: acq)!
assert(abs(e.liverPercent - 22) < 1e-3, "liver \(e.liverPercent)") // the 50 % rim is eroded away
assert(e.iqrLow == e.iqrHigh, "uniform block has no spread")
assert(try! JSONDecoder().decode(FattyLiverEstimate.self, from: JSONEncoder().encode(e)) == e, "round-trips through the sidecar")
assert(abs(e.spleenPercent! - 2) < 1e-3 && e.spleenVoxels == 216)
assert(abs(e.referencedPercent - 20) < 1e-3, "referenced \(e.referencedPercent)")
// T1 correction: fat weighs ~1.7× water at TR 4.07 ms / 10°, so 20 % apparent is ~12.7 % true.
assert(abs(acq.fatOverWater - 1.71) < 0.02, "k \(acq.fatOverWater)")
assert(abs(e.correctedPercent - 12.7) < 0.2, "corrected \(e.correctedPercent)")
assert(e.grade == .mild)
// Signal drop in → opposed: liver 1 − |0.78 − 0.22| = 44 %, spleen 4 %.
assert(abs(e.liverDrop! - 0.44) < 1e-4 && abs(e.spleenDrop! - 0.04) < 1e-4, "\(e.liverDrop!) \(e.spleenDrop!)")

// The fat map: every liver voxel labelled with its grade (22 − 2 = 20 % → moderate away from the
// rim, the 50 % rim severe), nothing outside the liver.
let fm = FattyLiverEstimate.fatMap(water: vol(w), fat: vol(f), map: map, floorPercent: 2)!
assert(fm.data.reduce(0) { $0 + ($1 == 0 ? 0 : 1) } == 16 * 16 * 16, "fat map covers the liver")
assert(fm.data[idx(12, 12, 12)] == 3 && fm.data[idx(4, 4, 4)] == 4 && fm.data[idx(24, 24, 24)] == 0, "\(fm.data[idx(12, 12, 12)]) \(fm.data[idx(4, 4, 4)])")
assert(fm.maxLabel == 4 && SteatosisGrade.none.label == 1 && SteatosisGrade.severe.label == 4)
assert(LabelTable.liverFat.names[1] == "No steatosis (< 6 %)" && LabelTable.liverFat.names[4] == "Severe (≥ 22 %)", "\(LabelTable.liverFat.names)")
assert(LabelTable.liverFat.colors[1] == SteatosisGrade.none.color && LabelTable.liverFat.colors[4]!.x == 1)
assert(LabelTable.forFile(named: LabelTable.liverFatMapName).names.count == 4)

// A map without a liver, or one on another grid, gives nothing.
assert(FattyLiverEstimate.compute(water: vol(w), fat: vol(f), inPhase: nil, opposed: nil,
                                  map: SegmentationMap(labels: LabelVolume(dims: dims, data: labels.map { $0 == 4 ? 9 : $0 }, maxLabel: 9), name: "x.nii", volume: vol(w)), acquisition: acq) == nil)

// BIDS JSON values, in seconds and degrees; the protocol's when absent.
let a = DixonAcquisition(text: #"{"RepetitionTime": 0.00407, "FlipAngle": 10, "EchoTime": 0.00129}"#)
assert(a.fromFile && abs(a.trMs - 4.07) < 1e-9 && a.flipDeg == 10)
assert(!DixonAcquisition(text: "{}").fromFile)
let p = DixonAcquisition(text: #"{"RepetitionTime_ms": "4.07", "EchoTime_ms": "1.29", "FlipAngle_deg": "10"}"#) // the stitching pipeline's metadata
assert(p.fromFile && abs(p.trMs - 4.07) < 1e-9 && p.flipDeg == 10, "\(p)")
assert(SteatosisGrade(percent: 5.9) == .none && SteatosisGrade(percent: 17) == .moderate && SteatosisGrade(percent: 30) == .severe)
print("fatty liver ok:", e)
