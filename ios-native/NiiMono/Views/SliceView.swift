//
//  SliceView.swift — one 2D slice in a UIScrollView, so pinch-zoom, pan, bounce and
//  double-tap behave exactly like Preview/Photos. Slices are tiny (≤ a few hundred
//  px square), so each one is windowed on the CPU into a CGImage.
//

import SwiftUI
import UIKit

struct SliceView: UIViewRepresentable {
    let volume: NiftiVolume
    let axis: Int
    let index: Int
    let lo: Float
    let hi: Float
    let mirrored: Bool
    var overlay: SegmentationOverlay? = nil
    /// Physical size (mm) to fit instead of the slice's own, so several panes share one
    /// scale: pass the envelope of all their extents. nil = fit this slice alone.
    var fitExtent: CGSize? = nil
    /// Shared zoom: applied when it differs from the view's own, and changes are reported
    /// through onZoom so several panes can follow each other. nil = independent.
    var zoom: CGFloat? = nil
    var zoomAnimated = false // follow with the same animation a double-tap uses
    var onZoom: ((CGFloat, _ animated: Bool) -> Void)? = nil
    /// Shared pan: the image point (fractions, x right, y down) to keep centred, followed like
    /// `zoom`; the user's own pans are reported through onPan. nil = independent.
    var centre: CGPoint? = nil
    var onPan: ((CGPoint, _ animated: Bool) -> Void)? = nil
    /// Crosshair position as fractions of the displayed image (0...1, x right, y down), or nil.
    var crosshair: CGPoint? = nil
    /// Acquisition FOV boxes in image fractions (x right, y down), with labels and edge lengths.
    var fov: [FOVRect] = []
    /// If set, a tap reports its position (same fractions) instead of calling onTap.
    var onLocate: ((CGPoint) -> Void)? = nil
    /// Reports the image's frame in the view's own coordinates whenever layout, zoom or pan
    /// moves it, so another pane can follow.
    var onViewport: ((CGRect) -> Void)? = nil
    /// Room the scale bar leaves at the bottom (for the slice scrubber while it shows).
    var scaleBarInset: CGFloat = 0
    let onTap: () -> Void
    let onScrub: (Int) -> Void

    func makeUIView(context: Context) -> ZoomView { ZoomView() }

    /// Everything the slice image depends on; the image is only rebuilt when this changes
    /// (a crosshair move or a zoom in another pane must not cost a full recomposite).
    struct ImageKey: Equatable {
        let axis: Int, index: Int, lo: Float, hi: Float, mirrored: Bool
        let mapID: UUID?, opacity: Float, lut: [SIMD4<UInt8>]
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        let key = ImageKey(axis: axis, index: index, lo: lo, hi: hi, mirrored: mirrored,
                           mapID: overlay?.mapID, opacity: overlay?.opacity ?? 0, lut: overlay?.lut ?? [])
        if view.imageKey != key {
            view.imageKey = key
            if let image = makeImage() { view.imageView.image = UIImage(cgImage: image, scale: 1, orientation: mirrored ? .upMirrored : .up) }
        }
        let e = volume.sliceExtent(axis: axis)
        view.extent = CGSize(width: CGFloat(e.0), height: CGFloat(e.1))
        view.fitExtent = fitExtent
        view.onTap = onTap
        view.onScrub = onScrub
        view.onLocate = onLocate
        view.crosshair = crosshair
        view.fov = fov
        view.onZoom = onZoom
        view.onPan = onPan
        view.onViewport = onViewport
        view.scaleBarInset = scaleBarInset
        // Following another pane, never fighting this one's own gesture.
        guard !view.isZooming, !view.isTracking, !view.isDecelerating else { return }
        let newZoom = zoom.flatMap { abs($0 - view.zoomScale) > 0.001 ? $0 : nil }
        let newCentre = centre.flatMap { c in
            let v = view.centreFraction
            return abs(c.x - v.x) > 0.001 || abs(c.y - v.y) > 0.001 ? c : nil
        }
        guard newZoom != nil || newCentre != nil else { return }
        // Don't echo the follow back into the model mid-update.
        view.applyingSharedZoom = true
        defer { view.applyingSharedZoom = false }
        let follow = {
            if let newZoom { view.setZoomScale(newZoom, keepingCentre: true) }
            if let newCentre { view.centreFraction = newCentre }
        }
        if zoomAnimated {
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut, animations: follow)
        } else {
            follow()
        }
    }

    private func makeImage() -> CGImage? {
        if let overlay {
            let s = volume.sliceRGBX(axis: axis, index: index, lo: lo, hi: hi, overlay: overlay)
            return CGDataProvider(data: Data(s.pixels) as CFData).flatMap {
                CGImage(width: s.width, height: s.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        } else {
            let s = volume.slice(axis: axis, index: index, lo: lo, hi: hi)
            return CGDataProvider(data: Data(s.pixels) as CFData).flatMap {
                CGImage(width: s.width, height: s.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: s.width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
    }
}

final class ZoomView: UIScrollView, UIScrollViewDelegate, SnapshotPane {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        SnapshotPanes.register(self)
    }

    func snapshotImage() -> UIImage? {
        UIGraphicsImageRenderer(bounds: bounds, format: .init(for: traitCollection)).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false) // image + crosshair, current zoom/pan
        }
    }

    let imageView = UIImageView()
    var onTap: () -> Void = {}
    var onScrub: (Int) -> Void = { _ in }
    var onLocate: ((CGPoint) -> Void)?
    var onZoom: ((CGFloat, _ animated: Bool) -> Void)?
    var onPan: ((CGPoint, _ animated: Bool) -> Void)?
    var onViewport: ((CGRect) -> Void)? { didSet { reported = nil; reportViewport() } }
    private var reported: CGRect?
    var imageKey: SliceView.ImageKey?
    var applyingSharedZoom = false
    private var animatingZoom = false
    var crosshair: CGPoint? { didSet { if crosshair != oldValue { layoutCrosshair() } } }
    private let crosshairLayer = CAShapeLayer()
    var scaleBarInset: CGFloat = 0 { didSet { if scaleBarInset != oldValue { layoutScaleBar() } } }
    private let scaleBar = CAShapeLayer()
    private let scaleLabel = CATextLayer()
    var fov: [FOVRect] = [] { didSet { if fov != oldValue { layoutFOV() } } }
    /// One outline layer per session, in that session's colour.
    private var fovLayers: [CAShapeLayer] = []
    private var fovLabels: [CATextLayer] = []
    /// Edge lengths: one along the bottom edge, one up the right edge of each box.
    private var fovSizeLabels: [CATextLayer] = []
    /// Physical size of the slice (mm); only its aspect ratio matters.
    var extent = CGSize(width: 1, height: 1) { didSet { if extent != oldValue { setNeedsLayout() } } }
    /// Extent whose aspect-fit sets the scale (see SliceView.fitExtent); nil = `extent`.
    var fitExtent: CGSize? { didSet { if fitExtent != oldValue { setNeedsLayout() } } }

    private var fitted: (bounds: CGSize, extent: CGSize, fitExtent: CGSize?) = (.zero, .zero, nil)
    private let scrub = UIPanGestureRecognizer()
    private static let pointsPerSlice: CGFloat = 5

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black // panes in the multiplanar grid must not show the divider colour
        maximumZoomScale = 12
        contentInsetAdjustmentBehavior = .never // content sits under the glass bars, like Preview
        topEdgeEffect.isHidden = true // no bar backdrop over the image; match the 3D view
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        addSubview(imageView)
        // Thin, translucent, with a gap at the centre so it marks the point without hiding it.
        crosshairLayer.strokeColor = UIColor(red: 1, green: 0.25, blue: 0.2, alpha: 0.45).cgColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.fillColor = nil
        layer.addSublayer(crosshairLayer)
        // Scale bar: white with a dark halo, like the direction labels but legible on tissue.
        for l in [scaleBar, scaleLabel] as [CALayer] {
            l.shadowColor = UIColor.black.cgColor; l.shadowOpacity = 0.9; l.shadowRadius = 1.5; l.shadowOffset = .zero
            layer.addSublayer(l)
        }
        scaleBar.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        scaleBar.lineWidth = 1.5
        scaleBar.fillColor = nil
        scaleLabel.fontSize = 11
        scaleLabel.foregroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        scaleLabel.alignmentMode = .center
        scaleLabel.contentsScale = UIScreen.main.scale

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        // Unzoomed, a vertical drag (or trackpad scroll) steps through slices; once
        // zoomed in, the scroll view's own pan takes over.
        scrub.addTarget(self, action: #selector(scrubbed))
        scrub.maximumNumberOfTouches = 1
        scrub.allowedScrollTypesMask = .all
        panGestureRecognizer.require(toFail: scrub)
        [double, single, scrub].forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, extent.width > 0, extent.height > 0 else { return }
        let refit = fitted.bounds != bounds.size || fitted.extent != extent || fitted.fitExtent != fitExtent
        // A width-only change with the same slice is the inspector opening or closing:
        // glide to the new centre instead of jumping. (Rotation already runs inside the
        // system's own animation; first layout and plane changes should not animate.)
        let glide = refit && fitted.extent == extent && fitted.bounds.height == bounds.height
            && fitted.bounds.width > 0 && UIView.inheritedAnimationDuration == 0
        let apply = { [self] in
            if refit {
                // Aspect-fit at zoom 1. Resets zoom on rotation / inspector / plane change.
                fitted = (bounds.size, extent, fitExtent)
                applyingSharedZoom = true // a refit is layout, not a zoom to broadcast
                zoomScale = 1
                applyingSharedZoom = false
                let ref = fitExtent ?? extent
                let k = min(bounds.width / ref.width, bounds.height / ref.height)
                imageView.frame = CGRect(x: 0, y: 0, width: extent.width * k, height: extent.height * k)
                contentSize = imageView.frame.size
            }
            // Keep the image centred whenever it is smaller than the viewport.
            imageView.frame.origin = CGPoint(x: max(0, (bounds.width - imageView.frame.width) / 2),
                                             y: max(0, (bounds.height - imageView.frame.height) / 2))
            layoutCrosshair()
            layoutFOV()
            layoutScaleBar()
            reportViewport()
        }
        if glide {
            // Our bounds have already jumped to the new width; let the image overflow them
            // while it glides so it isn't cut off before the panel has slid over it.
            clipsToBounds = false
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .allowUserInteraction],
                           animations: apply) { _ in self.clipsToBounds = true }
        } else {
            apply()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        setNeedsLayout()
        if !applyingSharedZoom { onZoom?(zoomScale, animatingZoom) }
    }

    /// Zoom about the middle of the viewport (setZoomScale alone keeps the top-left corner).
    func setZoomScale(_ scale: CGFloat, keepingCentre: Bool) {
        let centre = CGPoint(x: (bounds.midX - imageView.frame.minX) / zoomScale,
                             y: (bounds.midY - imageView.frame.minY) / zoomScale) // image points at zoom 1
        zoomScale = scale
        layoutIfNeeded()
        let o = imageView.frame.origin
        contentOffset = CGPoint(
            x: min(max(o.x + centre.x * scale - bounds.width / 2, 0), max(0, contentSize.width - bounds.width)),
            y: min(max(o.y + centre.y * scale - bounds.height / 2, 0), max(0, contentSize.height - bounds.height)))
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { // viewport moved
        layoutCrosshair(); layoutScaleBar(); reportViewport()
        // Only this pane's own pans, pinches and double-taps, not follows or layout.
        // ponytail: one SwiftUI update per scroll tick, like the shared zoom; route through a
        // UIKit bridge between the panes if Multi view panning ever stutters.
        if !applyingSharedZoom, isTracking || isDecelerating || isZooming || animatingZoom {
            onPan?(centreFraction, animatingZoom)
        }
    }

    /// The image point at the middle of the viewport, as fractions of the image (x right,
    /// y down); setting it scrolls there as far as the edges allow.
    var centreFraction: CGPoint {
        get {
            let s = imageView.bounds.size // unzoomed
            guard s.width > 0, s.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
            return CGPoint(x: (bounds.midX - imageView.frame.minX) / zoomScale / s.width,
                           y: (bounds.midY - imageView.frame.minY) / zoomScale / s.height)
        }
        set {
            layoutIfNeeded()
            let o = imageView.frame.origin, s = imageView.frame.size
            contentOffset = CGPoint(
                x: min(max(o.x + newValue.x * s.width - bounds.width / 2, 0), max(0, contentSize.width - bounds.width)),
                y: min(max(o.y + newValue.y * s.height - bounds.height / 2, 0), max(0, contentSize.height - bounds.height)))
        }
    }

    private func reportViewport() {
        guard let onViewport, bounds.width > 0 else { return }
        let f = imageView.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        if f != reported { reported = f; onViewport(f) }
    }

    /// Crosshair lines in content coordinates (the scroll view's own layer scrolls with the
    /// content), spanning the visible viewport, at a constant 1 pt whatever the zoom.
    /// FOV rectangles over the image (content coordinates, so they follow zoom and pan),
    /// each labelled with its station at the top-left corner and its width and height (cm)
    /// along the bottom and right edges. Labels stay 11 pt whatever the zoom.
    private func layoutFOV() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let f = imageView.frame
        let sessionCount = (fov.map(\.session).max() ?? -1) + 1
        while fovLayers.count < sessionCount {
            let l = CAShapeLayer()
            l.strokeColor = UIColor(FOVSession.color(fovLayers.count)).withAlphaComponent(0.85).cgColor
            l.lineWidth = 1 // as thin as the crosshair
            l.fillColor = nil
            layer.addSublayer(l); fovLayers.append(l)
        }
        let paths = (0..<fovLayers.count).map { _ in UIBezierPath() }
        var cornerUse = [CGPoint: Int]() // overlapping boxes (axial slices in a station overlap) share a corner
        func label(_ alignment: CATextLayerAlignmentMode) -> CATextLayer {
            let t = CATextLayer()
            t.fontSize = 11
            t.contentsScale = traitCollection.displayScale; t.alignmentMode = alignment
            // A dark halo keeps the coloured text legible over bright tissue.
            t.shadowColor = UIColor.black.cgColor; t.shadowOpacity = 0.9; t.shadowRadius = 1.5; t.shadowOffset = .zero
            layer.addSublayer(t); return t
        }
        while fovLabels.count < fov.count { fovLabels.append(label(.left)) }
        while fovSizeLabels.count < 2 * fov.count { fovSizeLabels.append(label(.center)) }
        // Stations overlap, and an axial slice through an overlap cuts two near-identical
        // boxes: an edge length already shown at (about) the same place isn't repeated.
        var shown = [(String, CGPoint)]()
        func place(_ t: CATextLayer, _ text: String, centre: CGPoint, vertical: Bool, color: CGColor) {
            if shown.contains(where: { $0.0 == text && hypot($0.1.x - centre.x, $0.1.y - centre.y) < 20 }) { t.isHidden = true; return }
            shown.append((text, centre))
            t.string = text; t.isHidden = false; t.foregroundColor = color
            t.setAffineTransform(.identity)
            t.bounds = CGRect(x: 0, y: 0, width: 60, height: 14)
            t.position = centre
            if vertical { t.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2)) } // reads bottom to top
        }
        for (i, t) in fovLabels.enumerated() {
            guard i < fov.count else { t.isHidden = true; continue }
            let r = fov[i].rect
            let box = CGRect(x: f.minX + r.minX * f.width, y: f.minY + r.minY * f.height,
                             width: r.width * f.width, height: r.height * f.height).integral.insetBy(dx: 0.75, dy: 0.75)
            paths[fov[i].session].append(UIBezierPath(rect: box))
            let color = UIColor(FOVSession.color(fov[i].session)).cgColor
            t.string = fov[i].label; t.isHidden = false; t.foregroundColor = color
            let n = cornerUse[box.origin, default: 0]; cornerUse[box.origin] = n + 1
            t.frame = CGRect(x: box.minX + 3 + CGFloat(n) * 16, y: box.minY + 2, width: 24, height: 14)
            // Inside the box, so neighbouring stations' labels don't land on each other.
            let w = fovSizeLabels[2 * i], h = fovSizeLabels[2 * i + 1]
            place(w, FOVRect.cm(fov[i].widthMM), centre: CGPoint(x: box.midX, y: box.maxY - 9), vertical: false, color: color)
            place(h, FOVRect.cm(fov[i].heightMM), centre: CGPoint(x: box.maxX - 9, y: box.midY), vertical: true, color: color)
            // Too small to fit a label: leave the edge bare.
            if box.width < 64 { w.isHidden = true }
            if box.height < 64 { h.isHidden = true }
        }
        for t in fovSizeLabels.dropFirst(2 * fov.count) { t.isHidden = true }
        for (l, p) in zip(fovLayers, paths) { l.path = p.isEmpty ? nil : p.cgPath }
    }

    /// A bar of a round length (1, 2 or 5 × 10ⁿ mm) about 80 pt long at the current zoom,
    /// pinned to the viewport's bottom-right corner (the scroll view's own layer moves with
    /// the content, so it is placed relative to `bounds`).
    private func layoutScaleBar() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let f = imageView.frame
        guard f.width > 0, extent.width > 0, bounds.width > 120 else { scaleBar.path = nil; scaleLabel.isHidden = true; return }
        let ptPerMM = f.width / extent.width
        let target = 80 / ptPerMM // mm
        let decade = pow(10, floor(log10(target)))
        let mm = [5, 2, 1].map { $0 * decade }.first { $0 <= target } ?? decade
        let length = (mm * ptPerMM).rounded()
        let right = bounds.maxX - 16, y = (bounds.maxY - 16 - scaleBarInset).rounded() + 0.5, tick: CGFloat = 4
        let path = UIBezierPath()
        path.move(to: CGPoint(x: right - length, y: y - tick)); path.addLine(to: CGPoint(x: right - length, y: y))
        path.addLine(to: CGPoint(x: right, y: y)); path.addLine(to: CGPoint(x: right, y: y - tick))
        scaleBar.path = path.cgPath
        scaleLabel.string = String(format: "%g cm", mm / 10)
        scaleLabel.isHidden = false
        scaleLabel.frame = CGRect(x: right - length / 2 - 40, y: y - tick - 16, width: 80, height: 14)
    }

    private func layoutCrosshair() {
        guard let c = crosshair else { crosshairLayer.path = nil; return }
        let f = imageView.frame, v = bounds, gap: CGFloat = 7
        let x = (f.minX + c.x * f.width).rounded() + 0.5, y = (f.minY + c.y * f.height).rounded() + 0.5
        let path = UIBezierPath()
        path.move(to: CGPoint(x: v.minX, y: y)); path.addLine(to: CGPoint(x: x - gap, y: y))
        path.move(to: CGPoint(x: x + gap, y: y)); path.addLine(to: CGPoint(x: v.maxX, y: y))
        path.move(to: CGPoint(x: x, y: v.minY)); path.addLine(to: CGPoint(x: x, y: y - gap))
        path.move(to: CGPoint(x: x, y: y + gap)); path.addLine(to: CGPoint(x: x, y: v.maxY))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        crosshairLayer.path = path.cgPath
        CATransaction.commit()
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === scrub { return zoomScale <= minimumZoomScale + 0.01 }
        return super.gestureRecognizerShouldBegin(g)
    }

    @objc private func singleTapped(_ g: UITapGestureRecognizer) {
        guard let onLocate else { onTap(); return }
        let p = g.location(in: imageView), size = imageView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        onLocate(CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1)))
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        // Animated by hand rather than zoom(to:animated:): that animates the zoom but not
        // the recentring done in layoutSubviews, so the image appeared to grow from the
        // wrong place. Here zoom, recentring and offset change in one animation, with the
        // offset chosen to keep the tapped point under the finger (as far as edges allow).
        let zoomIn = zoomScale <= minimumZoomScale + 0.01
        let scale = zoomIn ? 3 : minimumZoomScale
        let p = g.location(in: imageView)                       // tapped point, image points at zoom 1
        let q = g.location(in: self) - bounds.origin            // same point in the viewport
        animatingZoom = true
        defer { animatingZoom = false }
        UIView.animate(withDuration: 0.3) {
            self.zoomScale = scale
            self.layoutIfNeeded()
            guard zoomIn else { return }
            let o = self.imageView.frame.origin
            self.contentOffset = CGPoint(
                x: min(max(o.x + p.x * scale - q.x, 0), max(0, self.contentSize.width - self.bounds.width)),
                y: min(max(o.y + p.y * scale - q.y, 0), max(0, self.contentSize.height - self.bounds.height)))
        }
    }

    @objc private func scrubbed(_ g: UIPanGestureRecognizer) {
        let y = g.translation(in: self).y
        let steps = Int(-y / Self.pointsPerSlice) // drag up = towards higher slices
        guard steps != 0 else { return }
        onScrub(steps)
        g.setTranslation(CGPoint(x: 0, y: y + CGFloat(steps) * Self.pointsPerSlice), in: self)
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

extension UIColor {
    convenience init(_ rgb: SIMD3<Float>) { self.init(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1) }
}
