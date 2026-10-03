//
//  CustomSegmentationFile.swift — import and export of a drawn segmentation: a uint8 label
//  NIfTI on the scan's own grid and orientation, its label names and colours carried as
//  JSON in a header extension ({"labels": [{"id", "name", "color"}]}).
//

import Foundation

enum CustomSegmentationFile {
    private struct Payload: Codable { var labels: [CustomLabel] }

    /// The .nii.gz bytes for `map` (the drawing) with `labels`' names, on `volume`'s file grid.
    static func export(_ map: SegmentationMap, labels: [CustomLabel], like volume: NiftiVolume) -> Data {
        let json = try? JSONEncoder().encode(Payload(labels: labels))
        return NIfTI.labelFile(map.labels, like: volume, json: json)
    }

    /// A label file on `volume`'s grid as a drawing: its voxels and label names (from the
    /// header extension when the file has them, else "Label n" for each label present).
    static func read(from url: URL, scoped: Bool, volume: NiftiVolume) throws -> (map: SegmentationMap, labels: [CustomLabel]) {
        let raw = try SegmentationPipeline.read(url, scoped: scoped)
        let d = NIfTI.isGzip(raw) ? try NIfTI.gunzip(raw) : raw
        let grid = try NIfTI.parseLabels(d)
        guard grid.dims == volume.dims else { throw NiftiError.gridMismatch(grid.dims, volume.dims) }
        var present = [Bool](repeating: false, count: 256)
        grid.data.withUnsafeBufferPointer { for v in $0 { present[Int(v)] = true } }
        let ids = (1...255).filter { present[$0] }
        // Names from our own export; ids no longer present are dropped, unnamed ones added.
        var labels = names(in: d)?.filter { $0.id >= 1 && $0.id <= 255 && present[$0.id] } ?? []
        for id in ids where !labels.contains(where: { $0.id == id }) {
            let c = LabelTable.generic.color(id)
            labels.append(CustomLabel(id: id, name: "Label \(id)", color: [c.x, c.y, c.z]))
        }
        labels.sort { $0.id < $1.id }
        let volumeGrid = LabelVolume(dims: grid.dims, data: grid.data, maxLabel: ids.last ?? 0)
        let map = SegmentationMap(labels: volumeGrid, name: LabelTable.customMapName, volume: volume, table: .custom(labels))
        return (map, labels)
    }

    private static func names(in d: Data) -> [CustomLabel]? {
        guard d.count >= 352 else { return nil }
        let voxOffset = d.withUnsafeBytes { Int(Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 108, as: UInt32.self)))) }
        guard let json = NIfTI.embeddedJSON(in: d, voxOffset: voxOffset) else { return nil }
        return (try? JSONDecoder().decode(Payload.self, from: json))?.labels
    }
}
