//
//  RenderView.swift — SwiftUI host for the 3D render: MTKView, gestures (orbit, pan,
//  zoom-to-point, presets), the orientation indicator, and the resize glide.
//

import MetalKit
import SwiftUI

struct RenderView: UIViewRepresentable {
    let volume: NiftiVolume
    let lo: Float
    let hi: Float
    let mode: RenderMode
    let clips: [ClipSetting]
    let clipCutaway: Bool
    let clipHighlight: Bool
    /// Crosshair as fractions of the volume along x, y, z (0...1), or nil.
    var crosshair: SIMD3<Float>? = nil
    var overlay: SegmentationOverlay? = nil
    /// Station FOVs to outline, in voxel edges of the volume.
    var fov: [FOVBox] = []
    var cameraClip: Float = 0 // fraction of the eye→pivot distance, 0 = off
    /// Latest preset request; applied when `presetTick` changes.
    let preset: ViewPreset?
    let presetTick: Int
    let onTap: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: VolumeRenderer?
        var onTap: () -> Void = {}
        var presetTick = 0
        let gizmo = OrientationGizmo()
        let fovLabels = FOVLabelOverlay()
        /// What the FOV labels are drawn from (set in updateUIView).
        var fovBoxes: [FOVBox] = []
        var dims = SIMD3<Double>(1, 1, 1)
        var voxelSize = SIMD3<Double>(1, 1, 1)
        let orbit = UIPanGestureRecognizer()
        let mousePan = UIPanGestureRecognizer()
        let pinch = UIPinchGestureRecognizer()
        let scroll = UIPanGestureRecognizer()
        /// The current pinch comes from a trackpad (transform events) rather than fingers.
        private var trackpadPinch = false
        /// A trackpad pinch reports far larger scale steps than fingers on glass for the same
        /// motion, so its scale is damped by this exponent. The slice views' UIScrollView
        /// zoom is fine as is.
        private static let trackpadPinchDamping: Float = 0.18

        /// Edge lengths of the FOV wireframes: for each box and axis, of the two of its four
        /// parallel edges nearer the camera, the one further out on screen (so the text sits on
        /// the box's outline rather than over the tissue), labelled at its projected midpoint
        /// and nudged outward. Edges that look too short on screen go unlabelled, and a
        /// length already shown at about the same spot (stations share faces) isn't repeated.
        func updateFOVLabels() {
            guard let renderer else { return }
            let size = fovLabels.bounds.size, half = renderer.boxHalf
            var items = [(text: String, color: UIColor, at: CGPoint)]()
            func box(_ v: SIMD3<Double>) -> simd_float3 { (simd_float3(simd_clamp(v / dims, .zero, .one)) - 0.5) * 2 * half }
            for b in fovBoxes {
                let lo = box(b.lo), hi = box(b.hi), color = UIColor(FOVSession.color(b.session))
                guard let centre = renderer.project((lo + hi) / 2, in: size) else { continue }
                for a in 0..<3 {
                    var edges = [(mid: CGPoint, depth: Float, length: CGFloat)]()
                    for k in 0..<4 {
                        var p0 = lo, p1 = lo
                        let u = (a + 1) % 3, v = (a + 2) % 3
                        p0[u] = (k & 1) != 0 ? hi[u] : lo[u]; p0[v] = (k & 2) != 0 ? hi[v] : lo[v]
                        p1 = p0; p1[a] = hi[a]
                        guard let s0 = renderer.project(p0, in: size), let s1 = renderer.project(p1, in: size),
                              let m = renderer.project((p0 + p1) / 2, in: size) else { continue }
                        edges.append((m.point, m.depth, hypot(s1.point.x - s0.point.x, s1.point.y - s0.point.y)))
                    }
                    func out(_ p: CGPoint) -> CGFloat { hypot(p.x - centre.point.x, p.y - centre.point.y) }
                    guard let e = edges.sorted(by: { $0.depth < $1.depth }).prefix(2).max(by: { out($0.mid) < out($1.mid) }),
                          e.length > 50 else { continue }
                    // Outward from the box centre, so the text sits beside the line, not on it.
                    let dx = e.mid.x - centre.point.x, dy = e.mid.y - centre.point.y, n = max(hypot(dx, dy), 1)
                    let at = CGPoint(x: e.mid.x + dx / n * 12, y: e.mid.y + dy / n * 10)
                    let text = FOVRect.cm((b.hi[a] - b.lo[a]) * voxelSize[a])
                    if items.contains(where: { $0.text == text && hypot($0.at.x - at.x, $0.at.y - at.y) < 24 }) { continue }
                    items.append((text, color, at))
                }
            }
            fovLabels.show(items)
        }

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
            // Trackpad pinches arrive as transform events with no touches; check both, as the
            // event type isn't always seen by shouldReceive.
            if g.state == .began { trackpadPinch = trackpadPinch || g.numberOfTouches == 0 }
            let scale = trackpadPinch ? pow(Float(g.scale), Self.trackpadPinchDamping) : Float(g.scale)
            renderer.zoom(by: scale, atNDC: ndc(g.location(in: view), in: view), aspect: aspect(view))
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
            if g === pinch { trackpadPinch = event.type == .transform }
            let secondary = event.buttonMask.contains(.secondary)
            return g === mousePan ? secondary : g === orbit ? !secondary : true
        }

        // Pinch and two-finger pan run together (zoom while sliding); orbit stays exclusive,
        // and so do pinch and scroll, so a trackpad pinch that also scrolls doesn't zoom twice.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let pair: Set<ObjectIdentifier> = [ObjectIdentifier(g), ObjectIdentifier(other)]
            return g !== orbit && other !== orbit && pair != [ObjectIdentifier(pinch), ObjectIdentifier(scroll)]
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RenderHost {
        let host = RenderHost()
        let v = host.mtk
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
        c.scroll.addTarget(c, action: #selector(Coordinator.scrolled))
        c.scroll.allowedScrollTypesMask = .all
        c.scroll.allowedTouchTypes = [] // scroll events only, never touches
        c.pinch.addTarget(c, action: #selector(Coordinator.pinched))
        for g in [double, single, c.orbit, pan, c.mousePan, c.scroll, c.pinch] {
            g.delegate = c
            v.addGestureRecognizer(g)
        }

        c.fovLabels.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(c.fovLabels)
        NSLayoutConstraint.activate([
            c.fovLabels.leadingAnchor.constraint(equalTo: v.leadingAnchor), c.fovLabels.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            c.fovLabels.topAnchor.constraint(equalTo: v.topAnchor), c.fovLabels.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        c.renderer?.onDraw = { [weak c] in c?.updateFOVLabels() } // follows orbit, zoom, pan and glides
        c.gizmo.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(c.gizmo)
        NSLayoutConstraint.activate([
            c.gizmo.leadingAnchor.constraint(equalTo: v.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            c.gizmo.bottomAnchor.constraint(equalTo: v.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            c.gizmo.widthAnchor.constraint(equalToConstant: 76),
            c.gizmo.heightAnchor.constraint(equalToConstant: 76),
        ])
        host.renderer = c.renderer
        return host
    }

    func updateUIView(_ host: RenderHost, context: Context) {
        let view = host.mtk
        let c = context.coordinator
        guard let renderer = c.renderer else { return }
        let range = max(volume.dataMax - volume.dataMin, .leastNonzeroMagnitude)
        c.onTap = onTap
        renderer.windowLo = (lo - volume.dataMin) / range
        renderer.windowHi = (hi - volume.dataMin) / range
        renderer.mode = mode == .mip ? 0 : 1
        renderer.clips = clips
        renderer.clipCutaway = clipCutaway
        renderer.clipHighlight = clipHighlight
        renderer.crosshair = crosshair.map { ($0 - 0.5) * 2 * renderer.boxHalf }
        // Voxel edges → box space, cut to the volume (the render stops at its faces).
        let dims = SIMD3(Double(volume.dims.0), Double(volume.dims.1), Double(volume.dims.2))
        c.fovBoxes = fov
        c.dims = dims
        c.voxelSize = SIMD3(Double(volume.voxelSize.0), Double(volume.voxelSize.1), Double(volume.voxelSize.2))
        renderer.fov = fov.flatMap { b in
            // w carries the session (the shader's colour index).
            [b.lo, b.hi].map { simd_float4((SIMD3<Float>(simd_clamp($0 / dims, .zero, .one)) - 0.5) * 2 * renderer.boxHalf, Float(b.session)) }
        }
        renderer.setOverlay(overlay)
        renderer.cameraClipFraction = cameraClip
        if presetTick != c.presetTick, let preset {
            renderer.setView(yaw: preset.angles.yaw, pitch: preset.angles.pitch)
        }
        c.presetTick = presetTick
        c.cameraChanged(view)
    }
}

/// Holds the MTKView. When SwiftUI narrows this view (inspector opening), the MTKView keeps
/// its old size until the renderer has glided into the narrower layout, so the picture is
/// never cut off at the new edge before the panel has slid over it. Growing is immediate.
final class RenderHost: UIView, SnapshotPane {
    let mtk = MTKView()
    var renderer: VolumeRenderer?
    private var pendingSize: CGSize?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        SnapshotPanes.register(self)
    }

    func snapshotImage() -> UIImage? {
        guard let cg = renderer?.snapshot(size: mtk.drawableSize) else { return nil }
        let image = UIImage(cgImage: cg, scale: mtk.contentScaleFactor, orientation: .up)
        // The FOV edge lengths are UIKit text over the render: draw them on top.
        guard let labels = mtk.subviews.first(where: { $0 is FOVLabelOverlay }) else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = mtk.contentScaleFactor
        return UIGraphicsImageRenderer(size: mtk.bounds.size, format: format).image { ctx in
            image.draw(in: mtk.bounds)
            labels.layer.render(in: ctx.cgContext)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        addSubview(mtk)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let old = mtk.frame.size, new = bounds.size
        if let pendingSize, pendingSize != new { // layout changed again mid-glide
            self.pendingSize = nil
            renderer?.cancelGlide(in: mtk)
        }
        let narrowing = old.width > new.width && old.height == new.height && old.width > 0
            && UIView.inheritedAnimationDuration == 0 && pendingSize == nil
        guard narrowing, let renderer else { mtk.frame = bounds; return }
        pendingSize = new
        renderer.glide(toWidth: new.width * mtk.contentScaleFactor, in: mtk) { [weak self] in
            guard let self, pendingSize == new else { return }
            pendingSize = nil
            mtk.frame = bounds
        }
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

