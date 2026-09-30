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
    /// The Dixon fat image, needed for the muscle/fat tissue classes; found beside the scan
    /// (`<tag>_F.nii.gz`) or chosen by hand.
    private(set) var fat: NiftiVolume?
    private(set) var fatURL: URL?
    private var cancel: CancelFlag?

    init(volume: NiftiVolume) { self.volume = volume }

    /// What the renderers draw, or nil when no map is loaded.
    var overlay: SegmentationOverlay? {
        guard let map else { return nil }
        var lut = [SIMD4<UInt8>](repeating: .zero, count: 256)
        for l in map.labelRange where visible.indices.contains(l) && visible[l] {
            let c = map.table.color(l) * 255
            lut[l] = SIMD4(UInt8(c.x), UInt8(c.y), UInt8(c.z), 255)
        }
        return SegmentationOverlay(mapID: map.id, labels: map.labels, lut: lut, opacity: opacity, ghost: ghost)
    }

    func show(_ new: SegmentationMap?) {
        map = new
        visible = [Bool](repeating: true, count: (new?.labels.maxLabel ?? 0) + 1)
    }

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

    func loadFat(from url: URL, scoped: Bool, quiet: Bool = false) async {
        let volume = volume
        let result = await Task.detached(priority: .userInitiated) { Result { try SegmentationPipeline.loadVolume(from: url, scoped: scoped, matching: volume) } }.value
        switch result {
        case .success(let v): fat = v; fatURL = url
        case .failure(let e): if !quiet { error = e.localizedDescription }
        }
    }

    /// Pick up the fat image and a tissue map lying beside the scan, without complaint if absent.
    func discoverSiblings(of fileURL: URL) async {
        if fat == nil, let url = SegmentationPipeline.siblingFat(of: fileURL) { await loadFat(from: url, scoped: false, quiet: true) }
        if map == nil, let url = SegmentationPipeline.siblingLabels(of: fileURL) { await load(from: url, scoped: false, quiet: true) }
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
        let volume = volume, fat = fat
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try SegmentationPipeline.generate(volume: volume, fat: fat, progress: { stage, p in
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
