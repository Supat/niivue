//
//  ViewerViewModel.swift — what the viewer shows: plane, slice positions, window, 3D
//  settings. Lives outside ViewerView's @State so scrubbing and windowing invalidate only
//  the small views that read them, not the toolbar tree.
//

import Foundation
import Observation

@Observable @MainActor final class ViewerViewModel {
    let volume: NiftiVolume
    let fileURL: URL?
    let segmentation: SegmentationViewModel
    let bodyComposition = BodyCompositionViewModel()
    let profile: ProfileViewModel
    /// Where this scan's settings and maps persist; nil for a document without a file URL.
    let sidecar: SidecarStore?
    /// What the open-time restore is doing right now (shown as a banner), nil when done.
    private(set) var openingStage: String?
    private(set) var sidecarSavedAt: Date?
    private(set) var sidecarMapsSaved = false
    @ObservationIgnored private var sidecarSaveTask: Task<Void, Never>?

    // Opens in 3D. Launch argument `-plane Axial` (etc.) picks another view, for simulator checks.
    var plane = Plane(rawValue: UserDefaults.standard.string(forKey: "plane") ?? "") ?? .render
    var slices: [Int]
    var multiZoom: CGFloat = 1        // zoom shared by the multiplanar slice panes
    var multiZoomAnimated = false     // whether the last change came from an animated (double-tap) zoom
    var lo: Float
    var hi: Float
    // Remembered across documents and launches.
    var mirrored = UserDefaults.standard.bool(forKey: "mirrored") {
        didSet { UserDefaults.standard.set(mirrored, forKey: "mirrored") }
    }
    var renderMode = RenderMode(rawValue: UserDefaults.standard.string(forKey: "renderMode") ?? "") ?? .volume {
        didSet { UserDefaults.standard.set(renderMode.rawValue, forKey: "renderMode") }
    }
    // Up to ClipSetting.maxCount clip planes. `-clip Axial,Sagittal` and `-clipTilt 30` preset them for checks.
    var clips: [ClipSetting] = (UserDefaults.standard.string(forKey: "clip") ?? "").split(separator: ",")
        .compactMap { ClipSetting.Plane(rawValue: String($0)) }.prefix(ClipSetting.maxCount)
        .map { ClipSetting(plane: $0, tilt: SIMD2(UserDefaults.standard.float(forKey: "clipTilt"), 0)) }
    /// Remove only the corner between the planes instead of everything beyond each one.
    var clipCutaway = UserDefaults.standard.bool(forKey: "clipCutaway") // `-clipCutaway YES` for checks
    /// Draw each clip plane as a tinted, outlined sheet so its position is visible.
    var clipHighlight = UserDefaults.standard.bool(forKey: "clipHighlight") // `-clipHighlight YES` for checks
    /// Camera clip: discard everything nearer than this fraction of the way from the eye to
    /// the orbit pivot, so zooming into the volume shows its inside instead of the tissue
    /// pressed against the lens.
    var cameraClip = false
    var cameraClipDepth: Float = 0.5
    /// Side-by-side: a slice next to its paired profile photo. Only shown in landscape, for a
    /// slice plane whose photo exists; the request itself is remembered across those.
    var sideBySide = UserDefaults.standard.bool(forKey: "sideBySide") // `-sideBySide YES` for checks
    var landscape = false // the window is wider than tall (set by ViewerView)
    var pairedProfileView: ProfileView? { plane.axis.map { ProfileView.paired(axis: $0, mirrored: mirrored) } }
    var canSideBySide: Bool { landscape && pairedProfileView.flatMap { profile.photos[$0] } != nil }
    var showsSideBySide: Bool { sideBySide && canSideBySide }
    /// Where the slice image currently is in its pane (zoom and pan included); the photo follows it.
    var sliceViewport = CGRect.zero
    /// 3D and Multi: the subject's face (from the Coronal Front photo) in the corner of the render.
    var showProfile = UserDefaults.standard.bool(forKey: "showProfile") // `-showProfile YES` for checks
    var showsProfile: Bool { showProfile && profile.faceCutout != nil }
    /// Marker dropped by a tap on the photo, as fractions of the displayed slice (x right,
    /// y down; outside 0...1 where the photo reaches past the slice). Drawn in both panes.
    var photoMarker: CGPoint?
    private(set) var scanLandmarks: ScanLandmarks?
    // 3D camera preset request: RenderView applies `preset` whenever `presetTick` changes.
    var preset: ViewPreset?
    var presetTick = 0

    init(volume: NiftiVolume, fileURL: URL?) {
        self.volume = volume
        self.fileURL = fileURL
        segmentation = SegmentationViewModel(volume: volume, role: fileURL.map(ImageRole.inferred) ?? .other)
        sidecar = fileURL.map(SidecarStore.init)
        profile = ProfileViewModel(sidecar: sidecar)
        slices = (0..<3).map { volume.count(axis: $0) / 2 }
        lo = volume.displayMin
        hi = volume.displayMax
        bodyComposition.fromFile = volume.subject.merging(fileURL.map(Self.jsonSubject) ?? SubjectInfo())
    }

    /// Subject values from a BIDS JSON beside the scan (`<scan>.json`, as dcm2niix writes).
    private static func jsonSubject(for fileURL: URL) -> SubjectInfo {
        let json = fileURL.deletingLastPathComponent().appendingPathComponent(SegmentationPipeline.tags(of: fileURL)[0] + ".json")
        return (try? String(contentsOf: json, encoding: .utf8)).map(SubjectInfo.init(text:)) ?? SubjectInfo()
    }

    // MARK: Sidecar

    /// Everything the sidecar records (maps and companions are written separately).
    var sidecarSettings: SidecarSettings {
        SidecarSettings(
            role: segmentation.role,
            viewer: .init(plane: plane.rawValue, slices: slices, lo: lo, hi: hi, mirrored: mirrored, renderMode: renderMode.rawValue,
                          clips: clips.map { .init(plane: $0.plane.rawValue, pos: $0.pos, flip: $0.flip, tilt: [$0.tilt.x, $0.tilt.y], enabled: $0.enabled) },
                          clipCutaway: clipCutaway, clipHighlight: clipHighlight,
                          cameraClip: cameraClip, cameraClipDepth: cameraClipDepth),
            segmentation: .init(visible: segmentation.visible, opacity: segmentation.opacity, ghost: segmentation.ghost,
                                shownName: segmentation.map?.name, keptName: segmentation.kept?.name),
            water: segmentation.waterURL.flatMap(SidecarSettings.Companion.init),
            fat: segmentation.fatURL.flatMap(SidecarSettings.Companion.init),
            body: .init(weightKg: bodyComposition.weightKg, missing: bodyComposition.missing.map(\.rawValue).sorted(),
                        thighsMissingPercent: bodyComposition.thighsMissingPercent,
                        heightCm: bodyComposition.heightCm, ageYears: bodyComposition.ageYears,
                        subjectID: bodyComposition.subjectID))
    }

    private func apply(_ s: SidecarSettings) {
        segmentation.role = s.role
        plane = Plane(rawValue: s.viewer.plane) ?? plane
        if s.viewer.slices.count == 3 { slices = zip(s.viewer.slices, dims).map { max(0, min($1 - 1, $0)) } }
        (lo, hi) = (s.viewer.lo, s.viewer.hi)
        mirrored = s.viewer.mirrored
        renderMode = RenderMode(rawValue: s.viewer.renderMode) ?? renderMode
        clips = s.viewer.clips.prefix(ClipSetting.maxCount).compactMap { c in
            ClipSetting.Plane(rawValue: c.plane).map { ClipSetting(plane: $0, pos: c.pos, flip: c.flip, enabled: c.enabled ?? true, tilt: SIMD2(c.tilt.first ?? 0, c.tilt.last ?? 0)) }
        }
        clipCutaway = s.viewer.clipCutaway
        clipHighlight = s.viewer.clipHighlight
        cameraClip = s.viewer.cameraClip ?? false
        cameraClipDepth = s.viewer.cameraClipDepth ?? 0.5
        segmentation.opacity = s.segmentation.opacity
        segmentation.ghost = s.segmentation.ghost
        bodyComposition.weightKg = s.body.weightKg
        bodyComposition.heightCm = s.body.heightCm ?? bodyComposition.heightCm
        bodyComposition.ageYears = s.body.ageYears ?? bodyComposition.ageYears
        bodyComposition.subjectID = s.body.subjectID ?? ""
        bodyComposition.missing = Set(s.body.missing.compactMap(BodySegment.init))
        bodyComposition.thighsMissingPercent = s.body.thighsMissingPercent
    }

    /// On open: settings, maps and companion images from the sidecar if there is one; else
    /// whatever lies beside the scan. Returns true when a sidecar was used.
    func restoreFromSidecar() async -> Bool {
        guard let sidecar, let s = sidecar.loadSettings() else { return false }
        openingStage = "Restoring settings…"
        defer { openingStage = nil }
        apply(s)
        await profile.restore()
        let volume = volume
        if s.segmentation.shownName != nil {
            openingStage = "Loading saved segmentation…"
            let maps = await Task.detached(priority: .userInitiated) { () -> (SegmentationMap?, SegmentationMap?) in
                (s.segmentation.shownName.flatMap { sidecar.loadMap(slot: "shown", name: $0, volume: volume) },
                 s.segmentation.keptName.flatMap { sidecar.loadMap(slot: "kept", name: $0, volume: volume) })
            }.value
            segmentation.restore(shown: maps.0, kept: maps.1, visible: s.segmentation.visible)
            sidecarMapsSaved = maps.0 != nil
        }
        for (which, companion) in [(ImageRole.water, s.water), (.fat, s.fat)] {
            guard let companion, let url = companion.resolve() else { continue }
            openingStage = "Loading \(which.rawValue.lowercased()) image…"
            await segmentation.loadCompanion(which, from: url, scoped: true, quiet: true)
        }
        sidecarSavedAt = (try? sidecar.settingsURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return true
    }

    /// Companions and a tissue map lying beside the scan, with the banner up meanwhile.
    func discoverSiblings() async {
        guard let fileURL else { return }
        openingStage = "Looking beside the scan…"
        defer { openingStage = nil }
        await segmentation.discoverSiblings(of: fileURL)
    }

    /// Write the settings a moment after the last change (coalesces slider drags).
    func scheduleSidecarSave() {
        guard let sidecar else { return }
        sidecarSaveTask?.cancel()
        sidecarSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            let settings = sidecarSettings
            await Task.detached { try? sidecar.save(settings) }.value
            sidecarSavedAt = .now
        }
    }

    /// Write the current maps (after a generation, load, swap or removal) in the background.
    func saveSidecarMaps() {
        guard let sidecar else { return }
        let shown = segmentation.map, kept = segmentation.kept, voxel = volume.voxelSize
        sidecarMapsSaved = false
        Task { [weak self] in
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try sidecar.saveMap(shown, slot: "shown", voxelSize: voxel)
                    try sidecar.saveMap(kept, slot: "kept", voxelSize: voxel)
                    return true
                } catch { return false }
            }.value
            self?.sidecarMapsSaved = ok
            self?.scheduleSidecarSave() // the names in settings.json must match the files
        }
    }

    /// The scan's landmarks for aligning profile photos; redone when the segmentation changes.
    func updateScanLandmarks() async {
        let volume = volume, maps = [segmentation.map, segmentation.kept].compactMap { $0 }
        scanLandmarks = await Task.detached(priority: .utility) { ProfileAlignment.scanLandmarks(volume: volume, maps: maps) }.value
    }

    func deleteSidecar() {
        sidecarSaveTask?.cancel()
        sidecar?.delete()
        sidecarSavedAt = nil
        sidecarMapsSaved = false
        profile.clear()
    }

    var dims: [Int] { [volume.dims.0, volume.dims.1, volume.dims.2] }

    func resetWindow() { (lo, hi) = (volume.displayMin, volume.displayMax) }

    func stepSlice(axis: Int, by delta: Int) {
        slices[axis] = max(0, min(volume.count(axis: axis) - 1, slices[axis] + delta))
    }

    func applyPreset(_ p: ViewPreset) { preset = p; presetTick += 1 }

    /// Crosshair position as fractions of the volume along x, y, z (the current slices).
    var crosshairFractions: SIMD3<Float> {
        SIMD3((0..<3).map { (Float(slices[$0]) + 0.5) / Float(dims[$0]) })
    }

    /// Which volume axes run along a slice's columns and rows (rows go superior/anterior
    /// → inferior/posterior, i.e. the row axis is flipped); see NiftiVolume.slice.
    func sliceAxes(_ axis: Int) -> (col: Int, row: Int) { (axis == 0 ? 1 : 0, axis == 2 ? 1 : 2) }

    /// Crosshair in a slice pane as fractions of the displayed image (x right, y down).
    func crosshair(in axis: Int) -> CGPoint {
        let (c, r) = sliceAxes(axis)
        let u = (CGFloat(slices[c]) + 0.5) / CGFloat(dims[c])
        let v = 1 - (CGFloat(slices[r]) + 0.5) / CGFloat(dims[r])
        return CGPoint(x: mirrored ? 1 - u : u, y: v)
    }

    /// Tap in a slice pane at image fractions `p`: move the other two slices to that voxel.
    func locate(_ p: CGPoint, in axis: Int) {
        let (c, r) = sliceAxes(axis)
        let u = mirrored ? 1 - p.x : p.x
        slices[c] = max(0, min(dims[c] - 1, Int(u * CGFloat(dims[c]))))
        slices[r] = max(0, min(dims[r] - 1, Int((1 - p.y) * CGFloat(dims[r]))))
    }

    /// One scale for the multiplanar panes: the envelope of the three slice extents (mm).
    var sliceEnvelope: CGSize {
        let e = (0..<3).map(volume.sliceExtent)
        return CGSize(width: CGFloat(e.map(\.0).max()!), height: CGFloat(e.map(\.1).max()!))
    }

    // MARK: Clip planes

    func addClip() {
        guard clips.count < ClipSetting.maxCount else { return }
        // Start with an orientation that isn't in use yet.
        let unused = ClipSetting.Plane.allCases.first { p in !clips.contains { $0.plane == p } }
        clips.append(ClipSetting(plane: unused ?? .sagittal))
    }

    func removeClip(id: UUID) { clips.removeAll { $0.id == id } }
}
