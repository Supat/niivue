//
//  DrawingViewModel.swift — the segmentation editor's state: the label grid being drawn, the
//  labels, the tool, undo, and the throttled revisions the views and the 3D render follow.
//

import Foundation
import Observation

@Observable @MainActor
final class DrawingViewModel: Identifiable {
    enum Tool: String, CaseIterable, Identifiable {
        case brush = "Brush", eraser = "Eraser", fill = "Fill"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .brush: return "paintbrush.pointed"
            case .eraser: return "eraser"
            case .fill: return "drop"
            }
        }
    }

    let id = UUID()
    let volume: NiftiVolume
    /// Drawn in place; starts as the existing drawing's voxels (shared until the first stroke,
    /// so Cancel leaves that map untouched).
    let grid: LabelGrid
    private let mapID = UUID()

    var labels: [CustomLabel]
    var active: Int
    var tool = Tool.brush
    var brushMM: Float = 6 // diameter
    var drawsWithFinger = UserDefaults.standard.bool(forKey: "drawWithFinger") {
        didSet { UserDefaults.standard.set(drawsWithFinger, forKey: "drawWithFinger") }
    }
    /// The drawing pane's plane and the reference pane's (swappable).
    var mainAxis: Int
    var refAxis: Int
    var hideScan = false
    /// 3D pane: fade unlabelled tissue so the labels show through it.
    var showThrough = UserDefaults.standard.bool(forKey: "segGhost")
    /// 3D pane: the crosshair at the current slices.
    var crosshair3D = true
    /// Slice panes: the crosshair, and the paint (hidden to see the tissue under it; strokes
    /// still land).
    var crosshair2D = true
    var hidePaint = false
    private(set) var edited = false

    // Revisions: strokes change `grid` at once but are published at most ~30 times a second.
    private(set) var revision = 0
    private var dirtyZ: Range<Int>?
    private var pendingZ: Range<Int>?
    private var pendingAll = false
    private var flushTask: Task<Void, Never>?

    private var stroke: (plane: SlicePlane, last: SIMD2<Float>, before: [UInt8])?
    private var undoStack: [(box: VoxelBox, values: [UInt8])] = []
    private var lastCommit = Date.distantPast
    private var redoStack: [(box: VoxelBox, values: [UInt8])] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private static let undoLimit = 50

    init(volume: NiftiVolume, existing: SegmentationMap?, labels: [CustomLabel], mainAxis: Int) {
        self.volume = volume
        let empty = LabelVolume(dims: volume.dims, data: [UInt8](repeating: 0, count: volume.voxelCount), maxLabel: 0)
        grid = LabelGrid(existing.flatMap { $0.labels.dims == volume.dims ? $0.labels : nil } ?? empty)
        let start = existing != nil && !labels.isEmpty ? labels : [Self.newLabel(id: 1)]
        self.labels = start
        active = start[0].id
        self.mainAxis = mainAxis
        refAxis = mainAxis == 2 ? 1 : 2
    }

    private static func newLabel(id: Int) -> CustomLabel {
        let c = LabelTable.generic.color(id)
        return CustomLabel(id: id, name: "Label \(id)", color: [c.x, c.y, c.z])
    }

    var activeLabel: CustomLabel? { labels.first { $0.id == active } }

    func overlay(opacity: Float, in3D: Bool = false) -> SegmentationOverlay {
        var lut = [SIMD4<UInt8>](repeating: .zero, count: 256)
        for l in labels where l.color.count == 3 {
            lut[l.id] = SIMD4(UInt8(l.color[0] * 255), UInt8(l.color[1] * 255), UInt8(l.color[2] * 255), 255)
        }
        return SegmentationOverlay(mapID: mapID, labels: grid, lut: lut, opacity: opacity, ghost: in3D && showThrough,
                                   hideScan: hideScan, revision: revision, dirtyZ: dirtyZ)
    }

    // MARK: Labels

    func addLabel() {
        guard let id = (1...255).first(where: { id in !labels.contains { $0.id == id } }) else { return }
        labels.append(Self.newLabel(id: id))
        active = id
    }

    /// Removes the label and erases its voxels everywhere (not undoable: clears the history).
    func deleteLabel(_ id: Int) {
        guard labels.count > 1 else { return }
        labels.removeAll { $0.id == id }
        if active == id { active = labels[0].id }
        let value = UInt8(id)
        grid.data.withUnsafeMutableBufferPointer { d in for i in d.indices where d[i] == value { d[i] = 0 } }
        undoStack = []; redoStack = []
        edited = true
        markDirty(nil)
    }

    // MARK: Drawing

    /// A Pencil (or finger) event on the drawing pane: `p` in displayed-image fractions.
    func handle(_ phase: DrawPhase, _ p: CGPoint, index: Int, mirrored: Bool) {
        let plane = SlicePlane(axis: mainAxis, index: index, dims: volume.dims)
        let u = mirrored ? 1 - p.x : p.x
        let pt = SIMD2(Float(u) * Float(plane.width), Float(1 - p.y) * Float(plane.height))
        let value = tool == .eraser ? 0 : UInt8(active)
        switch phase {
        case .began:
            guard !isSmoothing else { return } // the smoother is reading the grid
            let before = LabelPainter.read(grid, box: plane.box)
            if tool == .fill {
                guard let rows = LabelPainter.fill(grid, plane: plane, at: Int(pt.x.rounded(.down)), Int(pt.y.rounded(.down)), value: value) else { return }
                commit(plane: plane, before: before, rows: rows)
            } else {
                stroke = (plane, pt, before)
                if let rows = LabelPainter.stamp(grid, plane: plane, at: pt, radius: radius(plane), value: value) { touched(plane, rows) }
            }
        case .moved:
            guard let s = stroke, s.plane == plane else { return }
            if let rows = LabelPainter.line(grid, plane: plane, from: s.last, to: pt, radius: radius(plane), value: value) { touched(plane, rows) }
            stroke?.last = pt
        case .ended:
            guard let s = stroke else { return }
            stroke = nil
            if s.plane == plane, let rows = LabelPainter.line(grid, plane: plane, from: s.last, to: pt, radius: radius(plane), value: value) { touched(plane, rows) }
            commit(plane: s.plane, before: s.before, rows: nil)
        }
    }

    /// Brush radius in voxels along the plane's columns and rows (voxels may be anisotropic).
    private func radius(_ plane: SlicePlane) -> SIMD2<Float> {
        let size = [volume.voxelSize.0, volume.voxelSize.1, volume.voxelSize.2]
        return SIMD2(brushMM / 2 / size[plane.col], brushMM / 2 / size[plane.row])
    }

    private func touched(_ plane: SlicePlane, _ rows: ClosedRange<Int>) {
        edited = true
        markDirty(plane.z(rows: rows))
    }

    private func commit(plane: SlicePlane, before: [UInt8], rows: ClosedRange<Int>?) {
        if let rows { touched(plane, rows) }
        pushUndo(plane.box, before)
        lastCommit = .now // a finger-tap undo may still drop this stroke (see tapUndo)
        flush()
    }

    private func pushUndo(_ box: VoxelBox, _ before: [UInt8]) {
        undoStack.append((box, before))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack = []
    }

    func undo() { swapSlice(from: &undoStack, to: &redoStack) }
    func redo() { swapSlice(from: &redoStack, to: &undoStack) }

    /// Undo / redo from a multi-finger tap. Drawing with a finger, the tap's first finger has
    /// already left a dot (a stroke ended a moment ago): that is dropped without a trace first.
    func tapUndo() { discardTapStroke(); undo() }
    func tapRedo() { discardTapStroke(); redo() }

    private func discardTapStroke() {
        guard drawsWithFinger else { return }
        let step: (box: VoxelBox, values: [UInt8])
        if let s = stroke { // still down: put its slice back and forget it
            stroke = nil
            step = (s.plane.box, s.before)
        } else if Date.now.timeIntervalSince(lastCommit) < 0.5, let last = undoStack.popLast() {
            step = last
            lastCommit = .distantPast
        } else {
            return
        }
        LabelPainter.write(grid, box: step.box, step.values)
        markDirty(step.box.z)
        flush()
    }

    private func swapSlice(from: inout [(box: VoxelBox, values: [UInt8])], to: inout [(box: VoxelBox, values: [UInt8])]) {
        guard !isSmoothing, let step = from.popLast() else { return }
        to.append((step.box, LabelPainter.read(grid, box: step.box)))
        LabelPainter.write(grid, box: step.box, step.values)
        edited = true
        markDirty(step.box.z)
        flush()
    }

    // MARK: Smoothing

    enum Smoothing: Float, CaseIterable, Identifiable {
        case light = 1, medium = 2, strong = 3.5 // σ in mm
        var id: Self { self }
        var name: String { switch self { case .light: "Light"; case .medium: "Medium"; case .strong: "Strong" } }
    }

    private(set) var isSmoothing = false

    /// Smooths every label's surface in 3D (see LabelPainter.smoothed), as one undo step.
    /// Runs in the background on a snapshot; drawing waits until it's done.
    func smooth(_ strength: Smoothing) async {
        guard !isSmoothing else { return }
        flush()
        isSmoothing = true
        defer { isSmoothing = false }
        let data = grid.data, dims = grid.dims, ids = labels.map(\.id)
        let size = SIMD3(volume.voxelSize.0, volume.voxelSize.1, volume.voxelSize.2)
        let result = await Task.detached(priority: .userInitiated) {
            LabelPainter.smoothed(data, dims: dims, voxelSize: size, sigmaMM: strength.rawValue, labels: ids)
        }.value
        guard let result else { return }
        pushUndo(result.box, LabelPainter.read(grid, box: result.box))
        LabelPainter.write(grid, box: result.box, result.values)
        edited = true
        markDirty(result.box.z)
        flush()
    }

    // MARK: Publishing

    /// `z` nil: everything changed.
    private func markDirty(_ z: Range<Int>?) {
        if let z, !pendingAll {
            pendingZ = pendingZ.map { min($0.lowerBound, z.lowerBound)..<max($0.upperBound, z.upperBound) } ?? z
        } else {
            pendingAll = true
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            self?.flush()
        }
    }

    private func flush() {
        flushTask?.cancel(); flushTask = nil
        guard pendingAll || pendingZ != nil else { return }
        dirtyZ = pendingAll ? nil : pendingZ
        pendingZ = nil; pendingAll = false
        revision += 1
    }

    // MARK: Result

    /// The drawing as a map for the viewer, or nil when nothing was drawn. Counting the
    /// voxels is one pass over the volume, so it runs off the main thread.
    func result() async -> SegmentationMap? {
        flush()
        guard edited else { return nil }
        let labels = LabelVolume(dims: grid.dims, data: grid.data, maxLabel: self.labels.map(\.id).max() ?? 0)
        let volume = volume, table = LabelTable.custom(self.labels)
        return await Task.detached(priority: .userInitiated) {
            SegmentationMap(labels: labels, name: LabelTable.customMapName, volume: volume, table: table)
        }.value
    }
}
