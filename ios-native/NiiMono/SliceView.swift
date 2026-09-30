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
    let onTap: () -> Void
    let onScrub: (Int) -> Void

    func makeUIView(context: Context) -> ZoomView { ZoomView() }

    func updateUIView(_ view: ZoomView, context: Context) {
        let s = volume.slice(axis: axis, index: index, lo: lo, hi: hi)
        if let provider = CGDataProvider(data: Data(s.pixels) as CFData),
           let image = CGImage(width: s.width, height: s.height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: s.width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            view.imageView.image = UIImage(cgImage: image, scale: 1, orientation: mirrored ? .upMirrored : .up)
        }
        let e = volume.sliceExtent(axis: axis)
        view.extent = CGSize(width: CGFloat(e.0), height: CGFloat(e.1))
        view.onTap = onTap
        view.onScrub = onScrub
    }
}

final class ZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: () -> Void = {}
    var onScrub: (Int) -> Void = { _ in }
    /// Physical size of the slice (mm); only its aspect ratio matters.
    var extent = CGSize(width: 1, height: 1) { didSet { if extent != oldValue { setNeedsLayout() } } }

    private var fitted: (bounds: CGSize, extent: CGSize) = (.zero, .zero)
    private let scrub = UIPanGestureRecognizer()
    private static let pointsPerSlice: CGFloat = 5

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        maximumZoomScale = 12
        contentInsetAdjustmentBehavior = .never // content sits under the glass bars, like Preview
        topEdgeEffect.isHidden = true // no bar backdrop over the image; match the 3D view
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        addSubview(imageView)

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
        let refit = fitted.bounds != bounds.size || fitted.extent != extent
        // A width-only change with the same slice is the inspector opening or closing:
        // glide to the new centre instead of jumping. (Rotation already runs inside the
        // system's own animation; first layout and plane changes should not animate.)
        let glide = refit && fitted.extent == extent && fitted.bounds.height == bounds.height
            && fitted.bounds.width > 0 && UIView.inheritedAnimationDuration == 0
        let apply = { [self] in
            if refit {
                // Aspect-fit at zoom 1. Resets zoom on rotation / inspector / plane change.
                fitted = (bounds.size, extent)
                zoomScale = 1
                let k = min(bounds.width / extent.width, bounds.height / extent.height)
                imageView.frame = CGRect(x: 0, y: 0, width: extent.width * k, height: extent.height * k)
                contentSize = imageView.frame.size
            }
            // Keep the image centred whenever it is smaller than the viewport.
            imageView.frame.origin = CGPoint(x: max(0, (bounds.width - imageView.frame.width) / 2),
                                             y: max(0, (bounds.height - imageView.frame.height) / 2))
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
    func scrollViewDidZoom(_ scrollView: UIScrollView) { setNeedsLayout() }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === scrub { return zoomScale <= minimumZoomScale + 0.01 }
        return super.gestureRecognizerShouldBegin(g)
    }

    @objc private func singleTapped() { onTap() }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        // Animated by hand rather than zoom(to:animated:): that animates the zoom but not
        // the recentring done in layoutSubviews, so the image appeared to grow from the
        // wrong place. Here zoom, recentring and offset change in one animation, with the
        // offset chosen to keep the tapped point under the finger (as far as edges allow).
        let zoomIn = zoomScale <= minimumZoomScale + 0.01
        let scale = zoomIn ? 3 : minimumZoomScale
        let p = g.location(in: imageView)                       // tapped point, image points at zoom 1
        let q = g.location(in: self) - bounds.origin            // same point in the viewport
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
