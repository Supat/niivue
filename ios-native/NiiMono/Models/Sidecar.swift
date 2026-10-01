//
//  Sidecar.swift — what the app remembers about a scan between openings: the inspector
//  settings, the segmentation maps, and where the companion Dixon images are.
//  Stored as `<scan>.niimono/settings.json` plus `shown.nii.gz` / `kept.nii.gz`.
//

import Foundation

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

struct SidecarSettings: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var role: ImageRole

    struct Viewer: Codable, Equatable {
        var plane: String, slices: [Int], lo: Float, hi: Float, mirrored: Bool, renderMode: String
        struct Clip: Codable, Equatable { var plane: String, pos: Float, flip: Bool, tilt: [Float] }
        var clips: [Clip], clipCutaway: Bool, clipHighlight: Bool
        var cameraClip: Bool?, cameraClipDepth: Float? // absent in older sidecars
    }
    var viewer: Viewer

    struct Segmentation: Codable, Equatable {
        var visible: [Bool], opacity: Float, ghost: Bool
        /// Original file / generated names of the shown and kept maps (the label table is
        /// picked from the name); the voxels live in shown.nii.gz / kept.nii.gz beside this file.
        var shownName: String?, keptName: String?
    }
    var segmentation: Segmentation

    /// A companion image: its file name and a bookmark that re-grants access to it.
    struct Companion: Codable, Equatable { var name: String, bookmark: Data }
    var water: Companion?, fat: Companion?

    struct Body: Codable, Equatable { var weightKg: Double, missing: [String], thighsMissingPercent: Double }
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
