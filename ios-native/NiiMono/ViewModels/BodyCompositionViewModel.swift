//
//  BodyCompositionViewModel.swift — the subject inputs for the body-composition estimate,
//  remembered across launches.
//

import Foundation
import Observation

@Observable @MainActor final class BodyCompositionViewModel {
    private let defaults = UserDefaults.standard

    /// Typed by hand; each is used only when the scan doesn't record that value (0 = not set).
    var weightKg: Double { didSet { defaults.set(weightKg, forKey: "subjectWeightKg") } }
    var heightCm: Double { didSet { defaults.set(heightCm, forKey: "subjectHeightCm") } }
    var ageYears: Double { didSet { defaults.set(ageYears, forKey: "subjectAgeYears") } }
    /// Per scan, so kept only in the sidecar (a remembered default would label the next subject wrongly).
    var subjectID = ""
    /// Read from the scan (header text / extension, or a BIDS JSON beside it); wins over typed values.
    var fromFile = SubjectInfo()
    var effectiveWeightKg: Double { fromFile.weightKg ?? weightKg }

    /// The subject lines shown under the profile photo: only what is known, file values first.
    func summaryLines(imagedKg: Double?) -> [String] {
        func number(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) }
        var lines = [String]()
        if let id = fromFile.id ?? (subjectID.isEmpty ? nil : subjectID) { lines.append("ID \(id)") }
        if effectiveWeightKg > 0 { lines.append("Weight \(number(effectiveWeightKg)) kg") }
        if let h = fromFile.heightCm ?? (heightCm > 0 ? heightCm : nil) { lines.append("Height \(number(h)) cm") }
        if let a = fromFile.ageYears ?? (ageYears > 0 ? ageYears : nil) { lines.append("Age \(number(a))") }
        if let imagedKg { lines.append("Imaged tissue \(number(imagedKg)) kg") }
        return lines
    }
    // Defaults match a shoulders-to-thigh whole-body protocol: head, lower legs and feet missing.
    var missing: Set<BodySegment> { didSet { defaults.set(missing.map(\.rawValue).joined(separator: ","), forKey: "missingSegments") } }
    var thighsMissingPercent: Double { didSet { defaults.set(thighsMissingPercent, forKey: "thighsMissingPercent") } }

    init() {
        weightKg = defaults.double(forKey: "subjectWeightKg")
        heightCm = defaults.double(forKey: "subjectHeightCm")
        ageYears = defaults.double(forKey: "subjectAgeYears")
        let raw = defaults.string(forKey: "missingSegments") ?? "Head & neck,Lower legs,Feet"
        missing = Set(raw.split(separator: ",").compactMap { BodySegment(rawValue: String($0)) })
        thighsMissingPercent = defaults.double(forKey: "thighsMissingPercent")
    }

    func setMissing(_ segment: BodySegment, _ on: Bool) {
        if on { missing.insert(segment) } else { missing.remove(segment) }
    }

    func estimate(for map: SegmentationMap) -> BodyCompositionEstimate {
        BodyCompositionEstimate(map: map, weightKg: effectiveWeightKg, missing: missing, thighsMissingPercent: thighsMissingPercent)
    }
}
