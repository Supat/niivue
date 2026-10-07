//
//  InspectorView.swift — the side panel, in pages: image (window level, FOV), 3D rendering
//  and clip planes, segmentation and body composition, profile photos, sidecar and info.
//

import SwiftUI

struct InspectorView: View {
    @Bindable var model: ViewerViewModel
    @AppStorage("inspectorPage") private var page = InspectorPage.image
    @State private var confirmDeleteSidecar = false

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
                NoiseSection(model: model)
                BandingSection(model: model)
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
                ImageSection(model: model.segmentation, fileURL: model.fileURL) // the Dixon role and companions
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
                        if let problem = model.sidecarProblem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange)
                            Button("Save Anyway", role: .destructive) { model.resumeSidecarSaving() }
                        } else if model.segmentation.map != nil {
                            LabeledContent("Segmentation", value: model.sidecarMapsSaved ? "saved" : "saving…")
                        }
                        Text("Settings, the segmentation maps, the companion images and the profile photos are remembered here and restored when the scan is opened again.")
                            .font(.caption2).foregroundStyle(.secondary)
                        // Asks first: this drops everything remembered for the scan at once.
                        Button("Delete Sidecar", role: .destructive) { confirmDeleteSidecar = true }
                            .confirmationDialog("Delete this scan's sidecar?", isPresented: $confirmDeleteSidecar, titleVisibility: .visible) {
                                Button("Delete Sidecar", role: .destructive) { model.deleteSidecar() }
                            } message: {
                                Text("The saved settings, segmentation maps, drawing, noise mask, scan repair, companion images and profile photos for this scan are deleted. The scan itself is not.")
                            }
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
            if !model.clips.isEmpty {
                // Needs a segmentation; its hidden labels are clipped like the rest.
                Toggle("Keep Visible Segments", isOn: $model.clipKeepSegments)
                    .disabled(model.segmentation.map == nil)
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
    let fileURL: URL?
    @State private var phaseTarget: PhaseImage = .inPhase
    @State private var choosingPhase = false
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
            // In-phase / opposed-phase: dark rims at water–fat boundaries make cavities easy to
            // see while drawing (Draw Segmentation › image picker). Loaded only when added.
            ForEach(PhaseImage.allCases) { phaseRow($0) }
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
        .fileImporter(isPresented: $choosingPhase, allowedContentTypes: [.nifti, .gzip, .data]) { result in
            switch result {
            case .success(let url): Task { await model.loadPhase(phaseTarget, from: url, scoped: true) }
            case .failure(let error): model.companionError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.nifti, .gzip, .data]) { result in
            switch result {
            case .success(let url): Task { await model.loadCompanion(target, from: url, scoped: true) }
            case .failure(let error): model.companionError = error.localizedDescription
            }
        }
    }

    private func phaseRow(_ which: PhaseImage) -> some View {
        let sibling = fileURL.flatMap { SegmentationPipeline.siblingDixon(of: $0, suffix: which.suffix) }
        return LabeledContent("\(which.rawValue) image") {
            HStack(spacing: 8) {
                if model.phase[which] != nil {
                    Text(model.phaseURL[which]?.lastPathComponent ?? "loaded").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) { model.removePhase(which) }
                } else {
                    if let sibling {
                        Button("Add") { Task { await model.loadPhase(which, from: sibling, scoped: false) } }
                    }
                    Button("Choose…") { phaseTarget = which; choosingPhase = true }
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.companionLoading)
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
    @State private var copying = false

    var body: some View {
        Section("Custom Segmentation") {
            if let shown = model.segmentation.map, !shown.isCustom {
                Button("Copy Labels to Drawing…", systemImage: "doc.on.doc") { copying = true }
                    .disabled(model.segmentation.isGenerating || model.customFileBusy)
                    .sheet(isPresented: $copying) { CopyLabelsSheet(model: model, source: shown) }
            }
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

/// Picks which labels of the map on screen to add to the drawing; starts from the visible ones.
private struct CopyLabelsSheet: View {
    let model: ViewerViewModel
    let source: SegmentationMap
    @State private var chosen: Set<Int> = []
    @Environment(\.dismiss) private var dismiss

    private var present: [Int] { source.labelRange.filter { source.counts[$0] > 0 } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(present, id: \.self) { label in
                        Toggle(isOn: Binding(get: { chosen.contains(label) }, set: { if $0 { chosen.insert(label) } else { chosen.remove(label) } })) {
                            HStack(spacing: 8) {
                                Circle().fill(Color(source.table.color(label))).frame(width: 12, height: 12)
                                Text(source.table.name(label))
                            }
                        }
                    }
                } footer: {
                    Text("Added to the drawing: a label with the same name there gains these voxels, the others become new labels. Voxels already drawn keep their label.")
                }
            }
            .navigationTitle("Copy from \(source.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy \(chosen.count)") {
                        let ids = present.filter(chosen.contains)
                        dismiss()
                        Task { await model.copyToDrawing(ids) }
                    }
                    .disabled(chosen.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Select All") { chosen = Set(present) }
                    Spacer()
                    Button("Select None") { chosen = [] }
                }
            }
        }
        .onAppear { chosen = Set(present.filter { model.segmentation.isVisible($0) }) }
    }
}

/// Noise drawn by hand (in the segmentation editor's noise mode) and cut out of the display.
private struct NoiseSection: View {
    @Bindable var model: ViewerViewModel
    @State private var confirmClear = false

    var body: some View {
        Section("Noise Removal") {
            Button(model.noise == nil ? "Remove Noise…" : "Edit Noise…", systemImage: "wand.and.rays") { model.startNoiseEditing() }
                .disabled(model.cleanupFileBusy == .noise)
            if model.noise != nil {
                Toggle("Remove Marked Noise", isOn: $model.removeNoise)

                Button("Clear Noise Mask", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear the noise mask? The marked voxels show again.", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { model.clearNoise() }
                    }
            }
            CleanupMaskRows(model: model, kind: .noise, hasMask: model.noise != nil)
            Text("Paint over noise with the drawing tools; it is blacked out on the slices, left out of the 3D render, and removed before Generate Segmentation runs. The scan file itself isn't changed. Export the mask to mark the same voxels on another image of this acquisition (water, fat, in-phase, opposed-phase: the same grid); any mask NIfTI on this grid can be imported.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Import and export of the noise mask or the scan repair as a NIfTI on the scan's grid, so
/// the same marks can be applied to another image of the acquisition.
private struct CleanupMaskRows: View {
    let model: ViewerViewModel
    let kind: CleanupMaskFile.Kind
    let hasMask: Bool
    @State private var importing = false

    var body: some View {
        let name = kind == .noise ? "Noise Mask" : "Scan Repair"
        let busy = model.cleanupFileBusy != nil || model.repairing
        Button("Import \(name)…", systemImage: "square.and.arrow.down") { importing = true }
            .disabled(busy)
            // ponytail: .gzip admits any .gz and .data any file; a bad pick fails with the reader's error.
            .fileImporter(isPresented: $importing, allowedContentTypes: [.nifti, .gzip, .data]) { result in
                if case .success(let url) = result { Task { await model.importCleanupMask(kind, from: url) } }
            }
        Button("Export \(name)…", systemImage: "square.and.arrow.up") { Task { await model.exportCleanupMask(kind) } }
            .disabled(!hasMask || busy)
        if model.cleanupFileBusy == kind { ProgressView() }
        if let status = model.cleanupFileStatus[kind] { Text(status).font(.footnote).foregroundStyle(.secondary) }
    }
}

/// Scan repair painted by hand (bands filled along z, blemishes from all around, see
/// ScanRepair), and the export of
/// the scan with noise removed and banding repaired.
private struct BandingSection: View {
    @Bindable var model: ViewerViewModel
    @State private var confirmUndo = false

    var body: some View {
        Section("Scan Repair") {
            Button(model.scanRepair == nil ? "Repair Scan…" : "Edit Scan Repair…", systemImage: "bandage") {
                model.startScanRepair()
            }
            .disabled(model.repairing || model.cleanupFileBusy == .repair)
            if model.repairing { ProgressView("Repairing…") }
            if model.scanRepair != nil {
                Button("Undo Scan Repair", role: .destructive) { confirmUndo = true }
                    .confirmationDialog("Put the original intensities back?", isPresented: $confirmUndo, titleVisibility: .visible) {
                        Button("Undo Repair", role: .destructive) { Task { await model.applyScanRepair(nil) } }
                    }
                    .disabled(model.cleanupFileBusy == .repair)
            }
            CleanupMaskRows(model: model, kind: .repair, hasMask: model.scanRepair != nil)
            Text("Band: paint over a thin band (best in a coronal or sagittal view, where it runs across); its voxels are filled in from the slices just above and below. Blemish: paint over a streak or spot; it is filled in from the tissue around it on all sides. Used everywhere, Generate Segmentation included; the scan file isn't changed. Export the repair to apply the same paint to another image of this acquisition (water, fat, in-phase, opposed-phase: the same grid); importing one replaces the repair here and applies it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if model.noise != nil || model.scanRepair != nil {
            Section("Cleaned Scan") {
                Button("Export Cleaned Scan…", systemImage: "square.and.arrow.up") { Task { await model.exportCleanedScan() } }
                    .disabled(model.cleanExportBusy)
                if model.cleanExportBusy { ProgressView("Writing cleaned scan…") }
                if let error = model.cleanExportError { Text(error).font(.footnote).foregroundStyle(.red) }
                Text("The scan with the marked noise removed and the repairs applied, as a NIfTI on its own grid and orientation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
