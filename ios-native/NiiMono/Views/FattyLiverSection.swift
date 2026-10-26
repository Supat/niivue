//
//  FattyLiverSection.swift — the apparent liver fat fraction over the segmented liver,
//  shown on the Segmentation page when a map has a liver and both Dixon images are here.
//  The measurement lives in the sidecar: made once, shown from then on, remade on request.
//

import SwiftUI

struct FattyLiverSection: View {
    @Bindable var viewer: ViewerViewModel
    /// The loaded maps with a liver label, the shown one first.
    let maps: [SegmentationMap]
    @State private var measuring = false
    @State private var failed = false
    /// The map picked here; until then the one the kept measurement was made on, else the first.
    @State private var chosenName: String?

    private var model: SegmentationViewModel { viewer.segmentation }
    private var map: SegmentationMap {
        maps.first { $0.name == (chosenName ?? viewer.fattyLiver?.mapName) } ?? maps[0]
    }

    var body: some View {
        Section("Fatty Liver") {
            if maps.count > 1 {
                Picker("Segmentation", selection: Binding(get: { map.name }, set: { name in
                    chosenName = name
                    failed = false
                    viewer.fattyLiver = nil // remeasured on the new map by the task below
                })) {
                    ForEach(maps, id: \.name) { Text($0.name).tag($0.name) }
                }
            } else {
                LabeledContent("Segmentation", value: map.name)
            }
            let liverNames = FattyLiverEstimate.labelNames(in: map.table, named: "liver")
            let spleenNames = FattyLiverEstimate.labelNames(in: map.table, named: "spleen")
            LabeledContent("Labels", value: "liver: " + liverNames.joined(separator: ", ")
                           + (spleenNames.isEmpty ? "; no spleen" : "; spleen: " + spleenNames.joined(separator: ", ")))
            if let e = viewer.fattyLiver {
                if let measured = e.mapName, measured != map.name {
                    Text("Measured on “\(measured)”, which is no longer loaded. Measure Again uses the map above.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("Liver fat fraction", value: String(format: "%.1f%% (IQR %.1f–%.1f)", e.liverPercent, e.iqrLow, e.iqrHigh))
                if let s = e.spleenPercent {
                    LabeledContent("Spleen (zero reference)", value: String(format: "%.1f%%", s))
                    LabeledContent("Liver − spleen", value: String(format: "%.1f%%", e.referencedPercent))
                }
                LabeledContent("T1-corrected", value: String(format: "%.1f%%", e.correctedPercent))
                LabeledContent("Estimate") {
                    Text("\(e.grade.rawValue) (±\(Int(FattyLiverEstimate.uncertaintyPP)) pp)")
                        .foregroundStyle(e.grade == .none ? Color.primary : Color(red: Double(e.grade.color.x), green: Double(e.grade.color.y), blue: Double(e.grade.color.z)))
                }
                if let l = e.liverDrop, let s = e.spleenDrop {
                    LabeledContent("In → opposed drop", value: String(format: "liver %.0f%%, spleen %.0f%%", l * 100, s * 100))
                }
                LabeledContent("Voxels", value: e.spleenVoxels > 0 ? "liver \(e.liverVoxels), spleen \(e.spleenVoxels)" : "liver \(e.liverVoxels)")
                if measuring {
                    ProgressView("Measuring…")
                } else {
                    Button("Measure Again") { Task { await measure() } }
                }
                // The fat-fraction map over the liver, as another segmentation map (grade colours; its label list is the legend).
                if model.makingLiverFat {
                    ProgressView("Making fat map…")
                } else {
                    Button(model.maps.contains { $0.name == LabelTable.liverFatMapName } ? "Remake Fat Map" : "Show Fat Map") {
                        Task { await model.showLiverFat(from: map, floorPercent: e.spleenPercent ?? 0) }
                    }
                }
                Text(String(format: "Median F/(W+F) over the liver eroded by 2 voxels, less the spleen's reading (the noise floor); T1 bias taken out for TR %.2f ms, %.0f°%@ (T1 liver 842 ms, fat 382 ms at 3 T). A negative in→opposed drop means T2* decay between the echoes outweighs the fat. Two-point Dixon, no T2* correction: an apparent fat fraction with limits of agreement of about ±6–7 pp against PDFF (grades at 6 / 17 / 22%%), not valid with iron overload or cirrhosis.",
                            e.acquisition.trMs, e.acquisition.flipDeg, e.acquisition.fromFile ? " (from file)" : ""))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if measuring {
                ProgressView("Measuring…")
            } else if failed {
                Text("The liver label erodes away or is not on this grid.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Button("Measure") { Task { await measure() } }
            }
        }
        // First time only (the sidecar keeps the result); re-tried as the companion images arrive.
        .task(id: "\(viewer.fattyLiver == nil) \(model.waterImage?.id.uuidString ?? "") \(model.fatImage?.id.uuidString ?? "")") {
            if viewer.fattyLiver == nil { await measure() }
        }
    }

    private func measure() async {
        guard let water = model.waterImage, let fat = model.fatImage, !measuring else { return }
        measuring = true
        defer { measuring = false }
        let inPhase = model.phase[.inPhase], opposed = model.phase[.opposed], map = map, acquisition = viewer.acquisition
        let e = await Task.detached(priority: .userInitiated) {
            FattyLiverEstimate.compute(water: water, fat: fat, inPhase: inPhase, opposed: opposed, map: map, acquisition: acquisition)
        }.value
        if let e { viewer.fattyLiver = e } else { failed = true }
    }
}
