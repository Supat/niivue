//
//  ViewerViewModel.swift — what the viewer shows: plane, slice positions, window, 3D
//  settings. Lives outside ViewerView's @State so scrubbing and windowing invalidate only
//  the small views that read them, not the toolbar tree.
//

import Foundation
import Observation

@Observable @MainActor final class ViewerViewModel {
    let volume: NiftiVolume
    let segmentation: SegmentationViewModel
    let bodyComposition = BodyCompositionViewModel()

    // Opens in 3D. Launch argument `-plane Axial` (etc.) picks another view, for simulator checks.
    var plane = Plane(rawValue: UserDefaults.standard.string(forKey: "plane") ?? "") ?? .render
    var slices: [Int]
    var multiZoom: CGFloat = 1        // zoom shared by the multiplanar slice panes
    var multiZoomAnimated = false     // whether the last change came from an animated (double-tap) zoom
    var lo: Float
    var hi: Float
    // Remembered across documents and launches.
    var mirrored = UserDefaults.standard.bool(forKey: "mirrored") {
        didSet { UserDefaults.standard.set(mirrored, forKey: "mirrored") }
    }
    var renderMode = RenderMode(rawValue: UserDefaults.standard.string(forKey: "renderMode") ?? "") ?? .volume {
        didSet { UserDefaults.standard.set(renderMode.rawValue, forKey: "renderMode") }
    }
    // Up to ClipSetting.maxCount clip planes. `-clip Axial,Sagittal` and `-clipTilt 30` preset them for checks.
    var clips: [ClipSetting] = (UserDefaults.standard.string(forKey: "clip") ?? "").split(separator: ",")
        .compactMap { ClipSetting.Plane(rawValue: String($0)) }.prefix(ClipSetting.maxCount)
        .map { ClipSetting(plane: $0, tilt: SIMD2(UserDefaults.standard.float(forKey: "clipTilt"), 0)) }
    /// Remove only the corner between the planes instead of everything beyond each one.
    var clipCutaway = UserDefaults.standard.bool(forKey: "clipCutaway") // `-clipCutaway YES` for checks
    /// Draw each clip plane as a tinted, outlined sheet so its position is visible.
    var clipHighlight = UserDefaults.standard.bool(forKey: "clipHighlight") // `-clipHighlight YES` for checks
    // 3D camera preset request: RenderView applies `preset` whenever `presetTick` changes.
    var preset: ViewPreset?
    var presetTick = 0

    init(volume: NiftiVolume) {
        self.volume = volume
        segmentation = SegmentationViewModel(volume: volume)
        slices = (0..<3).map { volume.count(axis: $0) / 2 }
        lo = volume.displayMin
        hi = volume.displayMax
    }

    var dims: [Int] { [volume.dims.0, volume.dims.1, volume.dims.2] }

    func resetWindow() { (lo, hi) = (volume.displayMin, volume.displayMax) }

    func stepSlice(axis: Int, by delta: Int) {
        slices[axis] = max(0, min(volume.count(axis: axis) - 1, slices[axis] + delta))
    }

    func applyPreset(_ p: ViewPreset) { preset = p; presetTick += 1 }

    /// Crosshair position as fractions of the volume along x, y, z (the current slices).
    var crosshairFractions: SIMD3<Float> {
        SIMD3((0..<3).map { (Float(slices[$0]) + 0.5) / Float(dims[$0]) })
    }

    /// Which volume axes run along a slice's columns and rows (rows go superior/anterior
    /// → inferior/posterior, i.e. the row axis is flipped); see NiftiVolume.slice.
    func sliceAxes(_ axis: Int) -> (col: Int, row: Int) { (axis == 0 ? 1 : 0, axis == 2 ? 1 : 2) }

    /// Crosshair in a slice pane as fractions of the displayed image (x right, y down).
    func crosshair(in axis: Int) -> CGPoint {
        let (c, r) = sliceAxes(axis)
        let u = (CGFloat(slices[c]) + 0.5) / CGFloat(dims[c])
        let v = 1 - (CGFloat(slices[r]) + 0.5) / CGFloat(dims[r])
        return CGPoint(x: mirrored ? 1 - u : u, y: v)
    }

    /// Tap in a slice pane at image fractions `p`: move the other two slices to that voxel.
    func locate(_ p: CGPoint, in axis: Int) {
        let (c, r) = sliceAxes(axis)
        let u = mirrored ? 1 - p.x : p.x
        slices[c] = max(0, min(dims[c] - 1, Int(u * CGFloat(dims[c]))))
        slices[r] = max(0, min(dims[r] - 1, Int((1 - p.y) * CGFloat(dims[r]))))
    }

    /// One scale for the multiplanar panes: the envelope of the three slice extents (mm).
    var sliceEnvelope: CGSize {
        let e = (0..<3).map(volume.sliceExtent)
        return CGSize(width: CGFloat(e.map(\.0).max()!), height: CGFloat(e.map(\.1).max()!))
    }

    // MARK: Clip planes

    func addClip() {
        guard clips.count < ClipSetting.maxCount else { return }
        // Start with an orientation that isn't in use yet.
        let unused = ClipSetting.Plane.allCases.first { p in !clips.contains { $0.plane == p } }
        clips.append(ClipSetting(plane: unused ?? .sagittal))
    }

    func removeClip(id: UUID) { clips.removeAll { $0.id == id } }
}
