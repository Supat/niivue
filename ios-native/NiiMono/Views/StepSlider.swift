//
//  StepSlider.swift — the app's slider: drag the knob as usual; a tap on the track
//  either side of the knob nudges the value one `unit` in that direction.
//

import SwiftUI
import UIKit

struct StepSlider<V: BinaryFloatingPoint>: UIViewRepresentable {
    @Binding var value: V
    let range: ClosedRange<V>
    let unit: V

    init(value: Binding<V>, in range: ClosedRange<V>, unit: V) {
        _value = value
        self.range = range
        self.unit = unit
    }

    final class Coordinator: NSObject {
        var set: (Float) -> Void = { _ in }
        @objc func changed(_ slider: UISlider) { set(slider.value) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TrackTapSlider {
        let slider = TrackTapSlider()
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .valueChanged)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateUIView(_ slider: TrackTapSlider, context: Context) {
        context.coordinator.set = { value = V($0) }
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.unit = Float(unit)
        // Don't fight the finger: while dragging, the slider is the source of truth
        // (the binding may round, e.g. to whole slices).
        if !slider.isTracking { slider.value = Float(value) }
    }
}

final class TrackTapSlider: UISlider {
    var unit: Float = 1

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let knob = thumbRect(forBounds: bounds, trackRect: trackRect(forBounds: bounds), value: value)
            .insetBy(dx: -8, dy: -8) // forgiving grab area
        let x = touch.location(in: self).x
        if x >= knob.minX && x <= knob.maxX { return super.beginTracking(touch, with: event) }
        let towardsMax = (x > knob.midX) != (effectiveUserInterfaceLayoutDirection == .rightToLeft)
        setValue(value + (towardsMax ? unit : -unit), animated: true) // UISlider clamps to its range
        sendActions(for: .valueChanged)
        return false
    }
}
