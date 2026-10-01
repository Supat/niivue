//
//  ViewerView.swift — the document screen: canvas (single plane, multiplanar grid or 3D),
//  toolbar, scrubber, auto-hiding chrome and the inspector.
//

import SwiftUI

struct ViewerView: View {
    @State var model: ViewerViewModel
    private var fileURL: URL? { model.fileURL }
    @State private var chromeHidden = false
    @State private var hideChromeTask: Task<Void, Never>?
    @State private var showInspector = UserDefaults.standard.bool(forKey: "inspector") // `-inspector YES` for checks
    @State private var fullWidth: CGFloat = 0   // window width including the inspector column
    @State private var canvasWidth: CGFloat = 0 // width left for the image
    private var inspectorShift: CGFloat { max(0, fullWidth - canvasWidth) }
    private var shiftsToolbar: Bool { inspectorShift > 1 && fullWidth >= 1150 }
    private static let inspectorWidth: CGFloat = 300

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
        let volume = model.volume
        VolumeCanvas(model: model,
                     onTap: { withAnimation { chromeHidden.toggle() } },
                     onInteract: { if chromeHidden { withAnimation { chromeHidden = false } } })
            // Full-bleed under the bars, but not under the inspector column (a trailing
            // safe-area inset), so the image is centred in the space that's actually visible.
            .ignoresSafeArea(edges: .vertical)
            .background(.black)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasWidth = $0 }
            .overlay {
                if let axis = model.plane.axis {
                    DirectionLabels(axis: axis, mirrored: model.mirrored, bottomInset: chromeHidden ? 0 : 64)
                }
            }
            .overlay(alignment: .bottom) {
                if !chromeHidden, let axis = model.plane.axis, volume.count(axis: axis) > 1 {
                    SliceScrubber(model: model, axis: axis, count: volume.count(axis: axis))
                }
            }
            .toolbar {
                // Trailing, not .principal: principal would replace the document title menu.
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("View", selection: $model.plane) {
                        ForEach(Plane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 440) // roomier than the intrinsic size, which cramps the longer labels
                    .environment(\.colorScheme, .dark) // match the dark bar in light mode
                }
                .sharedBackgroundVisibility(.hidden) // the segmented control is already glass
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.plane != .render {
                        Toggle("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                               isOn: $model.mirrored)
                    }
                    if model.plane.axis == nil { // 3D and multiplanar
                        Menu("View", systemImage: "cube") {
                            ForEach(ViewPreset.allCases) { preset in
                                Button(preset.rawValue) { model.applyPreset(preset) }
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
                // Sidecar first (it also records the companion images); siblings fill any gaps.
                let restored = await model.restoreFromSidecar()
                if let fileURL, !restored || model.segmentation.map == nil || !model.segmentation.canClassifyTissue {
                    await model.segmentation.discoverSiblings(of: fileURL)
                }
                if UserDefaults.standard.bool(forKey: "segmentOrgans") { model.segmentation.generate() } // for checks
            }
            .onChange(of: model.sidecarSettings) { model.scheduleSidecarSave() }
            .onChange(of: model.segmentation.map?.id) { model.saveSidecarMaps() }
            .onChange(of: chromeHidden) { if !chromeHidden { scheduleChromeHide() } }
            .onChange(of: showInspector) { showInspector ? hideChromeTask?.cancel() : scheduleChromeHide() }
            .onChange(of: model.plane) { scheduleChromeHide() }
            .onChange(of: model.slices) { scheduleChromeHide() }
            .onChange(of: model.mirrored) { scheduleChromeHide() }
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
            .background(NavigationBarHider(hidden: chromeHidden))
            .toolbarColorScheme(.dark, for: .navigationBar) // content is always black
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .statusBarHidden(chromeHidden)
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model, belowBar: !shiftsToolbar)
                    .inspectorColumnWidth(Self.inspectorWidth)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
    }
}

/// The canvas: one slice, the multiplanar grid, or the 3D render.
private struct VolumeCanvas: View {
    let model: ViewerViewModel
    let onTap: () -> Void
    /// A tap that does something else (moves the crosshair) still brings hidden chrome back.
    let onInteract: () -> Void

    var body: some View {
        switch model.plane {
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
            slice(model.plane.axis!)
        }
    }

    private var render: some View {
        RenderView(volume: model.volume, lo: model.lo, hi: model.hi, mode: model.renderMode,
                   clips: model.clips, clipCutaway: model.clipCutaway, clipHighlight: model.clipHighlight,
                   crosshair: model.plane == .multi ? model.crosshairFractions : nil,
                   overlay: model.segmentation.overlay,
                   preset: model.preset, presetTick: model.presetTick, onTap: onTap)
    }

    private func slice(_ axis: Int) -> some View {
        let multi = model.plane == .multi
        return SliceView(volume: model.volume, axis: axis, index: model.slices[axis], lo: model.lo, hi: model.hi,
                         mirrored: model.mirrored, overlay: model.segmentation.overlay,
                         fitExtent: multi ? model.sliceEnvelope : nil,
                         zoom: multi ? model.multiZoom : nil, zoomAnimated: model.multiZoomAnimated,
                         onZoom: multi ? { model.multiZoom = $0; model.multiZoomAnimated = $1 } : nil,
                         crosshair: multi ? model.crosshair(in: axis) : nil,
                         onLocate: multi ? { p in onInteract(); model.locate(p, in: axis) } : nil,
                         onTap: onTap) { model.stepSlice(axis: axis, by: $0) }
            .overlay {
                if multi { DirectionLabels(axis: axis, mirrored: model.mirrored, bottomInset: 0) }
            }
    }
}

/// Anatomical direction at each edge of a slice view (L/R, A/P, S/I), following the
/// display convention in NiftiVolume.slice and the mirror toggle.
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
    let model: ViewerViewModel
    let axis: Int
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            StepSlider(value: Binding(get: { Double(model.slices[axis]) }, set: { model.slices[axis] = Int($0.rounded()) }),
                       in: 0...Double(count - 1), unit: 1)
                .accessibilityLabel("Slice")
            Text("\(model.slices[axis] + 1) of \(count)")
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
