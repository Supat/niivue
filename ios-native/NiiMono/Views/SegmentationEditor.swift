//
//  SegmentationEditor.swift — draw a segmentation by hand: the drawing slice on the right,
//  a reference slice (swappable) and the 3D render of the labels on the left, tools below.
//

import SwiftUI

struct SegmentationEditor: View {
    let model: ViewerViewModel
    @Bindable var drawing: DrawingViewModel
    @State private var confirmDiscard = false
    @State private var showingLabels = false
    @State private var finishing = false
    @State private var adjusting = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { g in
                // Landscape: reference and 3D in a column on the left. Portrait: side by side on top.
                if g.size.width >= g.size.height {
                    HStack(spacing: 1) {
                        VStack(spacing: 1) { reference; render }
                            .frame(width: max(240, g.size.width * 0.32))
                        main
                    }
                } else {
                    VStack(spacing: 1) {
                        HStack(spacing: 1) { reference; render }
                            .frame(height: g.size.height * 0.32)
                        main
                    }
                }
            }
            .background(Color(white: 0.25))
            .ignoresSafeArea(edges: .bottom)
        }
        .background(.black)
        .background { UndoKeys(drawing: drawing, active: !showingLabels && !adjusting) }
    }

    /// A plain bar, not a navigation bar: inside the document's window a NavigationStack
    /// picks up the document's own back button (which would close it) and title menu.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Cancel") { if drawing.hasChanges { confirmDiscard = true } else { model.drawing = nil } }
                .confirmationDialog("Discard the drawing?", isPresented: $confirmDiscard) {
                    Button("Discard Changes", role: .destructive) { model.drawing = nil }
                }
            Spacer()
            Text("Draw Segmentation").font(.headline)
            Spacer()
            HStack(spacing: 4) {
                // Black / white levels of the slices and the paint's opacity (the viewer's own, so
                // they carry over).
                Button("Adjust Levels and Paint Opacity", systemImage: "circle.lefthalf.filled") { adjusting = true }
                    .labelStyle(.iconOnly)
                    .popover(isPresented: $adjusting) { LevelsPopover(model: model) }
                Toggle("Crosshair", systemImage: "plus.viewfinder", isOn: $drawing.crosshair2D)
                Toggle("Show Paint", systemImage: drawing.hidePaint ? "paintbrush.pointed" : "paintbrush.pointed.fill",
                       isOn: Binding(get: { !drawing.hidePaint }, set: { drawing.hidePaint = !$0 }))
                    .keyboardShortcut("h", modifiers: .command)
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            HStack(spacing: 4) {
                // ⌘Z / ⇧⌘Z come through UndoKeys (below), not .keyboardShortcut: the system's
                // Edit › Undo claims those keys first and asks the first responder's UndoManager.
                Button("Undo", systemImage: "arrow.uturn.backward") { drawing.undo() }
                    .disabled(!drawing.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { drawing.redo() }
                    .disabled(!drawing.canRedo)
            }
            .labelStyle(.iconOnly)
            Button("Done") {
                finishing = true
                Task { await model.finishDrawing() }
            }
            .buttonStyle(.glassProminent)
            .disabled(finishing)
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Panes

    /// The paint on the slice panes, or none while hidden.
    private var slicePaint: SegmentationOverlay? { drawing.hidePaint ? nil : drawing.overlay(opacity: model.segmentation.opacity) }

    private var main: some View {
        let axis = drawing.mainAxis
        return SliceView(volume: model.volume, axis: axis, index: model.slices[axis], lo: model.lo, hi: model.hi,
                         mirrored: model.mirrored, overlay: slicePaint,
                         crosshair: drawing.crosshair2D ? model.crosshair(in: axis) : nil,
                         onDraw: { phase, p in drawing.handle(phase, p, index: model.slices[axis], mirrored: model.mirrored) },
                         drawsWithFinger: drawing.drawsWithFinger,
                         onTwoFingerTap: { drawing.tapUndo() },
                         onThreeFingerTap: { drawing.tapRedo() },
                         scaleBarInset: 120,
                         onTap: {}) { model.stepSlice(axis: axis, by: $0) }
            .overlay(alignment: .topLeading) { paneTitle(axis) }
            .overlay(alignment: .top) {
                if drawing.isSmoothing {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Smoothing \(drawing.activeLabel?.name ?? "label")…").font(.footnote) }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 12)
                } else if let note = drawing.note {
                    Text(note).font(.footnote)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: drawing.note)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if model.volume.count(axis: axis) > 1 {
                        SliceScrubber(model: model, axis: axis, count: model.volume.count(axis: axis))
                    }
                    tools
                }
                .padding(.bottom, 16)
            }
    }

    private var reference: some View {
        let axis = drawing.refAxis
        return SliceView(volume: model.volume, axis: axis, index: model.slices[axis], lo: model.lo, hi: model.hi,
                         mirrored: model.mirrored, overlay: slicePaint,
                         crosshair: drawing.crosshair2D ? model.crosshair(in: axis) : nil,
                         onLocate: { model.locate($0, in: axis) }, // moves the drawing slice
                         onTap: {}) { model.stepSlice(axis: axis, by: $0) }
            .overlay(alignment: .topLeading) { paneTitle(axis) }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Menu("Reference Plane", systemImage: "square.on.square") {
                        ForEach([2, 1, 0].filter { $0 != drawing.mainAxis }, id: \.self) { a in
                            Button(Self.planeName(a)) { drawing.refAxis = a }
                        }
                    }
                    Button("Swap Views", systemImage: "arrow.left.arrow.right") {
                        (drawing.mainAxis, drawing.refAxis) = (drawing.refAxis, drawing.mainAxis)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .padding(8)
            }
    }

    private var render: some View {
        RenderView(volume: model.volume, lo: model.lo, hi: model.hi, mode: model.renderMode,
                   clips: [], clipCutaway: false, clipHighlight: false,
                   crosshair: drawing.crosshair3D ? model.crosshairFractions : nil,
                   // Hidden paint leaves the plain scan (the eye's labels-only mode needs labels).
                   overlay: drawing.hidePaint ? nil : drawing.overlay(opacity: model.segmentation.opacity, in3D: true),
                   cameraClip: model.cameraClip ? model.cameraClipDepth : 0,
                   preset: nil, presetTick: 0, onTap: {})
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Toggle("Crosshair", systemImage: "plus.viewfinder", isOn: $drawing.crosshair3D)
                    // The viewer's Clip at Camera (Inspector › 3D): tap to switch, hold for the depth.
                    if model.cameraClip { cameraClipMenu.buttonStyle(.glassProminent) } else { cameraClipMenu }
                    // Fades unlabelled tissue; moot once the scan is hidden altogether.
                    // Both act on the paint, so they wait while it's hidden.
                    Toggle("Show Through Tissue", systemImage: "cube.transparent", isOn: $drawing.showThrough)
                        .disabled(drawing.hideScan || drawing.hidePaint)
                    Toggle("Show Scan", systemImage: drawing.hideScan ? "eye.slash" : "eye",
                           isOn: Binding(get: { !drawing.hideScan }, set: { drawing.hideScan = !$0 }))
                        .disabled(drawing.hidePaint)
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .padding(8)
            }
    }

    private var cameraClipMenu: some View {
        Menu {
            Toggle("Clip at Camera", isOn: Binding(get: { model.cameraClip }, set: { model.cameraClip = $0 }))
            Picker("Clip Depth", selection: Binding(get: { model.cameraClipDepth }, set: { model.cameraClipDepth = $0; model.cameraClip = true })) {
                ForEach([Float(0.25), 0.5, 0.75, 0.9], id: \.self) { Text("\(Int($0 * 100))% to the pivot").tag($0) }
            }
        } label: {
            Label("Clip at Camera", systemImage: "camera.metering.center.weighted")
        } primaryAction: {
            model.cameraClip.toggle()
        }
    }

    private func paneTitle(_ axis: Int) -> some View {
        Text(Self.planeName(axis))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.6))
            .padding(10)
            .allowsHitTesting(false)
    }

    static func planeName(_ axis: Int) -> String { ["Sagittal", "Coronal", "Axial"][axis] }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: 14) {
            Button { showingLabels = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(drawing.activeLabel.map(color) ?? .clear).frame(width: 14, height: 14)
                    Text(drawing.activeLabel?.name ?? "").lineLimit(1)
                    if drawing.activeIsLocked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange) }
                    if drawing.activeIsHidden { Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
            .popover(isPresented: $showingLabels) { LabelList(drawing: drawing) }
            ColorPicker("Colour", selection: activeColor, supportsOpacity: false).labelsHidden()
            Picker("Tool", selection: $drawing.tool) {
                ForEach(DrawingViewModel.Tool.allCases) { Image(systemName: $0.symbol).accessibilityLabel($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            // Tap: medium. Hold for the other strengths.
            Menu {
                ForEach(DrawingViewModel.Smoothing.allCases) { s in
                    Button("\(s.name) (σ \(s.rawValue.formatted()) mm)") { Task { await drawing.smooth(s) } }
                }
                Divider()
                // Normally only what was edited since the last smoothing is smoothed again.
                Button("Whole Label (Medium)") { Task { await drawing.smooth(.medium, whole: true) } }
            } label: {
                Label("Smooth \(drawing.activeLabel?.name ?? "Label")", systemImage: "wand.and.sparkles")
            } primaryAction: {
                Task { await drawing.smooth(.medium) }
            }
            .labelStyle(.iconOnly)
            .disabled(drawing.isSmoothing)
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 6))
                StepSlider(value: $drawing.brushMM, in: 1...40, unit: 1).frame(width: 120)
                Text("\(Int(drawing.brushMM)) mm").font(.footnote.monospacedDigit()).frame(width: 44, alignment: .leading)
            }
            .disabled(drawing.tool == .fill)
            Toggle("Draw with Finger", systemImage: "hand.draw", isOn: $drawing.drawsWithFinger)
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private func color(_ l: CustomLabel) -> Color {
        l.color.count == 3 ? Color(red: Double(l.color[0]), green: Double(l.color[1]), blue: Double(l.color[2])) : .gray
    }

    private var activeColor: Binding<Color> {
        Binding(get: { drawing.activeLabel.map(color) ?? .gray }, set: { c in
            guard let i = drawing.labels.firstIndex(where: { $0.id == drawing.active }) else { return }
            let r = UIColor(c).cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components ?? []
            if r.count >= 3 { drawing.labels[i].color = r.prefix(3).map { Float($0) } }
        })
    }
}

/// Black and white levels for the editor's slices, as in Inspector › Image › Adjust, and the
/// paint's opacity.
private struct LevelsPopover: View {
    @Bindable var model: ViewerViewModel

    var body: some View {
        let volume = model.volume
        // Slider traps on an empty range; a constant-intensity volume gets a dummy one.
        let range = volume.dataMin...max(volume.dataMax, volume.dataMin + 1)
        let unit = (range.upperBound - range.lowerBound) / 100
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Black") { StepSlider(value: $model.lo, in: range, unit: unit) }
            LabeledContent("White") { StepSlider(value: $model.hi, in: range, unit: unit) }
            Button("Reset") { model.resetWindow() }
            Divider()
            // How strongly the paint covers the scan, in every pane (Inspector › Segmentation › Opacity).
            LabeledContent("Paint") { StepSlider(value: Binding(get: { model.segmentation.opacity }, set: { model.segmentation.opacity = $0 }), in: 0...1, unit: 0.05) }
            Text("\(Int(model.segmentation.opacity * 100))% opaque").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }
}

/// The drawing's labels: pick the one to draw with, rename and recolour in place, drag to
/// reorder (the order is kept, and the inspector lists them the same way), add or delete.
private struct LabelList: View {
    @Bindable var drawing: DrawingViewModel
    @State private var confirmDelete = false

    var body: some View {
        // No NavigationStack: in the document's window it picks up the document's back
        // button and title menu (see the editor's top bar).
        VStack(spacing: 0) {
            HStack {
                Button("New Label", systemImage: "plus") { drawing.addLabel() }
                Spacer()
                Text("Labels").font(.headline)
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .disabled(drawing.labels.count < 2 || drawing.activeIsLocked)
                    .confirmationDialog("Delete \(drawing.activeLabel?.name ?? "the label") and erase its voxels?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete Label", role: .destructive) { drawing.deleteLabel(drawing.active) }
                    }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .padding(12)
            List {
                ForEach($drawing.labels) { $label in
                    HStack(spacing: 10) {
                        Button { drawing.active = label.id } label: {
                            Image(systemName: label.id == drawing.active ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Draw with \(label.name)")
                        ColorPicker("Colour", selection: Binding(get: { Self.color(label) }, set: { label.color = Self.rgb($0) ?? label.color }),
                                    supportsOpacity: false)
                            .labelsHidden()
                        TextField("Name", text: $label.name)
                        // Hidden: left out of all three panes until shown again.
                        Button { label.hidden = label.hidden == true ? nil : true } label: {
                            Image(systemName: label.hidden == true ? "eye.slash" : "eye")
                                .foregroundStyle(label.hidden == true ? Color.secondary : Color.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(label.hidden == true ? "Show \(label.name)" : "Hide \(label.name)")
                        // Locked: nothing draws over, erases, fills or smooths its voxels.
                        Button { label.locked = label.locked == true ? nil : true } label: {
                            Image(systemName: label.locked == true ? "lock.fill" : "lock.open")
                                .foregroundStyle(label.locked == true ? Color.orange : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(label.locked == true ? "Unlock \(label.name)" : "Lock \(label.name)")
                    }
                }
                .onMove { drawing.labels.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active)) // drag handles always showing
        }
        .frame(minWidth: 340, minHeight: 360)
        .presentationCompactAdaptation(.popover)
    }

    static func color(_ l: CustomLabel) -> Color {
        l.color.count == 3 ? Color(red: Double(l.color[0]), green: Double(l.color[1]), blue: Double(l.color[2])) : .gray
    }

    static func rgb(_ c: Color) -> [Float]? {
        let r = UIColor(c).cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components ?? []
        return r.count >= 3 ? r.prefix(3).map { Float($0) } : nil
    }
}

/// Makes ⌘Z / ⇧⌘Z (and Edit › Undo / Redo in the menu bar) work in the editor: an invisible
/// first responder whose UndoManager forwards to the drawing's own history, with the two key
/// commands on it too. `active` false while a popover may hold the keyboard (the label names).
private struct UndoKeys: UIViewRepresentable {
    let drawing: DrawingViewModel
    let active: Bool

    func makeUIView(context: Context) -> Responder { Responder() }

    func updateUIView(_ view: Responder, context: Context) {
        view.forwarding.drawing = drawing
        view.active = active
        if active, !view.isFirstResponder { DispatchQueue.main.async { view.claim() } }
    }

    final class Responder: UIView {
        let forwarding = ForwardingUndoManager()
        var active = true
        override var canBecomeFirstResponder: Bool { true }
        override var undoManager: UndoManager? { forwarding }

        func claim() { if active, window != nil, !isFirstResponder { becomeFirstResponder() } }
        override func didMoveToWindow() { super.didMoveToWindow(); DispatchQueue.main.async { self.claim() } }

        override var keyCommands: [UIKeyCommand]? {
            let undo = UIKeyCommand(title: "Undo", action: #selector(undoKey), input: "z", modifierFlags: .command)
            let redo = UIKeyCommand(title: "Redo", action: #selector(redoKey), input: "z", modifierFlags: [.command, .shift])
            for c in [undo, redo] { c.wantsPriorityOverSystemBehavior = true }
            return [undo, redo]
        }
        @objc private func undoKey() { forwarding.undo() }
        @objc private func redoKey() { forwarding.redo() }
    }

    /// An UndoManager in name only: no registrations, it asks the drawing.
    final class ForwardingUndoManager: UndoManager {
        weak var drawing: DrawingViewModel?
        override var canUndo: Bool { MainActor.assumeIsolated { drawing?.canUndo ?? false } }
        override var canRedo: Bool { MainActor.assumeIsolated { drawing?.canRedo ?? false } }
        override func undo() { MainActor.assumeIsolated { drawing?.undo() } }
        override func redo() { MainActor.assumeIsolated { drawing?.redo() } }
    }
}
