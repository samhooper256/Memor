//
//  GraphSettingsStore.swift
//  Memor
//
//  The Graph tab's settings beyond the page's own @AppStorage inputs: node
//  colours per role, the ordered markup layers, and saved presets (a whole
//  graph — search, layout, field filter, colours, markups). Everything lives
//  in UserDefaults; the Graph page and the Graph Settings window both observe
//  the shared store, so an edit recolours an open graph at once.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// UserDefaults keys for the Graph page's own inputs (its @AppStorage
/// properties), shared with the store so presets can read and write them.
enum GraphPageDefaults {
    static let searchQueryKey = "com.sam.Memor.graphSearchQuery"
    static let fieldFilterTextKey = "com.sam.Memor.graphFieldFilterText"
    static let fieldFilterEnabledKey = "com.sam.Memor.graphFieldFilterEnabled"
}

/// The palette a node colour is chosen from: the app's own colours (the SRS
/// blue/red/green/magenta, the find bar's yellow and gray, the accent blue)
/// plus the rest of the system set. Fixed hex values: the page draws the same
/// colour in light and dark mode, as it always has.
enum GraphNodeColor: String, CaseIterable, Identifiable, Codable {
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

/// The chosen colour per role, as the Graph page hands it to the web view
/// and as a preset stores it.
struct GraphNodeColorSet: Codable, Equatable {
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

/// One markup layer: the instances matching `query` (the instance-search
/// language; empty matches every instance) are filled and/or outlined in its
/// colours. Layers apply in list order after the role colours, a later layer
/// overriding an earlier one per property; a disabled layer is skipped. The
/// id is stable across edits, reorders and preset round-trips.
struct GraphMarkup: Codable, Equatable, Identifiable {
    var id = UUID()
    var query = ""
    var fill: GraphNodeColor?
    var outline: GraphNodeColor?
    var isEnabled = true

    /// A disabled layer, or one with no colour at all, draws nothing.
    var drawsAnything: Bool { isEnabled && (fill != nil || outline != nil) }
}

/// Everything the Graph tab needs to show a graph.
struct GraphPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var query: String
    var layoutMode: GraphLayoutMode
    var fieldFilterText: String
    var isFieldFilterEnabled: Bool
    var colors: GraphNodeColorSet
    var markups: [GraphMarkup]
}

/// A node's resolved markup as the page receives it: CSS colours, nil = none.
struct GraphNodeMarkup: Equatable {
    var fill: String?
    var outline: String?
}

final class GraphSettingsStore: ObservableObject {
    static let shared = GraphSettingsStore()

    private static let markupsKey = "com.sam.Memor.graphMarkups"
    private static let presetsKey = "com.sam.Memor.graphPresets"

    @Published var markups: [GraphMarkup] {
        didSet { if markups != oldValue { Self.persist(markups, key: Self.markupsKey) } }
    }
    @Published var presets: [GraphPreset] {
        didSet { if presets != oldValue { Self.persist(presets, key: Self.presetsKey) } }
    }
    /// A preset the Graph page should load and run: set by `apply`, consumed
    /// by the page — at once while it is showing, else on its next visit.
    @Published var pendingApply: GraphPreset?

    private init() {
        markups = Self.load([GraphMarkup].self, key: Self.markupsKey) ?? []
        presets = Self.load([GraphPreset].self, key: Self.presetsKey) ?? []
    }

    // MARK: - Markups

    func addMarkup() {
        markups.append(GraphMarkup())
    }

    func removeMarkup(id: UUID) {
        markups.removeAll { $0.id == id }
    }

    func moveMarkup(id: UUID, by offset: Int) {
        guard let index = markups.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard markups.indices.contains(target) else { return }
        markups.swapAt(index, target)
    }

    // MARK: - The page's inputs and colours (UserDefaults, read by @AppStorage)

    func currentColors() -> GraphNodeColorSet {
        GraphNodeColorSet(
            isolated: storedColor(for: .isolated),
            inbound: storedColor(for: .inbound),
            sourceOnly: storedColor(for: .sourceOnly)
        )
    }

    private func storedColor(for role: GraphNodeRole) -> GraphNodeColor {
        UserDefaults.standard.string(forKey: role.userDefaultsKey)
            .flatMap(GraphNodeColor.init(rawValue:)) ?? role.defaultColor
    }

    /// The Graph tab as it stands: its persisted inputs plus the colours and
    /// markups, under the given name.
    func captureCurrentGraph(named name: String) -> GraphPreset {
        let defaults = UserDefaults.standard
        return GraphPreset(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            query: defaults.string(forKey: GraphPageDefaults.searchQueryKey) ?? "",
            layoutMode: defaults.string(forKey: GraphLayoutMode.userDefaultsKey)
                .flatMap(GraphLayoutMode.init(rawValue:)) ?? .tree,
            fieldFilterText: defaults.string(forKey: GraphPageDefaults.fieldFilterTextKey) ?? "",
            isFieldFilterEnabled: defaults.bool(forKey: GraphPageDefaults.fieldFilterEnabledKey),
            colors: currentColors(),
            markups: markups
        )
    }

    /// Writes the preset over the current settings and asks the Graph page
    /// to run it.
    func apply(_ preset: GraphPreset) {
        let defaults = UserDefaults.standard
        defaults.set(preset.query, forKey: GraphPageDefaults.searchQueryKey)
        defaults.set(preset.layoutMode.rawValue, forKey: GraphLayoutMode.userDefaultsKey)
        defaults.set(preset.fieldFilterText, forKey: GraphPageDefaults.fieldFilterTextKey)
        defaults.set(preset.isFieldFilterEnabled, forKey: GraphPageDefaults.fieldFilterEnabledKey)
        for role in GraphNodeRole.allCases {
            defaults.set(preset.colors.color(for: role).rawValue, forKey: role.userDefaultsKey)
        }
        markups = preset.markups
        pendingApply = preset
    }

    // MARK: - Presets

    /// Nil when the name is acceptable: non-empty and not another preset's
    /// (case-insensitively).
    func presetNameError(_ name: String, excluding id: UUID? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name." }
        if presets.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "A preset named “\(trimmed)” already exists."
        }
        return nil
    }

    func addPreset(named name: String) {
        presets.append(captureCurrentGraph(named: name))
    }

    func renamePreset(id: UUID, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
    }

    // MARK: - Persistence (JSON in UserDefaults)

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
