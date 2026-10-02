//
//  VolumeRenderer.swift — Metal renderer for a NiftiVolume: uploads the volume (and any
//  segmentation) as 3D textures and draws a fullscreen triangle that ray-marches them in
//  Raycaster.metal. Camera, clip planes, crosshair and overlay are plain properties set by
//  RenderView; nothing here knows about SwiftUI.
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
    var clips: (simd_float4, simd_float4, simd_float4, simd_float4, simd_float4, simd_float4)
    var dataMin: Float
    var dataMax: Float
    var steps: Int32
    var mode: Int32
    var clipCount: Int32
    var clipCutaway: Int32
    var clipHighlight: Int32
    var crosshairOn: Int32
    var crosshair: simd_float3
    var overlayOn: Int32
    var overlayOpacity: Float
    var overlayGhost: Int32
    var cameraClip: Float
    var fovCount: Int32
}

final class VolumeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let volumeTex: MTLTexture
    private let cmapTex: MTLTexture
    private let labelLUT: MTLTexture   // 256 × RGBA, alpha 0 = hidden label
    private var labelTex: MTLTexture?  // r8Uint labels, same grid as the volume
    private let noLabels: MTLTexture   // 1×1×1 r8Uint stand-in: the slot must hold a uint texture
    private var labelSource: UUID?
    var overlayOpacity: Float = 0.65
    var overlayGhost = false
    let boxHalf: simd_float3

    // Display window, normalized to the volume's full intensity range (0...1).
    var windowLo: Float = 0
    var windowHi: Float = 1
    var mode: Int32 = 0 // RenderMode.shaderMode
    var clips: [ClipSetting] = [] // at most ClipSetting.maxCount are used
    var clipCutaway = false
    var clipHighlight = false
    var crosshair: simd_float3? // box-space point, or nil for none
    /// Station FOV boxes as [lo, hi] pairs in box space (see RenderView), drawn as wireframes.
    var fov: [simd_float4] = []
    /// Fraction of the eye→pivot distance in front of which nothing is drawn (0 = off).
    var cameraClipFraction: Float = 0
    /// Called after each on-screen frame, for overlays that follow the camera.
    var onDraw: (() -> Void)?

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
        // Apple GPUs cap 3D textures at 2048 per axis; makeTexture returns nil beyond that.
        guard let tex = device.makeTexture(descriptor: td) else {
            fatalError("volume \(nx)×\(ny)×\(nz) exceeds the GPU's 3D texture limit") // ponytail: downsample instead when such scans show up
        }
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
        labelLUT = device.makeTexture(descriptor: cd)!
        let nd = MTLTextureDescriptor()
        nd.textureType = .type3D; nd.pixelFormat = .r8Uint; nd.width = 1; nd.height = 1; nd.depth = 1; nd.usage = .shaderRead
        noLabels = device.makeTexture(descriptor: nd)!

        // Volume box: half-extents proportional to physical size, normalized so the
        // largest axis is 1.0 — keeps anisotropic voxels in correct proportion.
        let phys = simd_float3(Float(nx) * volume.voxelSize.0,
                               Float(ny) * volume.voxelSize.1,
                               Float(nz) * volume.voxelSize.2)
        boxHalf = 0.5 * phys / max(phys.x, max(phys.y, phys.z))
        super.init()
    }

    // Re-centring glide when the view's width changes (inspector opening/closing). The
    // left edge stays put, so the render's centre would jump by half the width change and
    // its size by the change in fit distance; instead these two offsets are eased between
    // "where the image was" and "where it belongs". Growing views resize at once and glide
    // from an initial offset to zero; shrinking views (see RenderHost) keep their old size
    // while the render glides to the narrower layout, then resize with no offset.
    private var lastSize = CGSize.zero
    private var glideShift: Float = 0     // horizontal offset in NDC
    private var glideScale: Float = 1     // camera distance multiplier
    private var glide: (from: SIMD2<Float>, to: SIMD2<Float>, start: CFTimeInterval, done: (() -> Void)?)?
    private var glideLink: CADisplayLink?
    private weak var glideView: MTKView?
    private var skipResizeGlide = false

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        defer { lastSize = size }
        if skipResizeGlide { skipResizeGlide = false; return }
        guard lastSize.width > 0, size.width > 0, size.height > 0,
              lastSize.height == size.height, lastSize.width != size.width else { return }
        let oldW = Float(lastSize.width), newW = Float(size.width), h = Float(size.height)
        // Start from offsets that reproduce the old picture in the new view.
        glideShift = glideShift * oldW / newW + (oldW - newW) / newW
        glideScale *= fitDistance(aspect: oldW / h) / fitDistance(aspect: newW / h)
        startGlide(to: SIMD2(0, 1), in: view)
    }

    /// Glide the render into the layout it will have once `view` is `newWidth` pixels wide,
    /// without resizing the view yet; `done` runs when it can be resized.
    func glide(toWidth newWidth: CGFloat, in view: MTKView, done: @escaping () -> Void) {
        let oldW = Float(view.drawableSize.width), newW = Float(newWidth), h = Float(view.drawableSize.height)
        guard oldW > 0, newW > 0, h > 0 else { done(); return }
        let target = SIMD2((newW - oldW) / oldW, fitDistance(aspect: newW / h) / fitDistance(aspect: oldW / h))
        startGlide(to: target, in: view) { [weak self] in
            // The resize that follows must not start another glide.
            self?.skipResizeGlide = true
            self?.glideShift = 0
            self?.glideScale = 1
            done()
        }
    }

    /// Abandon a pending narrower layout and glide back to the view's own size.
    func cancelGlide(in view: MTKView) { startGlide(to: SIMD2(0, 1), in: view) }

    private func startGlide(to target: SIMD2<Float>, in view: MTKView, done: (() -> Void)? = nil) {
        glide = (SIMD2(glideShift, glideScale), target, CACurrentMediaTime(), done)
        glideView = view
        if glideLink == nil {
            glideLink = CADisplayLink(target: self, selector: #selector(glideTick))
            glideLink?.add(to: .main, forMode: .common)
        }
    }

    @objc private func glideTick() {
        guard let g = glide else { glideLink?.invalidate(); glideLink = nil; return }
        let t = min(1, Float((CACurrentMediaTime() - g.start) / 0.35))
        let e = t * t * (3 - 2 * t) // smoothstep ease in/out
        let v = g.from + (g.to - g.from) * e
        glideShift = v.x
        glideScale = v.y
        glideView?.setNeedsDisplay()
        if t >= 1 {
            glideLink?.invalidate()
            glideLink = nil
            glide = nil
            g.done?()
        }
    }

    /// Attach (or detach) a segmentation; the label volume is uploaded once per map.
    func setOverlay(_ seg: SegmentationOverlay?) {
        overlayOpacity = seg?.opacity ?? 0
        overlayGhost = seg?.ghost ?? false
        guard let seg else { labelTex = nil; labelSource = nil; return }
        seg.lut.withUnsafeBytes { labelLUT.replace(region: MTLRegionMake1D(0, 256), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256 * 4) }
        guard labelSource != seg.mapID else { return }
        let (nx, ny, nz) = seg.labels.dims
        let td = MTLTextureDescriptor()
        td.textureType = .type3D; td.pixelFormat = .r8Uint
        td.width = nx; td.height = ny; td.depth = nz; td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return }
        seg.labels.data.withUnsafeBytes { raw in
            for z in 0..<nz { // per slice: keeps the staging copy small
                tex.replace(region: MTLRegionMake3D(0, 0, z, nx, ny, 1), mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress! + z * nx * ny, bytesPerRow: nx, bytesPerImage: nx * ny)
            }
        }
        labelTex = tex
        labelSource = seg.mapID
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        encode(into: rpd, size: view.drawableSize, on: cmd)
        cmd.present(drawable)
        cmd.commit()
        onDraw?()
    }

    private func encode(into rpd: MTLRenderPassDescriptor, size: CGSize, on cmd: MTLCommandBuffer) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var u = makeUniforms(aspect: Float(size.width / max(size.height, 1)))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        let boxes = fov.isEmpty ? [simd_float4.zero] : fov // the slot must be bound
        enc.setFragmentBytes(boxes, length: boxes.count * MemoryLayout<simd_float4>.stride, index: 1)
        enc.setFragmentTexture(volumeTex, index: 0)
        enc.setFragmentTexture(cmapTex, index: 1)
        enc.setFragmentTexture(labelTex ?? noLabels, index: 2)
        enc.setFragmentTexture(labelLUT, index: 3)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// The current view rendered offscreen at `size` pixels (same camera, window, clips).
    func snapshot(size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard w > 0, h > 0, let tex = device.makeTexture(descriptor: td), let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        encode(into: rpd, size: size, on: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The camera for a view of `aspect` (width / height): position and view-projection.
    private func camera(aspect: Float) -> (eye: simd_float3, viewProj: simd_float4x4) {
        let eye = target + distance(aspect: aspect) * glideScale * Self.direction(yaw: yaw, pitch: pitch)
        let view = lookAt(eye: eye, center: target, up: simd_float3(0, 0, 1))
        var proj = perspective(fovy: Self.fovY, aspect: aspect, near: 0.05, far: 100)
        if glideShift != 0 { // slide the image sideways in NDC: x' = x + shift·w
            var slide = matrix_identity_float4x4
            slide.columns.3.x = glideShift
            proj = slide * proj
        }
        return (eye, proj * view)
    }

    /// Where a box-space point appears in a view of `size` (any unit, y down), and how far it
    /// is from the camera; nil behind the camera.
    func project(_ p: simd_float3, in size: CGSize) -> (point: CGPoint, depth: Float)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let cam = camera(aspect: Float(size.width / size.height))
        let c = cam.viewProj * simd_float4(p, 1)
        guard c.w > 1e-4 else { return nil }
        return (CGPoint(x: CGFloat((c.x / c.w + 1) / 2) * size.width, y: CGFloat((1 - c.y / c.w) / 2) * size.height),
                simd_distance(p, cam.eye))
    }

    private func makeUniforms(aspect: Float) -> Uniforms {
        let (eye, viewProj) = camera(aspect: aspect)
        let invVP = viewProj.inverse
        // Clip plane normal: the chosen axis, tilted about the other two. Depth runs along
        // the normal across the box's full extent in that direction, so the slider always
        // sweeps the whole volume whatever the tilt. Flip = same plane, opposite side kept.
        func unit(_ i: Int) -> simd_float3 { var v = simd_float3.zero; v[i % 3] = 1; return v }
        var planes = [simd_float4](repeating: .zero, count: ClipSetting.maxCount)
        let active = clips.prefix(ClipSetting.maxCount)
        for (i, clip) in active.enumerated() where clip.enabled { // disabled: zero normal, skipped by the shader
            let a = Int(clip.plane.axis), tilt = clip.tilt * (.pi / 180)
            var normal = simd_quatf(angle: tilt.y, axis: unit(a + 2)).act(
                simd_quatf(angle: tilt.x, axis: unit(a + 1)).act(unit(a)))
            var offset = (clip.pos - 0.5) * 2 * dot(abs(normal), boxHalf)
            if clip.flip { normal = -normal; offset = -offset }
            planes[i] = simd_float4(normal, offset)
        }
        return Uniforms(invViewProj: invVP, camPos: eye, boxHalf: boxHalf,
                        clips: (planes[0], planes[1], planes[2], planes[3], planes[4], planes[5]),
                        dataMin: windowLo, dataMax: windowHi, steps: steps, mode: mode,
                        clipCount: Int32(active.count), clipCutaway: clipCutaway ? 1 : 0,
                        clipHighlight: clipHighlight ? 1 : 0,
                        crosshairOn: crosshair == nil ? 0 : 1, crosshair: crosshair ?? .zero,
                        overlayOn: labelTex == nil ? 0 : 1, overlayOpacity: overlayOpacity, overlayGhost: overlayGhost ? 1 : 0,
                        cameraClip: cameraClipFraction * distance(aspect: aspect),
                        fovCount: Int32(fov.count / 2))
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
