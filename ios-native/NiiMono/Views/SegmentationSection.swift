//
//  SegmentationSection.swift — inspector controls for the segmentation overlay: load,
//  generate, choose the fat image, per-label visibility, opacity, show-through.
//

import SwiftUI
import UniformTypeIdentifiers

struct SegmentationSection: View {
    @Bindable var model: SegmentationViewModel
    @State private var importing = false
    @State private var importingFat = false

    var body: some View {
        Section("Segmentation") {
            if let map = model.map {
                if let kept = model.kept {
                    Picker("Show", selection: Binding(get: { map.id }, set: { _ in model.swapMaps() })) {
                        Text(map.name).tag(map.id)
                        Text(kept.name).tag(kept.id)
                    }
                }
                controls(for: map)
            } else {
                Button("Load Segmentation…", systemImage: "square.3.layers.3d") { importing = true }
                    .disabled(model.isLoading || model.isGenerating)
                if let p = model.progress {
                    ProgressView(value: p) { Text("Segmenting \(model.stage)… \(Int(p * 100))%") }
                    Button("Cancel", role: .cancel) { model.cancelGenerating() }
                } else {
                    // TotalSegmentator total_mr models (non-commercial licence), run on device.
                    Button("Generate Segmentation", systemImage: "brain") { model.generate() }
                        .disabled(model.isLoading)
                    if model.fat == nil {
                        Text("Muscle and fat classes need the Dixon fat image; without it only organs, bones and muscle groups are labelled.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Choose Fat Image…", systemImage: "drop") { importingFat = true }
                    } else {
                        LabeledContent("Fat image", value: model.fatURL?.lastPathComponent ?? "loaded").lineLimit(1).truncationMode(.middle)
                    }
                }
                if model.isLoading { ProgressView("Loading segmentation…") }
                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        // ponytail: .gzip admits any .gz and .data any file; a bad pick fails with the reader's error.
        .fileImporter(isPresented: $importing, allowedContentTypes: [.nifti, .gzip, .data]) { result in
            if case .success(let url) = result { Task { await model.load(from: url, scoped: true) } }
        }
        .fileImporter(isPresented: $importingFat, allowedContentTypes: [.nifti, .gzip, .data]) { result in
            if case .success(let url) = result { Task { await model.loadFat(from: url, scoped: true) } }
        }
    }

    @ViewBuilder private func controls(for map: SegmentationMap) -> some View {
        LabeledContent("File", value: map.name).lineLimit(1).truncationMode(.middle)
        LabeledContent("Opacity") { StepSlider(value: $model.opacity, in: 0...1, unit: 0.05) }
        Toggle("Show Through Tissue (3D)", isOn: $model.ghost)
        HStack {
            Button("Show All") { model.setAllVisible(true) }
            Spacer()
            Button("Hide All") { model.setAllVisible(false) }
        }
        .buttonStyle(.borderless)
        ForEach(Array(map.labelRange), id: \.self) { label in
            Toggle(isOn: $model.visible[label]) {
                HStack(spacing: 8) {
                    Circle().fill(Color(map.table.color(label))).frame(width: 12, height: 12)
                    Text(map.table.name(label))
                }
            }
        }
        Button("Remove Segmentation", role: .destructive) { model.remove() }
    }
}
