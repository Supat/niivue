//
//  ProfileViewModel.swift — the subject's own photos, one from each side of each
//  anatomical view, kept in the scan's sidecar as `profile-<view>.jpg` (e.g. `profile-axial-top.jpg`).
//

import Observation
import UIKit

/// The view a profile photo shows the subject from.
enum ProfileView: String, CaseIterable, Identifiable {
    case axialTop = "Axial Top", axialBottom = "Axial Bottom"
    case coronalFront = "Coronal Front", coronalBack = "Coronal Back"
    case sagittalLeft = "Sagittal Left", sagittalRight = "Sagittal Right"
    var id: Self { self }
    /// The photo shown beside a slice: the side of the subject that slice is seen from.
    static func paired(axis: Int, mirrored: Bool) -> ProfileView {
        switch axis {
        case 0: mirrored ? .sagittalLeft : .sagittalRight
        case 1: mirrored ? .coronalFront : .coronalBack
        default: mirrored ? .axialBottom : .axialTop
        }
    }

    var fileName: String { "profile-\(rawValue.lowercased().replacingOccurrences(of: " ", with: "-")).jpg" }
}

@Observable @MainActor final class ProfileViewModel {
    private(set) var photos: [ProfileView: UIImage] = [:]
    /// The person found in each photo (Vision), for the check mark and the side-by-side
    /// alignment; no entry when nobody was detected.
    private(set) var landmarks: [ProfileView: PhotoLandmarks] = [:]
    private(set) var error: String?
    private let sidecar: SidecarStore?
    /// Longest side of a stored photo, in pixels: plenty for the panel, small in the sidecar.
    private static let maxSide: CGFloat = 2048

    init(sidecar: SidecarStore?) { self.sidecar = sidecar }

    /// Photos already in the sidecar, read on open.
    func restore() async {
        guard let sidecar else { return }
        let found = await Task.detached(priority: .utility) {
            ProfileView.allCases.compactMap { view in sidecar.loadPhoto(view.fileName).map { (view, $0) } }
        }.value
        for (view, data) in found {
            guard let image = UIImage(data: data) else { continue }
            photos[view] = image
            await detectBody(in: image, for: view)
        }
    }

    /// Set (or, with nil, remove) the photo for a view and write the change to the sidecar.
    func set(_ image: UIImage?, for view: ProfileView) async {
        error = nil
        let stored = image.map(Self.fitted)
        photos[view] = stored
        landmarks[view] = nil
        if let stored { await detectBody(in: stored, for: view) }
        guard let sidecar else { return }
        let data = stored?.jpegData(compressionQuality: 0.9)
        let name = view.fileName
        do {
            try await Task.detached(priority: .utility) { try sidecar.savePhoto(data, name: name) }.value
        } catch {
            self.error = "Couldn't save the photo: \(error.localizedDescription)"
        }
    }

    func setError(_ message: String) { error = message }

    /// After the sidecar folder was deleted.
    func clear() { photos = [:]; landmarks = [:]; error = nil }

    /// Not stored: the check is quick and is redone whenever a photo is set or restored.
    private func detectBody(in image: UIImage, for view: ProfileView) async {
        guard let cg = image.cgImage else { return }
        let found = await Task.detached(priority: .utility) { ProfileAlignment.photoLandmarks(cg) }.value
        // The photo may have been replaced or removed while this ran.
        if let found, photos[view] === image { landmarks[view] = found }
    }

    /// Upright, and no larger than `maxSide` on its longest side.
    private static func fitted(_ image: UIImage) -> UIImage {
        let scale = min(1, maxSide / max(image.size.width * image.scale, image.size.height * image.scale, 1))
        let size = CGSize(width: (image.size.width * image.scale * scale).rounded(), height: (image.size.height * image.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
