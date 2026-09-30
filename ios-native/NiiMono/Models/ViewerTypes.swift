//
//  ViewerTypes.swift — value types the viewer is configured with.
//

import Foundation

/// What the canvas shows.
enum Plane: String, CaseIterable, Identifiable {
    case render = "3D", multi = "Multi", axial = "Axial", coronal = "Coronal", sagittal = "Sagittal" // picker order
    var id: Self { self }
    /// Volume axis the plane is perpendicular to; nil for the 3D render and multiplanar grid.
    var axis: Int? { [.sagittal: 0, .coronal: 1, .axial: 2][self] }
}

/// How the 3D view draws the volume.
enum RenderMode: String, CaseIterable, Identifiable {
    case volume = "Volume", mip = "MIP" // picker order
    var id: Self { self }
}

/// One clip plane for the 3D view: perpendicular to an anatomical axis, then tilted.
struct ClipSetting: Identifiable, Equatable {
    enum Plane: String, CaseIterable, Identifiable {
        case sagittal = "Sagittal", coronal = "Coronal", axial = "Axial"
        var id: Self { self }
        var axis: Int32 { [.sagittal: 0, .coronal: 1, .axial: 2][self]! }
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
    var tilt = SIMD2<Float>(0, 0)   // degrees, about the two axes after the plane's own (cyclic x→y→z)
}

/// Anatomical camera presets. Yaw/pitch place the camera on that side of the patient.
enum ViewPreset: String, CaseIterable, Identifiable {
    case anterior = "Anterior", posterior = "Posterior", left = "Left", right = "Right"
    case superior = "Superior", inferior = "Inferior"
    var id: Self { self }
    var angles: (yaw: Float, pitch: Float) {
        let pole = Float.pi / 2 - 0.001 // just shy of straight down: keeps "up" defined
        switch self {
        case .anterior: return (.pi, 0)
        case .posterior: return (0, 0)
        case .left: return (-.pi / 2, 0)
        case .right: return (.pi / 2, 0)
        case .superior: return (0, pole)   // anterior at the top of the screen
        case .inferior: return (0, -pole)
        }
    }
}
