import Foundation
import CoreGraphics

/// CSS-style cubic-bezier easing, so the intro timeline can mirror the web
/// keyframes exactly (each keyframe segment is eased independently, like CSS).
struct CubicBezier {
    let p1x, p1y, p2x, p2y: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        self.p1x = p1x; self.p1y = p1y; self.p2x = p2x; self.p2y = p2y
    }

    static let ease     = CubicBezier(0.25, 0.1, 0.25, 1)
    static let easeIn   = CubicBezier(0.42, 0, 1, 1)
    static let easeOut  = CubicBezier(0, 0, 0.58, 1)
    static let linear   = CubicBezier(0, 0, 1, 1)

    private func sample(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private func slope(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }

    func callAsFunction(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        var t = x
        for _ in 0..<8 {
            let err = sample(t, p1x, p2x) - x
            if abs(err) < 1e-5 { break }
            let d = slope(t, p1x, p2x)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        t = min(max(t, 0), 1)
        return sample(t, p1y, p2y)
    }
}

/// A CSS @keyframes track for a single scalar property.
struct Track {
    /// (offset 0…1, value)
    let stops: [(Double, Double)]
    let easing: CubicBezier

    init(_ stops: [(Double, Double)], easing: CubicBezier = .ease) {
        self.stops = stops
        self.easing = easing
    }

    func value(at p: Double) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if p <= first.0 { return first.1 }
        if p >= last.0 { return last.1 }
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            if p >= a.0 && p <= b.0 {
                let local = (p - a.0) / max(b.0 - a.0, 1e-9)
                return a.1 + (b.1 - a.1) * easing(local)
            }
        }
        return last.1
    }
}

/// Progress (0…1) of an animation that starts at `delay` and lasts `duration`
/// (both seconds), given elapsed time `t`. Mirrors `animation-fill-mode: forwards`.
@inline(__always)
func progress(_ t: Double, delay: Double, duration: Double) -> Double {
    min(max((t - delay) / duration, 0), 1)
}
