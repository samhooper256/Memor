//
//  ManageBoundariesWindowView.swift
//  Memor
//
//  Standalone window for managing boundary sets, styled like the main tab
//  pages (large title, rounded cards, hover-revealed row actions): upload new
//  sets, expand a set to see its boundaries, rename / delete user sets (hover
//  buttons or right-click), add boundaries to ANY set from a GeoJSON file
//  (hover "+" or right-click; built-in included), and rename (double-click or
//  right-click → Rename…) or delete (hover trash or right-click) any single
//  boundary. Deletes always confirm with the live cascade counts (PointMap
//  overlays, BoundaryMap attachments + queries). Confirmations surface as a
//  toast. The search field (Find in List shortcut, ⌘F) matches set names AND
//  boundary names; a set with matching boundaries opens itself and lists only
//  the matches.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ManageBoundariesWindowState: ObservableObject {
    @Published var requestNonce = UUID()

    func requestOpen() {
        requestNonce = UUID()
    }
}

/// What the rename popover is editing: a whole (user) set or one boundary.
private enum BoundaryRenameTarget: Identifiable, Hashable {
    case set(BoundarySet)
    case boundary(Boundary)

    var id: String {
        switch self {
        case .set(let set): return "set-\(set.id)"
        case .boundary(let boundary): return "boundary-\(boundary.id)"
        }
    }

    var currentName: String {
        switch self {
        case .set(let set): return set.name
        case .boundary(let boundary): return boundary.name
        }
    }

    var popoverTitle: String {
        switch self {
        case .set: return "Rename Set"
        case .boundary: return "Rename Boundary"
        }
    }

    var fieldPlaceholder: String {
        switch self {
        case .set: return "Set Name"
        case .boundary: return "Boundary Name"
        }
    }
}

/// What the delete confirmation is about, with the cascade it would cause
/// (fetched when the confirmation opens, so the counts are live).
private enum BoundaryDeleteTarget {
    case set(BoundarySet, usage: AppDatabase.BoundaryUsage)
    case boundary(Boundary, usage: AppDatabase.BoundaryUsage)

    var name: String {
        switch self {
        case .set(let set, _): return set.name
        case .boundary(let boundary, _): return boundary.name
        }
    }

    var alertMessage: String {
        switch self {
        case .set(let set, let usage):
            let count = set.boundaryCount
            let lead = "Its \(count) \(count == 1 ? "boundary is" : "boundaries are") deleted."
            return "\(lead) \(Self.cascadeSentence(usage: usage, plural: count != 1)) This cannot be undone."
        case .boundary(_, let usage):
            return "\(Self.cascadeSentence(usage: usage, plural: false)) This cannot be undone."
        }
    }

    private static func cascadeSentence(usage: AppDatabase.BoundaryUsage, plural: Bool) -> String {
        if usage.isEmpty {
            return "No PointMap or BoundaryMap instance uses \(plural ? "them" : "it")."
        }
        var places: [String] = []
        if usage.pointMapInstanceCount > 0 {
            places.append(counted(usage.pointMapInstanceCount, "PointMap instance"))
        }
        if usage.boundaryMapInstanceCount > 0 {
            places.append(counted(usage.boundaryMapInstanceCount, "BoundaryMap instance"))
        }
        var sentence = "\(plural ? "They are" : "It is") removed from \(places.joined(separator: " and "))"
        if usage.boundaryMapQueryCount > 0 {
            sentence += ", along with \(counted(usage.boundaryMapQueryCount, "BoundaryMap query", "BoundaryMap queries")) and their study progress"
        }
        return sentence + "."
    }

    private static func counted(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }
}

/// Item-based presentation, but scoped to ONE row: the popover modifier is
/// attached to every row, so a shared `$renameTarget` would present the
/// popover from all of them at once. Each row sees the target only when it is
/// that row's own.
private func scopedRenameItem(
    _ renameTarget: Binding<BoundaryRenameTarget?>,
    to rowTarget: BoundaryRenameTarget
) -> Binding<BoundaryRenameTarget?> {
    Binding(
        get: { renameTarget.wrappedValue?.id == rowTarget.id ? renameTarget.wrappedValue : nil },
        set: { newValue in
            if newValue == nil, renameTarget.wrappedValue?.id == rowTarget.id {
                renameTarget.wrappedValue = nil
            }
        }
    )
}

/// One set card as the list shows it. While a search is active this is the
/// FILTERED view of the set: a set with matching boundaries lists only those
/// (and opens itself so the matches are visible); a set matched by its own
/// name alone keeps its full list and normal expansion state.
private struct VisibleBoundarySet: Identifiable {
    let set: BoundarySet
    let boundaries: [Boundary]
    let isFilteredToMatches: Bool

    // `self.` is required: a bare leading `set` parses as a setter.
    var id: Int64 { self.set.id }
}

struct ManageBoundariesWindowView: View {
    let appDatabase: AppDatabase
    @EnvironmentObject private var windowState: ManageBoundariesWindowState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    @Environment(\.dismiss) private var dismiss

    @State private var sets: [BoundarySet] = []
    // Every set's boundaries (names only — no geometry), loaded up front so
    // the search can match boundaries inside collapsed sets.
    @State private var boundariesBySetID: [Int64: [Boundary]] = [:]
    @State private var expandedSetIDs: Set<Int64> = []

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    // Sets the user collapsed while a search had auto-opened them. Cleared on
    // every search-text change, so each new search shows its matches again.
    @State private var searchCollapsedSetIDs: Set<Int64> = []

    @State private var isUploadPresented = false
    // Set by whichever button opened the file importer, read in its completion.
    @State private var uploadDestination: BoundaryUploadDestination = .newSet
    @State private var isHelpPresented = false
    @State private var renameTarget: BoundaryRenameTarget?
    @State private var deleteTarget: BoundaryDeleteTarget?
    @State private var isDeleteConfirmationPresented = false

    @State private var errorMessage: String?
    @State private var toast: ToastMessage?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text("Boundary Sets")
                        .font(.largeTitle)
                        .fontWeight(.semibold)

                    Button {
                        isHelpPresented = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.borderless)
                    .help("Learn how to upload boundaries")
                }

                HStack(spacing: 12) {
                    Button("Upload Boundary Set…") {
                        uploadDestination = .newSet
                        isUploadPresented = true
                    }
                    .buttonStyle(.borderedProminent)

                    TextField(searchPlaceholder, text: $searchText)
                        .solidFocusField()
                        .focused($isSearchFocused)
                        .frame(maxWidth: .infinity)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if sets.isEmpty {
                    if errorMessage == nil {
                        Text("You have no boundary sets.")
                            .foregroundStyle(.secondary)
                    }
                } else if visibleSets.isEmpty {
                    Text("No boundary sets or boundaries match your search.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleSets) { visible in
                            BoundarySetCard(
                                set: visible.set,
                                isExpanded: isExpanded(visible),
                                boundaries: visible.boundaries,
                                isFilteredToMatches: visible.isFilteredToMatches,
                                renameTarget: $renameTarget,
                                onToggleExpanded: { toggleExpand(visible) },
                                onAddFromFile: {
                                    uploadDestination = .existingSet(visible.set)
                                    isUploadPresented = true
                                },
                                onDelete: { beginDelete(visible.set) },
                                onDeleteBoundary: beginDelete,
                                onCommitRename: commitRename
                            )
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle("Manage Boundaries")
        .background {
            FindShortcutKeyHandler(shortcutSettings: shortcutSettings) {
                isSearchFocused = true
            }
        }
        .onChange(of: searchText) { _, _ in
            searchCollapsedSetIDs = []
        }
        .overlay(alignment: .topTrailing) {
            if let toast {
                ToastView(toast: toast)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .onAppear {
            reload()
        }
        .onChange(of: windowState.requestNonce) { _, _ in
            reload()
        }
        .onExitCommand { dismiss() }
        .background(
            // Reliable Escape even when nothing holds focus.
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
        .fileImporter(
            isPresented: $isUploadPresented,
            allowedContentTypes: BoundaryUploader.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            let destination = uploadDestination
            let outcome = BoundaryUploader.handle(result: result, destination: destination, appDatabase: appDatabase)
            switch outcome {
            case .success(let setID, let count, let name):
                errorMessage = nil
                let noun = count == 1 ? "boundary" : "boundaries"
                switch destination {
                case .newSet:
                    showToast("Imported \(count) \(noun) from \(name)")
                case .existingSet:
                    // Open the set so the additions are visible, and let the
                    // map instance editors' pickers see them.
                    expandedSetIDs.insert(setID)
                    NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
                    showToast("Added \(count) \(noun) to \u{201C}\(name)\u{201D}")
                }
                reload()
            case .failure(let message):
                errorMessage = message
            }
        }
        .alert(
            "Delete \u{201C}\(deleteTarget?.name ?? "")\u{201D}?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button("Delete", role: .destructive) {
                commitDelete()
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text(deleteTarget?.alertMessage ?? "")
        }
        .sheet(isPresented: $isHelpPresented) {
            BoundaryUploadHelpView(onClose: { isHelpPresented = false })
        }
    }

    private var searchPlaceholder: String {
        "Search boundary sets and boundaries (\(shortcutSettings.binding(for: .findInList).displayString))"
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleSets: [VisibleBoundarySet] {
        let query = trimmedSearchText
        guard !query.isEmpty else {
            return sets.map {
                VisibleBoundarySet(set: $0, boundaries: boundariesBySetID[$0.id] ?? [], isFilteredToMatches: false)
            }
        }
        return sets.compactMap { set in
            let boundaries = boundariesBySetID[set.id] ?? []
            let matches = boundaries.filter { $0.name.localizedCaseInsensitiveContains(query) }
            if !matches.isEmpty {
                return VisibleBoundarySet(set: set, boundaries: matches, isFilteredToMatches: true)
            }
            if set.name.localizedCaseInsensitiveContains(query) {
                return VisibleBoundarySet(set: set, boundaries: boundaries, isFilteredToMatches: false)
            }
            return nil
        }
    }

    private func isExpanded(_ visible: VisibleBoundarySet) -> Bool {
        visible.isFilteredToMatches
            ? !searchCollapsedSetIDs.contains(visible.id)
            : expandedSetIDs.contains(visible.id)
    }

    private func toggleExpand(_ visible: VisibleBoundarySet) {
        if visible.isFilteredToMatches {
            searchCollapsedSetIDs.formSymmetricDifference([visible.id])
        } else {
            expandedSetIDs.formSymmetricDifference([visible.id])
        }
    }

    private func reload() {
        do {
            sets = try appDatabase.fetchBoundarySets()
            // Already ordered by name within each set.
            boundariesBySetID = Dictionary(
                grouping: try appDatabase.fetchAllBoundaryOptions().map(\.boundary),
                by: \.boundarySetID
            )
        } catch {
            sets = []
            boundariesBySetID = [:]
            errorMessage = "Failed to load boundary sets: \(error.localizedDescription)"
        }
    }

    /// Returns an error message for the popover to show in place (it stays
    /// open so the name can be corrected), or nil once the rename is done.
    private func commitRename(_ target: BoundaryRenameTarget, to newName: String) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Name cannot be empty." }
        guard trimmed != target.currentName else {
            renameTarget = nil
            return nil
        }
        do {
            switch target {
            case .set(let set):
                try appDatabase.renameBoundarySet(id: set.id, newName: trimmed)
            case .boundary(let boundary):
                try appDatabase.renameBoundary(id: boundary.id, newName: trimmed)
                // Boundary names show up outside this window (search results,
                // map instance editors), so let the visible pages refetch.
                NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            }
            renameTarget = nil
            errorMessage = nil
            reload()
            showToast("Renamed to \u{201C}\(trimmed)\u{201D}")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func beginDelete(_ set: BoundarySet) {
        guard !set.isBuiltin else { return }
        do {
            deleteTarget = .set(set, usage: try appDatabase.fetchBoundaryUsage(setID: set.id))
            isDeleteConfirmationPresented = true
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Always confirmed, even when nothing uses the boundary: unlike an
    /// office, a boundary's geometry can't be typed back in.
    private func beginDelete(_ boundary: Boundary) {
        do {
            deleteTarget = .boundary(boundary, usage: try appDatabase.fetchBoundaryUsage(boundaryID: boundary.id))
            isDeleteConfirmationPresented = true
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        do {
            switch target {
            case .set(let set, _):
                try appDatabase.deleteBoundarySet(id: set.id)
                expandedSetIDs.remove(set.id)
            case .boundary(let boundary, _):
                try appDatabase.deleteBoundary(id: boundary.id)
            }
            // Either delete can take attachments and queries with it.
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            errorMessage = nil
            reload()
            showToast("Deleted \u{201C}\(target.name)\u{201D}")
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toast = ToastMessage(message: message, style: .success)

        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

// MARK: - Set card

private struct BoundarySetCard: View {
    let set: BoundarySet
    let isExpanded: Bool
    let boundaries: [Boundary]
    /// True while a search narrows `boundaries` to the matching ones.
    let isFilteredToMatches: Bool
    let renameTarget: Binding<BoundaryRenameTarget?>
    let onToggleExpanded: () -> Void
    let onAddFromFile: () -> Void
    let onDelete: () -> Void
    let onDeleteBoundary: (Boundary) -> Void
    let onCommitRename: (BoundaryRenameTarget, String) -> String?

    @State private var isHovered = false

    private var countText: String {
        let noun = set.boundaryCount == 1 ? "boundary" : "boundaries"
        if isFilteredToMatches {
            return "\(boundaries.count) of \(set.boundaryCount) \(noun)"
        }
        return "\(set.boundaryCount) \(noun)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)
                boundaryList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        // 10 rather than the pages' 14: these cards are short when collapsed,
        // and 14 would round them into near-pills.
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.15), value: isExpanded)
                .frame(width: 12)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(set.name)
                    .font(.title3)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(countText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if set.isBuiltin {
                    Text("Built-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.15))
                        )
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                BoundaryRowIconButton(
                    systemImage: "plus",
                    tint: .primary,
                    tooltip: "Add boundaries from a file",
                    action: onAddFromFile
                )
                // The set itself (its name, its existence) is protected when
                // built-in; its contents are always editable.
                if !set.isBuiltin {
                    BoundaryRowIconButton(
                        systemImage: "pencil",
                        tint: .primary,
                        tooltip: "Rename set",
                        action: { renameTarget.wrappedValue = .set(set) }
                    )
                    BoundaryRowIconButton(
                        systemImage: "trash",
                        tint: .red,
                        tooltip: "Delete set",
                        action: onDelete
                    )
                }
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .frame(minHeight: 34)
        .contentShape(Rectangle())
        .pointerStyle(isHovered ? .link : .default)
        .onTapGesture(perform: onToggleExpanded)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
        .contextMenu {
            Button("Add Boundaries from File…", action: onAddFromFile)
            if !set.isBuiltin {
                Divider()
                Button("Rename…") {
                    renameTarget.wrappedValue = .set(set)
                }
                Button("Delete…", role: .destructive, action: onDelete)
            }
        }
        .popover(item: scopedRenameItem(renameTarget, to: .set(set)), arrowEdge: .bottom) { target in
            BoundaryRenamePopover(
                target: target,
                onCommit: { onCommitRename(target, $0) },
                onCancel: { renameTarget.wrappedValue = nil }
            )
        }
    }

    @ViewBuilder
    private var boundaryList: some View {
        if boundaries.isEmpty {
            Text("This set has no boundaries.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
                .padding(.vertical, 10)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(boundaries) { boundary in
                    BoundaryRow(
                        boundary: boundary,
                        renameTarget: renameTarget,
                        onDelete: { onDeleteBoundary(boundary) },
                        onCommitRename: onCommitRename
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Boundary row

private struct BoundaryRow: View {
    let boundary: Boundary
    let renameTarget: Binding<BoundaryRenameTarget?>
    let onDelete: () -> Void
    let onCommitRename: (BoundaryRenameTarget, String) -> String?

    @State private var isHovered = false

    private var isBeingRenamed: Bool {
        renameTarget.wrappedValue?.id == BoundaryRenameTarget.boundary(boundary).id
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(boundary.name)
                .lineLimit(1)
                .help("Double-click to rename")

            Spacer(minLength: 0)

            BoundaryRowIconButton(
                systemImage: "trash",
                tint: .red,
                tooltip: "Delete boundary",
                isCompact: true,
                action: onDelete
            )
            .opacity(isHovered ? 1 : 0)
        }
        // 8 (list inset) + 32 lines the names up under the set's name.
        .padding(.leading, 32)
        .padding(.trailing, 4)
        .padding(.vertical, 1)
        .frame(minHeight: 25)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered || isBeingRenamed ? Color.secondary.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            renameTarget.wrappedValue = .boundary(boundary)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
        .contextMenu {
            Button("Rename…") {
                renameTarget.wrappedValue = .boundary(boundary)
            }
            Button("Delete…", role: .destructive, action: onDelete)
        }
        .popover(item: scopedRenameItem(renameTarget, to: .boundary(boundary)), arrowEdge: .bottom) { target in
            BoundaryRenamePopover(
                target: target,
                onCommit: { onCommitRename(target, $0) },
                onCancel: { renameTarget.wrappedValue = nil }
            )
        }
    }
}

// MARK: - Shared pieces

/// Hover-revealed icon button in a set card's header or a boundary row (same
/// look as the Collections/Types row actions). `isCompact` shrinks it to fit
/// a boundary row without making the row taller.
private struct BoundaryRowIconButton: View {
    let systemImage: String
    let tint: Color
    let tooltip: String
    var isCompact = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(isCompact ? .system(size: 11) : .body)
                .foregroundStyle(tint)
                .padding(isCompact ? 4 : 6)
                .background(
                    RoundedRectangle(cornerRadius: isCompact ? 5 : 7)
                        .fill(isHovered ? tint.opacity(0.14) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct BoundaryRenamePopover: View {
    let target: BoundaryRenameTarget
    /// Returns an error message to show in place, or nil once the rename is
    /// saved (the owner dismisses the popover by clearing the target).
    let onCommit: (String) -> String?
    let onCancel: () -> Void

    @State private var text: String
    @State private var errorMessage: String?

    init(
        target: BoundaryRenameTarget,
        onCommit: @escaping (String) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: target.currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.popoverTitle)
                .font(.headline)

            TextField(target.fieldPlaceholder, text: $text)
                .solidFocusField()
                .frame(width: 240)
                .onSubmit { commit() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func commit() {
        errorMessage = onCommit(text)
    }
}

private struct BoundaryUploadHelpView: View {
    let onClose: () -> Void

    private static let exampleJSON: String = """
    [
      {
        "properties": { "name": "Custom Region A" },
        "geometry": {
          "type": "Polygon",
          "coordinates": [
            [
              [-122.5, 37.7],
              [-122.5, 37.8],
              [-122.4, 37.8],
              [-122.5, 37.7]
            ]
          ]
        }
      }
    ]
    """

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Uploading Boundaries")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Spacer()
                    }

                    Text(LocalizedStringKey("Click \"Upload Boundary Set…\" to import a JSON (`.json`) or GeoJSON (`.geojson`) file. The file is read once and all boundary geometries are saved into Memor's database, so you can delete the file from your computer after importing. The set is named after the file but can be renamed later."))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("To add boundaries to a set that already exists, hover over the set and click its + button (or right-click it and choose Add Boundaries from File…); the file's boundaries are appended to that set. Any single boundary can be renamed (double-click it, or right-click → Rename…) or deleted (hover and click the trash icon, or right-click → Delete…). All of this works in the built-in Countries set as well—only the set itself can't be renamed or deleted.")
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("File format")
                            .font(.headline)
                        Text("The top-level JSON value must be either an array of GeoJSON Feature objects or a GeoJSON FeatureCollection (an object with `\"type\": \"FeatureCollection\"` and a `features` array). For each feature:")
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 4) {
                            helpBullet("`properties.name` — a non-empty string used as the boundary's display name.")
                            helpBullet("`geometry.type` — `\"Polygon\"` or `\"MultiPolygon\"`. Other types are rejected.")
                            helpBullet("`geometry.coordinates` — standard GeoJSON `[lng, lat]` pairs; longitude in [−180, 180], latitude in [−90, 90]; each ring needs at least 3 points.")
                        }
                        .padding(.leading, 8)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Minimal example")
                            .font(.headline)
                        Text(Self.exampleJSON)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 560)
        .onExitCommand(perform: onClose)
    }

    @ViewBuilder
    private func helpBullet(_ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(LocalizedStringKey(markdown))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
