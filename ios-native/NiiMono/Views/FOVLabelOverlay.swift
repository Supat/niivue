//
//  FOVLabelOverlay.swift — edge lengths (cm) of the station FOV wireframes in the 3D view:
//  text laid over the render at the projected midpoint of one edge per axis of each box.
//

import UIKit

final class FOVLabelOverlay: UIView {
    private var labels: [CATextLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One label per entry: text, colour and position in this view's coordinates.
    func show(_ items: [(text: String, color: UIColor, at: CGPoint)]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        while labels.count < items.count {
            let t = CATextLayer()
            t.fontSize = 11; t.alignmentMode = .center
            t.contentsScale = traitCollection.displayScale
            // Same dark halo as the slice overlay, for legibility over bright tissue.
            t.shadowColor = UIColor.black.cgColor; t.shadowOpacity = 0.9; t.shadowRadius = 1.5; t.shadowOffset = .zero
            layer.addSublayer(t); labels.append(t)
        }
        for (i, t) in labels.enumerated() {
            guard i < items.count else { t.isHidden = true; continue }
            t.string = items[i].text; t.foregroundColor = items[i].color.cgColor; t.isHidden = false
            t.bounds = CGRect(x: 0, y: 0, width: 60, height: 14)
            t.position = items[i].at
        }
    }
}
