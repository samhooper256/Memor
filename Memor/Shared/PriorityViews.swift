//
//  PriorityViews.swift
//  Memor
//
//  Study-priority UI shared across the app: the compact "P3" badge, the
//  click-to-edit priority menu used by the instance editor, and the
//  "Set Priority" submenu used by context menus.
//
//  The editor control pops an NSMenu under a hosted SwiftUI badge (SwiftUI's
//  Menu can't be opened programmatically, and the instance editor's Open
//  Priority Menu shortcut needs to): a menu tracks without taking key status,
//  so the control also works inside the borderless Add/Edit Point panel,
//  which closes when it resigns key.
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

/// A PriorityBadge that opens a 1–10 menu when clicked — or when `openRequest`
/// changes to a fresh value (the instance editor's Open Priority Menu
/// shortcut, ⌘/ by default), so a priority can be set by keyboard alone: with
/// the menu up, ↑/↓ move and Return picks. The menu is an NSMenu popped under
/// the badge; SwiftUI's Menu can't be opened programmatically.
struct PriorityMenu: View {
    @Binding var priority: Int
    var effectivePriority: Int? = nil
    var help: String = "Priority (1–10). Click to change."
    /// Set to a new UUID to pop the menu open.
    var openRequest: UUID? = nil

    var body: some View {
        PriorityMenuControl(priority: $priority, effectivePriority: effectivePriority, openRequest: openRequest)
            .fixedSize()
            .help(effectiveHelp)
    }

    private var effectiveHelp: String {
        guard let effectivePriority, effectivePriority > priority else { return help }
        return help + " Studied at priority \(effectivePriority) because its instance's priority is higher."
    }
}

private struct PriorityMenuControl: NSViewRepresentable {
    @Binding var priority: Int
    let effectivePriority: Int?
    let openRequest: UUID?

    final class Coordinator {
        var lastOpenRequest: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PriorityMenuNSView {
        let view = PriorityMenuNSView(badge: PriorityBadge(priority: priority, effectivePriority: effectivePriority))
        view.currentPriority = priority
        view.onSelect = { [binding = $priority] in binding.wrappedValue = $0 }
        // A request already pending at creation is a remount's stale value, not a press.
        context.coordinator.lastOpenRequest = openRequest
        return view
    }

    func updateNSView(_ view: PriorityMenuNSView, context: Context) {
        view.badge = PriorityBadge(priority: priority, effectivePriority: effectivePriority)
        view.currentPriority = priority
        view.onSelect = { [binding = $priority] in binding.wrappedValue = $0 }
        if let openRequest, context.coordinator.lastOpenRequest != openRequest {
            context.coordinator.lastOpenRequest = openRequest
            // After this update pass — the menu tracks synchronously.
            DispatchQueue.main.async { view.popUpMenu() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PriorityMenuNSView, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

/// The hosted badge that pops the priority NSMenu on click or on request.
final class PriorityMenuNSView: NSView {
    private let hostingView: NSHostingView<PriorityBadge>
    var currentPriority = QUERY_PRIORITY_DEFAULT
    var onSelect: ((Int) -> Void)?

    var badge: PriorityBadge {
        get { hostingView.rootView }
        set {
            hostingView.rootView = newValue
            invalidateIntrinsicContentSize()
        }
    }

    init(badge: PriorityBadge) {
        hostingView = NSHostingView(rootView: badge)
        super.init(frame: .zero)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        hostingView.intrinsicContentSize
    }

    // Clicks are ours, not the hosted badge's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        popUpMenu()
    }

    func popUpMenu() {
        guard window != nil else { return }
        let menu = NSMenu()
        for value in (QUERY_PRIORITY_MIN...QUERY_PRIORITY_MAX).reversed() {
            let item = NSMenuItem(
                title: PriorityMenuItems.title(for: value),
                action: #selector(selectPriority(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = value
            item.state = value == currentPriority ? .on : .off
            menu.addItem(item)
        }
        // Drop down from the badge's bottom-left corner, like a menu button.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
    }

    @objc private func selectPriority(_ sender: NSMenuItem) {
        onSelect?(sender.tag)
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
