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
    /// Crosshair position as fractions of the displayed image (0...1, x right, y down), or nil.
    var crosshair: CGPoint? = nil
    /// If set, a tap reports its position (same fractions) instead of calling onTap.
    var onLocate: ((CGPoint) -> Void)? = nil
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
        view.onZoom = onZoom
        if let zoom, abs(zoom - view.zoomScale) > 0.001, !view.isZooming, !view.isTracking {
            if zoomAnimated {
                UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
                    view.setZoomScale(zoom, keepingCentre: true)
                }
            } else {
                view.setZoomScale(zoom, keepingCentre: true)
            }
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
    var imageKey: SliceView.ImageKey?
    private var animatingZoom = false
    var crosshair: CGPoint? { didSet { if crosshair != oldValue { layoutCrosshair() } } }
    private let crosshairLayer = CAShapeLayer()
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
                zoomScale = 1
                let ref = fitExtent ?? extent
                let k = min(bounds.width / ref.width, bounds.height / ref.height)
                imageView.frame = CGRect(x: 0, y: 0, width: extent.width * k, height: extent.height * k)
                contentSize = imageView.frame.size
            }
            // Keep the image centred whenever it is smaller than the viewport.
            imageView.frame.origin = CGPoint(x: max(0, (bounds.width - imageView.frame.width) / 2),
                                             y: max(0, (bounds.height - imageView.frame.height) / 2))
            layoutCrosshair()
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
        onZoom?(zoomScale, animatingZoom)
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
    func scrollViewDidScroll(_ scrollView: UIScrollView) { layoutCrosshair() } // viewport moved

    /// Crosshair lines in content coordinates (the scroll view's own layer scrolls with the
    /// content), spanning the visible viewport, at a constant 1 pt whatever the zoom.
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
