//
//  NiiMonoApp.swift — Preview-style MRI viewer shell.
//  DocumentGroup supplies the native document browser, title menu and window
//  management; this file adds the viewer chrome (plane picker, scrubber, inspector).
//

import Metal
import SwiftUI
import UniformTypeIdentifiers

/// A flag one thread sets and another polls (the segmenter's cancellation check).
final class ManagedAtomic: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

@main
struct NiiMonoApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MRIDocument.self) { file in
            DocumentView(data: file.document.data, fileURL: file.fileURL)
        }
    }
}

extension UTType {
    static let nifti = UTType(importedAs: "gov.nih.nifti-1")
}

struct MRIDocument: FileDocument {
    // ponytail: .nii.gz has no type of its own (the system sees only ".gz"), so every
    // gzip is openable and non-NIfTI ones fail with the reader's error in DocumentView.
    static let readableContentTypes: [UTType] = [.nifti, .gzip]
    /// Raw file bytes. Decoding happens in DocumentView, not here: the system shows nothing
    /// until this initializer returns, so a slow init looks like the pick was ignored.
    /// ponytail: the bytes stay in memory beside the decoded volume; drop them via a
    /// ReferenceFileDocument if memory gets tight on huge uncompressed files.
    let data: Data

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported) // viewer only
    }
}

/// Opens immediately with a progress indicator, decodes the volume off the main thread,
/// then swaps in the viewer (or the reader's error).
struct DocumentView: View {
    let data: Data
    let fileURL: URL?
    @State private var result: Result<NiftiVolume, Error>?

    var body: some View {
        Group {
            switch result {
            case .success(let volume):
                ViewerView(volume: volume, fileURL: fileURL)
            case .failure(let error):
                ContentUnavailableView("Can’t Open File", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            case nil:
                ProgressView("Opening…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .toolbarColorScheme(.dark, for: .navigationBar)
            }
        }
        .environment(\.colorScheme, result == nil ? .dark : colorScheme)
        .task {
            let data = data
            result = await Task.detached(priority: .userInitiated) {
                Result { try NIfTI.parse(NIfTI.isGzip(data) ? NIfTI.gunzip(data) : data) }
            }.value
        }
    }

    @Environment(\.colorScheme) private var colorScheme
}

enum Plane: String, CaseIterable, Identifiable {
    case render = "3D", multi = "Multi", axial = "Axial", coronal = "Coronal", sagittal = "Sagittal" // picker order
    var id: Self { self }
    /// Volume axis the plane is perpendicular to; nil for the 3D render and multiplanar grid.
    var axis: Int? { [.sagittal: 0, .coronal: 1, .axial: 2][self] }
}

/// How the 3D view draws the volume.
enum RenderMode: String, CaseIterable, Identifiable {
    case volume = "Volume", mip = "MIP" // picker order
    var id: Self { self }
}

/// Per-frame viewer state lives here rather than in ViewerView's @State so scrubbing
/// and windowing only invalidate the small views that read it, not the toolbar tree.
@Observable final class ViewState {
    // Opens in 3D. Launch argument `-plane Axial` (etc.) picks another view, for simulator checks.
    var plane = Plane(rawValue: UserDefaults.standard.string(forKey: "plane") ?? "") ?? .render
    var slices: [Int]
    var multiZoom: CGFloat = 1 // zoom shared by the multiplanar slice panes
    var multiZoomAnimated = false // whether the last change came from an animated (double-tap) zoom
    var lo: Float
    var hi: Float
    // Remembered across documents and launches.
    var mirrored = UserDefaults.standard.bool(forKey: "mirrored") {
        didSet { UserDefaults.standard.set(mirrored, forKey: "mirrored") }
    }
    var renderMode = RenderMode(rawValue: UserDefaults.standard.string(forKey: "renderMode") ?? "") ?? .volume {
        didSet { UserDefaults.standard.set(renderMode.rawValue, forKey: "renderMode") }
    }

    // Up to `maxClips` clip planes. `-clip Axial,Sagittal` and `-clipTilt 30` preset them for checks.
    static let maxClips = ClipSetting.maxCount
    var clips: [ClipSetting] = (UserDefaults.standard.string(forKey: "clip") ?? "").split(separator: ",")
        .compactMap { ClipSetting.Plane(rawValue: String($0)) }.prefix(maxClips)
        .map { ClipSetting(plane: $0, tilt: SIMD2(UserDefaults.standard.float(forKey: "clipTilt"), 0)) }
    /// Remove only the corner between the planes instead of everything beyond each one.
    var clipCutaway = UserDefaults.standard.bool(forKey: "clipCutaway") // `-clipCutaway YES` for checks
    /// Draw each clip plane as a tinted, outlined sheet so its position is visible.
    var clipHighlight = UserDefaults.standard.bool(forKey: "clipHighlight") // `-clipHighlight YES` for checks
    var segmentation: Segmentation?
    var segmentationLoading = false
    var segmentationError: String?

    /// Read a label file off the main thread and attach it if its grid matches the scan.
    @MainActor func loadSegmentation(from url: URL, scoped: Bool, volume: NiftiVolume) async {
        segmentationLoading = true
        segmentationError = nil
        defer { segmentationLoading = false }
        let dims = volume.dims
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Segmentation, Error> in
            let accessed = scoped && url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return Result {
                let data = try Data(contentsOf: url)
                let labels = try NIfTI.parseLabels(NIfTI.isGzip(data) ? NIfTI.gunzip(data) : data)
                guard labels.dims == dims else {
                    throw NiftiError.gridMismatch(labels.dims, dims)
                }
                return Segmentation(labels: labels, name: url.lastPathComponent, volume: volume)
            }
        }.value
        switch result {
        case .success(let seg): segmentation = seg
        case .failure(let error): segmentationError = error.localizedDescription
        }
    }

    var segmentingProgress: Double?     // non-nil while the organ model runs
    private var segmentingTask: Task<Void, Never>?

    /// Run the bundled TotalSegmentator organ model on the scan (minutes) and attach the result.
    @MainActor func segmentOrgans(volume: NiftiVolume) {
        guard segmentingTask == nil else { return }
        segmentationError = nil
        segmentingProgress = 0
        let cancelled = ManagedAtomic(false)
        segmentingTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Segmentation, Error> in
                Result {
                    guard let url = Bundle.main.url(forResource: "Organs", withExtension: "mlmodelc"),
                          let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary() else {
                        throw SegmenterError.noMetal
                    }
                    let segmenter = try OrganSegmenter(modelURL: url, library: library)
                    let labels = try segmenter.segment(volume, progress: { p in
                        Task { @MainActor in self?.segmentingProgress = p }
                    }, isCancelled: { cancelled.value })
                    return Segmentation(labels: labels, name: "organs (total_mr)", volume: volume)
                }
            }.value
            guard let self else { return }
            segmentingProgress = nil
            segmentingTask = nil
            switch result {
            case .success(let seg): segmentation = seg
            case .failure(is CancellationError): break
            case .failure(let error): segmentationError = error.localizedDescription
            }
        }
        segmentingCancel = { cancelled.value = true }
    }
    private var segmentingCancel: (() -> Void)?
    @MainActor func cancelSegmenting() { segmentingCancel?() }

    /// Look next to the scan for a matching segmentation (`<tag>_tissues.nii.gz`, also in a
    /// `seg/` folder, where `<tag>` is the scan name without a Dixon suffix) and load it quietly.
    @MainActor func loadSiblingSegmentation(of fileURL: URL, volume: NiftiVolume) async {
        guard segmentation == nil else { return }
        var base = fileURL.lastPathComponent
        for ext in [".nii.gz", ".nii"] where base.hasSuffix(ext) { base.removeLast(ext.count) }
        var tags = [base]
        for suffix in ["_W", "_F", "_in", "_opp"] where base.hasSuffix(suffix) { tags.append(String(base.dropLast(suffix.count))) }
        let dir = fileURL.deletingLastPathComponent()
        for tag in tags {
            for folder in [dir, dir.appendingPathComponent("seg")] {
                for name in ["\(tag)_tissues.nii.gz", "\(tag)_tissues.nii", "\(tag)_seg.nii.gz"] {
                    let url = folder.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) {
                        await loadSegmentation(from: url, scoped: false, volume: volume)
                        segmentationError = nil // a failed auto-load is not worth an error message
                        return
                    }
                }
            }
        }
    }

    // 3D camera preset request: RenderView applies `preset` whenever `presetTick` changes.
    var preset: ViewPreset?
    var presetTick = 0

    init(_ volume: NiftiVolume) {
        slices = (0..<3).map { volume.count(axis: $0) / 2 }
        lo = volume.displayMin
        hi = volume.displayMax
    }
}

struct ViewerView: View {
    let volume: NiftiVolume
    let fileURL: URL?
    @State private var state: ViewState
    @State private var chromeHidden = false
    @State private var hideChromeTask: Task<Void, Never>?
    @State private var showInspector = UserDefaults.standard.bool(forKey: "inspector") // `-inspector YES` for checks
    @State private var fullWidth: CGFloat = 0   // window width including the inspector column
    @State private var canvasWidth: CGFloat = 0 // width left for the image
    private var inspectorShift: CGFloat { max(0, fullWidth - canvasWidth) }
    private var shiftsToolbar: Bool { inspectorShift > 1 && fullWidth >= 1150 }
    private static let inspectorWidth: CGFloat = 300

    init(volume: NiftiVolume, fileURL: URL?) {
        self.volume = volume
        self.fileURL = fileURL
        _state = State(initialValue: ViewState(volume))
    }

    private func scheduleChromeHide() {
        hideChromeTask?.cancel()
        guard !chromeHidden, !showInspector else { return }
        hideChromeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !showInspector else { return }
            withAnimation { chromeHidden = true }
        }
    }

    var body: some View {
        VolumeCanvas(volume: volume, state: state,
                     onTap: { withAnimation { chromeHidden.toggle() } },
                     onInteract: { if chromeHidden { withAnimation { chromeHidden = false } } })
            // Full-bleed under the bars, but not under the inspector column (a trailing
            // safe-area inset), so the image is centred in the space that's actually visible.
            .ignoresSafeArea(edges: .vertical)
            .background(.black)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasWidth = $0 }
            .overlay {
                if let axis = state.plane.axis {
                    DirectionLabels(axis: axis, mirrored: state.mirrored, bottomInset: chromeHidden ? 0 : 64)
                }
            }
            .overlay(alignment: .bottom) {
                if !chromeHidden, let axis = state.plane.axis, volume.count(axis: axis) > 1 {
                    SliceScrubber(state: state, axis: axis, count: volume.count(axis: axis))
                }
            }
            .toolbar {
                // Trailing, not .principal: principal would replace the document title menu.
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View", selection: $state.plane) {
                        ForEach(Plane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 440) // roomier than the intrinsic size, which cramps the longer labels
                    .environment(\.colorScheme, .dark) // match the dark bar in light mode
                }
                .sharedBackgroundVisibility(.hidden) // the segmented control is already glass
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if state.plane != .render {
                        Toggle("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                               isOn: $state.mirrored)
                    }
                    if state.plane.axis == nil { // 3D and multiplanar
                        Menu("View", systemImage: "cube") {
                            ForEach(ViewPreset.allCases) { preset in
                                Button(preset.rawValue) { state.preset = preset; state.presetTick += 1 }
                            }
                        }
                    }
                    Button("Snapshot", systemImage: "camera") {
                        SnapshotPanes.captureAndShare(documentName: fileURL?.deletingPathExtension().deletingPathExtension().lastPathComponent ?? "Snapshot")
                    }
                    if let fileURL { ShareLink(item: fileURL) }
                    Button("Inspector", systemImage: "info.circle") { showInspector.toggle() }
                }
                // The bar spans the inspector column, so trailing items would sit on top of
                // it. An empty trailing item as wide as the column pushes them back over the
                // image. The width is measured (window minus canvas), not inferred from
                // showInspector, so the buttons can't end up shifted with no panel (or the
                // reverse) if the system closes or restores the panel behind our back.
                // Narrow windows (portrait, split view) skip the shift: the bar can't fit
                // everything beside the column and would collapse into an overflow menu.
                // ponytail: fixed 1150 pt threshold (fits an 11" iPad in landscape with a
                // typical title); measure the bar's real content if long titles overflow.
                if shiftsToolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Color.clear.frame(width: inspectorShift).allowsHitTesting(false)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            // Chrome auto-hides a few seconds after it appears or was last used, like a
            // video player; a tap brings it back. It stays while the inspector is open.
            .onAppear(perform: scheduleChromeHide)
            .task {
                if let fileURL { await state.loadSiblingSegmentation(of: fileURL, volume: volume) }
                if UserDefaults.standard.bool(forKey: "segmentOrgans") { state.segmentOrgans(volume: volume) } // for checks
            }
            .onChange(of: chromeHidden) { if !chromeHidden { scheduleChromeHide() } }
            .onChange(of: showInspector) { showInspector ? hideChromeTask?.cancel() : scheduleChromeHide() }
            .onChange(of: state.plane) { scheduleChromeHide() }
            .onChange(of: state.slices) { scheduleChromeHide() }
            .onChange(of: state.mirrored) { scheduleChromeHide() }
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
            .background(NavigationBarHider(hidden: chromeHidden))
            .toolbarColorScheme(.dark, for: .navigationBar) // content is always black
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .statusBarHidden(chromeHidden)
            .inspector(isPresented: $showInspector) {
                InspectorView(volume: volume, fileURL: fileURL, state: state, belowBar: !shiftsToolbar)
                    .inspectorColumnWidth(Self.inspectorWidth)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
    }
}

private struct VolumeCanvas: View {
    let volume: NiftiVolume
    let state: ViewState
    let onTap: () -> Void
    /// A tap that does something else (moves the crosshair) still brings hidden chrome back.
    let onInteract: () -> Void

    var body: some View {
        switch state.plane {
        case .render:
            render
        case .multi:
            // Multiplanar layout: coronal | sagittal over axial | 3D, thin dividers.
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow { slice(1); slice(0) }
                GridRow { slice(2); render }
            }
            .background(Color(white: 0.25))
        default:
            slice(state.plane.axis!)
        }
    }

    private var render: some View {
        let n = [volume.dims.0, volume.dims.1, volume.dims.2]
        let crosshair = SIMD3<Float>((0..<3).map { (Float(state.slices[$0]) + 0.5) / Float(n[$0]) })
        return RenderView(volume: volume, lo: state.lo, hi: state.hi, mode: state.renderMode,
                          clips: state.clips, clipCutaway: state.clipCutaway, clipHighlight: state.clipHighlight,
                          crosshair: state.plane == .multi ? crosshair : nil, segmentation: state.segmentation,
                          preset: state.preset, presetTick: state.presetTick, onTap: onTap)
    }

    private func slice(_ axis: Int) -> some View {
        let multi = state.plane == .multi
        // Which volume axes run along a slice's columns and rows (rows go superior/anterior
        // → inferior/posterior, i.e. the row axis is flipped); see NiftiVolume.slice.
        let colAxis = axis == 0 ? 1 : 0, rowAxis = axis == 2 ? 1 : 2
        let n = [volume.dims.0, volume.dims.1, volume.dims.2]
        let u = (CGFloat(state.slices[colAxis]) + 0.5) / CGFloat(n[colAxis])
        let v = 1 - (CGFloat(state.slices[rowAxis]) + 0.5) / CGFloat(n[rowAxis])
        // One scale for all three panes: each fits the envelope of the three slice extents.
        let extents = (0..<3).map(volume.sliceExtent)
        let envelope = CGSize(width: CGFloat(extents.map(\.0).max()!), height: CGFloat(extents.map(\.1).max()!))
        return SliceView(volume: volume, axis: axis, index: state.slices[axis], lo: state.lo, hi: state.hi,
                         mirrored: state.mirrored, segmentation: state.segmentation, fitExtent: multi ? envelope : nil,
                         zoom: multi ? state.multiZoom : nil, zoomAnimated: state.multiZoomAnimated,
                         onZoom: multi ? { state.multiZoom = $0; state.multiZoomAnimated = $1 } : nil,
                         crosshair: multi ? CGPoint(x: state.mirrored ? 1 - u : u, y: v) : nil,
                         onLocate: multi ? { p in
                             // Tap in one pane: move the other two slices to the tapped voxel.
                             onInteract()
                             let ud = state.mirrored ? 1 - p.x : p.x
                             state.slices[colAxis] = max(0, min(n[colAxis] - 1, Int(ud * CGFloat(n[colAxis]))))
                             state.slices[rowAxis] = max(0, min(n[rowAxis] - 1, Int((1 - p.y) * CGFloat(n[rowAxis]))))
                         } : nil,
                         onTap: onTap) {
            state.slices[axis] = max(0, min(volume.count(axis: axis) - 1, state.slices[axis] + $0))
        }
        .overlay {
            if multi { DirectionLabels(axis: axis, mirrored: state.mirrored, bottomInset: 0) }
        }
    }
}

private struct DirectionLabels: View {
    let axis: Int
    let mirrored: Bool
    let bottomInset: CGFloat // keeps the bottom label clear of the scrubber

    var body: some View {
        let horizontal = axis == 0 ? ["P", "A"] : ["L", "R"]
        let vertical = axis == 2 ? ["A", "P"] : ["S", "I"]
        ZStack {
            label(horizontal[mirrored ? 1 : 0], .leading)
            label(horizontal[mirrored ? 0 : 1], .trailing)
            label(vertical[0], .top)
            label(vertical[1], .bottom).padding(.bottom, bottomInset)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.45))
        .padding(10)
        .allowsHitTesting(false)
    }

    private func label(_ text: String, _ edge: Alignment) -> some View {
        Text(text).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge)
    }
}

private struct SliceScrubber: View {
    let state: ViewState
    let axis: Int
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            StepSlider(value: Binding(get: { Double(state.slices[axis]) }, set: { state.slices[axis] = Int($0.rounded()) }),
                       in: 0...Double(count - 1), unit: 1)
                .accessibilityLabel("Slice")
            Text("\(state.slices[axis] + 1) of \(count)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: 480)
        .glassEffect(.regular, in: .capsule)
        .padding()
    }
}

private struct InspectorView: View {
    let volume: NiftiVolume
    let fileURL: URL?
    @Bindable var state: ViewState
    /// Keep the empty strip under the navigation bar. False once the toolbar buttons have
    /// moved off the panel, so the controls can start at the top.
    let belowBar: Bool

    private func tiltSlider(_ title: String, _ value: Binding<Float>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: "\(Int(value.wrappedValue.rounded()))°")
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value.wrappedValue = 0 } // double-tap the readout to zero it
            StepSlider(value: value, in: -90...90, unit: 1)
        }
    }

    var body: some View {
        // Slider traps on an empty range; a constant-intensity volume gets a dummy one.
        let range = volume.dataMin...max(volume.dataMax, volume.dataMin + 1)
        let unit = (range.upperBound - range.lowerBound) / 100 // one tap on the track = 1% of the range
        Form {
            Section("Adjust") {
                LabeledContent("Black") { StepSlider(value: $state.lo, in: range, unit: unit) }
                LabeledContent("White") { StepSlider(value: $state.hi, in: range, unit: unit) }
                Button("Reset") { (state.lo, state.hi) = (volume.displayMin, volume.displayMax) }
            }
            Section("3D Rendering") {
                Picker("3D Rendering", selection: $state.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            // Bind each section by id, not by position. ForEach($state.clips) hands out
            // index-based bindings, and controls still on screen read theirs once more after
            // a plane is removed — an out-of-range crash. These fall back to the last value.
            ForEach(state.clips) { snapshot in
                let id = snapshot.id
                let binding = Binding<ClipSetting>(
                    get: { state.clips.first { $0.id == id } ?? snapshot },
                    set: { new in if let i = state.clips.firstIndex(where: { $0.id == id }) { state.clips[i] = new } })
                let clip = binding.wrappedValue
                let number = (state.clips.firstIndex { $0.id == id } ?? 0) + 1
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
                    Button("Remove Clip Plane", role: .destructive) {
                        state.clips.removeAll { $0.id == id }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("3D Clip Plane \(number)")
                        if state.clipHighlight { // the plane's highlight colour in the render
                            Circle().fill(ClipSetting.colors[number - 1]).frame(width: 9, height: 9)
                        }
                    }
                }
            }
            Section(state.clips.isEmpty ? "3D Clip Plane" : "") {
                // With one plane, cutaway and normal clipping are the same thing.
                if !state.clips.isEmpty {
                    Toggle("Highlight Planes", isOn: $state.clipHighlight)
                }
                if state.clips.count > 1 {
                    Toggle("Cutaway", isOn: $state.clipCutaway)
                }
                if state.clips.count < ViewState.maxClips {
                    Button("Add Clip Plane", systemImage: "plus") {
                        // Start with an orientation that isn't in use yet.
                        let unused = ClipSetting.Plane.allCases.first { p in !state.clips.contains { $0.plane == p } }
                        state.clips.append(ClipSetting(plane: unused ?? .sagittal))
                    }
                }
            }
            SegmentationSection(volume: volume, fileURL: fileURL, state: state)
            if let seg = state.segmentation { BodyCompositionSection(seg: seg) }
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

/// DocumentGroup's navigation controller ignores SwiftUI's toolbar-visibility preferences on
/// iPadOS, so the bar is hidden through UIKit: this invisible view finds the controller in
/// its responder chain and calls setNavigationBarHidden.
private struct NavigationBarHider: UIViewRepresentable {
    let hidden: Bool

    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async { // the view may not be in the hierarchy yet during an update
            var r: UIResponder? = view
            while let next = r?.next {
                if let nav = next as? UINavigationController {
                    if nav.isNavigationBarHidden != hidden { nav.setNavigationBarHidden(hidden, animated: true) }
                    return
                }
                r = next
            }
        }
    }
}
