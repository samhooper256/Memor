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

import SwiftUI

/// "P3"-style label. Priority 1 (the default) renders muted; anything higher
/// renders orange so raised priorities stand out. When `effectivePriority` is
/// higher than `priority` (the instance's priority outranks the query's own),
/// it is appended as "→ P5".
struct PriorityBadge: View {
    let priority: Int
    var effectivePriority: Int? = nil

    private var raisedEffectivePriority: Int? {
        guard let effectivePriority, effectivePriority > priority else { return nil }
        return effectivePriority
    }

    static func color(for priority: Int) -> Color {
        priority > QUERY_PRIORITY_DEFAULT ? .orange : .secondary
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
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(Self.color(for: shownPriority))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            Capsule()
                .fill(Self.color(for: shownPriority).opacity(0.15))
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
