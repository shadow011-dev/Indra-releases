import SwiftUI

/// Notch outline: concave "ears" at the top, large squircle-style corners at the bottom.
/// Curve exponents and the bottom corner aspect were fitted to a reference screenshot.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    /// Vertical radius of the bottom corners (horizontal radius is `bottomAspect` times larger).
    var bottomCornerRadius: CGFloat
    /// v394: on an external monitor the notch is a floating island. Its body is drawn like the notch's (`topCornerRadius`
    /// is then the inset of its sides, so every page sits exactly as it does in the notch), but all four corners are
    /// rounded, the top ones with `islandTopRadius`, the bottom ones with `bottomCornerRadius`.
    var island = false
    var islandTopRadius: CGFloat = 0
    /// v404: 0...1: how far the bottom-LEFT corner has turned into a true circle of `vinylCornerRadius`. On the Duo page
    /// with the record open, that circle is concentric with the disc, so the border of the notch is the same distance
    /// from the round disc all the way round (the normal corner is tighter than the disc and left a wide gap there).
    /// v405: the bottom-right corner takes the same shape, so the notch is symmetrical while the record is open.
    var vinylCorner: CGFloat = 0
    var vinylCornerRadius: CGFloat = 54

    private static let earExponent = 2.5
    private static let bottomExponent = 2.2
    private static let bottomAspect: CGFloat = 1.375
    private static let islandExponent = 2.6
    private static let steps = 18

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(topCornerRadius, AnimatablePair(bottomCornerRadius, AnimatablePair(islandTopRadius, vinylCorner))) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second.first
            islandTopRadius = newValue.second.second.first
            vinylCorner = newValue.second.second.second
        }
    }

    /// The island: a rounded body (superellipse corners, like the system's continuous corners).
    private func islandPath(in rect: CGRect) -> Path {
        let inset = min(max(0, topCornerRadius), max(0, rect.width / 2 - 1))
        let body = CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset * 2, height: rect.height)
        guard body.width > 1, body.height > 1 else { return Path(rect) }
        var rt = max(0, islandTopRadius)
        var rb = max(0, bottomCornerRadius)
        // v430: with the record open the bottom corners turn into the circle round the disc, exactly as on the Mac notch.
        let k = min(max(vinylCorner, 0), 1)
        rb += (max(vinylCornerRadius, rb) - rb) * k
        // v461: the top corners follow the record too, with the same curve as the bottom ones.
        rt += (max(vinylCornerRadius, rt) - rt) * k
        // The corners never overlap, whatever size the body is while it grows or shrinks.
        let vertical = min(1, body.height / max(rt + rb, 0.001))
        rt *= vertical
        rb *= vertical
        let horizontal = min(1, body.width / max(2 * max(rt, rb), 0.001))
        rt *= horizontal
        rb *= horizontal

        // With the record open the corner is a true circle (exponent 2), exactly like the Mac notch's record corner, so the
        // gap between the disc and the border is the same all the way round.
        let n = Self.islandExponent + (2.0 - Self.islandExponent) * Double(min(max(vinylCorner, 0), 1))
        let steps = Self.steps
        func sp(_ th: Double) -> CGFloat { CGFloat(pow(max(0, sin(th)), 2.0 / n)) }
        func cp(_ th: Double) -> CGFloat { CGFloat(pow(max(0, cos(th)), 2.0 / n)) }

        var p = Path()
        p.move(to: CGPoint(x: body.minX + rt, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - rt, y: body.minY))
        // Top right
        for i in 0...steps {
            let th = Double(i) / Double(steps) * Double.pi / 2
            p.addLine(to: CGPoint(x: body.maxX - rt + rt * sp(th), y: body.minY + rt - rt * cp(th)))
        }
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - rb))
        // Bottom right
        for i in 0...steps {
            let th = Double(i) / Double(steps) * Double.pi / 2
            p.addLine(to: CGPoint(x: body.maxX - rb + rb * cp(th), y: body.maxY - rb + rb * sp(th)))
        }
        p.addLine(to: CGPoint(x: body.minX + rb, y: body.maxY))
        // Bottom left
        for i in 0...steps {
            let th = Double(i) / Double(steps) * Double.pi / 2
            p.addLine(to: CGPoint(x: body.minX + rb - rb * sp(th), y: body.maxY - rb + rb * cp(th)))
        }
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + rt))
        // Top left
        for i in 0...steps {
            let th = Double(i) / Double(steps) * Double.pi / 2
            p.addLine(to: CGPoint(x: body.minX + rt - rt * cp(th), y: body.minY + rt - rt * sp(th)))
        }
        p.closeSubpath()
        return p
    }

    func path(in rect: CGRect) -> Path {
        if island { return islandPath(in: rect) }
        let t = max(0, topCornerRadius)
        let ry = max(0, bottomCornerRadius)
        let rx = ry * Self.bottomAspect
        let ne = Self.earExponent
        let nb = Self.bottomExponent
        let steps = Self.steps

        func sp(_ th: Double, _ n: Double) -> CGFloat { CGFloat(pow(max(0, sin(th)), 2.0 / n)) }
        func cp(_ th: Double, _ n: Double) -> CGFloat { CGFloat(pow(max(0, cos(th)), 2.0 / n)) }

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))

        func arc(_ point: (Double) -> CGPoint) {
            for i in 0...steps {
                let th = Double(i) / Double(steps) * Double.pi / 2
                p.addLine(to: point(th))
            }
        }

        // Left ear: (minX, minY) -> (minX + t, minY + t)
        arc { th in CGPoint(x: rect.minX + t * sp(th, ne),
                            y: rect.minY + t - t * cp(th, ne)) }

        // Bottom-left corner (turns into a true circle round the record while it is open on the Duo page)
        let k = min(max(vinylCorner, 0), 1)
        let target = max(vinylCornerRadius, ry)
        var ryL = ry + (target - ry) * k
        var rxL = rx + (target - rx) * k
        // v412: the bottom corners never get taller than the body below the ears, nor wider than half of it, so the
        // outline cannot fold over itself while the notch is still small (opening, closing, resizing). At rest the
        // factor is 1 and the curves are exactly what they were.
        let room = min(max(rect.height - t, 0.5) / max(ryL, 0.001), max(rect.width / 2 - t, 0.5) / max(rxL, 0.001))
        if room < 1 { ryL *= room; rxL *= room }
        let nbL = nb + (2.0 - nb) * Double(k)
        let blx = rect.minX + t + rxL
        let bly = rect.maxY - ryL
        arc { th in CGPoint(x: blx - rxL * cp(th, nbL),
                            y: bly + ryL * sp(th, nbL)) }

        // Bottom-right corner (the same shape as the left one, so the open record sits in a symmetrical notch)
        let ryR = ryL
        let rxR = rxL
        let brx = rect.maxX - t - rxR
        let bry = rect.maxY - ryR
        arc { th in CGPoint(x: brx + rxR * sp(th, nbL),
                            y: bry + ryR * cp(th, nbL)) }

        // Right ear: (maxX - t, minY + t) -> (maxX, minY)
        arc { th in CGPoint(x: rect.maxX - t * cp(th, ne),
                            y: rect.minY + t - t * sp(th, ne)) }

        p.closeSubpath()
        return p
    }
}
