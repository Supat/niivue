//
//  BodyCompositionSection.swift — per-class volume and mass, and whole-body estimates
//  from the subject's weight once the segments outside the scan are declared.
//

import SwiftUI

struct BodyCompositionSection: View {
    @Bindable var model: BodyCompositionViewModel
    let map: SegmentationMap

    var body: some View {
        let e = model.estimate(for: map)
        Section("Body Composition") {
            LabeledContent("Subject weight") {
                HStack(spacing: 4) {
                    TextField("kg", value: $model.weightKg, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                    Text("kg").foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Outside the scan") {
                ForEach(BodySegment.allCases.filter { $0 != .thighs }) { s in
                    Toggle(s.rawValue, isOn: Binding(get: { model.missing.contains(s) }, set: { model.setMissing(s, $0) }))
                }
                VStack(alignment: .leading) {
                    LabeledContent("Thighs missing", value: "\(Int(model.thighsMissingPercent))%")
                    StepSlider(value: $model.thighsMissingPercent, in: 0...100, unit: 5)
                }
            }
            LabeledContent("Imaged tissue", value: String(format: "%.1f kg", e.imagedKg))
            if let expected = e.expectedKg, let agreement = e.agreement {
                LabeledContent("Expected in scan", value: String(format: "%.1f kg (%.0f%% of weight)", expected, (1 - e.missingFraction) * 100))
                LabeledContent("Agreement", value: String(format: "%+.0f%%", agreement * 100))
                    .foregroundStyle(abs(agreement) > 0.1 ? .red : .primary)
            }
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Class").gridColumnAlignment(.leading)
                    Text("L"); Text("kg"); Text("kg, body")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(e.rows, id: \.label) { row in
                    GridRow {
                        Text(row.name).gridColumnAlignment(.leading).lineLimit(1)
                        Text(String(format: "%.2f", row.litres))
                        Text(String(format: "%.2f", row.kg))
                        Text(row.wholeBodyKg.map { String(format: "%.2f", $0) } ?? "–")
                    }
                    .font(.footnote.monospacedDigit())
                }
                GridRow {
                    Text("other tissue").gridColumnAlignment(.leading).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", e.otherLitres))
                    Text(String(format: "%.2f", e.otherKg)); Text("–")
                }
                .font(.footnote.monospacedDigit())
            }
            Text("Masses use typical tissue densities (adipose 0.92, muscle 1.06, organs ~1.05, lungs 0.3, bone 1.4 g/mL). Whole-body muscle and fat assume the missing limbs share the imaged composition.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
