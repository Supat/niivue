//
//  strip_check.swift — self-check for the 3D frame's strip plan (StripPlan).
//  Build & run: mkdir -p /tmp/sp && cp spike/strip_check.swift /tmp/sp/main.swift &&
//    swiftc NiiMono/Rendering/StripPlan.swift /tmp/sp/main.swift -O -o /tmp/sp/check && /tmp/sp/check
//
//  Frames are simulated against a cost profile like the one in the device log (the top
//  of the drawable free thanks to empty-space skipping, the body in the bottom rows):
//  the plan must bring every strip under budget, then hold still, at full quality and
//  through gesture frames at a quarter of the pixels.
//

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok: \(what)") } }
/// Same plan within a row: boundaries re-round to the rows of whatever drawable was just drawn.
func same(_ a: [Double], _ b: [Double], height: Double) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 1 / height }
}

/// GPU seconds a strip of `rows` costs at full quality on a `width`×`height` drawable:
/// nothing above 55% of the height, then a body whose cost rises towards the bottom.
func cost(rows: Range<Int>, width: Double, height: Double, full: (Double, Double)) -> Double {
    var t = 0.0
    for r in rows {
        let f = Double(r) / height
        guard f > 0.55 else { continue }
        t += (0.2 + 2.2 * (f - 0.55) / 0.45) * width / full.0 / full.1 // ~0.23 s for the bottom third of the full drawable
    }
    return t * 0.5
}

let full = (1107.0 * 2, 970.0 * 2) // the device's drawable at 2× (the log's 1107×970 was 1×)
var plan = StripPlan()

/// One frame: plan, "render", measure, rebalance. Returns the strips' real (unnormalised) seconds.
func frame(width: Double, height: Double, stride: Double = 1) -> [Double] {
    let rows = plan.rows(width: width, height: height)
    let bounds = rows.map { Double($0) / height }
    var real: [Double] = [], norm: [Double] = []
    for i in 0..<rows.count - 1 {
        let t = cost(rows: rows[i]..<rows[i + 1], width: width, height: height, full: full) / stride
        real.append(t)
        norm.append(t * stride * plan.peakPixels / (width * height))
    }
    plan.rebalance(bounds: bounds, height: height, times: norm)
    return real
}

// 1. First frame is the old equal split; the bottom strip is well over budget.
let first = frame(width: full.0, height: full.1)
check(first.count == 11, "first frame uses the pixel-count split (\(first.count) strips)")
check(first.max()! > StripPlan.budget, "the body strip is over budget before any measurement (\(String(format: "%.3f", first.max()!)) s)")

// 2. Within a few frames every strip is under budget, and the plan then holds still.
var times: [Double] = []
for _ in 0..<6 { times = frame(width: full.0, height: full.1) }
check(times.max()! <= StripPlan.budget, "every strip under budget after 6 frames (max \(String(format: "%.3f", times.max()!)) s, \(times.count) strips)")
let settled = plan.cuts
for _ in 0..<10 { _ = frame(width: full.0, height: full.1) }
check(plan.cuts == settled, "plan is still after settling (\(plan.cuts.count + 1) strips)")
check(plan.cuts.count + 1 <= StripPlan.maxStrips, "strip count within the cap")
let free = frame(width: full.0, height: full.1).prefix { $0 == 0 }.count
check(free <= 2, "the free rows above the body are at most two strips (\(free))")

// 3. Gesture frames at 1 pixel per point (a quarter of the pixels): the plan holds, so the
//    full-quality frame after the gesture is under budget too.
for _ in 0..<10 { _ = frame(width: full.0 / 2, height: full.1 / 2) }
check(same(plan.cuts, settled, height: full.1 / 2), "quarter-pixel frames leave the plan alone (\(plan.cuts.count + 1) strips)")
let after = frame(width: full.0, height: full.1)
check(after.max()! <= StripPlan.budget, "first full frame after a gesture is under budget (max \(String(format: "%.3f", after.max()!)) s)")

// 4. A glide at a quarter of the samples: same.
for _ in 0..<5 { _ = frame(width: full.0, height: full.1, stride: 4) }
check(same(plan.cuts, settled, height: full.1 / 2), "coarse-stride frames leave the plan alone (\(plan.cuts.count + 1) strips)")

// 5. A killed strip (reported as 4× budget by the renderer) is split next frame.
var killed = StripPlan()
_ = killed.rows(width: full.0, height: full.1)
let b = [0.0, 1.0 / 3, 2.0 / 3, 1.0]
killed.rebalance(bounds: b, height: full.1, times: [0, 0.016, 4 * StripPlan.budget])
check(killed.cuts.count + 1 == 1 + 6, "a killed bottom third is split six ways (\(killed.cuts.count + 1) strips)")
check(killed.cuts.first == 2.0 / 3, "the two free strips above it are merged into one")

// 6. A snapshot four times the pixels subdivides each strip; the plan is untouched.
let before = plan.cuts
let snap = plan.rows(width: full.0 * 2, height: full.1 * 2, onScreen: false)
check(snap.count - 1 >= 2 * (before.count + 1), "a 4× snapshot has at least twice the strips (\(snap.count - 1) vs \(before.count + 1))")
check(plan.cuts == before && plan.peakPixels == full.0 * full.1, "a snapshot changes neither the plan nor the peak")
check(zip(snap, snap.dropFirst()).allSatisfy { $0 < $1 } && snap.first == 0 && snap.last == Int(full.1 * 2), "snapshot rows ascend from 0 to the height")

// 7. Degenerate sizes don't crash or produce empty strips.
var tiny = StripPlan()
let r = tiny.rows(width: 3, height: 2)
check(r == [0, 2], "a 3×2 drawable is one strip (\(r))")
tiny.rebalance(bounds: [0, 1], height: 2, times: [1])
check(tiny.rows(width: 3, height: 2) == [0, 2], "a 2-row strip is never split below the minimum rows")

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
