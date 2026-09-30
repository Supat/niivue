//
//  NiiMonoApp.swift — Preview-style MRI viewer shell.
//  DocumentGroup supplies the native document browser, title menu and window
//  management; this file adds the viewer chrome (plane picker, scrubber, inspector).
//

import SwiftUI
import UniformTypeIdentifiers

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
    case axial = "Axial", coronal = "Coronal", sagittal = "Sagittal", render = "3D"
    var id: Self { self }
    /// Volume axis the plane is perpendicular to; nil for the 3D render.
    var axis: Int? { [.sagittal: 0, .coronal: 1, .axial: 2][self] }
}

/// How the 3D view draws the volume.
enum RenderMode: String, CaseIterable, Identifiable {
    case mip = "MIP", volume = "Volume"
    var id: Self { self }
}

/// Clip plane for the 3D view, perpendicular to one anatomical axis.
enum ClipPlane: String, CaseIterable, Identifiable {
    case off = "Off", sagittal = "Sagittal", coronal = "Coronal", axial = "Axial"
    var id: Self { self }
    var axis: Int32 { [.off: -1, .sagittal: 0, .coronal: 1, .axial: 2][self]! }
}

/// Per-frame viewer state lives here rather than in ViewerView's @State so scrubbing
/// and windowing only invalidate the small views that read it, not the toolbar tree.
@Observable final class ViewState {
    // Launch argument `-plane 3D` (etc.) picks the initial view, for simulator checks.
    var plane = Plane(rawValue: UserDefaults.standard.string(forKey: "plane") ?? "") ?? .axial
    var slices: [Int]
    var lo: Float
    var hi: Float
    // Remembered across documents and launches.
    var mirrored = UserDefaults.standard.bool(forKey: "mirrored") {
        didSet { UserDefaults.standard.set(mirrored, forKey: "mirrored") }
    }
    var renderMode = RenderMode(rawValue: UserDefaults.standard.string(forKey: "renderMode") ?? "") ?? .mip {
        didSet { UserDefaults.standard.set(renderMode.rawValue, forKey: "renderMode") }
    }

    var clip = ClipPlane(rawValue: UserDefaults.standard.string(forKey: "clip") ?? "") ?? .off // `-clip Axial`
    var clipPos: Float = 0.5
    var clipFlip = false
    // Degrees about the two axes after the plane's own (cyclic x→y→z). `-clipTilt 30` for checks.
    var clipTilt = SIMD2<Float>(UserDefaults.standard.float(forKey: "clipTilt"), 0)
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

    var body: some View {
        VolumeCanvas(volume: volume, state: state) { withAnimation { chromeHidden.toggle() } }
            // Full-bleed under the bars, but not under the inspector column (a trailing
            // safe-area inset), so the image is centred in the space that's actually visible.
            .ignoresSafeArea(edges: .vertical)
            .background(.black)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasWidth = $0 }
            .overlay { DirectionLabels(state: state, bottomInset: chromeHidden ? 0 : 64) }
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
                    .fixedSize()
                    .environment(\.colorScheme, .dark) // match the dark bar in light mode
                }
                .sharedBackgroundVisibility(.hidden) // the segmented control is already glass
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if state.plane.axis != nil {
                        Toggle("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                               isOn: $state.mirrored)
                    }
                    if state.plane == .render {
                        Menu("View", systemImage: "cube") {
                            ForEach(ViewPreset.allCases) { preset in
                                Button(preset.rawValue) { state.preset = preset; state.presetTick += 1 }
                            }
                        }
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
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar) // content is always black
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .statusBarHidden(chromeHidden)
            .inspector(isPresented: $showInspector) {
                InspectorView(volume: volume, state: state, belowBar: !shiftsToolbar)
                    .inspectorColumnWidth(Self.inspectorWidth)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
    }
}

private struct VolumeCanvas: View {
    let volume: NiftiVolume
    let state: ViewState
    let onTap: () -> Void

    var body: some View {
        if let axis = state.plane.axis {
            SliceView(volume: volume, axis: axis, index: state.slices[axis], lo: state.lo, hi: state.hi,
                      mirrored: state.mirrored, onTap: onTap) {
                state.slices[axis] = max(0, min(volume.count(axis: axis) - 1, state.slices[axis] + $0))
            }
        } else {
            RenderView(volume: volume, lo: state.lo, hi: state.hi, mode: state.renderMode,
                       clip: state.clip, clipPos: state.clipPos, clipFlip: state.clipFlip, clipTilt: state.clipTilt,
                       preset: state.preset, presetTick: state.presetTick, onTap: onTap)
        }
    }
}

/// Anatomical direction at each edge of a slice view (L/R, A/P, S/I), following the
/// display convention in NiftiVolume.slice and the mirror toggle.
private struct DirectionLabels: View {
    let state: ViewState
    let bottomInset: CGFloat // keeps the bottom label clear of the scrubber

    var body: some View {
        if let axis = state.plane.axis {
            let horizontal = axis == 0 ? ["P", "A"] : ["L", "R"]
            let vertical = axis == 2 ? ["A", "P"] : ["S", "I"]
            ZStack {
                label(horizontal[state.mirrored ? 1 : 0], .leading)
                label(horizontal[state.mirrored ? 0 : 1], .trailing)
                label(vertical[0], .top)
                label(vertical[1], .bottom).padding(.bottom, bottomInset)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.45))
            .padding(10)
            .allowsHitTesting(false)
        }
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
            Section("3D Clip Plane") {
                Picker("Plane", selection: $state.clip) {
                    ForEach(ClipPlane.allCases) { Text($0.rawValue).tag($0) }
                }
                if state.clip != .off {
                    LabeledContent("Depth") { StepSlider(value: $state.clipPos, in: 0...1, unit: 0.01) }
                    // Tilt axes are the two after the plane's own axis, cyclically (x→y→z→x).
                    let names = ["L–R", "A–P", "S–I"], a = Int(state.clip.axis)
                    tiltSlider("Tilt about \(names[(a + 1) % 3])", $state.clipTilt.x)
                    tiltSlider("Tilt about \(names[(a + 2) % 3])", $state.clipTilt.y)
                    Toggle("Flip Side", isOn: $state.clipFlip)
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
