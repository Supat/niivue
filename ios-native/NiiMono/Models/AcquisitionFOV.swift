//
//  AcquisitionFOV.swift — where each scanner station's field of view lies on the scan, from
//  the pipeline's `<tag>_metadata.json` beside it (stations[].geometry
//  .placement_in_stitched_volumes[<tag>].voxel_edges_xyz, in the NIfTI file's index order).
//

import CoreGraphics
import Foundation

/// One station's FOV as voxel edges on the displayed (RAS) grid: voxel i spans [i, i+1).
struct FOVBox: Equatable {
    let label: String
    let lo: SIMD3<Double>
    let hi: SIMD3<Double>
}

/// A station's FOV cut by a slice: where it lies in the displayed image (fractions, x right,
/// y down) and its physical size along the image's width and height.
struct FOVRect: Equatable {
    let rect: CGRect
    let label: String
    let widthMM: Double, heightMM: Double

    /// "34.5 cm": one decimal, as scanner FOVs are set in whole millimetres.
    static func cm(_ mm: Double) -> String { String(format: "%.1f cm", mm / 10) }
}

enum AcquisitionFOV {
    /// Boxes for `volume` from the metadata JSON beside `fileURL`, or [] if there is none or it
    /// describes a different grid.
    /// Why no boxes were found, for the inspector.
    enum Failure: Error, LocalizedError {
        case notFound, noGeometry, otherGrid
        var errorDescription: String? {
            switch self {
            case .notFound: return "No metadata in the file, and no readable *_metadata.json beside it."
            case .noGeometry: return "The metadata has no per-station placement for this scan."
            case .otherGrid: return "The metadata describes a different grid than this file."
            }
        }
    }

    /// Boxes from the metadata embedded in the file, else any `*_metadata.json` beside the scan
    /// that places stations on this grid, else `extra` (a copy kept in the sidecar).
    static func boxes(for fileURL: URL, volume: NiftiVolume, extra: URL? = nil) -> Result<[FOVBox], Failure> {
        // `S_S_W.nii.gz` → tags ["S_S_W", "S_S"]; placement entries are keyed by the stitched
        // volume's tag, but the grid check is what decides, so a renamed scan still matches.
        let keys = Array(SegmentationPipeline.tags(of: fileURL).reversed())
        var failure = Failure.notFound
        func attempt(_ data: Data?) -> [FOVBox]? {
            guard let data else { return nil }
            switch boxes(json: data, keys: keys, volume: volume) {
            case .success(let b): return b
            case .failure(let f): failure = f; return nil
            }
        }
        // Embedded first: a file opened from the browser is readable when its folder isn't.
        if let b = attempt(volume.embeddedJSON) { return .success(b) }
        let dir = fileURL.deletingLastPathComponent(), fm = FileManager.default
        let named = keys.map { "\($0)_metadata.json" }
        // iCloud lists a file that isn't downloaded as `.name.icloud`.
        let listed = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).map {
            $0.hasPrefix(".") && $0.hasSuffix(".icloud") ? String($0.dropFirst().dropLast(7)) : $0
        }.filter { $0.hasSuffix("_metadata.json") }.sorted()
        // A session's metadata places only its own stations on the whole-body grid, so of the
        // files that match, the one with the most stations wins (the scan's own name on a tie).
        var tried = Set<String>(), best = [FOVBox]()
        for name in named + listed where tried.insert(name).inserted {
            if let b = attempt(read(dir.appendingPathComponent(name))), b.count > best.count { best = b }
        }
        if best.isEmpty, let extra, let b = attempt(read(extra)) { best = b }
        return best.isEmpty ? .failure(failure) : .success(best)
    }

    static func boxes(json data: Data, keys: [String], volume: NiftiVolume) -> Result<[FOVBox], Failure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stations = json["stations"] as? [[String: Any]] else { return .failure(.noGeometry) }
        let found = boxes(stations: stations, keys: keys, volume: volume)
        if !found.isEmpty { return .success(found) }
        let hasGeometry = stations.contains { ($0["geometry"] as? [String: Any])?["placement_in_stitched_volumes"] != nil }
        return .failure(hasGeometry ? .otherGrid : .noGeometry)
    }

    /// Read a file that may be an iCloud placeholder: ask for the download and wait briefly.
    private static func read(_ url: URL) -> Data? {
        do { return try Data(contentsOf: url) } catch {
            MemoryLog.log.notice("fov: \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
                  // The placement on this file's grid: by tag first, then whichever matches.
                  let edges = (keys + placements.keys.sorted()).lazy
                      .compactMap({ (placements[$0] as? [String: Any])?["voxel_edges_xyz"] as? [String: Any] })
                      .first(where: { ($0["volume_size_xyz"] as? [Int]) == fileDims }),
                  let mn = (edges["min"] as? [NSNumber])?.map(\.doubleValue), mn.count == 3,
                  let mx = (edges["max"] as? [NSNumber])?.map(\.doubleValue), mx.count == 3
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
