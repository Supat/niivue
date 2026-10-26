//
//  ViewerTypes.swift — value types the viewer is configured with.
//

import Foundation
import simd

/// What the canvas shows.
enum Plane: String, CaseIterable, Identifiable {
    case render = "3D", multi = "Multi", axial = "Axial", coronal = "Coronal", sagittal = "Sagittal", oblique = "Oblique" // picker order
    var id: Self { self }
    /// Volume axis the plane is perpendicular to; nil for the 3D render, the multiplanar grid
    /// and the oblique slice.
    var axis: Int? { [.sagittal: 0, .coronal: 1, .axial: 2][self] }
    /// One slice: an axis plane or the oblique one.
    var isSlice: Bool { axis != nil || self == .oblique }
}

/// The Oblique view's plane: an anatomical plane tilted and slid, as a 3D clip plane is.
struct ObliquePlane: Equatable {
    var base: ClipSetting.Plane = .axial
    var tilt = SIMD2<Float>(0, 0)   // degrees, as ClipSetting.tilt
    var pos: Float = 0.5            // 0...1 across the volume, along the plane normal

    /// Where the plane cuts a volume of `dims` voxels of `voxelSize` mm, and the pixel grid
    /// to draw it on: every pixel `pitch` mm square (the smallest voxel side, coarser only
    /// when the plane would exceed `maxPixels`), the grid wide and high enough for the whole
    /// volume at any tilt, so the image doesn't jump in size as the plane turns.
    func frame(dims: (Int, Int, Int), voxelSize: (Float, Float, Float), maxPixels: Float = 600_000) -> ObliqueFrame {
        let o = base.orientation(tilt: tilt)
        let half = SIMD3(Float(dims.0) * voxelSize.0, Float(dims.1) * voxelSize.1, Float(dims.2) * voxelSize.2) / 2
        let hu = dot(abs(o.u), half), hv = dot(abs(o.v), half), depth = 2 * dot(abs(o.normal), half)
        let pitch = max(min(voxelSize.0, voxelSize.1, voxelSize.2), (4 * hu * hv / maxPixels).squareRoot())
        return ObliqueFrame(centre: half + o.normal * ((pos - 0.5) * depth), normal: o.normal, u: o.u, v: o.v, pitch: pitch,
                            width: max(1, Int((2 * hu / pitch).rounded(.up))), height: max(1, Int((2 * hv / pitch).rounded(.up))), depth: depth)
    }

    /// The plane through a line drawn on a slice perpendicular to `viewAxis`, from `a` to `b`
    /// (mm, volume corner at the origin): it holds the line and the view axis. On an axial
    /// slice the line runs across the oblique image with superior up (the line's anterior end
    /// to the right); on a coronal or sagittal slice the line runs up it, superior end up,
    /// with A–P or L–R across. The tilts come out within ±90°.
    static func through(_ a: SIMD3<Float>, _ b: SIMD3<Float>, viewAxis: Int, dims: (Int, Int, Int), voxelSize: (Float, Float, Float)) -> ObliquePlane? {
        let d = b - a
        guard length(d) > 0 else { return nil }
        var s = normalize(d)
        var plane = ObliquePlane()
        let deg = Float(180 / Double.pi)
        switch viewAxis {
        case 2: // sagittal plane turned about S–I: u = (−sin β, cos β, 0) = s
            if s.y < 0 { s = -s }
            plane = ObliquePlane(base: .sagittal, tilt: SIMD2(0, atan2(-s.x, s.y) * deg))
        case 1: // sagittal plane turned about A–P: v = (sin α, 0, cos α) = s
            if s.z < 0 { s = -s }
            plane = ObliquePlane(base: .sagittal, tilt: SIMD2(atan2(s.x, s.z) * deg, 0))
        default: // coronal plane turned about L–R: v = (0, −sin β, cos β) = s
            if s.z < 0 { s = -s }
            plane = ObliquePlane(base: .coronal, tilt: SIMD2(0, atan2(-s.y, s.z) * deg))
        }
        // Slide it through the line's midpoint.
        let f = plane.frame(dims: dims, voxelSize: voxelSize)
        let half = SIMD3(Float(dims.0) * voxelSize.0, Float(dims.1) * voxelSize.1, Float(dims.2) * voxelSize.2) / 2
        plane.pos = min(1, max(0, 0.5 + dot((a + b) / 2 - half, f.normal) / f.depth))
        return plane
    }
}

/// An oblique slice placed in a volume (mm, the volume's corner at the origin; x right,
/// y anterior, z superior): pixel (c, r), row 0 at the top, is at
/// `centre + u·((c + 0.5) − width/2)·pitch + v·(height/2 − (r + 0.5))·pitch`.
struct ObliqueFrame: Equatable {
    var centre, normal, u, v: SIMD3<Float>
    var pitch: Float        // mm per pixel, both ways
    var width, height: Int
    var depth: Float        // the volume's extent along the normal (mm)
}

/// How the 3D view draws the volume.
enum RenderMode: String, CaseIterable, Identifiable {
    case volume = "Volume", mip = "MIP", surface = "Surface" // picker order
    var id: Self { self }
    /// `Uniforms.mode` in Raycaster.metal.
    var shaderMode: Int32 { self == .mip ? 0 : self == .volume ? 1 : 2 }
}

/// One clip plane for the 3D view: perpendicular to an anatomical axis, then tilted.
struct ClipSetting: Identifiable, Equatable {
    enum Plane: String, CaseIterable, Identifiable {
        case sagittal = "Sagittal", coronal = "Coronal", axial = "Axial"
        var id: Self { self }
        var axis: Int32 { [.sagittal: 0, .coronal: 1, .axial: 2][self]! }
        /// The plane tilted by `tilt` (degrees, about the two axes after its own, cyclically
        /// x→y→z→x): its normal, and the in-plane directions along a slice's columns (screen
        /// right) and up its rows (screen up), the axes NiftiVolume.slice lays a slice out on.
        func orientation(tilt: SIMD2<Float>) -> (normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) {
            func unit(_ i: Int) -> SIMD3<Float> { var e = SIMD3<Float>.zero; e[i % 3] = 1; return e }
            let a = Int(axis), t = tilt * (.pi / 180)
            let q = simd_quatf(angle: t.y, axis: unit(a + 2)) * simd_quatf(angle: t.x, axis: unit(a + 1))
            return (q.act(unit(a)), q.act(unit(a == 0 ? 1 : 0)), q.act(unit(a == 2 ? 1 : 2)))
        }
    }
    /// Matches `float4 clips[6]` in Raycaster.metal.
    static let maxCount = 6
    /// Highlight colour per plane slot (0...1 RGB); mirrors kClipColors in Raycaster.metal.
    static let colors: [SIMD3<Float>] = [
        [1.00, 0.27, 0.23], [0.20, 0.78, 0.35], [0.04, 0.52, 1.00],
        [1.00, 0.80, 0.00], [0.75, 0.35, 0.95], [0.39, 0.82, 1.00],
    ]
    let id = UUID()
    var plane: Plane
    var pos: Float = 0.5            // 0...1 across the volume, along the plane normal
    var flip = false
    var enabled = true              // off = keeps its settings and slot but has no effect
    var tilt = SIMD2<Float>(0, 0)   // degrees, about the two axes after the plane's own (cyclic x→y→z)
}

/// Anatomical camera presets. Yaw/pitch place the camera on that side of the patient;
/// `level` keeps the line of sight and only puts superior up again (after rolling).
enum ViewPreset: String, CaseIterable, Identifiable {
    case anterior = "Anterior", posterior = "Posterior", left = "Left", right = "Right"
    case superior = "Superior", inferior = "Inferior"
    case level = "Level"
    var id: Self { self }
    static let sides: [ViewPreset] = allCases.filter { $0 != .level }
    var angles: (yaw: Float, pitch: Float) {
        let pole = Float.pi / 2 - 0.001 // just shy of straight down: keeps "up" defined
        switch self {
        case .level: return (0, 0) // not a side: see RenderView
        case .anterior: return (.pi, 0)
        case .posterior: return (0, 0)
        case .left: return (-.pi / 2, 0)
        case .right: return (.pi / 2, 0)
        case .superior: return (0, pole)   // anterior at the top of the screen
        case .inferior: return (0, -pole)
        }
    }
}
