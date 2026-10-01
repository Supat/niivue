//
//  ProfilePhotoPane.swift — the photo half of the side-by-side view: the profile photo
//  placed so it follows the slice pane's zoom and pan. A tap drops a marker, which the slice
//  pane shows at the matching position.
//

import SwiftUI
import UIKit

struct ProfilePhotoPane: UIViewRepresentable {
    let image: UIImage
    /// The photo's frame in the pane's coordinates (may extend beyond it; it is clipped).
    let frame: CGRect
    /// Marker position in the pane's coordinates, or nil.
    let marker: CGPoint?
    /// A tap, in the pane's coordinates.
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> PhotoPaneView { PhotoPaneView() }

    func updateUIView(_ view: PhotoPaneView, context: Context) {
        if view.imageView.image !== image { view.imageView.image = image }
        view.imageView.frame = frame
        view.marker = marker
        view.onTap = onTap
    }
}

final class PhotoPaneView: UIView, SnapshotPane {
    let imageView = UIImageView()
    var onTap: (CGPoint) -> Void = { _ in }
    var marker: CGPoint? { didSet { if marker != oldValue { layoutMarker() } } }
    private let markerLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        addSubview(imageView)
        // Same look as the slice panes' crosshair: thin, translucent, open at the centre.
        markerLayer.strokeColor = UIColor(red: 1, green: 0.25, blue: 0.2, alpha: 0.45).cgColor
        markerLayer.lineWidth = 1
        markerLayer.fillColor = nil
        layer.addSublayer(markerLayer)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) { onTap(g.location(in: self)) }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutMarker()
    }

    private func layoutMarker() {
        guard let m = marker else { markerLayer.path = nil; return }
        let gap: CGFloat = 7, x = m.x.rounded() + 0.5, y = m.y.rounded() + 0.5
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: y)); path.addLine(to: CGPoint(x: x - gap, y: y))
        path.move(to: CGPoint(x: x + gap, y: y)); path.addLine(to: CGPoint(x: bounds.maxX, y: y))
        path.move(to: CGPoint(x: x, y: bounds.minY)); path.addLine(to: CGPoint(x: x, y: y - gap))
        path.move(to: CGPoint(x: x, y: y + gap)); path.addLine(to: CGPoint(x: x, y: bounds.maxY))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        markerLayer.path = path.cgPath
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        SnapshotPanes.register(self)
    }

    func snapshotImage() -> UIImage? {
        UIGraphicsImageRenderer(bounds: bounds, format: .init(for: traitCollection)).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}
