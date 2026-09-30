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
            }
            ClipPlaneSections(model: model)
            SegmentationSection(model: model.segmentation)
            if let map = model.segmentation.map {
                BodyCompositionSection(model: model.bodyComposition, map: map)
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

extension Color {
    init(_ rgb: SIMD3<Float>) { self.init(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)) }
}
