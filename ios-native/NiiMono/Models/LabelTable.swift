//
//  LabelTable.swift — names, colours and densities for the label families the app knows.
//

import Foundation

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

    /// Ids whose names contain any of the substrings (muscle.py's `ids()`).
    static func ids(_ subs: [String]) -> Set<Int> {
        Set(names.filter { n in subs.contains { n.value.contains($0) } }.keys)
    }
}

/// Names, colours and densities for a family of label files. Picked from the file name.
struct LabelTable {
    let names: [Int: String]
    let colors: [Int: SIMD3<Float>] // 0...1 RGB
    var densities: [Int: Float] = [:] // g/mL, for mass estimates; see `density`

    func name(_ label: Int) -> String { names[label] ?? "Label \(label)" }

    /// Tissue density in g/mL (soft tissue when unknown).
    func density(_ label: Int) -> Float { densities[label] ?? Self.softTissue }
    static let softTissue: Float = 1.03

    func color(_ label: Int) -> SIMD3<Float> {
        if let c = colors[label] { return c }
        // Fallback palette: golden-ratio hues so neighbouring labels differ (HSV → RGB).
        let h = (Double(label) * 0.618034).truncatingRemainder(dividingBy: 1) * 6
        let s = 0.75, v = 0.95, f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let rgb: (Double, Double, Double)
        switch Int(h) % 6 {
        case 0: rgb = (v, t, p); case 1: rgb = (q, v, p); case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v); case 4: rgb = (t, p, v); default: rgb = (v, p, q)
        }
        return SIMD3(Float(rgb.0), Float(rgb.1), Float(rgb.2))
    }

    /// True for the 14-class tissue map, whose first three classes are muscle and fat.
    var isTissueMap: Bool { names.count == 14 && names[1] == "skeletal muscle" }

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
        if n.contains("structures") || n.contains("total_mr") || n.contains("totalseg") { return .totalMR }
        return .generic
    }
}
