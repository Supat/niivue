//
//  Segmentation.swift — a label map shown over the scan: which labels are visible, their
//  names and colours, and the slice compositing. The 3D side is in the raycaster.
//

import SwiftUI

/// Names and colours for a family of label files. Picked from the file name.
struct LabelTable {
    let names: [Int: String]
    let colors: [Int: SIMD3<Float>] // 0...1 RGB

    func name(_ label: Int) -> String { names[label] ?? "Label \(label)" }

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
                 13: [0.92, 0.92, 0.85], 14: [0.95, 0.60, 0.90]])

    /// TotalSegmentator's `total_mr` task (50 structures).
    static let totalMR = LabelTable(
        names: Dictionary(uniqueKeysWithValues: """
            spleen kidney_right kidney_left gallbladder liver stomach pancreas adrenal_gland_right \
            adrenal_gland_left lung_left lung_right esophagus small_bowel duodenum colon urinary_bladder prostate \
            sacrum vertebrae intervertebral_discs spinal_cord heart aorta inferior_vena_cava \
            portal_vein_and_splenic_vein iliac_artery_left iliac_artery_right iliac_vena_left iliac_vena_right \
            humerus_left humerus_right scapula_left scapula_right clavicula_left clavicula_right femur_left \
            femur_right hip_left hip_right gluteus_maximus_left gluteus_maximus_right gluteus_medius_left \
            gluteus_medius_right gluteus_minimus_left gluteus_minimus_right autochthon_left autochthon_right \
            iliopsoas_left iliopsoas_right brain
            """.split(separator: " ").enumerated().map { ($0.offset + 1, $0.element.replacingOccurrences(of: "_", with: " ")) }),
        colors: [:])

    static let generic = LabelTable(names: [:], colors: [:])

    static func forFile(named name: String) -> LabelTable {
        let n = name.lowercased()
        if n.contains("tissue") { return .tissues }
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

    init(labels: LabelVolume, name: String) {
        self.labels = labels
        self.name = name
        table = LabelTable.forFile(named: name)
        visible = [Bool](repeating: true, count: max(labels.maxLabel, 1) + 1)
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

    var body: some View {
        Section("Segmentation") {
            if let seg = state.segmentation {
                SegmentationControls(seg: seg) { state.segmentation = nil }
            } else {
                Button("Load Segmentation…", systemImage: "square.3.layers.3d") { importing = true }
                    .disabled(state.segmentationLoading || state.segmentingProgress != nil)
                if let p = state.segmentingProgress {
                    ProgressView(value: p) { Text("Segmenting organs… \(Int(p * 100))%") }
                    Button("Cancel", role: .cancel) { state.cancelSegmenting() }
                } else {
                    // TotalSegmentator total_mr organ model (non-commercial licence), run on device.
                    Button("Segment Organs", systemImage: "brain") { state.segmentOrgans(volume: volume) }
                        .disabled(state.segmentationLoading)
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
