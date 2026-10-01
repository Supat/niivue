//
//  InspectorView.swift — the side panel: window level, 3D rendering, clip planes,
//  segmentation, body composition, volume info.
//

import SwiftUI

struct InspectorView: View {
    @Bindable var model: ViewerViewModel
    /// Keep the empty strip under the navigation bar. False once the toolbar buttons have
    /// moved off the panel, so the controls can start at the top.
    let belowBar: Bool

    var body: some View {
        let volume = model.volume
        // Slider traps on an empty range; a constant-intensity volume gets a dummy one.
        let range = volume.dataMin...max(volume.dataMax, volume.dataMin + 1)
        let unit = (range.upperBound - range.lowerBound) / 100 // one tap on the track = 1% of the range
        Form {
            ImageSection(model: model.segmentation)
            Section("Adjust") {
                LabeledContent("Black") { StepSlider(value: $model.lo, in: range, unit: unit) }
                LabeledContent("White") { StepSlider(value: $model.hi, in: range, unit: unit) }
                Button("Reset") { model.resetWindow() }
            }
            Section("3D Rendering") {
                Picker("3D Rendering", selection: $model.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Clip at Camera", isOn: $model.cameraClip)
                if model.cameraClip {
                    VStack(alignment: .leading) {
                        LabeledContent("Clip depth", value: "\(Int(model.cameraClipDepth * 100))% of the way to the pivot")
                        StepSlider(value: $model.cameraClipDepth, in: 0...0.95, unit: 0.05)
                    }
                    Text("Nothing nearer the camera than this is drawn, so zooming into the volume shows its inside.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ClipPlaneSections(model: model)
            SegmentationSection(model: model.segmentation)
            if let map = model.segmentation.map {
                BodyCompositionSection(model: model.bodyComposition, map: map)
            }
            if let sidecar = model.sidecar {
                Section("Sidecar") {
                    LabeledContent("Location", value: sidecar.besideScan ? "Beside the scan" : "In the app's library")
                    LabeledContent("Settings", value: model.sidecarSavedAt.map { "saved " + $0.formatted(date: .omitted, time: .shortened) } ?? "not saved yet")
                    if model.segmentation.map != nil {
                        LabeledContent("Segmentation", value: model.sidecarMapsSaved ? "saved" : "saving…")
                    }
                    Text("Settings, the segmentation maps and the companion images are remembered here and restored when the scan is opened again.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Delete Sidecar", role: .destructive) { model.deleteSidecar() }
                }
            }
            Section("Info") {
                LabeledContent("Dimensions", value: "\(volume.dims.0) × \(volume.dims.1) × \(volume.dims.2)")
                LabeledContent("Voxel Size", value: String(format: "%.2f × %.2f × %.2f mm",
                                                           volume.voxelSize.0, volume.voxelSize.1, volume.voxelSize.2))
                LabeledContent("Intensity", value: String(format: "%g – %g", volume.dataMin, volume.dataMax))
                LabeledContent("Orientation", value: "RAS+")
            }
        }
        .scrollEdgeEffectHidden(true, for: .top) // no blurred bar backdrop at the top of the panel
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: belowBar ? [] : .top)
        .contentMargins(.top, belowBar ? 0 : 28, for: .scrollContent) // stay clear of the status bar icons
    }
}

/// One section per clip plane, plus the add / highlight / cutaway controls.
private struct ClipPlaneSections: View {
    @Bindable var model: ViewerViewModel

    var body: some View {
        // Bind each section by id, not by position. ForEach($model.clips) hands out
        // index-based bindings, and controls still on screen read theirs once more after
        // a plane is removed — an out-of-range crash. These fall back to the last value.
        ForEach(model.clips) { snapshot in
            let id = snapshot.id
            let binding = Binding<ClipSetting>(
                get: { model.clips.first { $0.id == id } ?? snapshot },
                set: { new in if let i = model.clips.firstIndex(where: { $0.id == id }) { model.clips[i] = new } })
            let clip = binding.wrappedValue
            let number = (model.clips.firstIndex { $0.id == id } ?? 0) + 1
            Section {
                Picker("Plane", selection: binding.plane) {
                    ForEach(ClipSetting.Plane.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("Depth") { StepSlider(value: binding.pos, in: 0...1, unit: 0.01) }
                // Tilt axes are the two after the plane's own axis, cyclically (x→y→z→x).
                let names = ["L–R", "A–P", "S–I"], a = Int(clip.plane.axis)
                tiltSlider("Tilt about \(names[(a + 1) % 3])", binding.tilt.x)
                tiltSlider("Tilt about \(names[(a + 2) % 3])", binding.tilt.y)
                Toggle("Flip Side", isOn: binding.flip)
                Button("Remove Clip Plane", role: .destructive) { model.removeClip(id: id) }
            } header: {
                HStack(spacing: 6) {
                    Text("3D Clip Plane \(number)")
                    if model.clipHighlight { // the plane's highlight colour in the render
                        Circle().fill(Color(ClipSetting.colors[number - 1])).frame(width: 9, height: 9)
                    }
                }
            }
        }
        Section(model.clips.isEmpty ? "3D Clip Plane" : "") {
            // With one plane, cutaway and normal clipping are the same thing.
            if !model.clips.isEmpty {
                Toggle("Highlight Planes", isOn: $model.clipHighlight)
            }
            if model.clips.count > 1 {
                Toggle("Cutaway", isOn: $model.clipCutaway)
            }
            if model.clips.count < ClipSetting.maxCount {
                Button("Add Clip Plane", systemImage: "plus") { model.addClip() }
            }
        }
    }

    private func tiltSlider(_ title: String, _ value: Binding<Float>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: "\(Int(value.wrappedValue.rounded()))°")
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value.wrappedValue = 0 } // double-tap the readout to zero it
            StepSlider(value: value, in: -90...90, unit: 1)
        }
    }
}

/// What the opened file is, and the companion Dixon images the tissue classes need.
private struct ImageSection: View {
    @Bindable var model: SegmentationViewModel
    // The target is kept separately from the presentation flag: SwiftUI clears the
    // presentation binding before (or without) calling the completion handler.
    @State private var target: ImageRole = .water
    @State private var choosing = false

    var body: some View {
        Section("Image") {
            Picker("This image is", selection: $model.role) {
                ForEach(ImageRole.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.role != .water { companionRow(.water, name: model.waterURL?.lastPathComponent, loaded: model.water != nil) }
            if model.role != .fat { companionRow(.fat, name: model.fatURL?.lastPathComponent, loaded: model.fat != nil) }
            if model.companionLoading { ProgressView("Loading image…") }
            if let error = model.companionError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if !model.canClassifyTissue {
                Text(model.role == .other
                     ? "Muscle and fat classes need both Dixon images (water and fat) on this grid."
                     : "Muscle and fat classes need the other Dixon image; it is picked up automatically when it lies beside this one.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.nifti, .gzip, .data]) { result in
            switch result {
            case .success(let url): Task { await model.loadCompanion(target, from: url, scoped: true) }
            case .failure(let error): model.companionError = error.localizedDescription
            }
        }
    }

    private func companionRow(_ which: ImageRole, name: String?, loaded: Bool) -> some View {
        LabeledContent("\(which.rawValue) image") {
            HStack(spacing: 8) {
                if loaded { Text(name ?? "loaded").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                Button(loaded ? "Change…" : "Choose…") { target = which; choosing = true }
                    .disabled(model.companionLoading)
            }
        }
    }
}

extension Color {
    init(_ rgb: SIMD3<Float>) { self.init(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)) }
}
