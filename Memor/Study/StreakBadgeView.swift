//
//  StreakBadgeView.swift
//  Memor
//
//  The Study-mode streak badge: the streak number inside concentric rings
//  that grow with the run. Up to 29 the progression is one rule over
//  s = min(streak, 29):
//
//    - s/10 + 1 solid rings, inside-out green (the Good button's green),
//      blue, magenta — a new ring is earned at every multiple of 10.
//    - s%10 decorates the OUTERMOST solid ring in its own color:
//      1...8 -> that many triangles pointing outward, equidistant, first at
//      12 o'clock; 9 -> a dashed ring just outside (the next milestone's
//      ghost); 0 -> nothing (the fresh ring stands alone).
//
//  Spelled out: 1-8 green triangles, 9 green dashed, 10 adds the blue ring,
//  11-18 blue triangles, 19 blue dashed, 20 adds the magenta ring, 21-28
//  magenta triangles, 29 magenta dashed.
//
//  The 30s break the pattern. 30: the three solid rings plus two LARGE
//  yellow equilateral triangles on the diagonals — one pointing at the
//  top-right corner, one at the bottom-left — floating clear of the magenta
//  ring. 31-38: one white dot per streak, alternating between two
//  half-rings — odd increments (31, 33, 35, 37) fill the half-ring running
//  clockwise from the LOWER (bottom-left) triangle to the higher one (the
//  left/top arc), even increments (32, 34, 36, 38) the half-ring running
//  clockwise from the HIGHER (top-right) triangle to the lower one (the
//  right/bottom arc). Each half-ring fills in sequence from its starting
//  triangle at the FINAL spacing — five equal 36° gaps per half-ring — so a
//  placed dot never moves and, once all four are down, dots are equidistant
//  to each other and to the triangles. 39: the dots become two dashed white
//  half-rings, each inset from the triangles so the pair reads as two
//  disconnected arcs rather than one dashed circle. >= 40 stays at the
//  39 badge (styling for later tiers is deliberately not designed yet).
//

import AppKit
import SwiftUI

struct StreakBadgeView: View {
    let streak: Int

    /// Ring colors inside-out. Green matches the Good rating button;
    /// magenta is the app's usual NSColor.magenta (SRS mature color).
    private static let ringColors: [Color] = [.green, .blue, Color(nsColor: .magenta)]
    private static let innerRadius: CGFloat = 13
    private static let ringGap: CGFloat = 4
    private static let lineWidth: CGFloat = 1.5
    private static let triangleHeight: CGFloat = 5
    /// Half the triangle's base chord, in points (converted to an angle at
    /// the ring's radius, so bases stay the same size on every ring).
    private static let triangleHalfBase: CGFloat = 3.2

    // MARK: 30s-tier geometry

    /// Side of the two large yellow equilateral triangles.
    private static let largeTriangleSide: CGFloat = 9
    private static var largeTriangleHeight: CGFloat { largeTriangleSide * 0.8660254 }
    /// Clearance between the magenta ring's outer edge and a triangle's base
    /// ("at some distance ... not touching the ring directly").
    private static let largeTriangleGap: CGFloat = 3
    /// The triangles' base line sits this far from center; the white dots
    /// and dashed half-rings run along the triangles' radial middle.
    private static var largeTriangleBaseRadius: CGFloat {
        innerRadius + 2 * ringGap + lineWidth / 2 + largeTriangleGap
    }
    private static var dotRingRadius: CGFloat { largeTriangleBaseRadius + largeTriangleHeight / 2 }
    private static let dotRadius: CGFloat = 1.6
    /// Screen angles (y grows downward): the "higher" triangle points at the
    /// top-right corner, the "lower" one at the bottom-left.
    private static let higherTriangleAngle: CGFloat = -.pi / 4
    private static let lowerTriangleAngle: CGFloat = 3 * .pi / 4
    /// Five equal gaps per half-ring: triangle, four dots, triangle.
    private static let dotSpacing: CGFloat = .pi / 5

    /// Max extent: the large triangles' apexes at largeTriangleBaseRadius +
    /// height (~32.5), plus slop.
    static let sideLength: CGFloat = 68

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let capped = min(max(streak, 1), 39)
                if capped >= 30 {
                    Self.drawThirtiesTier(context: context, center: center, remainder: capped - 30)
                    return
                }
                let solidRingCount = capped / 10 + 1
                let remainder = capped % 10
                let outermostIndex = solidRingCount - 1
                let outermostColor = Self.ringColors[outermostIndex]
                let outermostRadius = Self.innerRadius + CGFloat(outermostIndex) * Self.ringGap

                for index in 0..<solidRingCount {
                    context.stroke(
                        Self.ringPath(center: center, radius: Self.innerRadius + CGFloat(index) * Self.ringGap),
                        with: .color(Self.ringColors[index]),
                        lineWidth: Self.lineWidth
                    )
                }

                switch remainder {
                case 1...8:
                    for k in 0..<remainder {
                        // First triangle at 12 o'clock, the rest clockwise at
                        // equal spacing (screen y grows downward, so
                        // increasing angle IS clockwise).
                        let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(k) / CGFloat(remainder)
                        context.fill(
                            Self.trianglePath(center: center, ringRadius: outermostRadius, angle: angle),
                            with: .color(outermostColor)
                        )
                    }
                case 9:
                    context.stroke(
                        Self.ringPath(center: center, radius: outermostRadius + Self.ringGap),
                        with: .color(outermostColor),
                        style: StrokeStyle(lineWidth: Self.lineWidth, dash: [3, 2.5])
                    )
                default:
                    break // a fresh ring (streak 10/20) stands alone
                }
            }

            Text("\(streak)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: Self.innerRadius * 2 - 5)
        }
        .frame(width: Self.sideLength, height: Self.sideLength)
    }

    /// Streaks 30–39 (`remainder` = streak − 30, capped at 9): all three
    /// solid rings, the two large yellow diagonal triangles, and between the
    /// triangles either accumulating white dots (1–8) or two disconnected
    /// dashed white half-rings (9).
    private static func drawThirtiesTier(context: GraphicsContext, center: CGPoint, remainder: Int) {
        for index in 0..<ringColors.count {
            context.stroke(
                ringPath(center: center, radius: innerRadius + CGFloat(index) * ringGap),
                with: .color(ringColors[index]),
                lineWidth: lineWidth
            )
        }

        switch remainder {
        case 1...8:
            // Odd increments (31, 33, ...) fill the half-ring running
            // clockwise from the LOWER triangle, even ones (32, 34, ...) the
            // half-ring from the HIGHER triangle — each in sequence from its
            // starting triangle, pre-spaced at the final 36° gaps so placed
            // dots never move and the finished half-rings are equidistant
            // (triangle, four dots, triangle). Increasing screen angle IS
            // clockwise (y grows downward).
            for dot in 1...remainder {
                let startAngle = dot.isMultiple(of: 2) ? higherTriangleAngle : lowerTriangleAngle
                let slot = CGFloat((dot + 1) / 2)
                let angle = startAngle + slot * dotSpacing
                let dotCenter = CGPoint(
                    x: center.x + dotRingRadius * cos(angle),
                    y: center.y + dotRingRadius * sin(angle)
                )
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: dotCenter.x - dotRadius,
                        y: dotCenter.y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )),
                    with: .color(.white)
                )
            }
        case 9:
            // The dots give way to two dashed white half-rings along the
            // dots' circle, inset half a dot-gap from each triangle so they
            // read as two DISCONNECTED arcs with clear air around the
            // triangles — not one dashed ring passing beneath them. The
            // nominal 3/2.5 dash pattern is scaled so a WHOLE number of
            // dashes (with gaps between) exactly covers the arc: dashing
            // starts at the path's start, so both ends then finish on a
            // complete dash instead of the last one getting cut off.
            let inset = dotSpacing / 2
            let arcLength = (.pi - 2 * inset) * dotRingRadius
            let nominalDash: CGFloat = 3
            let nominalGap: CGFloat = 2.5
            let dashCount = max(2, Int(((arcLength + nominalGap) / (nominalDash + nominalGap)).rounded()))
            let fit = arcLength / (CGFloat(dashCount) * nominalDash + CGFloat(dashCount - 1) * nominalGap)
            let style = StrokeStyle(lineWidth: lineWidth, dash: [nominalDash * fit, nominalGap * fit])
            for startAngle in [lowerTriangleAngle, higherTriangleAngle] {
                var arc = Path()
                arc.addArc(
                    center: center,
                    radius: dotRingRadius,
                    startAngle: .radians(startAngle + inset),
                    endAngle: .radians(startAngle + .pi - inset),
                    clockwise: false
                )
                context.stroke(arc, with: .color(.white), style: style)
            }
        default:
            break // streak 30: triangles alone
        }

        for angle in [higherTriangleAngle, lowerTriangleAngle] {
            context.fill(
                largeTrianglePath(center: center, angle: angle),
                with: .color(.yellow)
            )
        }
    }

    /// An equilateral triangle pointing outward along `angle`, its base
    /// (perpendicular to the radial direction) at largeTriangleBaseRadius.
    private static func largeTrianglePath(center: CGPoint, angle: CGFloat) -> Path {
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
        let baseCenter = CGPoint(
            x: center.x + largeTriangleBaseRadius * direction.x,
            y: center.y + largeTriangleBaseRadius * direction.y
        )
        let apex = CGPoint(
            x: center.x + (largeTriangleBaseRadius + largeTriangleHeight) * direction.x,
            y: center.y + (largeTriangleBaseRadius + largeTriangleHeight) * direction.y
        )
        let halfSide = largeTriangleSide / 2
        var path = Path()
        path.move(to: apex)
        path.addLine(to: CGPoint(
            x: baseCenter.x + halfSide * perpendicular.x,
            y: baseCenter.y + halfSide * perpendicular.y
        ))
        path.addLine(to: CGPoint(
            x: baseCenter.x - halfSide * perpendicular.x,
            y: baseCenter.y - halfSide * perpendicular.y
        ))
        path.closeSubpath()
        return path
    }

    private static func ringPath(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    fileprivate static let previewStreaks = [
        1, 2, 5, 8, 9, 10, 11, 18, 19, 20, 21, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 137,
    ]

    /// An isosceles triangle whose base chord sits half a stroke inside the
    /// ring line (so it fuses with the ring) and whose apex points outward.
    private static func trianglePath(center: CGPoint, ringRadius: CGFloat, angle: CGFloat) -> Path {
        let baseRadius = ringRadius - lineWidth / 2
        let halfAngle = triangleHalfBase / baseRadius
        func point(radius: CGFloat, angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        var path = Path()
        path.move(to: point(radius: ringRadius + triangleHeight, angle: angle))
        path.addLine(to: point(radius: baseRadius, angle: angle - halfAngle))
        path.addLine(to: point(radius: baseRadius, angle: angle + halfAngle))
        path.closeSubpath()
        return path
    }
}

// The contact sheet of every badge state — open this file's canvas in Xcode
// to eyeball the whole progression on the study bar's dark backdrop.
#Preview("Streak badges") {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(StreakBadgeView.sideLength + 8)), count: 6)) {
        ForEach(StreakBadgeView.previewStreaks, id: \.self) { streak in
            VStack(spacing: 0) {
                StreakBadgeView(streak: streak)
                Text("\(streak)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding()
    .background(Color(white: 0.12))
    .environment(\.colorScheme, .dark)
}
