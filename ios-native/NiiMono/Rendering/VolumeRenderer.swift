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
    var crosshairStep: Float
    var cutoutOn: Int32
    var clipKeepLabels: Int32
}

final class VolumeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private var queue: MTLCommandQueue // replaced after a GPU error (see recover)
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let volumeTex: MTLTexture
    private var volumeID: UUID

    /// The scan's intensities changed in place (banding repair): upload the z slices `z`
    /// (nil = all) again. The scaling stays the scan's original data range.
    func updateVolume(_ volume: NiftiVolume, z: Range<Int>?) {
        guard volume.id != volumeID else { return }
        volumeID = volume.id
        Self.uploadVolume(volume, z: (z ?? 0..<volume.dims.2).clamped(to: 0..<volume.dims.2), into: volumeTex)
    }

    // Float → UInt16 with vDSP, one z-slice at a time: a plain Swift loop over a whole-body
    // volume (60M+ voxels) blocks the main thread for seconds in Debug, and slice-sized
    // scratch buffers avoid a second full-volume copy.
    private static func uploadVolume(_ volume: NiftiVolume, z range: Range<Int>, into tex: MTLTexture) {
        let (nx, ny, _) = volume.dims, n = nx * ny
        var k = 65535 / max(volume.dataMax - volume.dataMin, .leastNonzeroMagnitude)
        var bias = -volume.dataMin * k
        var scaled = [Float](repeating: 0, count: n)
        var texels = [UInt16](repeating: 0, count: n)
        volume.data.withUnsafeBufferPointer { src in
            for z in range {
                vDSP_vsmsa(src.baseAddress! + z * n, 1, &k, &bias, &scaled, 1, vDSP_Length(n))
                vDSP_vfixru16(scaled, 1, &texels, 1, vDSP_Length(n))
                tex.replace(region: MTLRegionMake3D(0, 0, z, nx, ny, 1), mipmapLevel: 0, slice: 0,
                            withBytes: texels, bytesPerRow: nx * 2, bytesPerImage: n * 2)
            }
        }
    }
    private let cmapTex: MTLTexture
    private let labelLUT: MTLTexture   // 256 × RGBA, alpha 0 = hidden label
    private var labelTex: MTLTexture?  // r8Uint labels, same grid as the volume
    private let noLabels: MTLTexture   // 1×1×1 r8Uint stand-in: the slot must hold a uint texture
    private var labelSource: UUID?
    private var labelRevision = 0
    var overlayOpacity: Float = 0.65
    var overlayGhost: Int32 = 0 // 0 = off, 1 = fade unlabelled tissue, 2 = labels alone
    let boxHalf: simd_float3
    /// Millimetres per box-space unit (the box's longest side is 1 unit: boxHalf ≤ 0.5).
    let mmPerUnit: Float
    /// Points per drawable pixel, so the scale can be measured in points.
    var pointScale: CGFloat = 1
    /// Called after each on-screen frame, for overlays that follow the camera.
    var onDraw: (() -> Void)?

    // Display window, normalized to the volume's full intensity range (0...1).
    var windowLo: Float = 0
    var windowHi: Float = 1
    var mode: Int32 = 0 // RenderMode.shaderMode
    var clips: [ClipSetting] = [] // at most ClipSetting.maxCount are used
    var clipCutaway = false
    var clipKeepLabels = false // clipping spares voxels of visible segments
    var clipHighlight = false
    var crosshair: simd_float3? // box-space point, or nil for none
    /// Station FOV boxes as [lo, hi] pairs in box space (see RenderView), drawn as wireframes.
    var fov: [simd_float4] = []
    /// Fraction of the eye→pivot distance in front of which nothing is drawn (0 = off).
    var cameraClipFraction: Float = 0

    // Arcball camera, driven by RenderView gestures: `rotation` takes camera space (x right,
    // y up, z towards the viewer) to the volume's RAS space, so any orientation is reachable
    // and a drag turns the volume like a ball under the finger. The presets and `level()`
    // give upright (superior-up) orientations from a yaw and a pitch.
    private static let startYaw: Float = .pi - 0.6 // in front of the face, slightly to one side
    private static let startPitch: Float = 0.3
    private static let startRotation = orientation(yaw: startYaw, pitch: startPitch)
    private static let fovY: Float = .pi / 4
    var rotation = startRotation
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
        volumeID = volume.id
        Self.uploadVolume(volume, z: 0..<nz, into: tex)

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
        mmPerUnit = max(phys.x, max(phys.y, phys.z))
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
        // Any new size needs a frame (rotation, split view): the view draws only on request,
        // and RenderView no longer asks on every SwiftUI update.
        defer { lastSize = size; view.setNeedsDisplay() }
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

    /// Removed noise: a mask whose marked voxels the render treats as empty.
    private var cutout = GridTexture()
    func setCutout(_ mask: SegmentationOverlay?) { cutout.sync(mask, device: device) }

    /// Attach (or detach) a segmentation; the label volume is uploaded once per map.
    func setOverlay(_ seg: SegmentationOverlay?) {
        overlayOpacity = seg?.opacity ?? 0
        overlayGhost = seg.map { $0.hideScan ? 2 : $0.ghost ? 1 : 0 } ?? 0
        guard let seg else { labelTex = nil; labelSource = nil; return }
        seg.lut.withUnsafeBytes { labelLUT.replace(region: MTLRegionMake1D(0, 256), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256 * 4) }
        let (nx, ny, nz) = seg.labels.dims
        if labelSource == seg.mapID, let tex = labelTex {
            guard labelRevision != seg.revision else { return }
            // A drawing changed some slices in place: upload just those, if none were missed.
            let z = seg.revision == labelRevision + 1 ? seg.dirtyZ ?? 0..<nz : 0..<nz
            upload(seg.labels, z: z.clamped(to: 0..<nz), into: tex)
            labelRevision = seg.revision
            return
        }
        let td = MTLTextureDescriptor()
        td.textureType = .type3D; td.pixelFormat = .r8Uint
        td.width = nx; td.height = ny; td.depth = nz; td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return }
        upload(seg.labels, z: 0..<nz, into: tex)
        labelTex = tex
        labelSource = seg.mapID
        labelRevision = seg.revision
    }

    private func upload(_ labels: LabelGrid, z range: Range<Int>, into tex: MTLTexture) {
        let (nx, ny, _) = labels.dims
        labels.data.withUnsafeBytes { raw in
            for z in range { // per slice: keeps the staging copy small
                tex.replace(region: MTLRegionMake3D(0, 0, z, nx, ny, 1), mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress! + z * nx * ny, bytesPerRow: nx, bytesPerImage: nx * ny)
            }
        }
    }

    /// Frames on the GPU (0 or 1) and whether one was asked for meanwhile. One frame at a
    /// time: a fast orbit asks for a frame every display refresh, and with up to three of
    /// them queued on the GPU a whole-body scan's frames add up past the GPU watchdog, which
    /// kills the one it catches and discards the ones behind it. The next frame is drawn
    /// when the current one completes, so the orbit keeps up at the rate the GPU manages.
    private var inFlight = 0, redrawWanted = false

    func draw(in view: MTKView) {
        if inFlight > 0 { redrawWanted = true; return }
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
            // No drawable (its allocation failed under memory pressure): a stale frame would
            // stay on screen, so ask for another go shortly.
            retryDraw(view, after: 0.25)
            return
        }
        let size = view.drawableSize, strips = Self.strips(for: size)
        for strip in 0..<strips {
            guard let cmd = queue.makeCommandBuffer() else { break }
            encode(into: rpd, size: size, strip: strip, of: strips, on: cmd)
            if strip == strips - 1 { cmd.present(drawable) }
            inFlight += 1
            cmd.addCompletedHandler { [weak self, weak view] buffer in
                DispatchQueue.main.async { self?.completed(buffer, strip: strip, of: strips, view: view) }
            }
            cmd.commit()
        }
        onDraw?()
    }

    /// The GPU watchdog kills a command buffer that runs too long, so a frame is encoded as
    /// horizontal strips of at most ~400k pixels, each its own command buffer: a whole-body
    /// scan's frame at a large size is well over a billion samples, which a single buffer
    /// couldn't finish in time on some machines even at the sample cap.
    private static func strips(for size: CGSize) -> Int {
        max(1, min(16, Int((size.width * size.height / 400_000).rounded(.up))))
    }

    private func completed(_ buffer: MTLCommandBuffer, strip: Int, of strips: Int, view: MTKView?) {
        inFlight -= 1
        let seconds = buffer.gpuEndTime - buffer.gpuStartTime
        if seconds > 0.5 {
            MemoryLog.log.notice("3D render: strip \(strip + 1, privacy: .public) of \(strips, privacy: .public) took \(seconds, format: .fixed(precision: 2), privacy: .public) s on the GPU")
        }
        if let error = buffer.error { recover(from: error, view: view) } else if strip == strips - 1 { gpuFailures = 0 }
        if inFlight == 0, redrawWanted { redrawWanted = false; view?.setNeedsDisplay() }
    }

    /// Frames that failed in a row (a success resets it); after a few, the view waits for
    /// the next camera change rather than retrying for ever.
    private var gpuFailures = 0

    /// A command buffer failed: a GPU hang (the watchdog, or a fault under memory pressure)
    /// or the drawable's allocation. After a hang Metal ignores everything submitted on the
    /// same queue, so the view would stay blank or stale for the rest of the session: a
    /// fresh queue starts clean, and the frame is drawn again after a short back-off.
    private func recover(from error: Error, view: MTKView?) {
        gpuFailures += 1
        let size = view?.drawableSize ?? .zero
        MemoryLog.log.error("3D render: frame \(self.gpuFailures, privacy: .public) failed: \(error.localizedDescription, privacy: .public); drawable \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public), free memory \(os_proc_available_memory() >> 20, privacy: .public) MB")
        guard gpuFailures <= 5 else { return }
        if let fresh = device.makeCommandQueue() { queue = fresh }
        retryDraw(view, after: 0.25 * Double(gpuFailures))
    }

    private func retryDraw(_ view: MTKView?, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in view?.setNeedsDisplay() }
    }

    /// One strip of the frame (rows `strip`/`strips` to `strip + 1`/`strips` of `size`):
    /// later strips load what the earlier ones drew rather than clearing it.
    private func encode(into rpd: MTLRenderPassDescriptor, size: CGSize, strip: Int, of strips: Int, on cmd: MTLCommandBuffer) {
        let pass = strip == 0 ? rpd : (rpd.copy() as! MTLRenderPassDescriptor)
        if strip > 0 { pass.colorAttachments[0].loadAction = .load }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let h = Int(size.height), y0 = h * strip / strips, y1 = h * (strip + 1) / strips
        enc.setScissorRect(MTLScissorRect(x: 0, y: y0, width: Int(size.width), height: max(0, y1 - y0)))
        var u = makeUniforms(aspect: Float(size.width / max(size.height, 1)))
        u.crosshairStep = scaleStep(size: CGSize(width: size.width / max(pointScale, 1), height: size.height / max(pointScale, 1)))
            .map { Float($0.mm) / mmPerUnit } ?? 0
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        let boxes = fov.isEmpty ? [simd_float4.zero] : fov // the slot must be bound
        enc.setFragmentBytes(boxes, length: boxes.count * MemoryLayout<simd_float4>.stride, index: 1)
        enc.setFragmentTexture(volumeTex, index: 0)
        enc.setFragmentTexture(cmapTex, index: 1)
        enc.setFragmentTexture(labelTex ?? noLabels, index: 2)
        enc.setFragmentTexture(labelLUT, index: 3)
        enc.setFragmentTexture(cutout.texture ?? noLabels, index: 4)
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
        let strips = Self.strips(for: size)
        for strip in 0..<strips - 1 { // in strips, as on screen; the queue runs them in order
            guard let c = queue.makeCommandBuffer() else { return nil }
            encode(into: rpd, size: size, strip: strip, of: strips, on: c)
            c.commit()
        }
        encode(into: rpd, size: size, strip: strips - 1, of: strips, on: cmd)
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

    private func makeUniforms(aspect: Float) -> Uniforms {
        let b = basis
        let eye = target + distance(aspect: aspect) * glideScale * b.toward
        let view = lookAt(eye: eye, center: target, up: b.up)
        var proj = perspective(fovy: Self.fovY, aspect: aspect, near: 0.05, far: 100)
        if glideShift != 0 { // slide the image sideways in NDC: x' = x + shift·w
            var slide = matrix_identity_float4x4
            slide.columns.3.x = glideShift
            proj = slide * proj
        }
        let invVP = (proj * view).inverse
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
                        overlayOn: labelTex == nil ? 0 : 1, overlayOpacity: overlayOpacity, overlayGhost: overlayGhost,
                        cameraClip: cameraClipFraction * distance(aspect: aspect),
                        fovCount: Int32(fov.count / 2), crosshairStep: 0,
                        cutoutOn: cutout.texture == nil ? 0 : 1, clipKeepLabels: clipKeepLabels ? 1 : 0)
    }
}

extension VolumeRenderer {
    /// Unit vector from the volume centre towards the camera (z-up).
    fileprivate static func direction(yaw: Float, pitch: Float) -> simd_float3 {
        simd_float3(cos(pitch) * sin(yaw), -cos(pitch) * cos(yaw), sin(pitch))
    }

    /// The upright orientation with the camera on that side: superior up on screen.
    fileprivate static func orientation(yaw: Float, pitch: Float) -> simd_quatf {
        upright(toward: direction(yaw: yaw, pitch: pitch))
    }

    /// The orientation looking along `toward` with superior up on screen (right is level).
    /// Looking straight up or down the body, where "up" is undefined, anterior goes to the
    /// top of the screen.
    fileprivate static func upright(toward: simd_float3) -> simd_quatf {
        var right = cross(-toward, simd_float3(0, 0, 1))
        if length(right) < 1e-4 { right = simd_float3(1, 0, 0) }
        right = normalize(right)
        let up = cross(right, -toward)
        return simd_quatf(simd_float3x3(columns: (right, up, toward)))
    }

    fileprivate func distance(aspect: Float) -> Float { fitDistance(aspect: aspect) / zoom }

    /// The scale at the orbit pivot (perspective: nearer is larger, farther smaller) for a
    /// view of `size` points, as the round step shared by the scale bar and crosshair ticks.
    func scaleStep(size: CGSize) -> (mm: CGFloat, pt: CGFloat)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let units = 2 * distance(aspect: Float(size.width / size.height)) * glideScale * tan(Self.fovY / 2) // box units across the height
        return ScaleStep.nice(pointsPerMM: size.height / CGFloat(units * mmPerUnit))
    }

    /// Screen-right, screen-up and towards-the-viewer unit vectors in volume (RAS) space.
    var basis: (right: simd_float3, up: simd_float3, toward: simd_float3) { Self.basis(of: rotation) }

    private static func basis(of rotation: simd_quatf) -> (right: simd_float3, up: simd_float3, toward: simd_float3) {
        (rotation.act(simd_float3(1, 0, 0)), rotation.act(simd_float3(0, 1, 0)), rotation.act(simd_float3(0, 0, 1)))
    }

    /// Turns the volume by `q`, given in camera space: the camera turns the other way.
    private func turn(by q: simd_quatf) {
        rotation = simd_normalize(rotation * q.inverse)
    }

    /// World-space offset on the plane through `target` for a screen offset in NDC (-1...1).
    private func planeOffset(_ ndc: simd_float2, aspect: Float, distance: Float) -> simd_float3 {
        let tanV = tan(Self.fovY / 2), b = basis
        return (b.right * ndc.x * tanV * aspect + b.up * ndc.y * tanV) * distance
    }

    /// A drag of (`dx`, `dy`) points (y down the screen) turns the volume like a ball under
    /// the finger: about the screen axis perpendicular to the drag, by `radiansPerPoint` per
    /// point, so the grabbed point follows the finger.
    func orbit(dx: Float, dy: Float, radiansPerPoint: Float) {
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return }
        turn(by: simd_quatf(angle: length * radiansPerPoint, axis: simd_float3(dy, dx, 0) / length))
    }

    /// Rolls the volume about the line of sight by `radians`, clockwise on screen when
    /// positive (a two-finger twist).
    func roll(by radians: Float) {
        turn(by: simd_quatf(angle: -radians, axis: simd_float3(0, 0, 1)))
    }

    /// Puts superior up again, keeping the line of sight.
    func level() {
        rotation = Self.upright(toward: basis.toward)
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
        rotation = yaw == nil && pitch == nil ? Self.startRotation
            : Self.orientation(yaw: yaw ?? Self.startYaw, pitch: pitch ?? Self.startPitch)
        zoom = 1
        target = .zero
    }

    /// Closest camera distance at which all eight corners of the volume box are inside
    /// the frustum. Evaluated at the starting orientation (not the live one) so the
    /// image fills the view on entry and after a resize, but doesn't pulse while orbiting.
    fileprivate func fitDistance(aspect: Float) -> Float {
        let (right, up, e) = Self.basis(of: Self.startRotation)
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

/// A label grid as an r8Uint 3D texture, uploaded once per grid and then only the z slices a
/// drawing changed (see SegmentationOverlay.revision / dirtyZ).
private struct GridTexture {
    private(set) var texture: MTLTexture?
    private var source: UUID?
    private var revision = 0

    mutating func sync(_ grid: SegmentationOverlay?, device: MTLDevice) {
        guard let grid else { texture = nil; source = nil; return }
        let (nx, ny, nz) = grid.labels.dims
        if source == grid.mapID, let tex = texture {
            guard revision != grid.revision else { return }
            let z = grid.revision == revision + 1 ? grid.dirtyZ ?? 0..<nz : 0..<nz
            Self.upload(grid.labels, z: z.clamped(to: 0..<nz), into: tex)
            revision = grid.revision
            return
        }
        let td = MTLTextureDescriptor()
        td.textureType = .type3D; td.pixelFormat = .r8Uint
        td.width = nx; td.height = ny; td.depth = nz; td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return }
        Self.upload(grid.labels, z: 0..<nz, into: tex)
        texture = tex; source = grid.mapID; revision = grid.revision
    }

    private static func upload(_ labels: LabelGrid, z range: Range<Int>, into tex: MTLTexture) {
        let (nx, ny, _) = labels.dims
        labels.data.withUnsafeBytes { raw in
            for z in range { // per slice: keeps the staging copy small
                tex.replace(region: MTLRegionMake3D(0, 0, z, nx, ny, 1), mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress! + z * nx * ny, bytesPerRow: nx, bytesPerImage: nx * ny)
            }
        }
    }
}
