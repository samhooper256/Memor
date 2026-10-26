//
//  PriorityViews.swift
//  Memor
//
//  Study-priority UI shared across the app: the compact "P3" badge, the
//  click-to-edit priority menu used by the instance editor, and the
//  "Set Priority" submenu used by context menus.
//
//  The editor control is a SwiftUI Menu (an NSMenu under the hood), not a
//  popover: menus track without taking key status, so the control also works
//  inside the borderless Add/Edit Point panel, which closes when it resigns
//  key.
//

import AppKit
import SwiftUI

/// "P3"-style label, colored by level. Priority 1 (the default) renders muted
/// gray; P2–P10 sweep amber → orange → red → crimson → magenta → purple, with
/// a slightly heavier capsule fill as priority rises, so each level looks
/// different and higher reads hotter. When `effectivePriority` is higher than
/// `priority` (the instance's priority outranks the query's own), it is
/// appended as "→ P5" and the badge takes the effective level's color.
struct PriorityBadge: View {
    let priority: Int
    var effectivePriority: Int? = nil
    var font: Font = .subheadline.monospacedDigit()

    private var raisedEffectivePriority: Int? {
        guard let effectivePriority, effectivePriority > priority else { return nil }
        return effectivePriority
    }

    /// 0 for P2 … 8 for P10 (P1 never reaches the ramp).
    private static func rampStep(for priority: Int) -> Double {
        Double(min(priority, QUERY_PRIORITY_MAX) - QUERY_PRIORITY_DEFAULT - 1)
    }

    static func color(for priority: Int) -> Color {
        guard priority > QUERY_PRIORITY_DEFAULT else { return .secondary }
        // 40° (amber) at P2, 12.5° hotter per step, through red (0°) at P5–P6
        // to 300° (purple) at P10 — neighbors differ a little, levels a few
        // apart differ a lot.
        var hueDegrees = 40 - rampStep(for: priority) * 12.5
        if hueDegrees < 0 { hueDegrees += 360 }
        let hue = hueDegrees / 360
        // Light mode gets a darker, fully saturated variant so colored text
        // stays legible on white; dark mode a brighter, softer one.
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(
                hue: hue,
                saturation: isDark ? 0.75 : 0.95,
                brightness: isDark ? 1.0 : 0.78,
                alpha: 1
            )
        })
    }

    /// Capsule tint: 15% at P1–P2 rising to ~31% at P10.
    static func fillOpacity(for priority: Int) -> Double {
        guard priority > QUERY_PRIORITY_DEFAULT else { return 0.15 }
        return 0.15 + rampStep(for: priority) * 0.02
    }

    var body: some View {
        let shownPriority = raisedEffectivePriority ?? priority
        HStack(spacing: 3) {
            Text("P\(priority)")
            if let raisedEffectivePriority {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                Text("P\(raisedEffectivePriority)")
            }
        }
        .font(font)
        .foregroundStyle(Self.color(for: shownPriority))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            Capsule()
                .fill(Self.color(for: shownPriority).opacity(Self.fillOpacity(for: shownPriority)))
        )
    }
}

/// A PriorityBadge that opens a 1–10 menu when clicked.
struct PriorityMenu: View {
    @Binding var priority: Int
    var effectivePriority: Int? = nil
    var help: String = "Priority (1–10). Click to change."

    var body: some View {
        Menu {
            PriorityMenuItems(currentPriority: priority) { priority = $0 }
        } label: {
            PriorityBadge(priority: priority, effectivePriority: effectivePriority)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(effectiveHelp)
    }

    private var effectiveHelp: String {
        guard let effectivePriority, effectivePriority > priority else { return help }
        return help + " Studied at priority \(effectivePriority) because its instance's priority is higher."
    }
}

/// The ten priority choices, highest first. `currentPriority` gets a
/// checkmark (nil — e.g. a mixed multi-selection — checks nothing).
struct PriorityMenuItems: View {
    let currentPriority: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        ForEach(Array((QUERY_PRIORITY_MIN...QUERY_PRIORITY_MAX).reversed()), id: \.self) { value in
            Button {
                onSelect(value)
            } label: {
                if value == currentPriority {
                    Label(Self.title(for: value), systemImage: "checkmark")
                } else {
                    Text(Self.title(for: value))
                }
            }
        }
    }

    static func title(for value: Int) -> String {
        switch value {
        case QUERY_PRIORITY_MAX: return "\(value) (highest)"
        case QUERY_PRIORITY_DEFAULT: return "\(value) (default)"
        default: return "\(value)"
        }
    }
}

/// A "Set Priority" submenu for context menus.
struct SetPrioritySubmenu: View {
    var title: String = "Set Priority"
    var currentPriority: Int? = nil
    let onSelect: (Int) -> Void

    var body: some View {
        Menu(title) {
            PriorityMenuItems(currentPriority: currentPriority, onSelect: onSelect)
        }
    }
}
