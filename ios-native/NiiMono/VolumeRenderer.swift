//
//  VolumeRenderer.swift — Metal renderer for a NiftiVolume (MIP raycast).
//  No webview, no GL. Uploads the volume as a 3D texture and draws a fullscreen
//  triangle that ray-marches it in Raycaster.metal.
//

import Accelerate
import MetalKit
import simd

// Mirrors `Uniforms` in Raycaster.metal. simd_float3 is 16-byte aligned in both
// Swift and MSL, so field offsets line up — keep them in sync if you edit either.
struct Uniforms {
    var invViewProj: simd_float4x4
    var camPos: simd_float3
    var boxHalf: simd_float3
    var clipNormal: simd_float3
    var dataMin: Float
    var dataMax: Float
    var steps: Int32
    var mode: Int32
    var clipOn: Int32
    var clipOffset: Float
}

final class VolumeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let volumeTex: MTLTexture
    private let cmapTex: MTLTexture
    private let boxHalf: simd_float3

    // Display window, normalized to the volume's full intensity range (0...1).
    var windowLo: Float = 0
    var windowHi: Float = 1
    var mode: Int32 = 0 // RenderMode.shaderMode
    var clipAxis: Int32 = -1 // -1 = off, else the axis the untilted plane is perpendicular to
    var clipFlip = false
    var clipPos: Float = 0.5 // 0...1 across the volume, along the plane normal
    var clipTilt = simd_float2.zero // radians, about the two axes following clipAxis (cyclic)

    // Orbit camera (z-up, matching the RAS volume), driven by RenderView gestures.
    private static let startYaw: Float = .pi - 0.6 // in front of the face, slightly to one side
    private static let startPitch: Float = 0.3
    private static let fovY: Float = .pi / 4
    var yaw = startYaw
    var pitch = startPitch
    var zoom: Float = 1 // 1 = volume fills the view at the starting orientation
    var target = simd_float3.zero // point the camera orbits and looks at
    var steps: Int32 = 384

    init(view: MTKView, volume: NiftiVolume) {
        guard let device = view.preferredDevice ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            fatalError("Metal unavailable")
        }
        self.device = device
        self.queue = queue
        view.device = device
        view.colorPixelFormat = .bgra8Unorm

        // Pipeline
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vtx")
        desc.fragmentFunction = library.makeFunction(name: "frag")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        // Sampler: linear, clamp (so rays leaving the box read black edges).
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToZero; sd.tAddressMode = .clampToZero; sd.rAddressMode = .clampToZero
        sampler = device.makeSamplerState(descriptor: sd)!

        // 3D volume texture, normalized to r16Unorm: linearly filterable on every GPU
        // (r32Float filtering is optional) and half the memory.
        let (nx, ny, nz) = volume.dims
        let td = MTLTextureDescriptor()
        td.textureType = .type3D
        td.pixelFormat = .r16Unorm
        td.width = nx; td.height = ny; td.depth = nz
        td.usage = .shaderRead
        let tex = device.makeTexture(descriptor: td)!
        volumeTex = tex
        // Float → UInt16 with vDSP, one z-slice at a time: a plain Swift loop over a
        // whole-body volume (60M+ voxels) blocks the main thread for seconds in Debug,
        // and slice-sized scratch buffers avoid a second full-volume copy.
        var k = 65535 / max(volume.dataMax - volume.dataMin, .leastNonzeroMagnitude)
        var bias = -volume.dataMin * k
        let n = nx * ny
        var scaled = [Float](repeating: 0, count: n)
        var texels = [UInt16](repeating: 0, count: n)
        volume.data.withUnsafeBufferPointer { src in
            for z in 0..<nz {
                vDSP_vsmsa(src.baseAddress! + z * n, 1, &k, &bias, &scaled, 1, vDSP_Length(n))
                vDSP_vfixru16(scaled, 1, &texels, 1, vDSP_Length(n))
                tex.replace(region: MTLRegionMake3D(0, 0, z, nx, ny, 1), mipmapLevel: 0, slice: 0,
                            withBytes: texels, bytesPerRow: nx * 2, bytesPerImage: n * 2)
            }
        }

        // Colormap: grayscale 256. ponytail: niivue's 73 JSON cmaps drop straight
        // in here — load R/G/B arrays into this 1D texture, nothing else changes.
        let cd = MTLTextureDescriptor()
        cd.textureType = .type1D; cd.pixelFormat = .rgba8Unorm; cd.width = 256
        cd.usage = .shaderRead
        cmapTex = device.makeTexture(descriptor: cd)!
        var lut = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<256 { lut[i*4] = UInt8(i); lut[i*4+1] = UInt8(i); lut[i*4+2] = UInt8(i); lut[i*4+3] = 255 }
        cmapTex.replace(region: MTLRegionMake1D(0, 256), mipmapLevel: 0, withBytes: lut, bytesPerRow: 256 * 4)

        // Volume box: half-extents proportional to physical size, normalized so the
        // largest axis is 1.0 — keeps anisotropic voxels in correct proportion.
        let phys = simd_float3(Float(nx) * volume.voxelSize.0,
                               Float(ny) * volume.voxelSize.1,
                               Float(nz) * volume.voxelSize.2)
        boxHalf = 0.5 * phys / max(phys.x, max(phys.y, phys.z))
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        var u = makeUniforms(aspect: aspect)

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(volumeTex, index: 0)
        enc.setFragmentTexture(cmapTex, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func makeUniforms(aspect: Float) -> Uniforms {
        let eye = target + distance(aspect: aspect) * Self.direction(yaw: yaw, pitch: pitch)
        let view = lookAt(eye: eye, center: target, up: simd_float3(0, 0, 1))
        let proj = perspective(fovy: Self.fovY, aspect: aspect, near: 0.05, far: 100)
        let invVP = (proj * view).inverse
        // Clip plane normal: the chosen axis, tilted about the other two. Depth runs along
        // the normal across the box's full extent in that direction, so the slider always
        // sweeps the whole volume whatever the tilt. Flip = same plane, opposite side kept.
        var normal = simd_float3(1, 0, 0), offset: Float = 0
        if clipAxis >= 0 {
            func unit(_ i: Int) -> simd_float3 { var v = simd_float3.zero; v[i % 3] = 1; return v }
            let a = Int(clipAxis)
            normal = simd_quatf(angle: clipTilt.y, axis: unit(a + 2)).act(
                simd_quatf(angle: clipTilt.x, axis: unit(a + 1)).act(unit(a)))
            offset = (clipPos - 0.5) * 2 * dot(abs(normal), boxHalf)
            if clipFlip { normal = -normal; offset = -offset }
        }
        return Uniforms(invViewProj: invVP, camPos: eye, boxHalf: boxHalf, clipNormal: normal,
                        dataMin: windowLo, dataMax: windowHi, steps: steps, mode: mode,
                        clipOn: clipAxis >= 0 ? 1 : 0, clipOffset: offset)
    }
}

extension VolumeRenderer {
    /// Unit vector from the volume centre towards the camera (z-up).
    fileprivate static func direction(yaw: Float, pitch: Float) -> simd_float3 {
        simd_float3(cos(pitch) * sin(yaw), -cos(pitch) * cos(yaw), sin(pitch))
    }

    fileprivate func distance(aspect: Float) -> Float { fitDistance(aspect: aspect) / zoom }

    /// Screen-right, screen-up and towards-the-viewer unit vectors in volume (RAS) space.
    var basis: (right: simd_float3, up: simd_float3, toward: simd_float3) {
        let e = Self.direction(yaw: yaw, pitch: pitch)
        let right = normalize(cross(-e, simd_float3(0, 0, 1)))
        return (right, cross(right, -e), e)
    }

    /// World-space offset on the plane through `target` for a screen offset in NDC (-1...1).
    private func planeOffset(_ ndc: simd_float2, aspect: Float, distance: Float) -> simd_float3 {
        let tanV = tan(Self.fovY / 2), b = basis
        return (b.right * ndc.x * tanV * aspect + b.up * ndc.y * tanV) * distance
    }

    func orbit(dx: Float, dy: Float) {
        yaw += dx * 0.01
        pitch = max(-1.5, min(1.5, pitch + dy * 0.01))
    }

    /// Slide the volume with the fingers; `delta` is the drag in NDC.
    func pan(byNDC delta: simd_float2, aspect: Float) {
        target -= planeOffset(delta, aspect: aspect, distance: distance(aspect: aspect))
        target = simd_clamp(target, -boxHalf, boxHalf) // can't lose the volume off-screen
    }

    /// Zoom keeping the point under `ndc` (pinch centre / pointer) fixed on screen.
    func zoom(by scale: Float, atNDC ndc: simd_float2, aspect: Float) {
        let d0 = distance(aspect: aspect)
        zoom = max(0.5, min(20, zoom * scale))
        target += planeOffset(ndc, aspect: aspect, distance: d0 - distance(aspect: aspect))
        target = simd_clamp(target, -boxHalf, boxHalf)
    }

    /// Standard view, re-fitted and re-centred. nil = the starting view.
    func setView(yaw: Float? = nil, pitch: Float? = nil) {
        self.yaw = yaw ?? Self.startYaw
        self.pitch = pitch ?? Self.startPitch
        zoom = 1
        target = .zero
    }

    /// Closest camera distance at which all eight corners of the volume box are inside
    /// the frustum. Evaluated at the starting orientation (not the live one) so the
    /// image fills the view on entry and after a resize, but doesn't pulse while orbiting.
    fileprivate func fitDistance(aspect: Float) -> Float {
        let e = Self.direction(yaw: Self.startYaw, pitch: Self.startPitch)
        let right = normalize(cross(-e, simd_float3(0, 0, 1))), up = cross(right, -e)
        let tanV = tan(Self.fovY / 2), tanH = tanV * max(aspect, 0.01)
        var d: Float = 0
        for i in 0..<8 {
            let c = boxHalf * simd_float3(i & 1 == 0 ? -1 : 1, i & 2 == 0 ? -1 : 1, i & 4 == 0 ? -1 : 1)
            d = max(d, abs(dot(c, up)) / tanV + dot(c, e), abs(dot(c, right)) / tanH + dot(c, e))
        }
        return d * 1.03 // small margin
    }
}

// MARK: - SwiftUI host

import SwiftUI

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

struct RenderView: UIViewRepresentable {
    let volume: NiftiVolume
    let lo: Float
    let hi: Float
    let mode: RenderMode
    let clip: ClipPlane
    let clipPos: Float
    let clipFlip: Bool
    let clipTilt: SIMD2<Float> // degrees
    /// Latest preset request; applied when `presetTick` changes.
    let preset: ViewPreset?
    let presetTick: Int
    let onTap: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: VolumeRenderer?
        var onTap: () -> Void = {}
        var presetTick = 0
        let gizmo = OrientationGizmo()
        let orbit = UIPanGestureRecognizer()
        let mousePan = UIPanGestureRecognizer()

        /// Redraw the volume and the orientation indicator after any camera change.
        func cameraChanged(_ view: UIView?) {
            if let renderer { gizmo.basis = renderer.basis }
            view?.setNeedsDisplay()
        }

        private func aspect(_ v: UIView) -> Float { Float(v.bounds.width / max(v.bounds.height, 1)) }
        private func ndc(_ p: CGPoint, in v: UIView) -> simd_float2 {
            simd_float2(Float(2 * p.x / max(v.bounds.width, 1) - 1), Float(1 - 2 * p.y / max(v.bounds.height, 1)))
        }

        @objc func tapped() { onTap() }

        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            renderer?.setView()
            cameraChanged(g.view)
        }

        @objc func orbited(_ g: UIPanGestureRecognizer) {
            guard let renderer, let view = g.view else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            renderer.orbit(dx: Float(t.x), dy: Float(t.y))
            cameraChanged(view)
        }

        /// Two-finger drag, or secondary-button drag with a mouse/trackpad.
        @objc func panned(_ g: UIPanGestureRecognizer) {
            guard let renderer, let view = g.view else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            let delta = simd_float2(Float(2 * t.x / max(view.bounds.width, 1)), Float(-2 * t.y / max(view.bounds.height, 1)))
            renderer.pan(byNDC: delta, aspect: aspect(view))
            cameraChanged(view)
        }

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            guard let renderer, let view = g.view else { return }
            renderer.zoom(by: Float(g.scale), atNDC: ndc(g.location(in: view), in: view), aspect: aspect(view))
            g.scale = 1
            cameraChanged(view)
        }

        /// Mouse wheel / trackpad scroll zooms towards the pointer.
        @objc func scrolled(_ g: UIPanGestureRecognizer) {
            guard let renderer, let view = g.view else { return }
            let dy = Float(g.translation(in: view).y)
            g.setTranslation(.zero, in: view)
            renderer.zoom(by: exp(dy * 0.005), atNDC: ndc(g.location(in: view), in: view), aspect: aspect(view))
            cameraChanged(view)
        }

        // A secondary-button (right) drag pans; any other drag orbits.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            let secondary = event.buttonMask.contains(.secondary)
            return g === mousePan ? secondary : g === orbit ? !secondary : true
        }

        // Pinch and two-finger pan run together (zoom while sliding); orbit stays exclusive.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g !== orbit && other !== orbit
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        let c = context.coordinator
        c.renderer = VolumeRenderer(view: v, volume: volume)
        v.delegate = c.renderer
        v.enableSetNeedsDisplay = true // draw on demand, not at 60 Hz
        v.isPaused = true

        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTapped))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped))
        single.require(toFail: double)
        c.orbit.addTarget(c, action: #selector(Coordinator.orbited))
        c.orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.panned))
        pan.minimumNumberOfTouches = 2
        c.mousePan.addTarget(c, action: #selector(Coordinator.panned))
        c.mousePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scrolled))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = [] // scroll events only, never touches
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinched))
        for g in [double, single, c.orbit, pan, c.mousePan, scroll, pinch] {
            g.delegate = c
            v.addGestureRecognizer(g)
        }

        c.gizmo.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(c.gizmo)
        NSLayoutConstraint.activate([
            c.gizmo.leadingAnchor.constraint(equalTo: v.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            c.gizmo.bottomAnchor.constraint(equalTo: v.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            c.gizmo.widthAnchor.constraint(equalToConstant: 76),
            c.gizmo.heightAnchor.constraint(equalToConstant: 76),
        ])
        return v
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        guard let renderer = c.renderer else { return }
        let range = max(volume.dataMax - volume.dataMin, .leastNonzeroMagnitude)
        c.onTap = onTap
        renderer.windowLo = (lo - volume.dataMin) / range
        renderer.windowHi = (hi - volume.dataMin) / range
        renderer.mode = mode == .mip ? 0 : 1
        renderer.clipAxis = clip.axis
        renderer.clipPos = clipPos
        renderer.clipFlip = clipFlip
        renderer.clipTilt = clipTilt * (.pi / 180)
        if presetTick != c.presetTick, let preset {
            renderer.setView(yaw: preset.angles.yaw, pitch: preset.angles.pitch)
        }
        c.presetTick = presetTick
        c.cameraChanged(view)
    }
}

/// Small axis indicator: the six anatomical directions drawn from a common centre,
/// rotating with the camera. Directions pointing towards the viewer are brighter.
final class OrientationGizmo: UIView {
    var basis: (right: simd_float3, up: simd_float3, toward: simd_float3) =
        (simd_float3(1, 0, 0), simd_float3(0, 0, 1), simd_float3(0, -1, 0)) { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let axes: [(String, simd_float3)] = [("R", simd_float3(1, 0, 0)), ("L", simd_float3(-1, 0, 0)),
                                             ("A", simd_float3(0, 1, 0)), ("P", simd_float3(0, -1, 0)),
                                             ("S", simd_float3(0, 0, 1)), ("I", simd_float3(0, 0, -1))]
        let centre = CGPoint(x: bounds.midX, y: bounds.midY), length = bounds.width / 2 - 10
        // Far-to-near so nearer labels draw on top.
        for (name, axis) in axes.sorted(by: { dot($0.1, basis.toward) < dot($1.1, basis.toward) }) {
            let depth = CGFloat(dot(axis, basis.toward)) // -1 away ... +1 towards viewer
            let color = UIColor.white.withAlphaComponent(0.25 + 0.3 * (depth + 1) / 2)
            let tip = CGPoint(x: centre.x + CGFloat(dot(axis, basis.right)) * length,
                              y: centre.y - CGFloat(dot(axis, basis.up)) * length)
            let line = UIBezierPath()
            line.move(to: centre)
            line.addLine(to: CGPoint(x: centre.x + (tip.x - centre.x) * 0.72, y: centre.y + (tip.y - centre.y) * 0.72))
            color.setStroke()
            line.stroke()
            let text = NSAttributedString(string: name, attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color])
            let size = text.size()
            text.draw(at: CGPoint(x: tip.x - size.width / 2, y: tip.y - size.height / 2))
        }
    }
}

// MARK: - simd matrix helpers (right-handed)

func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovy * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(columns: (
        simd_float4(x, 0, 0, 0),
        simd_float4(0, y, 0, 0),
        simd_float4(0, 0, z, -1),
        simd_float4(0, 0, z * near, 0)
    ))
}

func lookAt(eye: simd_float3, center: simd_float3, up: simd_float3) -> simd_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return simd_float4x4(columns: (
        simd_float4(s.x, u.x, -f.x, 0),
        simd_float4(s.y, u.y, -f.y, 0),
        simd_float4(s.z, u.z, -f.z, 0),
        simd_float4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
    ))
}
