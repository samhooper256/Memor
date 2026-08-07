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
//  disconnected arcs rather than one dashed circle.
//
//  The 40s: the dashed half-rings vanish and two ORANGE equilateral
//  triangles mirror the yellow pair on the other diagonal (pointing at the
//  top-left and bottom-right corners) — four triangles at 45° intervals.
//  41-48: one white dot with a red border per streak, on the triangles'
//  ring, two per side between adjacent triangles at the FINAL spacing
//  (three equal 30° gaps per side), so by 48 the twelve objects — 8 dots +
//  4 triangles — form one evenly spaced ring around the magenta circle.
//  Placement order: right-of-top, left-of-bottom, upper-of-right,
//  lower-of-left, left-of-top, right-of-bottom, lower-of-right,
//  upper-of-left. 49: the dots invert — red fill, white border.
//
//  50 starts over: every 1–49 element vanishes. Behind the number sits a
//  grid (verticals and horizontals at one even interval) fading out in a
//  circular vignette — at distance d from center the opacity is exactly
//  max(0, 1 − d/r), r = half the badge's square bounding box, while the
//  color eases from a slightly darker purple at d = 0 to the standard
//  magenta at d >= r — with a small rectangle cut out of the middle so the
//  number sits on clear background.
//
//  51–100 build ten-pointed stars over the grid at ten fixed sites: two
//  concentric pentagons around the badge center — five sites at a FAR
//  distance (a = 26) at angles A + 72°k, five at a CLOSE distance (b = 20)
//  offset 36° (pentagram vertices), with A = 270 by design. Every decade
//  sweeps the sites in ONE fixed placement order that alternates
//  far/close and never steps to an angular neighbor — each new site is
//  across the badge from the previous one. 51–60 light one site per
//  streak: a yellow circle plus two yellow isosceles spikes (taller than
//  their base is wide) pointing out from the center along one of the
//  site's five axes.
//  61–70 revisit the sites in the same order, adding orange spikes on a
//  second axis LAYERED BEHIND the yellow ones and a smaller orange circle
//  inside the yellow one (the yellow rim stays visible). 71–80: blue
//  spikes behind the orange on a third axis, and the inner circle turns
//  blue. 81–90: green behind the blue on a fourth axis, inner circle
//  green. 91–100: white spikes behind everything on the last free axis,
//  and the inner circle turns RED. Which axis each color takes varies per
//  site (a fixed per-site shuffle). At 100 all ten stars are complete —
//  five axes, ten spikes each — and >= 100 stays at the 100 badge.
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

    // MARK: 40s-tier geometry

    /// The orange pair mirrors the yellow pair on the other diagonal.
    private static let topLeftTriangleAngle: CGFloat = -3 * .pi / 4
    private static let bottomRightTriangleAngle: CGFloat = .pi / 4
    /// The 41–48 dot positions in PLACEMENT order (screen degrees):
    /// right-of-top, left-of-bottom, upper-of-right, lower-of-left,
    /// left-of-top, right-of-bottom, lower-of-right, upper-of-left. Each
    /// side's pair splits the 90° between adjacent triangles into three
    /// equal 30° gaps, so the finished ring of 8 dots + 4 triangles is
    /// uniformly spaced.
    private static let fortiesDotAngles: [CGFloat] = ([-75, 105, -15, 165, -105, 75, 15, 195] as [CGFloat])
        .map { $0 * .pi / 180 }
    /// Slightly larger than the 30s dots so the contrasting border reads.
    private static let borderedDotRadius: CGFloat = 2
    private static let borderedDotLineWidth: CGFloat = 1

    // MARK: 50s-tier geometry

    /// One interval for both the vertical and horizontal grid lines.
    private static let gridSpacing: CGFloat = 9
    private static let gridLineWidth: CGFloat = 1
    /// The rectangle cut out of the grid's middle so the number sits on
    /// clear background — snug around the digits.
    private static let gridCutoutSize = CGSize(width: 22, height: 13)
    /// The d=0 end of the grid's radial gradient: a slightly darker purple
    /// that eases LINEARLY into the standard magenta (1, 0, 1) by the
    /// vignette's edge (d >= r), so the grid subtly deepens toward the
    /// center. The opacity rides a DIFFERENT curve — max(0, 1 − (d/r)²) —
    /// which a two-stop gradient can't express independently of the color
    /// ramp, so gridGradient() samples both densely: the color lerps
    /// reproduce the linear ramp exactly, only the alpha curve bends.
    private static let gridCenterComponents = (red: 0.75, green: 0.0, blue: 0.85)

    private static func gridGradient() -> Gradient {
        let sampleCount = 16
        return Gradient(stops: (0...sampleCount).map { step in
            let t = Double(step) / Double(sampleCount)
            return Gradient.Stop(
                color: Color(
                    red: gridCenterComponents.red + (1 - gridCenterComponents.red) * t,
                    green: gridCenterComponents.green,
                    blue: gridCenterComponents.blue + (1 - gridCenterComponents.blue) * t,
                    opacity: 1 - t * t
                ),
                location: t
            )
        })
    }

    // MARK: 51–100 star geometry

    /// One of the ten star sites: a "random" layout designed once and
    /// hardcoded so every render agrees. `x`/`y` are offsets from the badge
    /// center; `axisByDecade` maps each decade (0 yellow, 1 orange, 2 blue,
    /// 3 green, 4 white) to one of the site's five axes (36° apart, the
    /// whole star rotated by `rotationDegrees`), each axis used exactly once.
    private struct StarPoint {
        let x: CGFloat
        let y: CGFloat
        let rotationDegrees: CGFloat
        let axisByDecade: [Int]
    }

    /// The ten sites in PLACEMENT order — streak 51 lights the first, 52 the
    /// second, …, 61 returns to the first for orange, and so on. The sites
    /// are two concentric pentagons sharing the badge's center: a FAR ring
    /// (distance a = 26) at angles A + 72°k and a CLOSE ring (b = 20)
    /// offset 36° from it — pentagram vertices, screen angles (y down), with
    /// A = 270 by design (a far star due north, the rest mirror-symmetric
    /// about the vertical). Every star clears the number cutout — the
    /// tightest, the close ring at 18°/162°, clears it by 1.5pt even at
    /// full disc reach — and the canvas edge (tightest 1.5pt, the far star
    /// at 270°). The placement order ALTERNATES far/close and never steps
    /// to an angular neighbor: consecutive picks (cyclically, so each
    /// decade's wrap-around included) are 37–46pt apart, while neighboring
    /// sites on the rings sit 15.3pt+ apart (stars span 13pt, so none
    /// touch). Rotations and axis shuffles stay per-site random.
    private static let starPoints: [StarPoint] = [
        StarPoint(x: -15.3, y: 21.0, rotationDegrees: 0.8, axisByDecade: [1, 4, 0, 2, 3]),   // far, 126°
        StarPoint(x: -11.8, y: -16.2, rotationDegrees: 17.8, axisByDecade: [4, 3, 0, 2, 1]), // close, 234°
        StarPoint(x: 24.7, y: -8.0, rotationDegrees: 14.3, axisByDecade: [2, 1, 4, 0, 3]),   // far, 342°
        StarPoint(x: -19.0, y: 6.2, rotationDegrees: 14.5, axisByDecade: [0, 4, 3, 1, 2]),   // close, 162°
        StarPoint(x: 15.3, y: 21.0, rotationDegrees: 25.4, axisByDecade: [1, 4, 0, 3, 2]),   // far, 54°
        StarPoint(x: 11.8, y: -16.2, rotationDegrees: 3.0, axisByDecade: [3, 0, 2, 4, 1]),   // close, 306°
        StarPoint(x: -24.7, y: -8.0, rotationDegrees: 0.4, axisByDecade: [0, 2, 3, 1, 4]),   // far, 198°
        StarPoint(x: 0.0, y: 20.0, rotationDegrees: 0.1, axisByDecade: [0, 1, 4, 2, 3]),     // close, 90°
        StarPoint(x: 0.0, y: -26.0, rotationDegrees: 34.3, axisByDecade: [3, 2, 1, 0, 4]),   // far, 270°
        StarPoint(x: 19.0, y: 6.2, rotationDegrees: 14.3, axisByDecade: [4, 2, 1, 0, 3]),    // close, 18°
    ]

    /// Spike apex distance from a star's center.
    private static let starRadius: CGFloat = 6.5
    /// Half the spike's base — the base (3.2) is well under the height
    /// (6.5), per the isosceles taller-than-wide rule.
    private static let starSpikeHalfBase: CGFloat = 1.6
    private static let starCircleRadius: CGFloat = 2.6
    /// Inner circle: enough smaller that the yellow rim always shows.
    private static let starInnerCircleRadius: CGFloat = 1.6
    /// Spike colors by decade 0–4.
    private static let starDecadeColors: [Color] = [.yellow, .orange, .blue, .green, .white]
    /// Inner-circle colors by latest decade 1–4: the white decade turns the
    /// center RED, not white.
    private static let starInnerColors: [Color] = [.orange, .blue, .green, .red]

    /// Max extent: the large triangles' apexes at largeTriangleBaseRadius +
    /// height (~32.5), plus slop.
    static let sideLength: CGFloat = 68

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let capped = min(max(streak, 1), 100)
                if capped >= 50 {
                    Self.drawFiftiesTier(context: context, center: center, remainder: capped - 50)
                    return
                }
                if capped >= 40 {
                    Self.drawFortiesTier(context: context, center: center, remainder: capped - 40)
                    return
                }
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

    /// Streaks 40–49 (`remainder` = streak − 40, capped at 9): all three
    /// solid rings, the yellow diagonal triangles now mirrored by an orange
    /// pair (top-left and bottom-right corners), and one red-bordered white
    /// dot per streak from 41 — placed on the triangles' ring at the final
    /// uniform spacing (see fortiesDotAngles) so 48 completes an evenly
    /// spaced ring of twelve objects. At 49 the dots invert to red with a
    /// white border.
    private static func drawFortiesTier(context: GraphicsContext, center: CGPoint, remainder: Int) {
        for index in 0..<ringColors.count {
            context.stroke(
                ringPath(center: center, radius: innerRadius + CGFloat(index) * ringGap),
                with: .color(ringColors[index]),
                lineWidth: lineWidth
            )
        }

        let inverted = remainder >= 9
        for dot in 0..<min(remainder, fortiesDotAngles.count) {
            let angle = fortiesDotAngles[dot]
            let dotCenter = CGPoint(
                x: center.x + dotRingRadius * cos(angle),
                y: center.y + dotRingRadius * sin(angle)
            )
            let circle = Path(ellipseIn: CGRect(
                x: dotCenter.x - borderedDotRadius,
                y: dotCenter.y - borderedDotRadius,
                width: borderedDotRadius * 2,
                height: borderedDotRadius * 2
            ))
            context.fill(circle, with: .color(inverted ? .red : .white))
            context.stroke(circle, with: .color(inverted ? .white : .red), lineWidth: borderedDotLineWidth)
        }

        for angle in [higherTriangleAngle, lowerTriangleAngle] {
            context.fill(largeTrianglePath(center: center, angle: angle), with: .color(.yellow))
        }
        for angle in [topLeftTriangleAngle, bottomRightTriangleAngle] {
            context.fill(largeTrianglePath(center: center, angle: angle), with: .color(.orange))
        }
    }

    /// Streaks 50–100 (`remainder` = streak − 50, capped at 50): the number
    /// over a grid fading out in a circular vignette, then one star element
    /// per streak past 50. The opacity law max(0, 1 − d/r) with r = half the
    /// square bounding box's side IS a linear radial gradient from opaque at
    /// the center to clear at r (clamped beyond), so the grid is stroked
    /// once with that shading; the same gradient carries the color from the
    /// darker center purple at d = 0 to the standard magenta at d >= r. The
    /// middle rectangle is inverse-clipped away so the number sits on clear
    /// background.
    ///
    /// Stars: remainder 1–50 decomposes into decade = (remainder−1)/10 (the
    /// color wave: yellow, orange, blue, green, white) and step =
    /// (remainder−1)%10 (how far the wave has swept the placement order).
    /// A site's LATEST decade is `decade` if already reached this wave,
    /// else `decade − 1`; sites the yellow wave hasn't reached yet draw
    /// nothing. Spikes draw latest-decade-first so every later color layers
    /// BEHIND all earlier ones, then the yellow circle and (from orange on)
    /// the inner circle cap the center.
    private static func drawFiftiesTier(context: GraphicsContext, center: CGPoint, remainder: Int) {
        let halfSide = sideLength / 2
        var grid = Path()
        let lineCount = Int(halfSide / gridSpacing)
        for k in -lineCount...lineCount {
            let offset = CGFloat(k) * gridSpacing
            grid.move(to: CGPoint(x: center.x + offset, y: center.y - halfSide))
            grid.addLine(to: CGPoint(x: center.x + offset, y: center.y + halfSide))
            grid.move(to: CGPoint(x: center.x - halfSide, y: center.y + offset))
            grid.addLine(to: CGPoint(x: center.x + halfSide, y: center.y + offset))
        }

        // GraphicsContext is a value type — the cutout clip dies with this
        // copy, so the stars below draw unclipped.
        var gridContext = context
        gridContext.clip(
            to: Path(CGRect(
                x: center.x - gridCutoutSize.width / 2,
                y: center.y - gridCutoutSize.height / 2,
                width: gridCutoutSize.width,
                height: gridCutoutSize.height
            )),
            options: .inverse
        )
        gridContext.stroke(
            grid,
            with: .radialGradient(
                gridGradient(),
                center: center,
                startRadius: 0,
                endRadius: halfSide
            ),
            lineWidth: gridLineWidth
        )

        guard remainder > 0 else { return } // streak 50: the grid alone
        let decade = (remainder - 1) / 10
        let step = (remainder - 1) % 10
        for (index, star) in starPoints.enumerated() {
            let latestDecade = index <= step ? decade : decade - 1
            guard latestDecade >= 0 else { continue }
            let starCenter = CGPoint(x: center.x + star.x, y: center.y + star.y)
            // Latest decade first: every later color layers behind all
            // earlier ones, yellow on top.
            for d in stride(from: latestDecade, through: 0, by: -1) {
                let axisAngle = (star.rotationDegrees + CGFloat(star.axisByDecade[d]) * 36) * .pi / 180
                for direction in [axisAngle, axisAngle + .pi] {
                    context.fill(
                        starSpikePath(center: starCenter, angle: direction),
                        with: .color(starDecadeColors[d])
                    )
                }
            }
            context.fill(
                ringPath(center: starCenter, radius: starCircleRadius),
                with: .color(.yellow)
            )
            if latestDecade >= 1 {
                context.fill(
                    ringPath(center: starCenter, radius: starInnerCircleRadius),
                    with: .color(starInnerColors[latestDecade - 1])
                )
            }
        }
    }

    /// One star spike: an isosceles triangle whose base (perpendicular to
    /// the axis) is centered ON the star's center with the apex pointing
    /// outward — taller (starRadius) than its base (2 × starSpikeHalfBase)
    /// is wide. An axis's opposite pair shares its base line; the yellow
    /// circle covers the shared middle.
    private static func starSpikePath(center: CGPoint, angle: CGFloat) -> Path {
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
        var path = Path()
        path.move(to: CGPoint(
            x: center.x + starRadius * direction.x,
            y: center.y + starRadius * direction.y
        ))
        path.addLine(to: CGPoint(
            x: center.x + starSpikeHalfBase * perpendicular.x,
            y: center.y + starSpikeHalfBase * perpendicular.y
        ))
        path.addLine(to: CGPoint(
            x: center.x - starSpikeHalfBase * perpendicular.x,
            y: center.y - starSpikeHalfBase * perpendicular.y
        ))
        path.closeSubpath()
        return path
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
        1, 2, 5, 8, 9, 10, 11, 18, 19, 20, 21, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
        40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
    ] + Array(51...100) + [137]

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
