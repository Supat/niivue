//
//  StripPlan.swift — Where a 3D frame is cut into strips, each its own command buffer.
//
//  The GPU watchdog kills a command buffer that runs too long, and the system kills the
//  frames of a process whose GPU work starves the compositor for seconds on end, so a
//  frame is encoded as horizontal strips. The strips are not equal: empty-space skipping
//  makes the rows above and below the body nearly free, so equal strips put the whole
//  body in one buffer (on a whole-body scan the bottom third took 0.2 s while the top two
//  took 0.016 s together, and the watchdog killed it). The boundaries are fractions of the
//  height, rebalanced after every frame from the strips' measured GPU times: a strip over
//  the budget is split, neighbours that are cheap together are merged, with a gap between
//  the two thresholds so the plan settles rather than flickers. Times are normalised by the
//  caller to the largest drawable seen at the full sample stride, so strips planned during
//  a gesture (1 pixel per point) or a glide (a quarter of the samples) still hold for the
//  full-quality frame that follows. `spike/strip_check.swift` exercises it.
//

import Foundation

struct StripPlan {
    static let budget = 0.05 // GPU seconds per command buffer, at full quality
    static let maxStrips = 32, minRows = 4

    /// Interior boundaries, as fractions of the height, ascending.
    private(set) var cuts: [Double] = []
    /// The largest drawable planned for (pixels): times are normalised to it, and a larger
    /// snapshot gets each strip subdivided to match.
    private(set) var peakPixels = 1.0

    /// Row boundaries of the strips for a drawable of `width`×`height` pixels: strip `i`
    /// is `rows[i]..<rows[i+1]`. `onScreen` frames raise the peak; snapshots don't.
    mutating func rows(width: Double, height: Double, onScreen: Bool = true) -> [Int] {
        let pixels = width * height, h = Int(height)
        if onScreen { peakPixels = max(peakPixels, pixels) }
        if cuts.isEmpty { // before any measurement: ~400k pixels a strip
            let n = max(1, min(16, Int((pixels / 400_000).rounded(.up))))
            cuts = (1..<n).map { Double($0) / Double(n) }
        }
        let extra = max(1, min(8, Int((pixels / peakPixels).rounded(.up))))
        var rows = [0]
        for (i, hi) in (cuts + [1]).enumerated() {
            let lo = i == 0 ? 0 : cuts[i - 1]
            for k in 1...extra { // the final boundary, at the height, is appended below
                let r = Int((Double(h) * (lo + (hi - lo) * Double(k) / Double(extra))).rounded())
                if r > rows.last!, r < h { rows.append(r) }
            }
        }
        rows.append(max(h, 1))
        return rows
    }

    /// New boundaries from a completed frame: its strips' `bounds` (fractions, one more
    /// than `times`), its `height` in rows, and each strip's normalised GPU seconds.
    mutating func rebalance(bounds: [Double], height: Double, times: [Double]) {
        let budget = Self.budget
        guard times.count == bounds.count - 1, !times.isEmpty else { return }
        let minFrac = Double(Self.minRows) / max(1, height)
        var out: [(lo: Double, hi: Double, t: Double)] = []
        for i in 0..<times.count {
            let lo = bounds[i], hi = bounds[i + 1], t = times[i]
            if t > budget, hi - lo > 2 * minFrac {
                let k = min(8, max(2, Int((t / (budget * 0.7)).rounded(.up))), Int((hi - lo) / minFrac))
                for j in 0..<k { out.append((lo + (hi - lo) * Double(j) / Double(k), lo + (hi - lo) * Double(j + 1) / Double(k), t / Double(k))) }
            } else if let last = out.last, last.t + t < budget * 0.4 {
                out[out.count - 1] = (last.lo, hi, last.t + t)
            } else {
                out.append((lo, hi, t))
            }
        }
        while out.count > Self.maxStrips { // merge the cheapest neighbours
            var best = 0
            for i in 1..<(out.count - 1) where out[i].t + out[i + 1].t < out[best].t + out[best + 1].t { best = i }
            out[best] = (out[best].lo, out[best + 1].hi, out[best].t + out[best + 1].t)
            out.remove(at: best + 1)
        }
        cuts = out.dropFirst().map(\.lo)
    }
}
