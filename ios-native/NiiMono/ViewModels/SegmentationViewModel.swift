//
//  SegmentationViewModel.swift — the segmentation shown over the scan: which map, which
//  labels are visible, how it's blended; loading and generating maps.
//

import Foundation
import Observation

@Observable @MainActor final class SegmentationViewModel {
    let volume: NiftiVolume

    /// The map on screen and, after generation, the structure map kept alongside it.
    private(set) var map: SegmentationMap?
    private(set) var kept: SegmentationMap?
    var visible: [Bool] = []      // indexed by label; [0] unused
    var opacity: Float = 0.65     // colour blend over the grey image
    var ghost = UserDefaults.standard.bool(forKey: "segGhost") // `-segGhost YES` for checks

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
    /// Water / fat as the tissue classifier needs them, from the opened file and companions.
    var waterImage: NiftiVolume? { role == .water ? volume : water }
    var fatImage: NiftiVolume? { role == .fat ? volume : fat }
    var canClassifyTissue: Bool { waterImage != nil && fatImage != nil }
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
        return SegmentationOverlay(mapID: map.id, labels: map.labels, lut: lut, opacity: opacity, ghost: ghost)
    }

    func show(_ new: SegmentationMap?) {
        map = new
        visible = [Bool](repeating: true, count: (new?.labelRange.upperBound ?? 0))
    }

    /// Safe against rows still on screen after the map shrank.
    func isVisible(_ label: Int) -> Bool { visible.indices.contains(label) && visible[label] }
    func setVisible(_ label: Int, _ on: Bool) { if visible.indices.contains(label) { visible[label] = on } }

    func remove() { show(nil); kept = nil }

    /// Swap the shown map with the kept one.
    func swapMaps() {
        guard let other = kept else { return }
        kept = map
        show(other)
    }

    func setAllVisible(_ on: Bool) { visible = visible.map { _ in on } }

    // MARK: - Loading

    func load(from url: URL, scoped: Bool, quiet: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        let volume = volume
        let result = await Task.detached(priority: .userInitiated) { Result { try SegmentationPipeline.loadLabels(from: url, scoped: scoped, volume: volume) } }.value
        switch result {
        case .success(let m): show(m); kept = nil; error = nil
        case .failure(let e): if !quiet { error = e.localizedDescription }
        }
    }

    /// Load a companion Dixon image (must share the scan's grid).
    func loadCompanion(_ which: ImageRole, from url: URL, scoped: Bool, quiet: Bool = false) async {
        let volume = volume
        let result = await Task.detached(priority: .userInitiated) { Result { try SegmentationPipeline.loadVolume(from: url, scoped: scoped, matching: volume) } }.value
        switch result {
        case .success(let v):
            if which == .fat { fat = v; fatURL = url } else { water = v; waterURL = url }
        case .failure(let e): if !quiet { error = e.localizedDescription }
        }
    }

    /// Pick up companion images and a tissue map lying beside the scan, without complaint if absent.
    func discoverSiblings(of fileURL: URL) async {
        if role != .fat, fat == nil, let url = SegmentationPipeline.siblingDixon(of: fileURL, suffix: "F") { await loadCompanion(.fat, from: url, scoped: false, quiet: true) }
        if role != .water, water == nil, let url = SegmentationPipeline.siblingDixon(of: fileURL, suffix: "W") { await loadCompanion(.water, from: url, scoped: false, quiet: true) }
        if map == nil, let url = SegmentationPipeline.siblingLabels(of: fileURL) { await load(from: url, scoped: false, quiet: true) }
    }

    /// Install maps read from the sidecar (no file access, no error reporting).
    func restore(shown: SegmentationMap?, kept: SegmentationMap?, visible: [Bool]) {
        show(shown)
        self.kept = kept
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
        let volume = volume, input = modelInput, water = waterImage, fat = fatImage
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try SegmentationPipeline.generate(volume: volume, modelInput: input, water: water, fat: fat, progress: { stage, p in
                        Task { @MainActor in self?.stage = stage; self?.progress = p }
                    }, cancel: flag)
                }
            }.value
            guard let self else { return }
            progress = nil
            cancel = nil
            switch result {
            case .success(let maps): show(maps.shown); kept = maps.kept
            case .failure(is CancellationError): break
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    func cancelGenerating() { cancel?.set() }
}
