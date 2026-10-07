//
//  Sidecar.swift — what the app remembers about a scan between openings: the inspector
//  settings, the segmentation maps, and where the companion Dixon images are.
//  Stored as `<scan>.niimono/settings.json` plus `shown.nii.gz` / `kept.nii.gz` / `kept2.nii.gz`.
//

import Foundation

/// The other two Dixon images, which the segmentation editor can show instead of the scan.
enum PhaseImage: String, CaseIterable, Identifiable {
    case inPhase = "In-phase", opposed = "Opposed-phase"
    var id: Self { self }
    /// File-name suffix beside the scan's tag (`S_S_in.nii.gz`, `S_S_opp.nii.gz`).
    var suffix: String { self == .inPhase ? "in" : "opp" }
}

/// Which Dixon contrast the opened file is; decides which companion images are needed.
enum ImageRole: String, Codable, CaseIterable, Identifiable {
    case water = "Water", fat = "Fat", other = "Other"
    var id: Self { self }

    /// Inferred from the Dixon suffix in the file name.
    static func inferred(from fileURL: URL) -> ImageRole {
        let n = fileURL.lastPathComponent
        return n.contains("_W.nii") ? .water : n.contains("_F.nii") ? .fat : .other
    }
}

/// A saved slice position (the x, y, z slice indices), recalled in every slice view.
struct SliceBookmark: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var slices: [Int]
}

struct SidecarSettings: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var role: ImageRole

    struct Viewer: Codable, Equatable {
        var plane: String, slices: [Int], lo: Float, hi: Float, mirrored: Bool, renderMode: String
        struct Clip: Codable, Equatable { var plane: String, pos: Float, flip: Bool, tilt: [Float]; var enabled: Bool? } // enabled absent in older sidecars
        var clips: [Clip], clipCutaway: Bool, clipHighlight: Bool
        var cameraClip: Bool?, cameraClipDepth: Float? // absent in older sidecars
        var bookmarks: [SliceBookmark]? // absent in older sidecars
        /// A noise mask is saved (noise.nii.gz), and whether it is applied.
        var noise: Bool?, removeNoise: Bool?
        /// A banding repair mask is saved (repair.nii.gz).
        var repair: Bool?
        var clipKeepSegments: Bool? // absent in older sidecars
    }
    var viewer: Viewer

    struct Segmentation: Codable, Equatable {
        var visible: [Bool], opacity: Float, ghost: Bool
        var mask: Bool? // absent in older sidecars
        /// Original file / generated names of the shown and kept maps (the label table is
        /// picked from the name); the voxels live in shown.nii.gz / kept.nii.gz / kept2.nii.gz beside this file.
        var shownName: String?, keptName: String?
        var kept2Name: String? // a third map (the drawing beside both generated maps); absent in older sidecars
        var customLabels: [CustomLabel]? // the drawn map's label names; absent in older sidecars
    }
    var segmentation: Segmentation

    /// A companion image: its file name and a bookmark that re-grants access to it.
    struct Companion: Codable, Equatable { var name: String, bookmark: Data }
    var water: Companion?, fat: Companion?
    /// The Dixon in-phase and opposed-phase images, when added (for spotting cavities while
    /// drawing); absent in older sidecars.
    var inPhase: Companion?, opposed: Companion?

    struct Body: Codable, Equatable {
        var weightKg: Double, missing: [String], thighsMissingPercent: Double
        var heightCm: Double?, ageYears: Double?, subjectID: String? // absent in older sidecars
    }
    var body: Body
}

extension SidecarSettings.Companion {
    init?(url: URL) {
        guard let data = try? url.bookmarkData() else { return nil }
        self.init(name: url.lastPathComponent, bookmark: data)
    }

    func resolve() -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
