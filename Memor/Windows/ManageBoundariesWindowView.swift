//
//  ManageBoundariesWindowView.swift
//  Memor
//
//  Standalone window for managing boundary sets, styled like the main tab
//  pages (large title, rounded cards, hover-revealed row actions): upload new
//  sets, expand a set to see its boundaries, rename / delete user sets (hover
//  buttons or right-click), and rename any single boundary (double-click or
//  right-click → Rename…). Confirmations surface as a toast.
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

struct ManageBoundariesWindowView: View {
    let appDatabase: AppDatabase
    @EnvironmentObject private var windowState: ManageBoundariesWindowState
    @Environment(\.dismiss) private var dismiss

    @State private var sets: [BoundarySet] = []
    @State private var boundariesBySetID: [Int64: [Boundary]] = [:]
    @State private var expandedSetIDs: Set<Int64> = []

    @State private var isUploadPresented = false
    @State private var isHelpPresented = false
    @State private var renameTarget: BoundaryRenameTarget?
    @State private var deleteTarget: BoundarySet?
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

                Button("Upload Boundary Set…") {
                    isUploadPresented = true
                }
                .buttonStyle(.borderedProminent)

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
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(sets) { set in
                            BoundarySetCard(
                                set: set,
                                isExpanded: expandedSetIDs.contains(set.id),
                                boundaries: boundariesBySetID[set.id] ?? [],
                                renameTarget: $renameTarget,
                                onToggleExpanded: { toggleExpand(set) },
                                onDelete: { beginDelete(set) },
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
            let outcome = BoundaryUploader.handle(result: result, appDatabase: appDatabase)
            switch outcome {
            case .success(_, let count, let name):
                errorMessage = nil
                reload()
                showToast("Imported \(count) \(count == 1 ? "boundary" : "boundaries") from \(name)")
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
            let count = deleteTarget?.boundaryCount ?? 0
            Text("Its \(count) \(count == 1 ? "boundary is" : "boundaries are") removed from every PointMap and BoundaryMap instance that uses them, along with their BoundaryMap queries. This cannot be undone.")
        }
        .sheet(isPresented: $isHelpPresented) {
            BoundaryUploadHelpView(onClose: { isHelpPresented = false })
        }
    }

    private func reload() {
        do {
            sets = try appDatabase.fetchBoundarySets()
            var cache: [Int64: [Boundary]] = [:]
            for set in sets where expandedSetIDs.contains(set.id) {
                cache[set.id] = (try? appDatabase.fetchBoundaries(setID: set.id)) ?? []
            }
            boundariesBySetID = cache
        } catch {
            sets = []
            boundariesBySetID = [:]
            errorMessage = "Failed to load boundary sets: \(error.localizedDescription)"
        }
    }

    private func toggleExpand(_ set: BoundarySet) {
        if expandedSetIDs.contains(set.id) {
            expandedSetIDs.remove(set.id)
            boundariesBySetID.removeValue(forKey: set.id)
        } else {
            expandedSetIDs.insert(set.id)
            boundariesBySetID[set.id] = (try? appDatabase.fetchBoundaries(setID: set.id)) ?? []
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
        deleteTarget = set
        isDeleteConfirmationPresented = true
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        do {
            try appDatabase.deleteBoundarySet(id: target.id)
            expandedSetIDs.remove(target.id)
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
    let renameTarget: Binding<BoundaryRenameTarget?>
    let onToggleExpanded: () -> Void
    let onDelete: () -> Void
    let onCommitRename: (BoundaryRenameTarget, String) -> String?

    @State private var isHovered = false

    private var countText: String {
        "\(set.boundaryCount) \(set.boundaryCount == 1 ? "boundary" : "boundaries")"
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

            // Built-in sets are protected: no set-level rename or delete.
            if !set.isBuiltin {
                HStack(spacing: 2) {
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
                .opacity(isHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        // Tall enough for the hover buttons, so built-in cards (which have
        // none) match the user sets' height.
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
            if !set.isBuiltin {
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
    let onCommitRename: (BoundaryRenameTarget, String) -> String?

    @State private var isHovered = false

    private var isBeingRenamed: Bool {
        renameTarget.wrappedValue?.id == BoundaryRenameTarget.boundary(boundary).id
    }

    var body: some View {
        Text(boundary.name)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 8 (list inset) + 32 lines the names up under the set's name.
            .padding(.leading, 32)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered || isBeingRenamed ? Color.secondary.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
            .help("Double-click to rename")
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

/// Hover-revealed icon button in a set card's header (same look as the
/// Collections/Types row actions).
private struct BoundaryRowIconButton: View {
    let systemImage: String
    let tint: Color
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
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

                    Text("Any single boundary can be renamed too—double-click it, or right-click it and choose Rename. This works in the built-in Countries set as well.")
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
