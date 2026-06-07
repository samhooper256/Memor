//
//  ManageBoundariesWindowView.swift
//  Memor
//
//  Standalone window for managing boundary sets: list all sets, expand to
//  view per-set boundaries, upload new sets, rename / delete user sets.
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

struct ManageBoundariesWindowView: View {
    let appDatabase: AppDatabase
    @EnvironmentObject private var windowState: ManageBoundariesWindowState

    @State private var sets: [BoundarySet] = []
    @State private var boundariesBySetID: [Int64: [Boundary]] = [:]
    @State private var expandedSetIDs: Set<Int64> = []
    @State private var selectedSetID: Int64?

    @State private var isUploadPresented = false
    @State private var isHelpPresented = false
    @State private var renameTarget: BoundarySet?
    @State private var renameDraft: String = ""
    @State private var deleteTarget: BoundarySet?

    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    isUploadPresented = true
                } label: {
                    Label("Upload new set…", systemImage: "arrow.up.doc")
                }

                Button {
                    beginRename()
                } label: {
                    Label("Rename set", systemImage: "pencil")
                }
                .disabled(!canModifySelection)

                Button(role: .destructive) {
                    beginDelete()
                } label: {
                    Label("Delete set", systemImage: "trash")
                }
                .disabled(!canModifySelection)

                Button {
                    isHelpPresented = true
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sets.isEmpty {
                        Text("No boundary sets yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(16)
                    } else {
                        ForEach(sets) { set in
                            BoundarySetRow(
                                set: set,
                                isSelected: selectedSetID == set.id,
                                isExpanded: expandedSetIDs.contains(set.id),
                                boundaries: boundariesBySetID[set.id] ?? [],
                                onSelect: { selectedSetID = set.id },
                                onToggleExpanded: { toggleExpand(set) }
                            )
                            Divider()
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            if let successMessage {
                Text(successMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle("Manage Boundaries")
        .onAppear {
            reload()
        }
        .onChange(of: windowState.requestNonce) { _, _ in
            reload()
        }
        .fileImporter(
            isPresented: $isUploadPresented,
            allowedContentTypes: BoundaryUploader.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            let outcome = BoundaryUploader.handle(result: result, appDatabase: appDatabase)
            switch outcome {
            case .success(_, let count, let name):
                errorMessage = nil
                successMessage = "Imported \(count) from \(name)"
                reload()
            case .failure(let message):
                successMessage = nil
                errorMessage = message
            }
        }
        .alert("Rename set", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") { commitRename() }
        } message: {
            if let target = renameTarget {
                Text("New name for \"\(target.name)\"")
            }
        }
        .alert("Delete set?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) { commitDelete() }
        } message: {
            if let target = deleteTarget {
                Text("Delete \"\(target.name)\" and its \(target.boundaryCount) boundary/boundaries? This cannot be undone.")
            }
        }
        .sheet(isPresented: $isHelpPresented) {
            BoundaryUploadHelpView(onClose: { isHelpPresented = false })
        }
    }

    private var canModifySelection: Bool {
        guard let selectedSetID,
              let set = sets.first(where: { $0.id == selectedSetID }) else { return false }
        return !set.isBuiltin
    }

    private func reload() {
        do {
            sets = try appDatabase.fetchBoundarySets()
            var cache: [Int64: [Boundary]] = [:]
            for set in sets where expandedSetIDs.contains(set.id) {
                cache[set.id] = (try? appDatabase.fetchBoundaries(setID: set.id)) ?? []
            }
            boundariesBySetID = cache
            if let selectedSetID, !sets.contains(where: { $0.id == selectedSetID }) {
                self.selectedSetID = nil
            }
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

    private func beginRename() {
        guard let selectedSetID,
              let set = sets.first(where: { $0.id == selectedSetID }),
              !set.isBuiltin else { return }
        renameDraft = set.name
        renameTarget = set
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renameTarget = nil }
        guard !trimmed.isEmpty else {
            errorMessage = "Name cannot be empty."
            return
        }
        do {
            try appDatabase.renameBoundarySet(id: target.id, newName: trimmed)
            errorMessage = nil
            successMessage = "Renamed."
            reload()
        } catch {
            successMessage = nil
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    private func beginDelete() {
        guard let selectedSetID,
              let set = sets.first(where: { $0.id == selectedSetID }),
              !set.isBuiltin else { return }
        deleteTarget = set
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        defer { deleteTarget = nil }
        do {
            try appDatabase.deleteBoundarySet(id: target.id)
            errorMessage = nil
            successMessage = "Deleted \(target.name)."
            if selectedSetID == target.id {
                selectedSetID = nil
            }
            expandedSetIDs.remove(target.id)
            reload()
        } catch {
            successMessage = nil
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}

private struct BoundarySetRow: View {
    let set: BoundarySet
    let isSelected: Bool
    let isExpanded: Bool
    let boundaries: [Boundary]
    let onSelect: () -> Void
    let onToggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggleExpanded) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                Text(set.name)
                    .font(.body)
                    .lineLimit(1)

                if set.isBuiltin {
                    Text("Built-in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.15))
                        )
                }

                Spacer()

                Text("\(set.boundaryCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            if isExpanded {
                if boundaries.isEmpty {
                    Text("(empty)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 34)
                        .padding(.bottom, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(boundaries) { b in
                            Text(b.name)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 34)
                                .padding(.vertical, 2)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
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

                    Text(LocalizedStringKey("Click \"Upload new set…\" to import a JSON (`.json`) or GeoJSON (`.geojson`) file. The file is read once and all boundary geometries are saved into Memor's database, so you can delete the file from your computer after importing. The set is named after the file but can be renamed later."))
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
