//
//  ScaleBar.swift — the scale shown with images: a round length (1, 2 or 5 × 10ⁿ mm) about
//  80 pt long at the current magnification, used for the scale bar and the crosshair ticks.
//

import UIKit

enum ScaleStep {
    /// The round length for `pointsPerMM`, in mm and in points; nil when there is no scale.
    static func nice(pointsPerMM: CGFloat) -> (mm: CGFloat, pt: CGFloat)? {
        guard pointsPerMM > 0, pointsPerMM.isFinite else { return nil }
        let target = 80 / pointsPerMM
        let decade = pow(10, floor(log10(target)))
        let mm = [5, 2, 1].map { $0 * decade }.first { $0 <= target } ?? decade
        return (mm, (mm * pointsPerMM).rounded())
    }

    static func label(mm: CGFloat) -> String { String(format: "%g cm", mm / 10) }
}

/// A free-standing scale bar (the 3D view's): bar left-aligned at the bottom of the view,
/// its length above it.
final class ScaleBarView: UIView {
    private let bar = CAShapeLayer()
    private let text = CATextLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // White with a dark halo, as on the slice views.
        for l in [bar, text] as [CALayer] {
            l.shadowColor = UIColor.black.cgColor; l.shadowOpacity = 0.9; l.shadowRadius = 1.5; l.shadowOffset = .zero
            layer.addSublayer(l)
        }
        bar.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        bar.lineWidth = 1.5
        bar.fillColor = nil
        text.fontSize = 11
        text.foregroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        text.alignmentMode = .center
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ step: (mm: CGFloat, pt: CGFloat)?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let step, step.pt <= bounds.width else { bar.path = nil; text.isHidden = true; return }
        let y = (bounds.maxY - 1).rounded() + 0.5, tick: CGFloat = 4, length = step.pt
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.75, y: y - tick)); path.addLine(to: CGPoint(x: 0.75, y: y))
        path.addLine(to: CGPoint(x: length, y: y)); path.addLine(to: CGPoint(x: length, y: y - tick))
        bar.path = path.cgPath
        text.contentsScale = traitCollection.displayScale
        text.string = ScaleStep.label(mm: step.mm); text.isHidden = false
        text.frame = CGRect(x: length / 2 - 40, y: y - tick - 16, width: 80, height: 14)
    }
}
