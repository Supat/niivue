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
    /// Index into the session list (FOVSession.all order); also picks the colour.
    var session = 0
}

/// One scanning session (a DICOM study) whose stations were stitched into the scan.
struct FOVSession: Equatable {
    /// The study's role in the pipeline's metadata, e.g. "chest re-run (station 1 only)".
    let name: String
    /// yyyy-MM-dd and HH:mm when the metadata has them.
    let date: String?
    let stationCount: Int

    /// Wireframe and label colour per session, cycling; mirrors kFOVColors in Raycaster.metal.
    static let colors: [SIMD3<Float>] = [
        [1.00, 0.84, 0.00], [0.20, 0.85, 1.00], [1.00, 0.40, 0.85], [0.45, 0.95, 0.35], [1.00, 0.55, 0.15], [0.70, 0.55, 1.00],
    ]
    static func color(_ index: Int) -> SIMD3<Float> { colors[index % colors.count] }
}

/// The station boxes found for a scan and the sessions they belong to.
struct FOVSet: Equatable {
    var boxes: [FOVBox] = []
    var sessions: [FOVSession] = []
    var isEmpty: Bool { boxes.isEmpty }
}

/// A station's FOV cut by a slice: where it lies in the displayed image (fractions, x right,
/// y down) and its physical size along the image's width and height.
struct FOVRect: Equatable {
    let rect: CGRect
    let label: String
    let widthMM: Double, heightMM: Double
    var session = 0

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
    static func boxes(for fileURL: URL, volume: NiftiVolume, extra: URL? = nil) -> Result<FOVSet, Failure> {
        // `S_S_W.nii.gz` → tags ["S_S_W", "S_S"]; placement entries are keyed by the stitched
        // volume's tag, but the grid check is what decides, so a renamed scan still matches.
        let keys = Array(SegmentationPipeline.tags(of: fileURL).reversed())
        var failure = Failure.notFound
        func attempt(_ data: Data?) -> FOVSet? {
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
        var tried = Set<String>(), best = FOVSet()
        for name in named + listed where tried.insert(name).inserted {
            if let b = attempt(read(dir.appendingPathComponent(name))), b.boxes.count > best.boxes.count { best = b }
        }
        if best.isEmpty, let extra, let b = attempt(read(extra)) { best = b }
        return best.isEmpty ? .failure(failure) : .success(best)
    }

    static func boxes(json data: Data, keys: [String], volume: NiftiVolume) -> Result<FOVSet, Failure> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stations = json["stations"] as? [[String: Any]] else { return .failure(.noGeometry) }
        let found = boxes(stations: stations, studies: json["studies"] as? [[String: Any]] ?? [], keys: keys, volume: volume)
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

    /// The session a station was acquired in. Stations name their study by UID (DICOM-sourced
    /// metadata) or only by role (NIfTI-sourced); either way the role matches a `studies` entry.
    private static func sessionKey(_ s: [String: Any]) -> String {
        (s["StudyInstanceUID"] as? String) ?? (s["role"] as? String) ?? (s["FrameOfReferenceUID"] as? String) ?? ""
    }

    static func boxes(stations: [[String: Any]], studies: [[String: Any]] = [], keys: [String], volume: NiftiVolume) -> FOVSet {
        let fileDims = (0..<3).map { a in [volume.dims.0, volume.dims.1, volume.dims.2][volume.filePerm.firstIndex(of: a)!] }
        var seen = Set<String>(), out = [FOVBox]()
        var sessionKeys = [String](), sessionNames = [String: String]()
        for s in stations {
            // Every Dixon contrast of a station shares its geometry: keep one per session + step.
            let role = s["role"] as? String ?? "", step = (s["step"] as? Int) ?? 0, key = sessionKey(s)
            guard seen.insert("\(key)#\(step)").inserted,
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
            if !sessionKeys.contains(key) { sessionKeys.append(key); sessionNames[key] = role }
            out.append(FOVBox(label: "\(step)", lo: lo, hi: hi, session: sessionKeys.firstIndex(of: key)!))
        }
        let sessions = sessionKeys.enumerated().map { i, key in
            let study = studies.first { ($0["StudyInstanceUID"] as? String) == key || ($0["role"] as? String) == sessionNames[key] }
            let name = (sessionNames[key]).flatMap { $0.isEmpty ? nil : $0 } ?? "Session \(i + 1)"
            return FOVSession(name: name.prefix(1).uppercased() + name.dropFirst(), date: study.flatMap(studyDate),
                              stationCount: out.filter { $0.session == i }.count)
        }
        return FOVSet(boxes: out, sessions: sessions)
    }

    /// "2021-11-16 09:42" from DICOM StudyDate (yyyyMMdd) and StudyTime (HHmmss…).
    private static func studyDate(_ study: [String: Any]) -> String? {
        guard let d = study["StudyDate"] as? String, d.count == 8 else { return nil }
        var out = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
        if let t = study["StudyTime"] as? String, t.count >= 4 { out += " \(t.prefix(2)):\(t.dropFirst(2).prefix(2))" }
        return out
    }
}
