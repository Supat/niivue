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
        renderer.setOverlay(overlay)
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
        return UIImage(cgImage: cg, scale: mtk.contentScaleFactor, orientation: .up)
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

