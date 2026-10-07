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
    /// A segmentation, or the noise mask (one fixed "Noise" label; what it marks is removed
    /// from the scan's display).
    enum Purpose { case segmentation, noise, banding }
    let purpose: Purpose
    /// Drawn in place; starts as the existing drawing's voxels (shared until the first stroke,
    /// so Cancel leaves that map untouched).
    let grid: LabelGrid
    private let mapID = UUID()

    var labels: [CustomLabel]
    /// The labels as the editor opened, to tell a rename or recolour from no change.
    private let openingLabels: [CustomLabel]
    var labelsChanged: Bool { labels != openingLabels }
    /// Anything to keep: voxels drawn, or labels renamed, recoloured or added.
    var hasChanges: Bool { edited || labelsChanged }
    var active: Int
    var tool = Tool.brush
    var brushMM: Float = 3 // diameter, mm
    var drawsWithFinger = UserDefaults.standard.bool(forKey: "drawWithFinger") {
        didSet { UserDefaults.standard.set(drawsWithFinger, forKey: "drawWithFinger") }
    }
    /// The drawing pane's plane and the reference pane's (swappable).
    var mainAxis: Int
    var refAxis: Int
    var hideScan = false
    /// 3D pane: fade unlabelled tissue so the labels show through it.
    var showThrough = UserDefaults.standard.bool(forKey: "segGhost")
    /// Which image the slice panes show: the opened scan or a loaded companion (water, fat,
    /// in-phase, opposed-phase), each with its own black/white levels.
    enum DisplayImage: Hashable { case scan, water, fat, phase(PhaseImage) }
    var display = DisplayImage.scan
    var levels: [DisplayImage: SIMD2<Float>] = [:]

    /// The crosshair at the current slices, in all three panes.
    var crosshair = true
    /// All panes, 3D included: the paint (hidden to see the tissue under it; strokes still land).
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

    init(volume: NiftiVolume, existing: SegmentationMap?, labels: [CustomLabel], mainAxis: Int,
         purpose: Purpose = .segmentation, existingGrid: LabelVolume? = nil) {
        self.volume = volume
        self.purpose = purpose
        let empty = LabelVolume(dims: volume.dims, data: [UInt8](repeating: 0, count: volume.voxelCount), maxLabel: 0)
        let seed = existingGrid ?? existing?.labels
        grid = LabelGrid(seed.flatMap { $0.dims == volume.dims ? $0 : nil } ?? empty)
        let start = purpose == .noise ? [Self.noiseLabel] : purpose == .banding ? [Self.bandLabel]
            : existing != nil && !labels.isEmpty ? labels : [Self.newLabel(id: 1)]
        self.labels = start
        openingLabels = start
        active = start[0].id
        self.mainAxis = mainAxis
        refAxis = mainAxis == 2 ? 1 : 2
    }

    static let noiseLabel = CustomLabel(id: 1, name: "Noise", color: [1, 0.25, 0.85])
    static let bandLabel = CustomLabel(id: 1, name: "Band", color: [1, 0.6, 0.1])

    /// The noise mask as drawn, nil when nothing was changed.
    var editedGrid: LabelVolume? {
        flush()
        return edited ? LabelVolume(dims: grid.dims, data: grid.data, maxLabel: 1) : nil
    }

    private static func newLabel(id: Int) -> CustomLabel {
        let c = LabelTable.generic.color(id)
        return CustomLabel(id: id, name: "Label \(id)", color: [c.x, c.y, c.z])
    }

    var activeLabel: CustomLabel? { labels.first { $0.id == active } }

    func overlay(opacity: Float, in3D: Bool = false) -> SegmentationOverlay {
        var lut = [SIMD4<UInt8>](repeating: .zero, count: 256)
        for l in labels where l.color.count == 3 && l.hidden != true {
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
        let locked = lockedTable
        switch phase {
        case .began:
            guard !isSmoothing else { return } // the smoother is reading the grid
            if tool != .eraser, activeIsLocked {
                show(note: "\(activeLabel?.name ?? "This label") is locked. Unlock it in the label list to edit it.")
                return
            }
            let before = LabelPainter.read(grid, box: plane.box)
            if tool == .fill {
                guard let rows = LabelPainter.fill(grid, plane: plane, at: Int(pt.x.rounded(.down)), Int(pt.y.rounded(.down)), value: value, locked: locked) else { return }
                commit(plane: plane, before: before, rows: rows)
            } else {
                stroke = (plane, pt, before)
                if let rows = LabelPainter.stamp(grid, plane: plane, at: pt, radius: radius(plane), value: value, locked: locked) { touched(plane, rows) }
            }
        case .moved:
            guard let s = stroke, s.plane == plane else { return }
            if let rows = LabelPainter.line(grid, plane: plane, from: s.last, to: pt, radius: radius(plane), value: value, locked: locked) { touched(plane, rows) }
            stroke?.last = pt
        case .ended:
            guard let s = stroke else { return }
            stroke = nil
            if s.plane == plane, let rows = LabelPainter.line(grid, plane: plane, from: s.last, to: pt, radius: radius(plane), value: value, locked: locked) { touched(plane, rows) }
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

    /// Labels already smoothed remember the bricks whose voxels of theirs changed in `box`
    /// (`before` → its contents now), so the next smoothing only redoes those.
    private func noteEdit(_ box: VoxelBox, before: [UInt8]) {
        let changes = LabelPainter.changedBricks(before: before, after: LabelPainter.read(grid, box: box), box: box, dims: grid.dims)
        for i in labels.indices where labels[i].smoothed == true {
            guard let bricks = changes[labels[i].id] else { continue }
            labels[i].unsmoothedBricks = Array(bricks.union(labels[i].unsmoothedBricks ?? [])).sorted()
        }
    }

    private func commit(plane: SlicePlane, before: [UInt8], rows: ClosedRange<Int>?) {
        if let rows { touched(plane, rows) }
        noteEdit(plane.box, before: before)
        repairBanding(plane.box, before: before)
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
        let current = LabelPainter.read(grid, box: step.box)
        LabelPainter.write(grid, box: step.box, step.values)
        repairBanding(step.box, before: current)
        markDirty(step.box.z)
        flush()
    }

    private func swapSlice(from: inout [(box: VoxelBox, values: [UInt8])], to: inout [(box: VoxelBox, values: [UInt8])]) {
        guard !isSmoothing, let step = from.popLast() else { return }
        let current = LabelPainter.read(grid, box: step.box)
        to.append((step.box, current))
        LabelPainter.write(grid, box: step.box, step.values)
        edited = true
        noteEdit(step.box, before: current)
        repairBanding(step.box, before: current)
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

    /// A passing message for the editor (why a smoothing or stroke did nothing); nil otherwise.
    private(set) var note: String?

    private func show(note text: String) {
        note = text
        Task { try? await Task.sleep(for: .seconds(4)); if note == text { note = nil } }
    }

    /// Per label value: locked (256 entries).
    private var lockedTable: [Bool] {
        var t = LabelPainter.unlocked
        for l in labels where l.locked == true { t[l.id] = true }
        return t
    }

    var activeIsLocked: Bool { activeLabel?.locked == true }
    var activeIsHidden: Bool { activeLabel?.hidden == true }

    /// Smooths the surface of the label being edited in 3D (see LabelPainter.smoothed), as
    /// one undo step; other labels stay as they are. Once a label has been smoothed, only
    /// what was edited since is smoothed again (else repeated passes erode it); `whole`
    /// smooths all of it regardless.
    /// Runs in the background on a snapshot; drawing waits until it's done.
    func smooth(_ strength: Smoothing, whole: Bool = false) async {
        guard !isSmoothing, let i = labels.firstIndex(where: { $0.id == active }) else { return }
        guard labels[i].locked != true else { show(note: "\(labels[i].name) is locked."); return }
        flush()
        note = nil
        let region: Set<Int>? = whole || labels[i].smoothed != true ? nil : Set(labels[i].unsmoothedBricks ?? [])
        if let region, region.isEmpty {
            show(note: "\(labels[i].name) is already smoothed; nothing edited since. (Hold the wand for Whole Label.)")
            return
        }
        isSmoothing = true
        defer { isSmoothing = false }
        let data = grid.data, dims = grid.dims, ids = [active]
        let size = SIMD3(volume.voxelSize.0, volume.voxelSize.1, volume.voxelSize.2)
        let result = await Task.detached(priority: .userInitiated) {
            LabelPainter.smoothed(data, dims: dims, voxelSize: size, sigmaMM: strength.rawValue, labels: ids, bricks: region)
        }.value
        labels[i].smoothed = true
        labels[i].unsmoothedBricks = nil
        guard let result else { return }
        let before = LabelPainter.read(grid, box: result.box)
        pushUndo(result.box, before)
        LabelPainter.write(grid, box: result.box, result.values)
        repairBanding(result.box, before: before)
        edited = true
        markDirty(result.box.z)
        flush()
    }

    // MARK: Live banding repair

    /// Banding: the scan with the band painted so far repaired, nil before the first stroke;
    /// and the z slices the last repair changed (for the 3D texture).
    private(set) var preview: NiftiVolume?
    private(set) var previewDirtyZ: Range<Int>?
    /// The repair in force when the editor opened: its mask and the original values of the
    /// voxels it replaced (`volume` holds the repaired ones).
    private var previousMask: [UInt8]?
    private var previousOriginals: [Int32: Float] = [:]

    func setPreviousRepair(mask: [UInt8], indices: [Int32], originals: [Float]) {
        previousMask = mask
        previousOriginals = Dictionary(zip(indices, originals), uniquingKeysWith: { a, _ in a })
    }

    /// The scan's own value at `i`, before any repair.
    private func original(_ i: Int, _ current: UnsafeBufferPointer<Float>) -> Float {
        if let m = previousMask, m[i] != 0, let v = previousOriginals[Int32(i)] { return v }
        return current[i]
    }

    /// After a change to the mask in `box` (`before` → now): every column through the changed
    /// voxels is filled in again along z (BandRepair's rule), and voxels no longer painted get
    /// their original values back. Cost follows the columns a stroke touches.
    private func repairBanding(_ box: VoxelBox, before: [UInt8]) {
        guard purpose == .banding,
              let changed = LabelPainter.changedBounds(before: before, after: LabelPainter.read(grid, box: box), box: box) else { return }
        let (nx, ny, nz) = volume.dims, plane = nx * ny
        var v = preview ?? volume // the first stroke copies the scan once
        var zlo = Int.max, zhi = -1, repaired = 0, restored = 0, wholeColumns = 0
        v.data.withUnsafeMutableBufferPointer { d in grid.data.withUnsafeBufferPointer { m in volume.data.withUnsafeBufferPointer { o in
            for y in changed.lo.y..<changed.hi.y { for x in changed.lo.x..<changed.hi.x {
                for z in 0..<nz {
                    let i = x + nx * (y + ny * z)
                    var want = original(i, o)
                    if m[i] != 0 {
                        var below = z - 1, above = z + 1
                        while below >= 0, m[i - (z - below) * plane] != 0 { below -= 1 }
                        while above < nz, m[i + (above - z) * plane] != 0 { above += 1 }
                        let bi = i - (z - below) * plane, ai = i + (above - z) * plane
                        switch (below >= 0, above < nz) {
                        case (true, true):
                            let a = original(bi, o), b = original(ai, o)
                            want = a + (b - a) * Float(z - below) / Float(above - below)
                        case (true, false): want = original(bi, o)
                        case (false, true): want = original(ai, o)
                        case (false, false): wholeColumns += 1 // a whole column painted: left as it is
                        }
                    }
                    if d[i] != want {
                        if m[i] != 0 { repaired += 1 } else { restored += 1 }
                        d[i] = want; zlo = min(zlo, z); zhi = max(zhi, z)
                    }
                }
            } }
        } } }
        // Say what happened, so a stroke that changes nothing doesn't look like a broken tool.
        if repaired > 0 || restored > 0 {
            show(note: (repaired > 0 ? "Repaired \(repaired.formatted()) voxels" : "") + (repaired > 0 && restored > 0 ? ", " : "")
                 + (restored > 0 ? "restored \(restored.formatted())" : "") + " on slices \(zlo + 1)–\(zhi + 1)")
        } else if wholeColumns > 0 {
            show(note: "Nothing to fill in from: the paint covers whole columns from top to bottom.")
        } else {
            show(note: "Nothing changed: the painted voxels already match the slices above and below.")
        }
        guard zhi >= 0 else { return }
        v.id = UUID()
        previewDirtyZ = zlo..<(zhi + 1)
        preview = v
    }

    /// Done in banding mode: the repaired scan, and for every voxel it changed its original
    /// value (for editing again or undoing); nil when nothing was painted this time.
    func bandingResult() -> (volume: NiftiVolume, mask: LabelVolume, indices: [Int32], originals: [Float])? {
        flush()
        guard edited, let preview else { return nil }
        let (nx, ny, nz) = volume.dims, plane = nx * ny
        var indices: [Int32] = [], originals: [Float] = []
        let zeros = [UInt8](repeating: 0, count: plane)
        grid.data.withUnsafeBufferPointer { m in preview.data.withUnsafeBufferPointer { p in volume.data.withUnsafeBufferPointer { o in zeros.withUnsafeBufferPointer { zr in
            for z in 0..<nz {
                guard memcmp(m.baseAddress! + z * plane, zr.baseAddress!, plane) != 0 else { continue }
                for i in (z * plane)..<((z + 1) * plane) where m[i] != 0 {
                    let orig = original(i, o)
                    if p[i] != orig { indices.append(Int32(i)); originals.append(orig) }
                }
            }
        } } } }
        _ = (nx, ny)
        return (preview, LabelVolume(dims: grid.dims, data: grid.data, maxLabel: 1), indices, originals)
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
