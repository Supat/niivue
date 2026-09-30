//
//  BodyComposition.swift — volume/mass per tissue class and whole-body extrapolation.
//

import Foundation

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

/// The estimate for one segmentation map and one set of subject inputs.
struct BodyCompositionEstimate {
    struct Row { let label: Int; let name: String; let litres: Double; let kg: Double; let wholeBodyKg: Double? }
    let rows: [Row]
    let otherLitres: Double
    let otherKg: Double
    let imagedKg: Double
    /// Share of body mass outside the scan.
    let missingFraction: Double
    /// Expected imaged mass for the subject's weight, or nil without a weight.
    let expectedKg: Double?

    /// Masses use typical densities per label; unlabelled body voxels count as soft tissue.
    /// Missing limbs are assumed to share the imaged muscle/fat composition (ponytail:
    /// per-segment composition tables would refine this); organs are all imaged.
    init(map: SegmentationMap, weightKg: Double, missing: Set<BodySegment>, thighsMissingPercent: Double) {
        let fThigh = BodySegment.thighs.massFraction * thighsMissingPercent / 100
        let whole = missing.filter { $0 != .thighs }
        missingFraction = whole.reduce(fThigh) { $0 + $1.massFraction }
        let fLimb = whole.filter(\.isLimb).reduce(fThigh) { $0 + $1.massFraction }
        let limbScale = 1 + fLimb / max(1 - missingFraction, 0.01)
        func kg(_ l: Int) -> Double { Double(map.counts[l]) * map.voxelML * Double(map.table.density(l)) / 1000 }
        rows = map.labelRange.filter { map.counts[$0] > 0 }.map { l -> Row in
            let limbTissue = map.table.isTissueMap && (1...3).contains(l) // muscle and the fat classes
            return Row(label: l, name: map.table.name(l), litres: Double(map.counts[l]) * map.voxelML / 1000, kg: kg(l),
                       wholeBodyKg: limbTissue && weightKg > 0 ? kg(l) * limbScale : nil)
        }
        otherLitres = Double(map.unlabelledBodyVoxels) * map.voxelML / 1000
        otherKg = otherLitres * Double(LabelTable.softTissue)
        imagedKg = rows.reduce(otherKg) { $0 + $1.kg }
        expectedKg = weightKg > 0 ? weightKg * (1 - missingFraction) : nil
    }

    /// Imaged mass relative to the expected share of the weight (+0.05 = 5% over), or nil.
    var agreement: Double? { expectedKg.map { imagedKg / max($0, 0.1) - 1 } }
}
