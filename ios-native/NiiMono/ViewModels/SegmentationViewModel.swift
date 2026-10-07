//
//  SegmentationViewModel.swift — the segmentation shown over the scan: which map, which
//  labels are visible, how it's blended; loading and generating maps.
//

import Foundation
import Observation

@Observable @MainActor final class SegmentationViewModel {
    /// The scan (replaced, same grid, when its intensities are repaired by hand).
    var volume: NiftiVolume

    /// Every map this scan has — after generation the tissue classes and the structures, or a
    /// loaded file, plus the drawing — and which one is on screen.
    private(set) var maps: [SegmentationMap] = []
    private(set) var shownID: UUID?
    var map: SegmentationMap? { maps.first { $0.id == shownID } }
    /// The maps not on screen, in order (the sidecar's `kept`, `kept2` slots).
    var others: [SegmentationMap] { maps.filter { $0.id != shownID } }
    var mapIDs: [UUID] { maps.map(\.id) }
    /// The maps in sidecar order (shown first); a change means the sidecar's maps need writing.
    var savedOrder: [UUID] { ([map] + others).compactMap { $0?.id } }
    var visible: [Bool] = []      // indexed by label; [0] unused
    var opacity: Float = 0.65     // colour blend over the grey image
    var ghost = UserDefaults.standard.bool(forKey: "segGhost") // `-segGhost YES` for checks
    /// The visible labels act as a mask: only the scan inside them is shown, uncoloured, in
    /// every view.
    var mask = UserDefaults.standard.bool(forKey: "segMask") // `-segMask YES` for checks

    var isLoading = false
    var error: String?
    var progress: Double?         // non-nil while the models run
    var stage = ""
    /// Which Dixon contrast the opened file is. The tissue classes need both the water and
    /// the fat image; the one that isn't the opened file comes from beside it or by hand.
    var role: ImageRole
    private(set) var water: NiftiVolume?
    private(set) var waterURL: URL?
    private(set) var fat: NiftiVolume?
    private(set) var fatURL: URL?
    /// The companions as the sidecar records them (name + bookmark), made while each was
    /// loaded: the bookmark needs the file's security scope, open only during the load.
    private(set) var waterCompanion: SidecarSettings.Companion?
    private(set) var fatCompanion: SidecarSettings.Companion?
    private(set) var phaseCompanion: [PhaseImage: SidecarSettings.Companion] = [:]
    /// Water / fat as the tissue classifier needs them, from the opened file and companions.
    var waterImage: NiftiVolume? { role == .water ? volume : water }
    var fatImage: NiftiVolume? { role == .fat ? volume : fat }
    var canClassifyTissue: Bool { waterImage != nil && fatImage != nil }
    /// The hand-drawn noise mask while it is applied (set by the viewer): generation removes it.
    var noise: [UInt8]?
    /// In-phase / opposed-phase images, only when added (each is the scan's size in memory).
    private(set) var phase: [PhaseImage: NiftiVolume] = [:]
    private(set) var phaseURL: [PhaseImage: URL] = [:]
    /// The networks run on the water image where there is one (what TotalSegmentator's
    /// total_mr was used on), else on the opened file.
    var modelInput: NiftiVolume { waterImage ?? volume }
    @ObservationIgnored nonisolated(unsafe) private var cancel: CancelFlag? // touched from deinit

    init(volume: NiftiVolume, role: ImageRole) { self.volume = volume; self.role = role }

    /// Closing the document must not leave a minutes-long model run going.
    deinit { cancel?.set() }

    /// What the renderers draw, or nil when no map is loaded.
    var overlay: SegmentationOverlay? {
        guard let map else { return nil }
        var lut = [SIMD4<UInt8>](repeating: .zero, count: 256)
        for l in map.labelRange where isVisible(l) {
            let c = map.table.color(l) * 255
            lut[l] = SIMD4(UInt8(c.x), UInt8(c.y), UInt8(c.z), 255)
        }
        // Masked: the scan alone inside the labels, no colour.
        return SegmentationOverlay(mapID: map.id, labels: LabelGrid(map.labels), lut: lut, opacity: mask ? 0 : opacity, ghost: ghost,
                                   hideScan: mask, mask: mask)
    }

    /// Put a map on screen, all its labels visible.
    func select(_ id: UUID?) {
        shownID = id
        visible = [Bool](repeating: true, count: (map?.labelRange.upperBound ?? 0))
    }

    /// New generated or loaded maps replace the old ones; the drawing stays.
    private func replaceMaps(with new: [SegmentationMap]) {
        maps = new + maps.filter(\.isCustom)
        select(new.first?.id ?? maps.first?.id)
    }

    /// Safe against rows still on screen after the map shrank.
    func isVisible(_ label: Int) -> Bool { visible.indices.contains(label) && visible[label] }
    func setVisible(_ label: Int, _ on: Bool) { if visible.indices.contains(label) { visible[label] = on } }

    /// Removes the map on screen and shows the next one.
    func remove() {
        guard let map else { return }
        if map.isCustom { customLabels = [] }
        maps.removeAll { $0.id == map.id }
        select(maps.first?.id)
    }

    func setAllVisible(_ on: Bool) { visible = visible.map { _ in on } }

    // MARK: - Drawn segmentation

    /// Names and colours of the drawn map's labels (kept in the sidecar settings).
    var customLabels: [CustomLabel] = []

    /// The drawn map, shown or not.
    var customMap: SegmentationMap? { maps.first(where: \.isCustom) }

    /// Show a finished (or imported) drawing in place of the previous one; other maps stay.
    func showCustom(_ new: SegmentationMap, labels: [CustomLabel]) {
        customLabels = labels
        maps.removeAll(where: \.isCustom)
        maps.append(new)
        select(new.id)
    }

    /// New names or colours for the drawing's labels, its voxels unchanged.
    func updateCustomLabels(_ labels: [CustomLabel]) {
        customLabels = labels
        if let i = maps.firstIndex(where: \.isCustom) { maps[i].table = .custom(labels) }
    }

    private func withCustomTable(_ m: SegmentationMap) -> SegmentationMap {
        guard m.isCustom else { return m }
        var m = m
        m.table = .custom(customLabels)
        return m
    }

    // MARK: - Loading

    func load(from url: URL, scoped: Bool, quiet: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        let volume = volume
        let result = await Task.detached(priority: .userInitiated) { Result { try SegmentationPipeline.loadLabels(from: url, scoped: scoped, volume: volume) } }.value
        switch result {
        case .success(let m): replaceMaps(with: [m]); error = nil
        case .failure(let e): if !quiet { error = e.localizedDescription }
        }
    }

    /// Load an in-phase or opposed-phase image (must share the scan's grid).
    func loadPhase(_ which: PhaseImage, from url: URL, scoped: Bool, quiet: Bool = false) async {
        companionLoading = true
        companionError = nil
        defer { companionLoading = false }
        let volume = volume
        let result = await Task.detached(priority: .userInitiated) {
            Result { (try SegmentationPipeline.loadVolume(from: url, scoped: scoped, matching: volume), SidecarSettings.Companion(url: url, scoped: scoped)) }
        }.value
        switch result {
        case .success(let (v, companion)): phase[which] = v; phaseURL[which] = url; phaseCompanion[which] = companion
        case .failure(let e): if !quiet { companionError = e.localizedDescription }
        }
    }

    /// Frees the image (and forgets it in the sidecar).
    func removePhase(_ which: PhaseImage) { phase[which] = nil; phaseURL[which] = nil; phaseCompanion[which] = nil }

    var companionLoading = false
    var companionError: String?

    /// Load a companion Dixon image (must share the scan's grid).
    func loadCompanion(_ which: ImageRole, from url: URL, scoped: Bool, quiet: Bool = false) async {
        companionLoading = true
        companionError = nil
        defer { companionLoading = false }
        let volume = volume
        let result = await Task.detached(priority: .userInitiated) {
            Result { (try SegmentationPipeline.loadVolume(from: url, scoped: scoped, matching: volume), SidecarSettings.Companion(url: url, scoped: scoped)) }
        }.value
        switch result {
        case .success(let (v, companion)):
            if which == .fat { fat = v; fatURL = url; fatCompanion = companion } else { water = v; waterURL = url; waterCompanion = companion }
        case .failure(let e): if !quiet { companionError = e.localizedDescription }
        }
    }

    /// Pick up companion images and a tissue map lying beside the scan, without complaint if absent.
    func discoverSiblings(of fileURL: URL) async {
        if role != .fat, fat == nil, let url = SegmentationPipeline.siblingDixon(of: fileURL, suffix: "F") { await loadCompanion(.fat, from: url, scoped: false, quiet: true) }
        if role != .water, water == nil, let url = SegmentationPipeline.siblingDixon(of: fileURL, suffix: "W") { await loadCompanion(.water, from: url, scoped: false, quiet: true) }
        if map == nil, let url = SegmentationPipeline.siblingLabels(of: fileURL) { await load(from: url, scoped: false, quiet: true) }
    }

    /// Install maps read from the sidecar, the shown one first (no file access, no error reporting).
    func restore(_ restored: [SegmentationMap], visible: [Bool]) {
        maps = restored.map(withCustomTable)
        select(maps.first?.id)
        if visible.count == self.visible.count { self.visible = visible }
    }

    // MARK: - Generating

    var isGenerating: Bool { progress != nil }

    /// Run the bundled models in the background; minutes on an iPad.
    func generate() {
        guard !isGenerating else { return }
        error = nil
        progress = 0
        let flag = CancelFlag()
        cancel = flag
        let volume = volume, input = modelInput, water = waterImage, fat = fatImage, noise = noise
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try SegmentationPipeline.generate(volume: volume, modelInput: input, water: water, fat: fat, noise: noise, progress: { stage, p in
                        Task { @MainActor in self?.stage = stage; self?.progress = p }
                    }, cancel: flag)
                }
            }.value
            guard let self else { return }
            progress = nil
            cancel = nil
            switch result {
            case .success(let maps): replaceMaps(with: [maps.shown] + [maps.kept].compactMap { $0 })
            case .failure(is CancellationError): break
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    func cancelGenerating() { cancel?.set() }
}
