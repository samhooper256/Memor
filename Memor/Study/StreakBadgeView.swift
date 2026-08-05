//
//  StreakBadgeView.swift
//  Memor
//
//  The Study-mode streak badge: the streak number inside concentric rings
//  that grow with the run. The whole progression is one rule over
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
//  magenta triangles, 29 magenta dashed — and >= 29 stays there (styling
//  for 30+ is deliberately not designed yet).
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
    /// Max extent: dashed ring at innerRadius + 3 gaps (25) or triangle
    /// apexes at innerRadius + 2 gaps + height (26), plus stroke slop.
    static let sideLength: CGFloat = 56

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let capped = min(max(streak, 1), 29)
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

    private static func ringPath(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

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
