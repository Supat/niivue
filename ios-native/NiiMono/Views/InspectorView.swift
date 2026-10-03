//
//  InspectorView.swift — the side panel, in pages: image (window level, FOV), 3D rendering
//  and clip planes, segmentation and body composition, profile photos, sidecar and info.
//

import SwiftUI

struct InspectorView: View {
    @Bindable var model: ViewerViewModel
    @AppStorage("inspectorPage") private var page = InspectorPage.image

    var body: some View {
        let volume = model.volume
        // Slider traps on an empty range; a constant-intensity volume gets a dummy one.
        let range = volume.dataMin...max(volume.dataMax, volume.dataMin + 1)
        let unit = (range.upperBound - range.lowerBound) / 100 // one tap on the track = 1% of the range
        Form {
            switch page {
            case .image:
                Section("Adjust") {
                    LabeledContent("Black") { StepSlider(value: $model.lo, in: range, unit: unit) }
                    LabeledContent("White") { StepSlider(value: $model.hi, in: range, unit: unit) }
                    Button("Reset") { model.resetWindow() }
                }
                FOVSection(model: model)
            case .render:
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
            case .segmentation:
                ImageSection(model: model.segmentation) // the Dixon role and companions the tissue classes need
                SegmentationSection(model: model.segmentation)
                CustomSegmentationSection(model: model)
                if let map = model.segmentation.map, map.name != LabelTable.customMapName { // no tissue densities for drawn labels
                    BodyCompositionSection(model: model.bodyComposition, map: map)
                }
            case .profile:
                ProfileSection(model: model.profile)
            case .info:
                if let sidecar = model.sidecar {
                    Section("Sidecar") {
                        LabeledContent("Location", value: sidecar.besideScan ? "Beside the scan" : "In the app's library")
                        LabeledContent("Settings", value: model.sidecarSavedAt.map { "saved " + $0.formatted(date: .omitted, time: .shortened) } ?? "not saved yet")
                        if model.segmentation.map != nil {
                            LabeledContent("Segmentation", value: model.sidecarMapsSaved ? "saved" : "saving…")
                        }
                        Text("Settings, the segmentation maps, the companion images and the profile photos are remembered here and restored when the scan is opened again.")
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
        }
        // Pages, like the tabs at the top of Preview's inspector. The panel keeps to the safe
        // area so the tabs sit below the navigation bar: the bar spans this column, and over
        // it the bar's buttons covered the tabs and took their touches.
        .safeAreaBar(edge: .top, spacing: 0) {
            Picker("Page", selection: $page) {
                ForEach(InspectorPage.allCases) { Image(systemName: $0.symbol).accessibilityLabel($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }
}

enum InspectorPage: String, CaseIterable, Identifiable {
    case image = "Image", render = "3D", segmentation = "Segmentation", profile = "Profile", info = "Info"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .render: return "cube"
        case .segmentation: return "square.3.layers.3d"
        case .profile: return "person.crop.rectangle"
        case .info: return "info.circle"
        }
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
                Toggle("Enabled", isOn: binding.enabled)
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

/// The acquisition metadata that places each station's field of view on the scan.
private struct FOVSection: View {
    @Bindable var model: ViewerViewModel
    @State private var choosing = false

    var body: some View {
        Section("Field of View") {
            if model.fovBoxes.isEmpty {
                LabeledContent("Metadata") { Button("Choose…") { choosing = true } }
                if let status = model.fovStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } else {
                Toggle("Show station FOVs (\(model.fovBoxes.count))", isOn: $model.showFOV)
                // One row per scanning session, in its overlay colour; a tap shows or hides it.
                ForEach(Array(model.fovSessions.enumerated()), id: \.offset) { i, session in
                    let on = !model.hiddenFOVSessions.contains(i)
                    Button {
                        if on { model.hiddenFOVSessions.insert(i) } else { model.hiddenFOVSessions.remove(i) }
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(Color(FOVSession.color(i)), lineWidth: 2)
                                .frame(width: 16, height: 12).opacity(on ? 1 : 0.3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name).foregroundStyle(on ? .primary : .secondary)
                                Text([session.date, "\(session.stationCount) station\(session.stationCount == 1 ? "" : "s")"]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: on ? "eye" : "eye.slash").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.showFOV)
                    .accessibilityValue(on ? "Shown" : "Hidden")
                }
                LabeledContent("Metadata") { Button("Change…") { choosing = true } }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await model.loadFOVMetadata(from: url) } }
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

/// Draw, import and export the hand-drawn segmentation.
private struct CustomSegmentationSection: View {
    let model: ViewerViewModel
    @State private var importing = false

    var body: some View {
        Section("Custom Segmentation") {
            Button(model.segmentation.customMap == nil ? "Draw Segmentation…" : "Edit Drawing…",
                   systemImage: "pencil.and.scribble") { model.startDrawing() }
                .disabled(model.segmentation.isGenerating || model.customFileBusy)
            Button("Import…", systemImage: "square.and.arrow.down") { importing = true }
                .disabled(model.customFileBusy)
            Button("Export…", systemImage: "square.and.arrow.up") { Task { await model.exportCustomSegmentation() } }
                .disabled(model.segmentation.customMap == nil || model.customFileBusy)
            if model.customFileBusy { ProgressView() }
            if let status = model.customFileStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
            Text("Draw labels slice by slice with Apple Pencil, alongside a reference slice and the 3D render. Exports are label NIfTIs on the scan's own grid and orientation, with the label names inside; any label map on this grid can be imported.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        // ponytail: .gzip admits any .gz and .data any file; a bad pick fails with the reader's error.
        .fileImporter(isPresented: $importing, allowedContentTypes: [.nifti, .gzip, .data]) { result in
            if case .success(let url) = result { Task { await model.importCustomSegmentation(from: url) } }
        }
    }
}
