//
//  AcquisitionFOV.swift — where each scanner station's field of view lies on the scan, from
//  the pipeline's `<tag>_metadata.json` beside it (stations[].geometry
//  .placement_in_stitched_volumes[<tag>].voxel_edges_xyz, in the NIfTI file's index order).
//

import Foundation

/// One station's FOV as voxel edges on the displayed (RAS) grid: voxel i spans [i, i+1).
struct FOVBox: Equatable {
    let label: String
    let lo: SIMD3<Double>
    let hi: SIMD3<Double>
}

enum AcquisitionFOV {
    /// Boxes for `volume` from the metadata JSON beside `fileURL`, or [] if there is none or it
    /// describes a different grid.
    /// Why no boxes were found, for the inspector.
    enum Failure: Error, LocalizedError {
        case notFound, noGeometry, otherGrid
        var errorDescription: String? {
            switch self {
            case .notFound: return "No <subject>_metadata.json beside the scan (or the app can't read that folder)."
            case .noGeometry: return "The metadata has no per-station placement for this scan."
            case .otherGrid: return "The metadata describes a different grid than this file."
            }
        }
    }

    /// Boxes from the metadata JSON beside the scan, or from `extra` (a copy kept in the sidecar).
    static func boxes(for fileURL: URL, volume: NiftiVolume, extra: URL? = nil) -> Result<[FOVBox], Failure> {
        let dir = fileURL.deletingLastPathComponent()
        // `S_S_W.nii.gz` → tags ["S_S_W", "S_S"]; the metadata is per subject and its placement
        // entries are keyed by the stitched volume's tag.
        let tags = SegmentationPipeline.tags(of: fileURL)
        let candidates = tags.reversed().map { dir.appendingPathComponent("\($0)_metadata.json") } + [extra].compactMap { $0 }
        var failure = Failure.notFound
        for url in candidates {
            guard let data = read(url) else { continue }
            switch boxes(json: data, keys: tags.reversed(), volume: volume) {
            case .success(let b): return .success(b)
            case .failure(let f): failure = f
            }
        }
        return .failure(failure)
    }

    static func boxes(json data: Data, keys: [String], volume: NiftiVolume) -> Result<[FOVBox], Failure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stations = json["stations"] as? [[String: Any]] else { return .failure(.noGeometry) }
        // Any placement keyed by one of the tags, else the only one there is.
        var keys = keys
        if let any = stations.lazy.compactMap({ (($0["geometry"] as? [String: Any])?["placement_in_stitched_volumes"] as? [String: Any])?.keys }).first,
           any.count == 1, let only = any.first { keys.append(only) }
        let found = boxes(stations: stations, keys: keys, volume: volume)
        if !found.isEmpty { return .success(found) }
        let hasGeometry = stations.contains { ($0["geometry"] as? [String: Any])?["placement_in_stitched_volumes"] != nil }
        return .failure(hasGeometry ? .otherGrid : .noGeometry)
    }

    /// Read a file that may be an iCloud placeholder: ask for the download and wait briefly.
    private static func read(_ url: URL) -> Data? {
        if let d = try? Data(contentsOf: url) { return d }
        let fm = FileManager.default
        guard (try? fm.startDownloadingUbiquitousItem(at: url)) != nil else { return nil }
        for _ in 0..<20 { // up to ~10 s
            Thread.sleep(forTimeInterval: 0.5)
            if let d = try? Data(contentsOf: url) { return d }
        }
        return nil
    }

    static func boxes(stations: [[String: Any]], keys: [String], volume: NiftiVolume) -> [FOVBox] {
        let fileDims = (0..<3).map { a in [volume.dims.0, volume.dims.1, volume.dims.2][volume.filePerm.firstIndex(of: a)!] }
        var seen = Set<String>(), out = [FOVBox]()
        for s in stations {
            // Every Dixon contrast of a station shares its geometry: keep one per role + step.
            let role = s["role"] as? String ?? "", step = (s["step"] as? Int) ?? 0
            guard seen.insert("\(role)#\(step)").inserted,
                  let placements = (s["geometry"] as? [String: Any])?["placement_in_stitched_volumes"] as? [String: Any],
                  let placement = keys.lazy.compactMap({ placements[$0] as? [String: Any] }).first,
                  let edges = placement["voxel_edges_xyz"] as? [String: Any],
                  let mn = (edges["min"] as? [NSNumber])?.map(\.doubleValue), mn.count == 3,
                  let mx = (edges["max"] as? [NSNumber])?.map(\.doubleValue), mx.count == 3,
                  (edges["volume_size_xyz"] as? [Int]) == fileDims // same grid as the opened file
            else { continue }
            // File index order → RAS: permute, and mirror the range on flipped axes.
            var lo = SIMD3<Double>(), hi = SIMD3<Double>()
            for w in 0..<3 {
                let a = volume.filePerm[w], n = Double(fileDims[a])
                (lo[w], hi[w]) = volume.fileFlip[w] ? (n - mx[a], n - mn[a]) : (mn[a], mx[a])
            }
            let label = role.lowercased().contains("re-run") ? "\(step)′" : "\(step)"
            out.append(FOVBox(label: label, lo: lo, hi: hi))
        }
        return out
    }
}
