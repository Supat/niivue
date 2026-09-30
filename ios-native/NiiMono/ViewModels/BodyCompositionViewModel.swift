//
//  BodyCompositionViewModel.swift — the subject inputs for the body-composition estimate,
//  remembered across launches.
//

import Foundation
import Observation

@Observable @MainActor final class BodyCompositionViewModel {
    private let defaults = UserDefaults.standard

    var weightKg: Double { didSet { defaults.set(weightKg, forKey: "subjectWeightKg") } }
    // Defaults match a shoulders-to-thigh whole-body protocol: head, lower legs and feet missing.
    var missing: Set<BodySegment> { didSet { defaults.set(missing.map(\.rawValue).joined(separator: ","), forKey: "missingSegments") } }
    var thighsMissingPercent: Double { didSet { defaults.set(thighsMissingPercent, forKey: "thighsMissingPercent") } }

    init() {
        weightKg = defaults.double(forKey: "subjectWeightKg")
        let raw = defaults.string(forKey: "missingSegments") ?? "Head & neck,Lower legs,Feet"
        missing = Set(raw.split(separator: ",").compactMap { BodySegment(rawValue: String($0)) })
        thighsMissingPercent = defaults.double(forKey: "thighsMissingPercent")
    }

    func setMissing(_ segment: BodySegment, _ on: Bool) {
        if on { missing.insert(segment) } else { missing.remove(segment) }
    }

    func estimate(for map: SegmentationMap) -> BodyCompositionEstimate {
        BodyCompositionEstimate(map: map, weightKg: weightKg, missing: missing, thighsMissingPercent: thighsMissingPercent)
    }
}
