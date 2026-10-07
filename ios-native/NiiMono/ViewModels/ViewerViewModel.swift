//
//  ViewerViewModel.swift — what the viewer shows: plane, slice positions, window, 3D
//  settings. Lives outside ViewerView's @State so scrubbing and windowing invalidate only
//  the small views that read them, not the toolbar tree.
//

import Foundation
import Observation

@Observable @MainActor final class ViewerViewModel {
    /// The scan as shown and analysed: the file's, with any banding repair applied (the file
    /// itself is never written).
    private(set) var volume: NiftiVolume
    /// The z slices the last change to `volume` touched, for the 3D view's texture.
    private(set) var volumeDirtyZ: Range<Int>?
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
    /// Set when the sidecar named maps that couldn't be read back: nothing is saved (which
    /// would overwrite or delete them) until the scan is reopened or the user says so.
    private(set) var sidecarProblem: String?
    private var mapSaveTask: Task<Void, Never>?
    /// True while the sidecar is being read back: the state is half restored (settings in,
    /// maps still loading), and a save then would write settings.json without the map names,
    /// which loses the maps on the next opening. Saves wait until it's done.
    private var restoring = false
    private var backedUpDrawing: UUID?

    /// Accept what was restored and save again (the unreadable maps are then given up).
    func resumeSidecarSaving() {
        sidecarProblem = nil
        saveSidecarMaps()
        scheduleSidecarSave()
    }
    @ObservationIgnored private var sidecarSaveTask: Task<Void, Never>?

    // Opens in 3D. Launch argument `-plane Axial` (etc.) picks another view, for simulator checks.
    var plane = Plane(rawValue: UserDefaults.standard.string(forKey: "plane") ?? "") ?? .render
    var slices: [Int]
    /// Saved slice positions, kept in the sidecar.
    var bookmarks: [SliceBookmark] = []
    /// The segmentation editor, while it is open.
    var drawing: DrawingViewModel?

    /// Opens the editor on the drawn map if there is one (else a blank grid), drawing on the
    /// plane in view.
    func startDrawing() {
        drawing = DrawingViewModel(volume: volume, existing: segmentation.customMap,
                                   labels: segmentation.customLabels, mainAxis: plane.axis ?? 2)
    }

    // MARK: Noise removal

    /// A mask of noise drawn by hand: the voxels it marks are blacked out on the slices and
    /// left out of the 3D render. The scan's data is untouched (erasing the mask brings them
    /// back, and the scan isn't held twice).
    struct NoiseMask { let id = UUID(); let labels: LabelVolume }
    private(set) var noise: NoiseMask? { didSet { syncNoise() } }
    /// Apply the mask (off shows the original scan, and generation uses it as is).
    var removeNoise = true { didSet { syncNoise() } }
    private func syncNoise() { segmentation.noise = removeNoise ? noise?.labels.data : nil }

    var noiseCutout: SegmentationOverlay? {
        guard removeNoise, let noise else { return nil }
        return SegmentationOverlay(mapID: noise.id, labels: LabelGrid(noise.labels), lut: [], opacity: 0, ghost: false)
    }

    func startNoiseEditing() {
        drawing = DrawingViewModel(volume: volume, existing: nil, labels: [], mainAxis: plane.axis ?? 2,
                                   purpose: .noise, existingGrid: noise?.labels)
    }

    func clearNoise() { noise = nil; saveNoise() }

    // MARK: Scan repair (banding and blemishes)

    /// The scan repair in force: the painted mask (band / blemish, see ScanRepair), and the
    /// original values of the voxels it replaced (so it can be edited again or undone).
    struct ScanRepairState { let mask: LabelVolume; let indices: [Int32]; let originals: [Float] }
    private(set) var scanRepair: ScanRepairState?
    private(set) var repairing = false

    /// Opens on the slice view in use (coronal from 3D / Multi), with the Blemish paint.
    func startScanRepair() {
        let d = DrawingViewModel(volume: volume, existing: nil, labels: [], mainAxis: plane.axis ?? 1,
                                 purpose: .repair, existingGrid: scanRepair?.mask)
        if let r = scanRepair { d.setPreviousRepair(mask: r.mask.data, indices: r.indices, originals: r.originals) }
        d.repairPaint = "Blemish"
        drawing = d
    }

    /// Puts the original values back, then repairs what `mask` marks (nil: just undo).
    func applyScanRepair(_ mask: LabelVolume?, save: Bool = true) async {
        repairing = true
        defer { repairing = false }
        let current = volume, previous = scanRepair
        let result = await Task.detached(priority: .userInitiated) { () -> (NiftiVolume, ScanRepairState?, Range<Int>?) in
            var v = current
            var zs: [Int] = []
            let plane = v.dims.0 * v.dims.1
            v.data.withUnsafeMutableBufferPointer { d in
                if let previous {
                    for (i, o) in zip(previous.indices, previous.originals) { d[Int(i)] = o; zs.append(Int(i) / plane) }
                }
            }
            guard let mask, !LabelPainter.isEmpty(mask.data) else {
                v.id = UUID()
                return (v, nil, zs.isEmpty ? nil : zs.min()!..<(zs.max()! + 1))
            }
            let r = ScanRepair.repaired(data: v.data, mask: mask.data, dims: v.dims, background: v.dataMin)
            var originals = [Float](); originals.reserveCapacity(r.indices.count)
            v.data.withUnsafeMutableBufferPointer { d in
                for (i, value) in zip(r.indices, r.values) { originals.append(d[Int(i)]); d[Int(i)] = value; zs.append(Int(i) / plane) }
            }
            v.id = UUID()
            return (v, ScanRepairState(mask: mask, indices: r.indices, originals: originals), zs.isEmpty ? nil : zs.min()!..<(zs.max()! + 1))
        }.value
        volumeDirtyZ = result.2
        volume = result.0
        segmentation.volume = result.0
        scanRepair = result.1
        if save { saveScanRepair() }
    }

    private func saveScanRepair() {
        guard let sidecar, sidecarProblem == nil, !restoring else { return }
        let mask = scanRepair?.mask, voxel = volume.voxelSize
        Task { [weak self] in
            await Task.detached(priority: .utility) { try? sidecar.saveLabels(mask, slot: "repair", voxelSize: voxel) }.value
            self?.scheduleSidecarSave()
        }
    }

    /// True while the cleaned scan is written; why it couldn't be, if it couldn't.
    private(set) var cleanExportBusy = false
    private(set) var cleanExportError: String?

    /// The scan with the noise mask applied, as `<scan>_clean.nii.gz` (float32, the scan's own
    /// grid, orientation and header, its embedded metadata kept), in the share sheet.
    func exportCleanedScan() async {
        guard noise != nil || scanRepair != nil else { return }
        cleanExportBusy = true
        cleanExportError = nil
        defer { cleanExportBusy = false }
        let volume = volume, mask = noise?.labels.data // the repair is already in `volume`
        let base = fileURL.map { SegmentationPipeline.tags(of: $0)[0] } ?? "Scan"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
            .appendingPathComponent("\(base)_clean.nii.gz")
        let written = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let data = NIfTI.floatFile(volume, mask: mask, background: volume.dataMin) else { return false }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? data.write(to: url, options: .atomic)) != nil
        }.value
        guard written else { cleanExportError = "Couldn't write the cleaned scan (the scan's header wasn't kept)."; return }
        SnapshotPanes.share(url)
    }

    private func saveNoise() {
        guard let sidecar, sidecarProblem == nil, !restoring else { return }
        let labels = noise?.labels, voxel = volume.voxelSize
        Task { [weak self] in
            await Task.detached(priority: .utility) { try? sidecar.saveLabels(labels, slot: "noise", voxelSize: voxel) }.value
            self?.scheduleSidecarSave()
        }
    }

    /// Import/export of the drawing: true while a file is read or written, and the outcome.
    private(set) var customFileBusy = false
    private(set) var customFileStatus: String?

    /// A label file on this scan's grid becomes the drawing (names from our own exports).
    func importCustomSegmentation(from url: URL) async {
        customFileBusy = true
        defer { customFileBusy = false }
        let volume = volume
        let result = await Task.detached(priority: .userInitiated) {
            Result { try CustomSegmentationFile.read(from: url, scoped: true, volume: volume) }
        }.value
        switch result {
        case .success(let r):
            segmentation.showCustom(r.map, labels: r.labels)
            customFileStatus = "Imported \(url.lastPathComponent): \(r.labels.count) label\(r.labels.count == 1 ? "" : "s")."
        case .failure(let e):
            customFileStatus = "Couldn't import \(url.lastPathComponent): \(e.localizedDescription)"
        }
    }

    /// Adds labels `ids` of the map on screen (a generated or loaded one) to the drawing, with
    /// their names and colours, and opens the editor. A copied label takes the id of a drawn
    /// label with the same name (so copying it again adds to it), else a free id; voxels
    /// already drawn keep their label.
    func copyToDrawing(_ ids: [Int]) async {
        guard let source = segmentation.map, !source.isCustom, !ids.isEmpty else { return }
        customFileBusy = true
        defer { customFileBusy = false }
        let existing = segmentation.customMap
        var labels = existing == nil ? [] : segmentation.customLabels
        var mapping: [Int: Int] = [:], skipped = 0
        for id in ids {
            let name = source.table.name(id)
            if let k = labels.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                mapping[id] = labels[k].id
                labels[k].smoothed = nil // new voxels: smooth it whole next time
            } else if let free = (1...255).first(where: { f in !labels.contains { $0.id == f } }) {
                let c = source.table.color(id)
                labels.append(CustomLabel(id: free, name: name, color: [c.x, c.y, c.z]))
                mapping[id] = free
            } else {
                skipped += 1 // all 255 ids in use
            }
        }
        let volume = volume, grid = source.labels, base = existing?.labels.data, all = labels
        let map = await Task.detached(priority: .userInitiated) {
            let copied = LabelPainter.relabelled(grid.data, dims: grid.dims, mapping: mapping)
            let data = base.map { LabelPainter.fillingUnlabelled($0, from: copied, rowLength: grid.dims.0) } ?? copied
            return SegmentationMap(labels: LabelVolume(dims: grid.dims, data: data, maxLabel: all.map(\.id).max() ?? 0),
                                   name: LabelTable.customMapName, volume: volume, table: .custom(all))
        }.value
        segmentation.showCustom(map, labels: labels)
        let n = ids.count - skipped
        customFileStatus = "Added \(n) label\(n == 1 ? "" : "s") from \(source.name) to the drawing."
            + (skipped > 0 ? " \(skipped) didn't fit (255 labels at most)." : "")
        startDrawing()
    }

    /// Writes the drawing as `<scan>_drawing.nii.gz` (the scan's grid and orientation, label
    /// names in the header) and opens the share sheet.
    func exportCustomSegmentation() async {
        guard let map = segmentation.customMap else { return }
        customFileBusy = true
        defer { customFileBusy = false }
        let volume = volume, labels = segmentation.customLabels
        let base = fileURL.map { SegmentationPipeline.tags(of: $0)[0] } ?? "Segmentation"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
            .appendingPathComponent("\(base)_drawing.nii.gz")
        let written = await Task.detached(priority: .userInitiated) { () -> Bool in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? CustomSegmentationFile.export(map, labels: labels, like: volume).write(to: url, options: .atomic)) != nil
        }.value
        guard written else { customFileStatus = "Couldn't write the export."; return }
        customFileStatus = nil
        SnapshotPanes.share(url)
    }

    /// Closes the editor, showing the drawing if anything was drawn.
    func finishDrawing() async {
        guard let d = drawing else { return }
        if d.purpose == .repair {
            // The editor repaired the scan as the band was painted: keep its result.
            if let r = d.repairResult() {
                volumeDirtyZ = nil
                volume = r.volume
                segmentation.volume = r.volume
                scanRepair = r.indices.isEmpty ? nil : ScanRepairState(mask: r.mask, indices: r.indices, originals: r.originals)
                saveScanRepair()
            }
            drawing = nil
            return
        }
        if d.purpose == .noise {
            if let grid = d.editedGrid {
                noise = LabelPainter.isEmpty(grid.data) ? nil : NoiseMask(labels: grid)
                removeNoise = true
                saveNoise()
            }
            drawing = nil
            return
        }
        if let map = await d.result() {
            segmentation.showCustom(map, labels: d.labels)
        } else if d.labelsChanged, segmentation.customMap != nil {
            segmentation.updateCustomLabels(d.labels) // renamed or recoloured only: no recount
        }
        drawing = nil
    }
    var multiZoom: CGFloat = 1        // zoom shared by the multiplanar slice panes
    var multiZoomAnimated = false     // whether the last change came from an animated (double-tap) zoom
    /// Point of the volume (fractions along x, y, z) the multiplanar panes keep centred, so
    /// panning one pans the others along the axes they share.
    var multiCentre = SIMD3<Double>(repeating: 0.5)
    var lo: Float
    var hi: Float
    // Remembered across documents and launches.
    /// Station FOVs from the acquisition metadata beside the scan; [] when there is none.
    private(set) var fovBoxes: [FOVBox] = []
    /// The sessions those stations were acquired in (index = FOVBox.session).
    private(set) var fovSessions: [FOVSession] = []
    /// Sessions switched off in the inspector.
    var hiddenFOVSessions = Set<Int>()
    /// The boxes to draw: all of them while the overlay is on, less any hidden sessions.
    var visibleFOVBoxes: [FOVBox] { showFOV ? fovBoxes.filter { !hiddenFOVSessions.contains($0.session) } : [] }
    var showFOV = UserDefaults.standard.bool(forKey: "showFOV") { // `-showFOV YES` for checks
        didSet { UserDefaults.standard.set(showFOV, forKey: "showFOV") }
    }
    /// Draw the crosshair (the current slice positions) in every slice and 3D view.
    var showCrosshair = UserDefaults.standard.object(forKey: "showCrosshair") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCrosshair, forKey: "showCrosshair") }
    }
    /// Multi view: taps on a slice leave the crosshair where it is.
    var crosshairLocked = UserDefaults.standard.bool(forKey: "crosshairLocked") {
        didSet { UserDefaults.standard.set(crosshairLocked, forKey: "crosshairLocked") }
    }
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
    /// Clip planes remove unlabelled tissue only: visible segments stay whole.
    var clipKeepSegments = UserDefaults.standard.bool(forKey: "clipKeepSegments") // `-clipKeepSegments YES` for checks
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
                          cameraClip: cameraClip, cameraClipDepth: cameraClipDepth, bookmarks: bookmarks,
                          noise: noise != nil, removeNoise: removeNoise, repair: scanRepair != nil,
                          clipKeepSegments: clipKeepSegments),
            segmentation: .init(visible: segmentation.visible, opacity: segmentation.opacity, ghost: segmentation.ghost,
                                mask: segmentation.mask,
                                shownName: segmentation.map?.name, keptName: segmentation.others.first?.name,
                                kept2Name: segmentation.others.dropFirst().first?.name,
                                customLabels: segmentation.customLabels.isEmpty ? nil : segmentation.customLabels),
            water: segmentation.waterURL.flatMap(SidecarSettings.Companion.init),
            fat: segmentation.fatURL.flatMap(SidecarSettings.Companion.init),
            inPhase: segmentation.phaseURL[.inPhase].flatMap(SidecarSettings.Companion.init),
            opposed: segmentation.phaseURL[.opposed].flatMap(SidecarSettings.Companion.init),
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
        clipKeepSegments = s.viewer.clipKeepSegments ?? false
        clipHighlight = s.viewer.clipHighlight
        cameraClip = s.viewer.cameraClip ?? false
        cameraClipDepth = s.viewer.cameraClipDepth ?? 0.5
        bookmarks = (s.viewer.bookmarks ?? []).filter { $0.slices.count == 3 }
        removeNoise = s.viewer.removeNoise ?? true
        segmentation.opacity = s.segmentation.opacity
        segmentation.ghost = s.segmentation.ghost
        segmentation.mask = s.segmentation.mask ?? false
        segmentation.customLabels = s.segmentation.customLabels ?? []
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
        restoring = true
        var recovered = false // a map came back from the drawing backup: write the slots again
        defer {
            openingStage = nil
            restoring = false
            sidecarSaveTask?.cancel() // anything queued meanwhile saw a half-restored state
            // Also when the drawing has no backup yet (sidecars from before backups existed).
            let unbackedDrawing = segmentation.customMap != nil && !FileManager.default.fileExists(atPath: sidecar.drawingBackupURL.path)
            if unbackedDrawing { backedUpDrawing = nil }
            if recovered || unbackedDrawing, sidecarProblem == nil { saveSidecarMaps() }
        }
        apply(s)
        await profile.restore()
        let volume = volume
        if s.viewer.repair == true {
            openingStage = "Repairing the scan…"
            if let mask = await Task.detached(priority: .userInitiated, operation: { sidecar.loadLabels(slot: "repair", volume: volume) }).value {
                await applyScanRepair(mask, save: false)
            } else {
                sidecarProblem = "Couldn't read the scan repair from the sidecar. Saving is paused so it isn't overwritten; reopen the scan to try again."
            }
        }
        var missingNoise = false
        if s.viewer.noise == true {
            openingStage = "Loading noise mask…"
            if let labels = await Task.detached(priority: .userInitiated, operation: { sidecar.loadLabels(slot: "noise", volume: volume) }).value {
                noise = NoiseMask(labels: labels)
            } else {
                missingNoise = true
            }
        }
        if s.segmentation.shownName != nil || missingNoise {
            openingStage = "Loading saved segmentation…"
            let slots = zip(Self.mapSlots, [s.segmentation.shownName, s.segmentation.keptName, s.segmentation.kept2Name])
                .compactMap { slot, name in name.map { (slot, $0) } }
            var (maps, missing) = await Task.detached(priority: .userInitiated) { () -> ([SegmentationMap], [String]) in
                var maps: [SegmentationMap] = [], missing: [String] = []
                for (slot, name) in slots {
                    if let m = sidecar.loadMap(slot: slot, name: name, volume: volume) { maps.append(m) } else { missing.append(name) }
                }
                return (maps, missing)
            }.value
            // A drawing whose slot can't be read comes back from its backup (names included).
            if missing.contains(LabelTable.customMapName),
               let r = try? CustomSegmentationFile.read(from: sidecar.drawingBackupURL, scoped: false, volume: volume) {
                maps.append(r.map)
                segmentation.customLabels = r.labels
                missing.removeAll { $0 == LabelTable.customMapName }
                recovered = true
            }
            segmentation.restore(maps, visible: s.segmentation.visible)
            backedUpDrawing = segmentation.customMap?.id // restored as saved: no new backup needed
            sidecarMapsSaved = missing.isEmpty && !maps.isEmpty
            if missingNoise { missing.append("the noise mask") }
            if !missing.isEmpty {
                sidecarProblem = "Couldn't read \(missing.joined(separator: ", ")) from the sidecar. Saving is paused so it isn't overwritten; reopen the scan to try again."
                MemoryLog.log.notice("sidecar: missing maps \(missing, privacy: .public) in \(sidecar.folder.path, privacy: .public)")
            }
        }
        for (which, companion) in [(ImageRole.water, s.water), (.fat, s.fat)] {
            guard let companion, let url = companion.resolve() else { continue }
            openingStage = "Loading \(which.rawValue.lowercased()) image…"
            await segmentation.loadCompanion(which, from: url, scoped: true, quiet: true)
        }
        for (which, companion) in [(PhaseImage.inPhase, s.inPhase), (.opposed, s.opposed)] {
            guard let companion, let url = companion.resolve() else { continue }
            openingStage = "Loading \(which.rawValue.lowercased()) image…"
            await segmentation.loadPhase(which, from: url, scoped: true, quiet: true)
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
        guard let sidecar, sidecarProblem == nil, !restoring else { return }
        sidecarSaveTask?.cancel()
        sidecarSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            // Checked again here: a save queued while the sidecar was being restored must not
            // land after restoring found maps missing.
            guard !Task.isCancelled, let self, sidecarProblem == nil, !restoring else { return }
            let settings = sidecarSettings
            await Task.detached { try? sidecar.save(settings) }.value
            sidecarSavedAt = .now
        }
    }

    /// Sidecar files of the shown map and the others, in that order.
    private static let mapSlots = ["shown", "kept", "kept2"]

    /// Write the current maps (after a generation, load, switch or removal) in the background,
    /// one save after another (two at once could leave the slots mixed), plus a backup of the
    /// drawing when it is new.
    func saveSidecarMaps() {
        guard let sidecar, sidecarProblem == nil, !restoring else { return }
        let ordered: [SegmentationMap?] = [segmentation.map] + segmentation.others
        let voxel = volume.voxelSize, volume = volume
        let drawing = segmentation.customMap.flatMap { $0.id == backedUpDrawing ? nil : $0 }
        let labels = segmentation.customLabels
        sidecarMapsSaved = false
        let previous = mapSaveTask
        mapSaveTask = Task { [weak self] in
            await previous?.value
            guard self?.sidecarProblem == nil else { return }
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    for (i, slot) in Self.mapSlots.enumerated() {
                        try sidecar.saveMap(i < ordered.count ? ordered[i] : nil, slot: slot, voxelSize: voxel)
                    }
                    if let drawing {
                        try sidecar.saveDrawingBackup(CustomSegmentationFile.export(drawing, labels: labels, like: volume))
                    }
                    return true
                } catch { return false }
            }.value
            guard let self else { return }
            if ok, let drawing { backedUpDrawing = drawing.id }
            sidecarMapsSaved = ok
            scheduleSidecarSave() // the names in settings.json must match the files
        }
    }

    /// The scan's landmarks for aligning profile photos; redone when the segmentation changes.
    func updateScanLandmarks() async {
        let volume = volume, maps = segmentation.maps
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

    /// Why there are no FOV boxes, shown in the inspector; nil when loaded.
    private(set) var fovStatus: String?

    func loadFOV() async {
        guard let fileURL else { fovStatus = "No file."; return }
        let volume = volume, extra = sidecar?.folder.appendingPathComponent("metadata.json")
        let result = await Task.detached(priority: .utility) { AcquisitionFOV.boxes(for: fileURL, volume: volume, extra: extra) }.value
        switch result {
        case .success(let set): applyFOV(set)
        case .failure(let f): applyFOV(FOVSet()); fovStatus = f.localizedDescription
        }
    }

    private func applyFOV(_ set: FOVSet) {
        fovBoxes = set.boxes; fovSessions = set.sessions; hiddenFOVSessions = []
        fovStatus = nil
    }

    /// A metadata JSON chosen by hand: checked against this scan, then kept in the sidecar
    /// (`metadata.json`) so it is found again next time.
    func loadFOVMetadata(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { fovStatus = "Couldn't read \(url.lastPathComponent)."; return }
        let keys = fileURL.map { SegmentationPipeline.tags(of: $0).reversed() } ?? []
        switch AcquisitionFOV.boxes(json: data, keys: Array(keys), volume: volume) {
        case .success(let b):
            applyFOV(b); showFOV = true
            if let sidecar {
                try? FileManager.default.createDirectory(at: sidecar.folder, withIntermediateDirectories: true)
                try? data.write(to: sidecar.folder.appendingPathComponent("metadata.json"), options: .atomic)
            }
        case .failure(let f): fovStatus = f.localizedDescription
        }
    }

    /// The FOV boxes cut by the current slice of a pane, as rectangles in image fractions
    /// (x right, y down, mirror applied), with their station labels and edge lengths.
    func fovRects(in axis: Int) -> [FOVRect] {
        let (c, r) = sliceAxes(axis), k = Double(slices[axis]) + 0.5
        return visibleFOVBoxes.compactMap { b in
            guard k > b.lo[axis], k < b.hi[axis] else { return nil }
            var x0 = b.lo[c] / Double(dims[c]), x1 = b.hi[c] / Double(dims[c])
            if mirrored { (x0, x1) = (1 - x1, 1 - x0) }
            let y0 = 1 - b.hi[r] / Double(dims[r]), y1 = 1 - b.lo[r] / Double(dims[r])
            let size = [Double(volume.voxelSize.0), Double(volume.voxelSize.1), Double(volume.voxelSize.2)]
            return FOVRect(rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), label: b.label,
                           widthMM: (b.hi[c] - b.lo[c]) * size[c], heightMM: (b.hi[r] - b.lo[r]) * size[r], session: b.session)
        }
    }

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

    /// The shared pan centre in a slice pane, as fractions of the displayed image (x right, y down).
    func panCentre(in axis: Int) -> CGPoint {
        let (c, r) = sliceAxes(axis)
        let u = CGFloat(multiCentre[c])
        return CGPoint(x: mirrored ? 1 - u : u, y: 1 - CGFloat(multiCentre[r]))
    }

    func setPanCentre(_ p: CGPoint, in axis: Int) {
        let (c, r) = sliceAxes(axis)
        multiCentre[c] = Double(mirrored ? 1 - p.x : p.x)
        multiCentre[r] = Double(1 - p.y)
    }

    func addBookmark() {
        // Next unused number, so deleting one doesn't produce a duplicate name.
        let n = (bookmarks.compactMap { Int($0.name.split(separator: " ").last ?? "") }.max() ?? 0) + 1
        bookmarks.append(SliceBookmark(name: "Bookmark \(n)", slices: slices))
    }

    func recall(_ b: SliceBookmark) {
        slices = zip(b.slices, dims).map { max(0, min($1 - 1, $0)) }
    }

    /// "Axial 120 · Coronal 300 · Sagittal 190", 1-based like the scrubber.
    func describe(_ b: SliceBookmark) -> String {
        [(2, "Axial"), (1, "Coronal"), (0, "Sagittal")].map { "\($1) \(b.slices[$0] + 1)" }.joined(separator: " · ")
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
