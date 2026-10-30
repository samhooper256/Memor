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
/// plus the rest of the system set, and white. Fixed hex values: the page
/// draws the same colour in light and dark mode, as it always has.
enum GraphNodeColor: String, CaseIterable, Identifiable, Codable {
    case red, orange, yellow, green, teal, blue, indigo, purple, magenta, pink, gray, white

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// The choices for a role colour: everything but white, which is offered
    /// for markup fills and outlines only.
    static var roleChoices: [GraphNodeColor] { allCases.filter { $0 != .white } }

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
        case .white: return "#FFFFFF"
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

/// What a Quick Graph (Study mode) is drawn with: the defaults or a preset.
nonisolated enum QuickGraphSelection: Equatable {
    case `default`
    case preset(UUID)

    /// The UserDefaults form: "default" or the preset's id.
    var storageValue: String {
        switch self {
        case .default: return "default"
        case .preset(let id): return id.uuidString
        }
    }

    init?(storageValue: String) {
        if storageValue == "default" {
            self = .default
            return
        }
        guard let id = UUID(uuidString: storageValue) else { return nil }
        self = .preset(id)
    }
}

/// The settings a Quick Graph draws with: a preset's, or the defaults (every
/// instance, no field filter, Tree, the default colours, no markups).
struct QuickGraphSettings {
    var name: String
    var query: String
    var fieldFilter: String?
    var layoutMode: GraphLayoutMode
    var colors: GraphNodeColorSet
    var markups: [GraphMarkup]

    static let defaults = QuickGraphSettings(
        name: "(default)",
        query: "",
        fieldFilter: nil,
        layoutMode: .tree,
        colors: GraphNodeColorSet(
            isolated: GraphNodeRole.isolated.defaultColor,
            inbound: GraphNodeRole.inbound.defaultColor,
            sourceOnly: GraphNodeRole.sourceOnly.defaultColor
        ),
        markups: []
    )
}

/// One row of Study mode's Quick Graph submenu.
struct QuickGraphMenuEntry {
    var selection: QuickGraphSelection
    var title: String
    var isLastUsed: Bool
}

/// The markup layers resolved against a graph's nodes: each enabled layer
/// with a colour, in list order, paints its fill and/or outline on the nodes
/// its search matches, a later layer overriding an earlier one per property.
/// A layer whose search fails to parse or names an unknown collection/office
/// is skipped (the settings window shows why). Shared by the Graph tab and
/// the Quick Graph window.
func resolveGraphMarkups(
    _ markups: [GraphMarkup],
    for data: GraphData,
    appDatabase: AppDatabase
) -> [Int64: GraphNodeMarkup] {
    let nodeIDs = Set(data.nodes.map(\.instanceID))
    var result: [Int64: GraphNodeMarkup] = [:]
    for markup in markups where markup.drawsAnything {
        guard let matches = try? appDatabase.fetchInstanceIDs(matchingInstanceSearch: markup.query) else { continue }
        for id in matches where nodeIDs.contains(id) {
            var entry = result[id] ?? GraphNodeMarkup()
            if let fill = markup.fill { entry.fill = fill.hex }
            if let outline = markup.outline { entry.outline = outline.hex }
            result[id] = entry
        }
    }
    return result
}

extension GraphData {
    /// The connected component holding the instance — arrows followed in
    /// either direction — with the edges between its nodes and the source
    /// set narrowed to it; nil when the instance is not a node.
    func connectedComponent(containing instanceID: Int64) -> GraphData? {
        guard nodes.contains(where: { $0.instanceID == instanceID }) else { return nil }
        var neighbours: [Int64: [Int64]] = [:]
        for edge in edges {
            neighbours[edge.fromInstanceID, default: []].append(edge.toInstanceID)
            neighbours[edge.toInstanceID, default: []].append(edge.fromInstanceID)
        }
        var reached: Set<Int64> = [instanceID]
        var queue = [instanceID]
        while let current = queue.popLast() {
            for next in neighbours[current] ?? [] where reached.insert(next).inserted {
                queue.append(next)
            }
        }
        return GraphData(
            nodes: nodes.filter { reached.contains($0.instanceID) },
            sourceNodeIDs: sourceNodeIDs.intersection(reached),
            edges: edges.filter { reached.contains($0.fromInstanceID) && reached.contains($0.toInstanceID) }
        )
    }
}

final class GraphSettingsStore: ObservableObject {
    static let shared = GraphSettingsStore()

    private static let markupsKey = "com.sam.Memor.graphMarkups"
    private static let presetsKey = "com.sam.Memor.graphPresets"
    private static let quickGraphLastUsedKey = "com.sam.Memor.quickGraphLastUsed"

    @Published var markups: [GraphMarkup] {
        didSet { if markups != oldValue { Self.persist(markups, key: Self.markupsKey) } }
    }
    @Published var presets: [GraphPreset] {
        didSet { if presets != oldValue { Self.persist(presets, key: Self.presetsKey) } }
    }
    /// A preset the Graph page should load and run: set by `apply`, consumed
    /// by the page — at once while it is showing, else on its next visit.
    @Published var pendingApply: GraphPreset?
    /// Info mode: every node shows its label beside it. Session-only by
    /// design — never persisted and never part of a preset.
    @Published var isInfoModeEnabled = false
    /// The option the last Quick Graph was opened with: ⌘G reuses it and the
    /// submenu lists it first. Persisted; a deleted preset counts as none.
    @Published var quickGraphLastUsed: QuickGraphSelection? {
        didSet {
            if let quickGraphLastUsed {
                UserDefaults.standard.set(quickGraphLastUsed.storageValue, forKey: Self.quickGraphLastUsedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.quickGraphLastUsedKey)
            }
        }
    }

    private init() {
        markups = Self.load([GraphMarkup].self, key: Self.markupsKey) ?? []
        presets = Self.load([GraphPreset].self, key: Self.presetsKey) ?? []
        quickGraphLastUsed = UserDefaults.standard.string(forKey: Self.quickGraphLastUsedKey)
            .flatMap(QuickGraphSelection.init(storageValue:))
    }

    // MARK: - Quick Graph

    func preset(id: UUID) -> GraphPreset? {
        presets.first { $0.id == id }
    }

    /// The last-used option, or the defaults when there is none or its
    /// preset has been deleted.
    var effectiveQuickGraphSelection: QuickGraphSelection {
        if case .preset(let id)? = quickGraphLastUsed, preset(id: id) == nil { return .default }
        return quickGraphLastUsed ?? .default
    }

    func recordQuickGraphUse(_ selection: QuickGraphSelection) {
        quickGraphLastUsed = selection
    }

    func quickGraphSettings(for selection: QuickGraphSelection) -> QuickGraphSettings {
        guard case .preset(let id) = selection, let preset = preset(id: id) else {
            return .defaults
        }
        return QuickGraphSettings(
            name: preset.name,
            query: preset.query,
            fieldFilter: preset.isFieldFilterEnabled ? preset.fieldFilterText : nil,
            layoutMode: preset.layoutMode,
            colors: preset.colors,
            markups: preset.markups
        )
    }

    /// The submenu's rows: the last-used option first, marked, then
    /// "(default)", then the presets A–Z — each option listed once.
    func quickGraphMenuEntries() -> [QuickGraphMenuEntry] {
        var ordered: [(selection: QuickGraphSelection, title: String)] = [(.default, "(default)")]
        ordered += presets
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { (.preset($0.id), $0.name) }
        let lastUsed = effectiveQuickGraphSelection
        var entries: [QuickGraphMenuEntry] = []
        if quickGraphLastUsed != nil, let match = ordered.first(where: { $0.selection == lastUsed }) {
            entries.append(QuickGraphMenuEntry(selection: match.selection, title: "\(match.title) [last used]", isLastUsed: true))
        }
        for option in ordered where !(quickGraphLastUsed != nil && option.selection == lastUsed) {
            entries.append(QuickGraphMenuEntry(selection: option.selection, title: option.title, isLastUsed: false))
        }
        return entries
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
