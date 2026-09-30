//
//  SegmentationPipeline.swift — file loading and on-device generation of segmentation
//  maps. Pure functions; the view model owns the threading and the state.
//

import Foundation
import Metal

/// A flag one thread sets and another polls (the segmenter's cancellation check).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}

enum SegmentationPipeline {
    /// Read a NIfTI file, optionally through a security scope.
    private static func read(_ url: URL, scoped: Bool) throws -> Data {
        let accessed = scoped && url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    /// A label file on the scan's grid.
    static func loadLabels(from url: URL, scoped: Bool, volume: NiftiVolume) throws -> SegmentationMap {
        let data = try read(url, scoped: scoped)
        let labels = try NIfTI.parseLabels(NIfTI.isGzip(data) ? NIfTI.gunzip(data) : data)
        guard labels.dims == volume.dims else { throw NiftiError.gridMismatch(labels.dims, volume.dims) }
        return SegmentationMap(labels: labels, name: url.lastPathComponent, volume: volume)
    }

    /// A second image (the Dixon fat image) on the scan's grid.
    static func loadVolume(from url: URL, scoped: Bool, matching volume: NiftiVolume) throws -> NiftiVolume {
        let data = try read(url, scoped: scoped)
        let v = try NIfTI.parse(NIfTI.isGzip(data) ? NIfTI.gunzip(data) : data)
        guard v.dims == volume.dims else { throw NiftiError.gridMismatch(v.dims, volume.dims) }
        return v
    }

    /// Run the bundled TotalSegmentator models (organs, then muscles/bones), merge them, and
    /// — with the fat image — derive the 14 tissue classes. Returns the map to show and,
    /// when a tissue map was made, the structure map to keep alongside it.
    static func generate(volume: NiftiVolume, fat: NiftiVolume?, progress: @escaping (String, Double) -> Void,
                         cancel: CancelFlag) throws -> (shown: SegmentationMap, kept: SegmentationMap?) {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary() else { throw SegmenterError.noMetal }
        func run(_ model: String, classes: Int, stage: String, from: Double, to: Double) throws -> LabelVolume {
            guard let url = Bundle.main.url(forResource: model, withExtension: "mlmodelc") else { throw SegmenterError.missingModel(model) }
            let seg = try OrganSegmenter(modelURL: url, library: library, classes: classes)
            return try seg.segment(volume, progress: { progress(stage, from + (to - from) * $0) }, isCancelled: { cancel.isSet })
        }
        let organs = try run("Organs", classes: TotalMR.organCount + 1, stage: "organs", from: 0, to: 0.45)
        let muscles = try run("Muscles", classes: TotalMR.names.count - TotalMR.organCount + 1, stage: "muscles and bones", from: 0.45, to: 0.9)
        // Merge like TotalSegmentator: the later part overwrites where both claim a voxel.
        var merged = organs.data
        muscles.data.withUnsafeBufferPointer { m in
            merged.withUnsafeMutableBufferPointer { o in
                for i in 0..<m.count where m[i] != 0 { o[i] = m[i] + UInt8(TotalMR.organCount) }
            }
        }
        let all = LabelVolume(dims: volume.dims, data: merged, maxLabel: TotalMR.names.count)
        let structures = SegmentationMap(labels: all, name: "structures (total_mr)", volume: volume)
        guard let fat else { return (structures, nil) }
        progress("tissue classes", 0.9)
        let tissue = try TissueClassifier.classify(water: volume, fat: fat, labels: all, library: library,
                                                   progress: { progress("tissue classes", 0.9 + 0.1 * $0) })
        return (SegmentationMap(labels: tissue, name: "tissues (generated)", volume: volume), structures)
    }

    // MARK: - Files beside the scan

    /// Scan name without extension and without a Dixon suffix (`S_S_W.nii.gz` → `S_S`).
    static func tags(of fileURL: URL) -> [String] {
        var base = fileURL.lastPathComponent
        for ext in [".nii.gz", ".nii"] where base.hasSuffix(ext) { base.removeLast(ext.count) }
        var tags = [base]
        for suffix in ["_W", "_F", "_in", "_opp"] where base.hasSuffix(suffix) { tags.append(String(base.dropLast(suffix.count))) }
        return tags
    }

    /// The Dixon fat image beside a `<tag>_W` scan, if present.
    static func siblingFat(of fileURL: URL) -> URL? {
        guard fileURL.lastPathComponent.contains("_W.nii") else { return nil }
        let tag = tags(of: fileURL).last!, dir = fileURL.deletingLastPathComponent()
        return ["\(tag)_F.nii.gz", "\(tag)_F.nii"].map(dir.appendingPathComponent).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A tissue map beside the scan or in a `seg/` folder, if present.
    static func siblingLabels(of fileURL: URL) -> URL? {
        let dir = fileURL.deletingLastPathComponent()
        for tag in tags(of: fileURL) {
            for folder in [dir, dir.appendingPathComponent("seg")] {
                for name in ["\(tag)_tissues.nii.gz", "\(tag)_tissues.nii", "\(tag)_seg.nii.gz"] {
                    let url = folder.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }
}
