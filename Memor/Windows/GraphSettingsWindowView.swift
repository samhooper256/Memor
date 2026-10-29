//
//  GraphSettingsWindowView.swift
//  Memor
//
//  The Graph tab's settings window, opened from the gear between the Search
//  button and the Layout picker. Holds the per-role node colours (UserDefaults;
//  the Graph page reads the same keys, so a change recolours the open graph).
//

import AppKit
import SwiftUI

/// The palette a node colour is chosen from: the app's own colours (the SRS
/// blue/red/green/magenta, the find bar's yellow and gray, the accent blue)
/// plus the rest of the system set. Fixed hex values: the page draws the same
/// colour in light and dark mode, as it always has.
enum GraphNodeColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, indigo, purple, magenta, pink, gray

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// The CSS colour the page fills nodes with.
    var hex: String {
        switch self {
        case .red: return "#FF453A"
        case .orange: return "#FF9F0A"
        case .yellow: return "#FFD60A"
        case .green: return "#30D158"
        case .teal: return "#40C8E0"
        case .blue: return "#0A84FF"
        case .indigo: return "#5E5CE6"
        case .purple: return "#BF5AF2"
        case .magenta: return "#FF00FF"
        case .pink: return "#FF375F"
        case .gray: return "#8E8E93"
        }
    }

    var nsColor: NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var color: Color { Color(nsColor: nsColor) }

    /// A filled circle for the picker's menu rows (NSMenu items take images,
    /// not arbitrary views).
    var swatchImage: NSImage {
        if let cached = Self.swatchCache[self] { return cached }
        let fill = nsColor
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            fill.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
        Self.swatchCache[self] = image
        return image
    }

    private static var swatchCache: [GraphNodeColor: NSImage] = [:]
}

/// The three node roles the Graph tab colours, decided by the arrows actually
/// drawn (links between two search results, in the filtered fields when the
/// field filter is on).
enum GraphNodeRole: String, CaseIterable, Identifiable {
    case isolated     // no incident edges
    case inbound      // 1+ inbound edges, whatever the out-degree
    case sourceOnly   // no inbound edges, some outbound

    var id: String { rawValue }

    var title: String {
        switch self {
        case .isolated: return "Color: no incident edges"
        case .inbound: return "Color: 1+ inbound edges"
        case .sourceOnly: return "Color: no inbound edges, but some outbound edges"
        }
    }

    var userDefaultsKey: String {
        switch self {
        case .isolated: return "com.sam.Memor.graphColorIsolated"
        case .inbound: return "com.sam.Memor.graphColorInbound"
        case .sourceOnly: return "com.sam.Memor.graphColorSourceOnly"
        }
    }

    /// What the page drew before the colours were customizable.
    var defaultColor: GraphNodeColor {
        switch self {
        case .isolated: return .red
        case .inbound: return .blue
        case .sourceOnly: return .green
        }
    }

    /// The page's node kind (`nodes[i].kind`) for this role.
    var pageKind: Int {
        switch self {
        case .isolated: return 0
        case .sourceOnly: return 1
        case .inbound: return 2
        }
    }
}

/// The chosen colour per role, as the Graph page hands it to the web view.
struct GraphNodeColorSet: Equatable {
    var isolated: GraphNodeColor
    var inbound: GraphNodeColor
    var sourceOnly: GraphNodeColor

    func color(for role: GraphNodeRole) -> GraphNodeColor {
        switch role {
        case .isolated: return isolated
        case .inbound: return inbound
        case .sourceOnly: return sourceOnly
        }
    }

    /// Hex strings indexed by the page's node kind: the `setNodeColors` payload.
    var hexesByKind: [String] {
        var hexes = [String](repeating: "", count: GraphNodeRole.allCases.count)
        for role in GraphNodeRole.allCases {
            hexes[role.pageKind] = color(for: role).hex
        }
        return hexes
    }
}

struct GraphSettingsWindowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Colors") {
                ForEach(GraphNodeRole.allCases) { role in
                    GraphNodeColorRow(role: role)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 220)
        .onExitCommand { dismiss() }
        .background(
            // Reliable Escape-to-close even when no control holds focus.
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }
}

/// One role's row: the title, the current colour's swatch, and a menu of the
/// palette. Each row owns its UserDefaults binding.
private struct GraphNodeColorRow: View {
    let role: GraphNodeRole
    @AppStorage private var color: GraphNodeColor

    init(role: GraphNodeRole) {
        self.role = role
        _color = AppStorage(wrappedValue: role.defaultColor, role.userDefaultsKey)
    }

    var body: some View {
        LabeledContent(role.title) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color.color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                Picker("", selection: $color) {
                    ForEach(GraphNodeColor.allCases) { option in
                        Label {
                            Text(option.title)
                        } icon: {
                            Image(nsImage: option.swatchImage)
                        }
                        .tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }
}
