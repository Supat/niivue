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

    // MARK: Sessions
    //
    // Which session a station belongs to, strongest evidence first:
    //   1. its StudyInstanceUID (DICOM-sourced metadata);
    //   2. the `studies` entry whose `session_dir` its source file or folder lies in
    //      (NIfTI-sourced metadata, where every session has its own folder);
    //   3. its `role` text;
    //   4. its FrameOfReferenceUID;
    //   5. nothing: all such stations start in one unnamed group.
    // Whatever the key, a step that comes back with a different FOV starts another session
    // under the same key (two runs that share a role, or no evidence at all), while the same
    // step with the same FOV is just another Dixon contrast of that station and is skipped.
    // Names: the role, else the session folder's name, else "Session N". Where two sessions
    // would show the same name, each gets its folder appended ("Run · s01"), or failing that
    // its order of appearance among them ("Run (run 2)"). Dates: the study's StudyDate/
    // StudyTime, else the earliest AcquisitionTime/SeriesTime of its stations (time only).

    private static func sourcePath(_ s: [String: Any]) -> String? {
        (s["source_file"] as? String) ?? (s["source_dir"] as? String)
    }

    /// The `studies` entry a station belongs to, if one can be told.
    private static func study(of s: [String: Any], in studies: [[String: Any]]) -> [String: Any]? {
        if let uid = s["StudyInstanceUID"] as? String, let st = studies.first(where: { ($0["StudyInstanceUID"] as? String) == uid }) { return st }
        if let src = sourcePath(s), let st = studies.first(where: { inFolder(src, $0["session_dir"] as? String) }) { return st }
        if let role = s["role"] as? String, let st = studies.first(where: { ($0["role"] as? String) == role }) { return st }
        return nil
    }

    /// Whether `path` lies in `folder` (both as the metadata writes them: relative or absolute).
    private static func inFolder(_ path: String, _ folder: String?) -> Bool {
        guard var f = folder, !f.isEmpty else { return false }
        if !f.hasSuffix("/") { f += "/" }
        return path.hasPrefix(f) || path.contains("/" + f)
    }

    private static func sessionKey(_ s: [String: Any], studies: [[String: Any]]) -> String {
        if let uid = s["StudyInstanceUID"] as? String, !uid.isEmpty { return "uid:" + uid }
        if let src = sourcePath(s), let dir = studies.lazy.compactMap({ $0["session_dir"] as? String }).first(where: { inFolder(src, $0) }) {
            return "dir:" + dir
        }
        if let role = s["role"] as? String, !role.isEmpty { return "role:" + role }
        if let frame = s["FrameOfReferenceUID"] as? String, !frame.isEmpty { return "frame:" + frame }
        return ""
    }

    static func boxes(stations: [[String: Any]], studies: [[String: Any]] = [], keys: [String], volume: NiftiVolume) -> FOVSet {
        let fileDims = (0..<3).map { a in [volume.dims.0, volume.dims.1, volume.dims.2][volume.filePerm.firstIndex(of: a)!] }
        struct Group { let key: String; var steps: [Int: (SIMD3<Double>, SIMD3<Double>)] = [:]; var first: [String: Any] }
        var groups = [Group](), out = [FOVBox](), times = [Int: String]()
        for s in stations {
            let step = (s["step"] as? Int) ?? 0, key = sessionKey(s, studies: studies)
            guard let placements = (s["geometry"] as? [String: Any])?["placement_in_stitched_volumes"] as? [String: Any],
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
            // The first run under this key that hasn't had this step, or had it with this FOV.
            let g: Int
            if let i = groups.firstIndex(where: { $0.key == key && ($0.steps[step] == nil || $0.steps[step]! == (lo, hi)) }) {
                if groups[i].steps[step] != nil { continue } // another contrast of a station already placed
                g = i
            } else {
                groups.append(Group(key: key, first: s))
                g = groups.count - 1
            }
            groups[g].steps[step] = (lo, hi)
            if let t = clock(s["AcquisitionTime"] as? String ?? s["SeriesTime"] as? String), times[g].map({ t < $0 }) ?? true { times[g] = t }
            out.append(FOVBox(label: "\(step)", lo: lo, hi: hi, session: g))
        }
        let found = groups.enumerated().map { i, group in
            let study = study(of: group.first, in: studies)
            let role = (group.first["role"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let folder = (study?["session_dir"] as? String).map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            let name = role ?? folder ?? "Session \(i + 1)"
            return (name: name.prefix(1).uppercased() + name.dropFirst(), folder: folder, study: study)
        }
        let sessions = found.enumerated().map { i, f in
            var name = f.name
            let twins = found.indices.filter { found[$0].name == f.name }
            if twins.count > 1 {
                let folders = Set(twins.compactMap { found[$0].folder })
                if let folder = f.folder, folders.count == twins.count, folder != f.name { name += " · " + folder }
                else { name += " (run \(twins.firstIndex(of: i)! + 1))" }
            }
            return FOVSession(name: name, date: f.study.flatMap(studyDate) ?? times[i],
                              stationCount: out.filter { $0.session == i }.count)
        }
        return FOVSet(boxes: out, sessions: sessions)
    }

    /// "2021-11-16 09:42" from DICOM StudyDate (yyyyMMdd) and StudyTime (HHmmss…).
    private static func studyDate(_ study: [String: Any]) -> String? {
        guard let d = study["StudyDate"] as? String, d.count == 8 else { return nil }
        var out = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
        if let t = clock(study["StudyTime"] as? String) { out += " " + t }
        return out
    }

    /// "09:42" from a DICOM time, with or without colons ("094200.5", "09:42:00.500000").
    private static func clock(_ time: String?) -> String? {
        guard let digits = time?.filter(\.isNumber), digits.count >= 4 else { return nil }
        return "\(digits.prefix(2)):\(digits.dropFirst(2).prefix(2))"
    }
}
