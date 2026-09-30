//
//  Segmentation.swift — a label map shown over the scan: which labels are visible, their
//  names and colours, and the slice compositing. The 3D side is in the raycaster.
//

import SwiftUI

/// Names and colours for a family of label files. Picked from the file name.
struct LabelTable {
    let names: [Int: String]
    let colors: [Int: SIMD3<Float>] // 0...1 RGB
    var densities: [Int: Float] = [:] // g/mL, for mass estimates; see `density`

    func name(_ label: Int) -> String { names[label] ?? "Label \(label)" }

    /// Tissue density in g/mL (soft tissue when unknown).
    func density(_ label: Int) -> Float { densities[label] ?? 1.03 }
    static let softTissue: Float = 1.03

    func color(_ label: Int) -> SIMD3<Float> {
        if let c = colors[label] { return c }
        // Fallback palette: spread hues so neighbouring labels differ.
        let h = Double(label) * 0.618034
        let rgb = UIColor(hue: h - floor(h), saturation: 0.75, brightness: 0.95, alpha: 1).rgb
        return SIMD3(Float(rgb.x), Float(rgb.y), Float(rgb.z))
    }

    /// The 14 tissue classes of tissue_render.py, with its colours.
    static let tissues = LabelTable(
        names: [1: "skeletal muscle", 2: "subcutaneous/intermuscular fat", 3: "visceral/internal trunk fat",
                4: "liver", 5: "spleen", 6: "kidneys", 7: "pancreas/adrenals/gallbladder", 8: "stomach/bowel",
                9: "bladder/prostate", 10: "heart", 11: "lungs", 12: "vessels", 13: "bones", 14: "spinal cord/brain"],
        colors: [1: [0.90, 0.20, 0.20], 2: [1.00, 0.85, 0.20], 3: [1.00, 0.55, 0.10], 4: [0.45, 0.25, 0.10],
                 5: [0.55, 0.10, 0.45], 6: [0.20, 0.50, 0.20], 7: [0.60, 0.80, 0.30], 8: [0.35, 0.75, 0.65],
                 9: [0.65, 0.45, 0.85], 10: [0.85, 0.30, 0.55], 11: [0.55, 0.75, 1.00], 12: [0.10, 0.35, 0.95],
                 13: [0.92, 0.92, 0.85], 14: [0.95, 0.60, 0.90]],
        // Adipose 0.92, skeletal muscle 1.06, organs ~1.05, lungs 0.3, bone with marrow ~1.4.
        densities: [1: 1.06, 2: 0.92, 3: 0.92, 4: 1.05, 5: 1.05, 6: 1.05, 7: 1.04, 8: 1.04, 9: 1.03,
                    10: 1.05, 11: 0.30, 12: 1.05, 13: 1.40, 14: 1.04])

    /// TotalSegmentator's `total_mr` task (50 structures).
    static let totalMR = LabelTable(
        names: TotalMR.names.mapValues { $0.replacingOccurrences(of: "_", with: " ") },
        colors: [:],
        densities: Dictionary(uniqueKeysWithValues: (1...50).map { l in
            (l, [10, 11].contains(l) ? Float(0.30) : (18...20).contains(l) || (30...39).contains(l) ? 1.40 : 1.05) }))

    static let generic = LabelTable(names: [:], colors: [:])

    static func forFile(named name: String) -> LabelTable {
        let n = name.lowercased()
        if n.contains("tissue") { return .tissues }
        if n.contains("structures") { return .totalMR }
        if n.contains("total_mr") || n.contains("totalseg") { return .totalMR }
        return .generic
    }
}

private extension UIColor {
    var rgb: SIMD3<Double> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: nil)
        return SIMD3(r, g, b)
    }
}

/// A loaded segmentation and how it is displayed.
@Observable final class Segmentation {
    let labels: LabelVolume
    let name: String
    let table: LabelTable
    var visible: [Bool]           // indexed by label; [0] unused
    var opacity: Float = 0.65     // colour blend over the grey image
    var ghost = UserDefaults.standard.bool(forKey: "segGhost") // 3D: fade unlabelled tissue (`-segGhost YES` for checks)
    /// Voxel counts per label ([0] = unlabelled), and how many of those unlabelled voxels are
    /// inside the body (non-zero intensity) — for the body-composition estimate.
    let counts: [Int]
    let unlabelledBodyVoxels: Int
    let voxelML: Double

    /// `volume` is the scan the labels sit on; counting is one pass, do it off the main thread.
    init(labels: LabelVolume, name: String, volume: NiftiVolume) {
        self.labels = labels
        self.name = name
        table = LabelTable.forFile(named: name)
        visible = [Bool](repeating: true, count: max(labels.maxLabel, 1) + 1)
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

    var labelRange: ClosedRange<Int> { 1...max(labels.maxLabel, 1) }

    /// RGBA per label (256 entries): alpha 255 = shown, 0 = hidden. Fed to both renderers.
    var lut: [SIMD4<UInt8>] {
        var t = [SIMD4<UInt8>](repeating: .zero, count: 256)
        for l in labelRange where visible[l] {
            let c = table.color(l) * 255
            t[l] = SIMD4(UInt8(c.x), UInt8(c.y), UInt8(c.z), 255)
        }
        return t
    }
}

extension NiftiVolume {
    /// Grey slice with the segmentation blended in (RGBX, 4 bytes/pixel): pixels whose label
    /// is shown get `opacity` of the label colour, the rest stay grey.
    func sliceRGBX(axis: Int, index: Int, lo: Float, hi: Float,
                   labels: LabelVolume, lut: [SIMD4<UInt8>], opacity: Float) -> (width: Int, height: Int, pixels: [UInt8]) {
        let s = slice(axis: axis, index: index, lo: lo, hi: hi)
        let (nx, ny, _) = dims, (w, h) = (s.width, s.height)
        let k = max(0, min(count(axis: axis) - 1, index))
        let a = Int(opacity * 256), ia = 256 - a
        var px = [UInt8](repeating: 255, count: w * h * 4)
        labels.data.withUnsafeBufferPointer { lab in
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
        return (w, h, px)
    }
}

/// Segmentation controls for the inspector.
struct SegmentationSection: View {
    let volume: NiftiVolume
    let fileURL: URL?
    let state: ViewState
    @State private var importing = false
    @State private var importingFat = false

    var body: some View {
        Section("Segmentation") {
            if let seg = state.segmentation {
                if state.structures != nil {
                    Picker("Show", selection: Binding(get: { seg.name }, set: { _ in state.swapSegmentation() })) {
                        Text(seg.name).tag(seg.name)
                        Text(state.structures!.name).tag(state.structures!.name)
                    }
                }
                SegmentationControls(seg: seg) { state.segmentation = nil; state.structures = nil }
            } else {
                Button("Load Segmentation…", systemImage: "square.3.layers.3d") { importing = true }
                    .disabled(state.segmentationLoading || state.segmentingProgress != nil)
                if let p = state.segmentingProgress {
                    ProgressView(value: p) { Text("Segmenting \(state.segmentingStage)… \(Int(p * 100))%") }
                    Button("Cancel", role: .cancel) { state.cancelSegmenting() }
                } else {
                    // TotalSegmentator total_mr models (non-commercial licence), run on device.
                    Button("Generate Segmentation", systemImage: "brain") { state.generateSegmentation(volume: volume) }
                        .disabled(state.segmentationLoading)
                    if state.fatVolume == nil {
                        Text("Muscle and fat classes need the Dixon fat image; without it only organs, bones and muscle groups are labelled.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Choose Fat Image…", systemImage: "drop") { importingFat = true }
                    } else {
                        LabeledContent("Fat image", value: state.fatURL?.lastPathComponent ?? "loaded").lineLimit(1).truncationMode(.middle)
                    }
                }
                if state.segmentationLoading { ProgressView("Loading segmentation…") }
                if let error = state.segmentationError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        // ponytail: .gzip admits any .gz and .data any file; a bad pick fails with the reader's error.
        .fileImporter(isPresented: $importing, allowedContentTypes: [.nifti, .gzip, .data]) { result in
            if case .success(let url) = result {
                Task { await state.loadSegmentation(from: url, scoped: true, volume: volume) }
            }
        }
        .fileImporter(isPresented: $importingFat, allowedContentTypes: [.nifti, .gzip, .data]) { result in
            if case .success(let url) = result {
                Task { await state.loadFat(from: url, scoped: true, volume: volume) }
            }
        }
    }
}

private struct SegmentationControls: View {
    @Bindable var seg: Segmentation
    let remove: () -> Void

    var body: some View {
        LabeledContent("File", value: seg.name).lineLimit(1).truncationMode(.middle)
        LabeledContent("Opacity") { StepSlider(value: $seg.opacity, in: 0...1, unit: 0.05) }
        Toggle("Show Through Tissue (3D)", isOn: $seg.ghost)
        HStack {
            Button("Show All") { seg.visible = seg.visible.map { _ in true } }
            Spacer()
            Button("Hide All") { seg.visible = seg.visible.map { _ in false } }
        }
        .buttonStyle(.borderless)
        ForEach(Array(seg.labelRange), id: \.self) { label in
            Toggle(isOn: $seg.visible[label]) {
                HStack(spacing: 8) {
                    let c = seg.table.color(label)
                    Circle().fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
                        .frame(width: 12, height: 12)
                    Text(seg.table.name(label))
                }
            }
        }
        Button("Remove Segmentation", role: .destructive, action: remove)
    }
}

// MARK: - Body composition

/// Body segments that may lie outside the scan, with their share of body mass
/// (Dempster / Winter anthropometric tables; both sides where paired).
enum BodySegment: String, CaseIterable, Identifiable {
    case headNeck = "Head & neck", upperArms = "Upper arms", forearmsHands = "Forearms & hands"
    case thighs = "Thighs", shanks = "Lower legs", feet = "Feet"
    var id: Self { self }
    var massFraction: Double {
        switch self {
        case .headNeck: return 0.081
        case .upperArms: return 2 * 0.028
        case .forearmsHands: return 2 * 0.022
        case .thighs: return 2 * 0.100
        case .shanks: return 2 * 0.0465
        case .feet: return 2 * 0.0145
        }
    }
    /// Limbs are extrapolated with the imaged muscle/fat composition; the head is not.
    var isLimb: Bool { self != .headNeck }
}

/// Inspector section: per-class volume and mass, and whole-body estimates from the
/// subject's weight once the segments outside the scan are declared.
struct BodyCompositionSection: View {
    let seg: Segmentation
    @AppStorage("subjectWeightKg") private var weightKg = 0.0
    // Defaults match a shoulders-to-thigh whole-body protocol: head, lower legs and feet missing.
    @AppStorage("missingSegments") private var missingRaw = "Head & neck,Lower legs,Feet"
    @AppStorage("thighsMissingPercent") private var thighsMissing = 0.0

    private var missing: Set<BodySegment> {
        Set(missingRaw.split(separator: ",").compactMap { BodySegment(rawValue: String($0)) })
    }

    private func massKg(_ l: Int) -> Double { Double(seg.counts[l]) * seg.voxelML * Double(seg.table.density(l)) / 1000 }

    /// Missing mass fraction (whole segments plus the declared part of the thighs), the
    /// limb-only part of it, and the factor that extrapolates imaged limb tissue to the
    /// whole body. Missing limbs are assumed to share the imaged muscle/fat composition
    /// (ponytail: per-segment composition tables would refine this); organs are all imaged.
    private var missingModel: (fMissing: Double, limbScale: Double) {
        let fThigh = BodySegment.thighs.massFraction * thighsMissing / 100
        let whole = missing.filter { $0 != .thighs }
        let fMissing = whole.reduce(fThigh) { $0 + $1.massFraction }
        let fLimb = whole.filter(\.isLimb).reduce(fThigh) { $0 + $1.massFraction }
        return (fMissing, 1 + fLimb / max(1 - fMissing, 0.01))
    }

    var body: some View {
        let rows = seg.labelRange.filter { seg.counts[$0] > 0 }
        let otherKg = Double(seg.unlabelledBodyVoxels) * seg.voxelML * Double(LabelTable.softTissue) / 1000
        let imagedKg = rows.reduce(otherKg) { $0 + massKg($1) }
        let (fMissing, limbScale) = missingModel
        let expectedKg = weightKg * (1 - fMissing)

        Section("Body Composition") {
            LabeledContent("Subject weight") {
                HStack(spacing: 4) {
                    TextField("kg", value: $weightKg, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                    Text("kg").foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Outside the scan") {
                ForEach(BodySegment.allCases.filter { $0 != .thighs }) { s in
                    Toggle(s.rawValue, isOn: Binding(
                        get: { missing.contains(s) },
                        set: { on in var m = missing; if on { m.insert(s) } else { m.remove(s) }
                               missingRaw = m.map(\.rawValue).joined(separator: ",") }))
                }
                VStack(alignment: .leading) {
                    LabeledContent("Thighs missing", value: "\(Int(thighsMissing))%")
                    StepSlider(value: $thighsMissing, in: 0...100, unit: 5)
                }
            }
            LabeledContent("Imaged tissue", value: String(format: "%.1f kg", imagedKg))
            if weightKg > 0 {
                LabeledContent("Expected in scan", value: String(format: "%.1f kg (%.0f%% of weight)", expectedKg, (1 - fMissing) * 100))
                LabeledContent("Agreement", value: String(format: "%+.0f%%", (imagedKg / max(expectedKg, 0.1) - 1) * 100))
                    .foregroundStyle(abs(imagedKg / max(expectedKg, 0.1) - 1) > 0.1 ? .red : .primary)
            }
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Class").gridColumnAlignment(.leading)
                    Text("L"); Text("kg"); Text("kg, body")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(rows, id: \.self) { l in
                    let litres = Double(seg.counts[l]) * seg.voxelML / 1000
                    let isLimbTissue = (1...3).contains(l) && seg.table.names.count == 14 // muscle / fat classes of the tissue map
                    GridRow {
                        Text(seg.table.name(l)).gridColumnAlignment(.leading).lineLimit(1)
                        Text(String(format: "%.2f", litres))
                        Text(String(format: "%.2f", massKg(l)))
                        Text(isLimbTissue && weightKg > 0 ? String(format: "%.2f", massKg(l) * limbScale) : "–")
                    }
                    .font(.footnote.monospacedDigit())
                }
                GridRow {
                    Text("other tissue").gridColumnAlignment(.leading).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", Double(seg.unlabelledBodyVoxels) * seg.voxelML / 1000))
                    Text(String(format: "%.2f", otherKg)); Text("–")
                }
                .font(.footnote.monospacedDigit())
            }
            Text("Masses use typical tissue densities (adipose 0.92, muscle 1.06, organs ~1.05, lungs 0.3, bone 1.4 g/mL). Whole-body muscle and fat assume the missing limbs share the imaged composition.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
