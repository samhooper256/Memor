//
//  GraphSettingsWindowView.swift
//  Memor
//
//  The Graph tab's settings window, opened from the gear between the Search
//  button and the Layout picker (or ⌘S on the tab). Three sections: the
//  per-role node colours, the ordered markup layers, and the saved presets.
//  The models and their persistence live in Shared/GraphSettingsStore.swift.
//

import AppKit
import SwiftUI

struct GraphSettingsWindowView: View {
    let appDatabase: AppDatabase

    @EnvironmentObject private var navigationState: AppNavigationState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = GraphSettingsStore.shared

    @State private var presetPendingRename: GraphPreset?
    @State private var presetPendingDelete: GraphPreset?
    @State private var isAddPresetPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                colorsSection
                markupsSection
                presetsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 760, idealWidth: 760, minHeight: 540, idealHeight: 640)
        .background {
            GraphSettingsEscapeHandler { dismiss() }
        }
        .alert(
            "Delete preset?",
            isPresented: Binding(
                get: { presetPendingDelete != nil },
                set: { if !$0 { presetPendingDelete = nil } }
            ),
            presenting: presetPendingDelete
        ) { preset in
            Button("Delete", role: .destructive) { store.deletePreset(id: preset.id) }
            Button("Cancel", role: .cancel) { }
        } message: { preset in
            Text("“\(preset.name)” will be removed. The graph's current settings are not affected.")
        }
    }

    // MARK: - Colors

    private var colorsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(GraphNodeRole.allCases) { role in
                    GraphNodeColorRow(role: role)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Colors").font(.headline)
        }
    }

    // MARK: - Markups

    private var markupsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Instances matching a search are filled and/or outlined in its colors. Layers apply top to bottom after the colors above, so a lower layer wins where two overlap; an unchecked layer is skipped. An empty search matches every instance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.markups.isEmpty {
                    Text("No markups yet.")
                        .foregroundStyle(.secondary)
                }

                ForEach($store.markups) { $markup in
                    let index = store.markups.firstIndex(where: { $0.id == markup.id }) ?? 0
                    GraphMarkupRow(
                        markup: $markup,
                        appDatabase: appDatabase,
                        canMoveUp: index > 0,
                        canMoveDown: index < store.markups.count - 1,
                        onMoveUp: { store.moveMarkup(id: markup.id, by: -1) },
                        onMoveDown: { store.moveMarkup(id: markup.id, by: 1) },
                        onRemove: { store.removeMarkup(id: markup.id) }
                    )
                }

                Button {
                    store.addMarkup()
                } label: {
                    Label("Add Markup", systemImage: "plus")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Markups").font(.headline)
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("A preset stores a whole graph: the search, the layout, the field filter and its checkbox, the colors and the markups. Applying one replaces the current settings and runs its search on the Graph tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.presets.isEmpty {
                    Text("No presets yet.")
                        .foregroundStyle(.secondary)
                }

                ForEach(store.presets) { preset in
                    GraphPresetRow(
                        preset: preset,
                        onApply: { apply(preset) },
                        onRename: { presetPendingRename = preset },
                        onDelete: { presetPendingDelete = preset }
                    )
                    .popover(item: scopedPopoverItem($presetPendingRename, to: preset), arrowEdge: .bottom) { target in
                        RenamePopover(
                            title: "Rename Preset",
                            placeholder: "Preset name",
                            initialName: target.name,
                            onCommit: { name in
                                if let error = store.presetNameError(name, excluding: target.id) { return error }
                                store.renamePreset(id: target.id, to: name)
                                presetPendingRename = nil
                                return nil
                            },
                            onCancel: { presetPendingRename = nil }
                        )
                    }
                }

                Button {
                    isAddPresetPresented = true
                } label: {
                    Label("Add current graph as preset", systemImage: "plus")
                }
                .popover(isPresented: $isAddPresetPresented, arrowEdge: .bottom) {
                    RenamePopover(
                        title: "Name Preset",
                        placeholder: "Preset name",
                        initialName: defaultPresetName,
                        commitTitle: "Add",
                        onCommit: { name in
                            if let error = store.presetNameError(name) { return error }
                            store.addPreset(named: name)
                            isAddPresetPresented = false
                            return nil
                        },
                        onCancel: { isAddPresetPresented = false }
                    )
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Presets").font(.headline)
        }
    }

    /// The Graph tab's current search text, or a numbered fallback.
    private var defaultPresetName: String {
        let query = (UserDefaults.standard.string(forKey: GraphPageDefaults.searchQueryKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? "Preset \(store.presets.count + 1)" : query
    }

    private func apply(_ preset: GraphPreset) {
        store.apply(preset)
        navigationState.select(.graph)
    }
}

// MARK: - Rows

/// A Colors row: the role's title and its colour circle (the control).
private struct GraphNodeColorRow: View {
    let role: GraphNodeRole
    @AppStorage private var color: GraphNodeColor

    init(role: GraphNodeRole) {
        self.role = role
        _color = AppStorage(wrappedValue: role.defaultColor, role.userDefaultsKey)
    }

    var body: some View {
        HStack {
            Text(role.title)
            Spacer()
            GraphColorButton(
                selection: Binding(
                    get: { color },
                    set: { if let chosen = $0 { color = chosen } }
                ),
                allowsNone: false
            )
        }
    }
}

/// A Markups row: enabled checkbox, the search box, Fill and Outline circles,
/// reorder arrows, remove. The search is checked as it is typed and a
/// problem (bad syntax, unknown collection/office) shows in red beneath.
private struct GraphMarkupRow: View {
    @Binding var markup: GraphMarkup
    let appDatabase: AppDatabase
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    @State private var queryError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle("", isOn: $markup.isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Enabled")

                SearchQueryTextField(
                    "Search instances",
                    text: $markup.query,
                    autocomplete: SearchAutocompleteProvider(appDatabase: appDatabase)
                )
                .searchCodeEditorStyle()
                .frame(maxWidth: .infinity)
                .opacity(markup.isEnabled ? 1 : 0.6)

                Text("Fill")
                    .foregroundStyle(.secondary)
                GraphColorButton(selection: $markup.fill, allowsNone: true)

                Text("Outline")
                    .foregroundStyle(.secondary)
                GraphColorButton(selection: $markup.outline, allowsNone: true)

                Button {
                    onMoveUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move up")

                Button {
                    onMoveDown()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move down")

                Button {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }

            if let queryError {
                Text(queryError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 30)
            }
        }
        .task(id: markup.query) {
            do {
                try appDatabase.validateInstanceSearch(query: markup.query)
                queryError = nil
            } catch {
                queryError = error.localizedDescription
            }
        }
    }
}

/// A Presets row: name and a one-line summary (double-click or right-click
/// to rename), Apply, Delete.
private struct GraphPresetRow: View {
    let preset: GraphPreset
    let onApply: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .fontWeight(.medium)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onRename() }
            .contextMenu {
                Button("Rename…") { onRename() }
                Button("Delete…") { onDelete() }
            }

            Button("Apply") { onApply() }
            Button("Delete") { onDelete() }
        }
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(preset.query.isEmpty ? "all instances" : preset.query)
        parts.append(preset.layoutMode.title)
        if preset.isFieldFilterEnabled {
            parts.append("filter: \(preset.fieldFilterText)")
        }
        parts.append("\(preset.markups.count) markup\(preset.markups.count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Colour picking

/// The colour circle that is the control: clicking it opens the palette
/// popover. `allowsNone` adds a "None" cell (the markup colours).
private struct GraphColorButton: View {
    @Binding var selection: GraphNodeColor?
    let allowsNone: Bool

    @State private var isPalettePresented = false

    var body: some View {
        Button {
            isPalettePresented.toggle()
        } label: {
            GraphColorSwatch(color: selection, diameter: 18)
        }
        .buttonStyle(.plain)
        .help(selection?.title ?? "None")
        .popover(isPresented: $isPalettePresented, arrowEdge: .bottom) {
            GraphColorPaletteView(selection: $selection, allowsNone: allowsNone) {
                isPalettePresented = false
            }
        }
    }
}

/// The palette popover: four circles per row (the 11 colours fall 4/4/3,
/// 4/4/4 with None), the current choice ringed, the name on hover. A click
/// chooses and closes.
private struct GraphColorPaletteView: View {
    @Binding var selection: GraphNodeColor?
    let allowsNone: Bool
    let onPick: () -> Void

    private static let cell: CGFloat = 30
    private let columns = Array(repeating: GridItem(.fixed(cell), spacing: 6), count: 4)

    private var options: [GraphNodeColor?] {
        GraphNodeColor.allCases.map(Optional.some) + (allowsNone ? [nil] : [])
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
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
                .help(option?.title ?? "None")
            }
        }
        .padding(12)
    }
}

/// A filled colour circle with a faint edge so pale colours keep a shape;
/// nil draws the "none" swatch (an empty circle with a red slash).
private struct GraphColorSwatch: View {
    let color: GraphNodeColor?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            if let color {
                Circle().fill(color.color)
            } else {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
                Path { path in
                    path.move(to: CGPoint(x: diameter * 0.22, y: diameter * 0.78))
                    path.addLine(to: CGPoint(x: diameter * 0.78, y: diameter * 0.22))
                }
                .stroke(Color.red, lineWidth: 1.5)
            }
            Circle().stroke(Color.black.opacity(0.25), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Escape

/// Escape closes the window — unless a search box's autocomplete popup is
/// open, in which case it closes that instead. A local monitor, because it
/// sees the key before the field would (the Search window does the same).
private struct GraphSettingsEscapeHandler: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onEscape = onEscape
    }

    final class MonitorView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window, event.keyCode == 53 else { return event }
                    if SearchAutocompleteController.dismissActivePopup() { return nil }
                    self.onEscape?()
                    return nil
                }
            }
        }

        deinit {
            removeMonitor()
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
