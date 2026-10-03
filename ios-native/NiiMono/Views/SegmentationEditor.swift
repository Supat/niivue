//
//  SegmentationEditor.swift — draw a segmentation by hand: the drawing slice on the right,
//  a reference slice (swappable) and the 3D render of the labels on the left, tools below.
//

import SwiftUI

struct SegmentationEditor: View {
    let model: ViewerViewModel
    @Bindable var drawing: DrawingViewModel
    @State private var confirmDiscard = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var finishing = false

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
        .alert("Rename Label", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let i = drawing.labels.firstIndex(where: { $0.id == drawing.active }), !newName.isEmpty { drawing.labels[i].name = newName }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A plain bar, not a navigation bar: inside the document's window a NavigationStack
    /// picks up the document's own back button (which would close it) and title menu.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Cancel") { if drawing.edited { confirmDiscard = true } else { model.drawing = nil } }
                .confirmationDialog("Discard the drawing?", isPresented: $confirmDiscard) {
                    Button("Discard Changes", role: .destructive) { model.drawing = nil }
                }
            Spacer()
            Text("Draw Segmentation").font(.headline)
            Spacer()
            HStack(spacing: 4) {
                Button("Undo", systemImage: "arrow.uturn.backward") { drawing.undo() }
                    .disabled(!drawing.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo", systemImage: "arrow.uturn.forward") { drawing.redo() }
                    .disabled(!drawing.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
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

    private var overlay: SegmentationOverlay { drawing.overlay(opacity: model.segmentation.opacity) }

    private var main: some View {
        let axis = drawing.mainAxis
        return SliceView(volume: model.volume, axis: axis, index: model.slices[axis], lo: model.lo, hi: model.hi,
                         mirrored: model.mirrored, overlay: overlay,
                         crosshair: model.showCrosshair ? model.crosshair(in: axis) : nil,
                         onDraw: { phase, p in drawing.handle(phase, p, index: model.slices[axis], mirrored: model.mirrored) },
                         drawsWithFinger: drawing.drawsWithFinger,
                         onTwoFingerTap: { drawing.tapUndo() },
                         onThreeFingerTap: { drawing.tapRedo() },
                         scaleBarInset: 120,
                         onTap: {}) { model.stepSlice(axis: axis, by: $0) }
            .overlay(alignment: .topLeading) { paneTitle(axis) }
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
                         mirrored: model.mirrored, overlay: overlay,
                         crosshair: model.crosshair(in: axis),
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
                   overlay: drawing.overlay(opacity: model.segmentation.opacity, in3D: true),
                   preset: nil, presetTick: 0, onTap: {})
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Toggle("Crosshair", systemImage: "plus.viewfinder", isOn: $drawing.crosshair3D)
                    // Fades unlabelled tissue; moot once the scan is hidden altogether.
                    Toggle("Show Through Tissue", systemImage: "cube.transparent", isOn: $drawing.showThrough)
                        .disabled(drawing.hideScan)
                    Toggle("Show Scan", systemImage: drawing.hideScan ? "eye.slash" : "eye",
                           isOn: Binding(get: { !drawing.hideScan }, set: { drawing.hideScan = !$0 }))
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .padding(8)
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
            Menu {
                Picker("Label", selection: $drawing.active) {
                    ForEach(drawing.labels) { l in
                        Label { Text(l.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(color(l)) }.tag(l.id)
                    }
                }
                Divider()
                Button("New Label", systemImage: "plus") { drawing.addLabel() }
                Button("Rename…", systemImage: "pencil") { newName = drawing.activeLabel?.name ?? ""; renaming = true }
                Button("Delete Label", systemImage: "trash", role: .destructive) { drawing.deleteLabel(drawing.active) }
                    .disabled(drawing.labels.count < 2)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(drawing.activeLabel.map(color) ?? .clear).frame(width: 14, height: 14)
                    Text(drawing.activeLabel?.name ?? "").lineLimit(1)
                }
                .frame(maxWidth: 160, alignment: .leading)
            }
            ColorPicker("Colour", selection: activeColor, supportsOpacity: false).labelsHidden()
            Picker("Tool", selection: $drawing.tool) {
                ForEach(DrawingViewModel.Tool.allCases) { Image(systemName: $0.symbol).accessibilityLabel($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
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
