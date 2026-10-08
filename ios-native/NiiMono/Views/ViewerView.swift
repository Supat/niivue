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
    @State private var fullWidth: CGFloat = 0 // window width including the inspector column
    @State private var canvasHeight: CGFloat = 0 // the screen's, since the canvas runs under the bars
    private static let inspectorWidth: CGFloat = 300

    // The view selector sits at the window's horizontal centre whatever else the bar holds.
    // It can't be a .principal item (that replaces the document title menu), so it is a
    // trailing item padded on its right by however much puts it at the centre, given where
    // the button cluster will end: the bar's trailing inset, the cluster (≈ 52 pt a button)
    // and a gap. The cluster keeps the bar's trailing end whether or not the inspector is
    // open (the bar spans the column, so it sits over the column then). When that padding
    // would go negative the cluster folds into a More menu (two buttons); if even that
    // doesn't fit, the selector gives way to the right by what's missing.
    private static let pickerWidth: CGFloat = 400 // roomier than the intrinsic size, which cramps the longer labels
    private static let barInset: CGFloat = 10, clusterGap: CGFloat = 12
    private static func clusterWidth(buttons: Int) -> CGFloat { 52 * CGFloat(buttons) }
    /// Buttons in the full cluster (see `viewControls`, plus Inspector).
    private var clusterButtons: Int {
        5 + (fileURL == nil ? 0 : 1) + (model.plane != .render ? 2 : 0) + (model.plane.axis == nil ? 1 : 0)
    }
    /// The clear width right of the selector that centres it, for a cluster of `buttons`.
    private func pickerPadding(buttons: Int) -> CGFloat {
        let clusterStart = fullWidth - Self.barInset - Self.clusterWidth(buttons: buttons)
        return clusterStart - Self.clusterGap - (fullWidth / 2 + Self.pickerWidth / 2)
    }
    private var collapsesCluster: Bool { fullWidth > 0 && pickerPadding(buttons: clusterButtons) < 0 }

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
        VolumeCanvas(model: model, labelInset: chromeHidden ? 0 : 64,
                     onTap: { withAnimation { chromeHidden.toggle() } },
                     onInteract: { if chromeHidden { withAnimation { chromeHidden = false } } })
            // Full-bleed under the bars, but not under the inspector column (a trailing
            // safe-area inset), so the image is centred in the space that's actually visible.
            .ignoresSafeArea(edges: .vertical)
            .background(.black)
            .overlay(alignment: .top) {
                // Open-time restore (sidecar settings, saved segmentation, companion images).
                if let stage = model.openingStage {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(stage).font(.footnote)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, chromeHidden ? 8 : 64) // below the toolbar while it's showing
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.openingStage == nil)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { canvasHeight = $0 }
            .overlay(alignment: .bottom) {
                // The scrubber's bottom edge sits 15% of the screen height up from the bottom,
                // in either orientation, clear of the thumb and the home indicator.
                if !chromeHidden, let axis = model.plane.axis, volume.count(axis: axis) > 1 {
                    SliceScrubber(model: model, axis: axis, count: volume.count(axis: axis))
                        .padding(.bottom, max(0, canvasHeight * 0.15 - 16)) // less the scrubber's own margin
                }
            }
            // Chrome auto-hides a few seconds after it appears or was last used, like a
            // video player; a tap brings it back. It stays while the inspector is open.
            .onAppear(perform: scheduleChromeHide)
            .task { await model.loadFOV() }
            .task {
                // Sidecar first (it also records the companion images); siblings fill any gaps.
                let restored = await model.restoreFromSidecar()
                if !restored || model.segmentation.map == nil || !model.segmentation.canClassifyTissue {
                    await model.discoverSiblings()
                }
                if UserDefaults.standard.bool(forKey: "segmentOrgans") { model.segmentation.generate() } // for checks
                if UserDefaults.standard.bool(forKey: "openEditor") { model.startDrawing() } // for checks
                if UserDefaults.standard.bool(forKey: "openRepair") { model.startScanRepair() } // for checks
            }
            .task(id: model.segmentation.mapIDs) { await model.updateScanLandmarks() }
            .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { model.landscape = $0 }
            .onChange(of: model.pairedProfileView) { model.photoMarker = nil } // another photo: the marker no longer applies
            .onChange(of: model.sidecarSettings) { model.scheduleSidecarSave() }
            .onChange(of: model.segmentation.savedOrder) { model.saveSidecarMaps() }
            // A photo alone must still leave a settings.json, or the sidecar isn't found on reopening.
            .onChange(of: model.profile.photos.keys.sorted { $0.rawValue < $1.rawValue }) { model.scheduleSidecarSave() }
            .onChange(of: chromeHidden) { if !chromeHidden { scheduleChromeHide() } }
            .onChange(of: showInspector) { showInspector ? hideChromeTask?.cancel() : scheduleChromeHide() }
            .onChange(of: model.plane) { scheduleChromeHide() }
            .onChange(of: model.slices) { scheduleChromeHide() }
            .onChange(of: model.mirrored) { scheduleChromeHide() }
            .modifier(EditorCover(model: model))
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(Self.inspectorWidth)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
            // Toolbar modifiers sit outside the inspector: declared inside it they are lost on
            // iPadOS 27 when the document opens in the launch window (a browser pick), leaving
            // only the back button and title; a document opened in a window of its own kept them.
            .toolbar {
                // Trailing, not .principal: principal would replace the document title menu.
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        Picker("View", selection: $model.plane) {
                            ForEach(Plane.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: Self.pickerWidth)
                        .environment(\.colorScheme, .dark) // match the dark bar in light mode
                        // Pads the selector out to the window's centre (see pickerPadding).
                        Color.clear.frame(width: max(0, pickerPadding(buttons: collapsesCluster ? 2 : clusterButtons)))
                            .allowsHitTesting(false)
                    }
                }
                .sharedBackgroundVisibility(.hidden) // the segmented control is already glass
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Not enough room right of the centred selector for every button: the
                    // cluster folds into a More menu beside the Inspector button.
                    if collapsesCluster {
                        Menu("More", systemImage: "ellipsis.circle") { viewControls }
                    } else {
                        viewControls
                    }
                    Button("Inspector", systemImage: "info.circle") { showInspector.toggle() }
                }
            }
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
            .background(NavigationBarHider(hidden: chromeHidden))
            .toolbarColorScheme(.dark, for: .navigationBar) // content is always black
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .statusBarHidden(chromeHidden)
    }

    /// The view controls of the toolbar cluster: in the bar, or in a More menu while the
    /// inspector is open.
    @ViewBuilder private var viewControls: some View {
        if model.plane != .render {
            Toggle("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                   isOn: $model.mirrored)
        }
        // Station fields of view from the acquisition metadata (Inspector › Image).
        // Shown off while there is nothing to draw (a disabled "on" toggle renders as a blank disc).
        Toggle("Field of View", systemImage: "viewfinder",
               isOn: Binding(get: { model.showFOV && !model.fovBoxes.isEmpty }, set: { model.showFOV = $0 }))
            .disabled(model.fovBoxes.isEmpty)
        Toggle("Crosshair", systemImage: "plus.viewfinder", isOn: $model.showCrosshair)
        if model.plane != .render { BookmarkMenu(model: model) }
        if model.plane.axis == nil { // 3D and multiplanar
            Menu("View", systemImage: "cube") {
                ForEach(ViewPreset.allCases) { preset in
                    Button(preset.rawValue) { model.applyPreset(preset) }
                }
            }
        }
        if model.plane.axis != nil {
            Toggle("Side by Side with Photo", systemImage: "rectangle.split.2x1",
                   isOn: Binding(get: { model.showsSideBySide }, set: { model.sideBySide = $0 }))
                .disabled(!model.canSideBySide) // landscape, and the view's photo is in the profile
        } else {
            Toggle("Show Profile", systemImage: "person.crop.rectangle",
                   isOn: Binding(get: { model.showsProfile }, set: { model.showProfile = $0 }))
                .disabled(model.profile.faceCutout == nil) // needs a Coronal Front photo with a face in it
        }
        Button("Snapshot", systemImage: "camera") {
            SnapshotPanes.captureAndShare(documentName: fileURL?.deletingPathExtension().deletingPathExtension().lastPathComponent ?? "Snapshot")
        }
        if let fileURL { ShareLink(item: fileURL) }
    }
}

/// The canvas: one slice, the multiplanar grid, or the 3D render.
private struct VolumeCanvas: View {
    let model: ViewerViewModel
    /// Room the bottom direction label leaves for the scrubber.
    let labelInset: CGFloat
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
            .overlay(alignment: .bottomTrailing) {
                if model.showCrosshair { lockButton(bottom: 0) }
            }
        default:
            let axis = model.plane.axis!
            let pane = slice(axis)
                .overlay { DirectionLabels(axis: axis, mirrored: model.mirrored, bottomInset: labelInset) }
                .overlay(alignment: .bottomTrailing) {
                    // Above the scale bar, which sits in this corner.
                    if model.showCrosshair && !model.showsSideBySide { lockButton(bottom: labelInset + 32) }
                }
            if model.showsSideBySide, let view = model.pairedProfileView, let photo = model.profile.photos[view] {
                // Slice | its profile photo, the photo placed to line up with the slice.
                let e = model.volume.sliceExtent(axis: axis)
                let unit = ProfileAlignment.photoFrame(axis: axis, mirrored: model.mirrored,
                                                       extent: CGSize(width: CGFloat(e.0), height: CGFloat(e.1)), photoSize: photo.size,
                                                       scan: model.scanLandmarks, photo: model.profile.landmarks[view])
                let v = model.sliceViewport
                HStack(spacing: 1) {
                    pane
                    // Both panes are the same size, so a point of one is the same point of the other.
                    ProfilePhotoPane(image: photo, frame: CGRect(x: v.minX + unit.minX * v.width, y: v.minY + unit.minY * v.height,
                                                                 width: unit.width * v.width, height: unit.height * v.height),
                                     marker: model.photoMarker.map { CGPoint(x: v.minX + $0.x * v.width, y: v.minY + $0.y * v.height) }) { p in
                        guard v.width > 0, v.height > 0 else { return }
                        onInteract()
                        model.photoMarker = CGPoint(x: (p.x - v.minX) / v.width, y: (p.y - v.minY) / v.height)
                    }
                        .overlay(alignment: .bottomTrailing) {
                            Text(view.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.45))
                                .padding(10).padding(.bottom, labelInset).allowsHitTesting(false)
                        }
                }
                .background(Color(white: 0.25))
            } else {
                pane
            }
        }
    }

    /// Stops taps on a slice from moving the crosshair.
    private func lockButton(bottom: CGFloat) -> some View {
        Button(model.crosshairLocked ? "Unlock Crosshair" : "Lock Crosshair",
               systemImage: model.crosshairLocked ? "lock.fill" : "lock.open") {
            onInteract()
            model.crosshairLocked.toggle()
        }
        .labelStyle(.iconOnly)
        .font(.footnote)
        .foregroundStyle(.white.opacity(model.crosshairLocked ? 0.7 : 0.35))
        .frame(width: 44, height: 44) // hit target; the glyph stays small
        .contentShape(.rect)
        .padding(8)
        .padding(.bottom, bottom)
    }

    private var render: some View {
        RenderView(volume: model.volume, lo: model.lo, hi: model.hi, mode: model.renderMode,
                   clips: model.clips, clipCutaway: model.clipCutaway, clipKeepLabels: model.clipKeepSegments, clipHighlight: model.clipHighlight,
                   crosshair: model.showCrosshair ? model.crosshairFractions : nil,
                   overlay: model.segmentation.overlay, cutout: model.noiseCutout, volumeDirtyZ: model.volumeDirtyZ, fov: model.visibleFOVBoxes, cameraClip: model.cameraClip ? model.cameraClipDepth : 0,
                   preset: model.preset, presetTick: model.presetTick, onTap: onTap)
            .overlay {
                if model.showsProfile, let face = model.profile.faceCutout {
                    // Top-left of the render, sized to the pane; in the full 3D view it sits
                    // below the back button (the canvas runs under the bar).
                    GeometryReader { g in
                        let multi = model.plane == .multi
                        let width = min(max(min(g.size.width, g.size.height) * 0.16, 44), 150)
                        VStack(alignment: .leading, spacing: 6) {
                            Image(uiImage: face)
                                .resizable().scaledToFit()
                                .frame(width: width)
                                .clipShape(.rect(cornerRadius: width * 0.06))
                                .overlay { RoundedRectangle(cornerRadius: width * 0.06).strokeBorder(.white.opacity(0.35), lineWidth: 1) }
                                .accessibilityLabel("Subject's face")
                            // The full 3D view also lists what is known about the subject;
                            // the small Multi pane keeps the photo only.
                            if !multi {
                                let imaged = model.segmentation.map.map { model.bodyComposition.estimate(for: $0).imagedKg }
                                ForEach(model.bodyComposition.summaryLines(imagedKg: imaged), id: \.self) { line in
                                    Text(line)
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                        .padding(.leading, multi ? 8 : 16)
                        .padding(.top, multi ? 8 : 84)
                    }
                    .allowsHitTesting(false)
                }
            }
    }

    private func slice(_ axis: Int) -> some View {
        let multi = model.plane == .multi
        return SliceView(volume: model.volume, axis: axis, index: model.slices[axis], lo: model.lo, hi: model.hi,
                         mirrored: model.mirrored, overlay: model.segmentation.overlay, cutout: model.noiseCutout,
                         fitExtent: multi ? model.sliceEnvelope : nil,
                         zoom: multi ? model.multiZoom : nil, zoomAnimated: model.multiZoomAnimated,
                         onZoom: multi ? { model.multiZoom = $0; model.multiZoomAnimated = $1 } : nil,
                         centre: multi ? model.panCentre(in: axis) : nil,
                         onPan: multi ? { model.setPanCentre($0, in: axis); model.multiZoomAnimated = $1 } : nil,
                         // Side by side: a marker dropped on the photo takes the crosshair's place.
                         crosshair: !multi && model.showsSideBySide && model.photoMarker != nil ? model.photoMarker
                             : model.showCrosshair ? model.crosshair(in: axis) : nil,
                         fov: model.fovRects(in: axis),
                         onLocate: (multi || !model.showsSideBySide) && model.showCrosshair && !model.crosshairLocked ? { p in onInteract(); model.locate(p, in: axis) } : nil,
                         onViewport: model.showsSideBySide ? { model.sliceViewport = $0 } : nil,
                         scaleBarInset: multi ? 0 : labelInset,
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

struct SliceScrubber: View {
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

/// Saved slice positions: add the current one, recall one into every slice view, or remove.
private struct BookmarkMenu: View {
    let model: ViewerViewModel

    var body: some View {
        Menu("Bookmarks", systemImage: model.bookmarks.isEmpty ? "bookmark" : "bookmark.fill") {
            Button("Add Bookmark", systemImage: "plus") { model.addBookmark() }
            if !model.bookmarks.isEmpty {
                Section {
                    ForEach(model.bookmarks) { b in
                        Button { model.recall(b) } label: {
                            Text(b.name)
                            Text(model.describe(b))
                        }
                    }
                }
                Menu("Remove", systemImage: "trash") {
                    ForEach(model.bookmarks) { b in
                        Button(b.name, role: .destructive) { model.bookmarks.removeAll { $0.id == b.id } }
                    }
                }
            }
        }
    }
}

/// The segmentation editor, full screen while `model.drawing` is set. A modifier of its own
/// keeps ViewerView's long modifier chain within the type checker's reach.
private struct EditorCover: ViewModifier {
    let model: ViewerViewModel

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(get: { model.drawing }, set: { model.drawing = $0 })) { drawing in
            SegmentationEditor(model: model, drawing: drawing)
        }
    }
}
