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

/// One role's row: the title and the chosen colour's circle, which is the
/// selector — clicking it opens a popover with the palette as a 4-column
/// grid of circles (4/4/3), no colour names. Each row owns its UserDefaults
/// binding.
private struct GraphNodeColorRow: View {
    let role: GraphNodeRole
    @AppStorage private var color: GraphNodeColor
    @State private var isPalettePresented = false

    init(role: GraphNodeRole) {
        self.role = role
        _color = AppStorage(wrappedValue: role.defaultColor, role.userDefaultsKey)
    }

    var body: some View {
        LabeledContent(role.title) {
            Button {
                isPalettePresented.toggle()
            } label: {
                GraphColorSwatch(color: color, diameter: 18)
            }
            .buttonStyle(.plain)
            .help("Choose a color")
            .popover(isPresented: $isPalettePresented, arrowEdge: .bottom) {
                GraphColorPaletteView(selection: $color) {
                    isPalettePresented = false
                }
            }
        }
    }
}

/// The palette popover: four circles per row (the 11 colours fall 4/4/3),
/// the current choice ringed, the name on hover. A click chooses and closes.
private struct GraphColorPaletteView: View {
    @Binding var selection: GraphNodeColor
    let onPick: () -> Void

    private static let cell: CGFloat = 30
    private let columns = Array(repeating: GridItem(.fixed(cell), spacing: 6), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(GraphNodeColor.allCases) { option in
                Button {
                    selection = option
                    onPick()
                } label: {
                    GraphColorSwatch(color: option, diameter: 22)
                        .overlay {
                            if option == selection {
                                Circle()
                                    .stroke(Color.primary, lineWidth: 2)
                                    .frame(width: Self.cell - 2, height: Self.cell - 2)
                            }
                        }
                        .frame(width: Self.cell, height: Self.cell)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.title)
            }
        }
        .padding(12)
    }
}

/// A filled colour circle with a faint edge so pale colours keep a shape.
private struct GraphColorSwatch: View {
    let color: GraphNodeColor
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(color.color)
            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
            .frame(width: diameter, height: diameter)
    }
}
