//
//  BoundaryPicker.swift
//  Memor
//
//  Popover for picking which country / uploaded place boundaries are
//  attached to a PointMap instance, plus the shared upload-file helper
//  that wraps SwiftUI's .fileImporter.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared upload helper

enum BoundaryUploadResult {
    /// `setName` is the set the features landed in: the file's base name for
    /// a new set, the existing set's name when appending.
    case success(setID: Int64, featureCount: Int, setName: String)
    case failure(message: String)
}

/// Where an uploaded file's features go.
enum BoundaryUploadDestination {
    /// A new user set named after the file.
    case newSet
    /// Appended to an existing set (built-in included).
    case existingSet(BoundarySet)
}

enum BoundaryUploader {
    static let allowedTypes: [UTType] = {
        var types: [UTType] = [.json]
        if let geo = UTType(filenameExtension: "geojson", conformingTo: .json) {
            types.append(geo)
        }
        return types
    }()

    static func handle(
        result: Result<[URL], Error>,
        destination: BoundaryUploadDestination,
        appDatabase: AppDatabase
    ) -> BoundaryUploadResult {
        switch result {
        case .failure(let error):
            return .failure(message: "Upload failed: \(error.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else {
                return .failure(message: "No file selected.")
            }
            let features: [AppDatabase.ImportedBoundaryFeature]
            switch readFeatures(from: url) {
            case .success(let parsed): features = parsed
            case .failure(let message): return .failure(message: message)
            }
            do {
                switch destination {
                case .newSet:
                    let baseName = url.deletingPathExtension().lastPathComponent
                    let setID = try appDatabase.importBoundarySet(name: baseName, features: features)
                    return .success(setID: setID, featureCount: features.count, setName: baseName)
                case .existingSet(let set):
                    try appDatabase.addBoundaries(toSet: set.id, features: features)
                    return .success(setID: set.id, featureCount: features.count, setName: set.name)
                }
            } catch let err as AppDatabase.BoundaryImportError {
                return .failure(message: err.message)
            } catch {
                return .failure(message: "Failed to save boundaries: \(error.localizedDescription)")
            }
        }
    }

    private enum ReadOutcome {
        case success([AppDatabase.ImportedBoundaryFeature])
        case failure(String)
    }

    private static func readFeatures(from url: URL) -> ReadOutcome {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer {
            if needsScope { url.stopAccessingSecurityScopedResource() }
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure("Could not read file: \(error.localizedDescription)")
        }
        do {
            return .success(try AppDatabase.parseUploadedBoundaryFile(data: data))
        } catch let err as AppDatabase.BoundaryImportError {
            return .failure(err.message)
        } catch {
            return .failure("Invalid file: \(error.localizedDescription)")
        }
    }
}

// MARK: - Picker state

@MainActor
final class BoundaryPickerState: ObservableObject {
    @Published var selectedIDs: Set<Int64> = []
    @Published var options: [BoundaryWithSet] = []
    @Published var searchQuery: String = ""

    func reload(appDatabase: AppDatabase) {
        do {
            options = try appDatabase.fetchAllBoundaryOptions()
        } catch {
            options = []
        }
    }

    var selectedBoundaries: [BoundaryWithSet] {
        let selected = selectedIDs
        return options.filter { selected.contains($0.id) }
    }

    func toggle(_ id: Int64) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    var filteredOptions: [BoundaryWithSet] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return options }
        return options.filter { opt in
            opt.boundary.name.localizedCaseInsensitiveContains(query)
                || opt.setName.localizedCaseInsensitiveContains(query)
        }
    }
}

// MARK: - Popover view

struct BoundaryPickerPopoverView: View {
    @ObservedObject var state: BoundaryPickerState
    let appDatabase: AppDatabase
    let onManage: () -> Void

    @State private var isUploadPresented = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search boundaries", text: $state.searchQuery)
                .solidFocusField()
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if state.filteredOptions.isEmpty {
                        Text(state.options.isEmpty ? "No boundaries yet." : "No matches.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(groupedFiltered(), id: \.setID) { group in
                            Text(group.setName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                            ForEach(group.items) { item in
                                BoundaryPickerRow(
                                    item: item,
                                    isChecked: state.selectedIDs.contains(item.id),
                                    onToggle: { state.toggle(item.id) }
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(height: 260)
            .background(Color(nsColor: .controlBackgroundColor))

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }
            if let successMessage {
                Text(successMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    isUploadPresented = true
                } label: {
                    Label("Upload file…", systemImage: "arrow.up.doc")
                }
                Button {
                    onManage()
                } label: {
                    Label("Manage…", systemImage: "slider.horizontal.3")
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
        .onAppear {
            state.reload(appDatabase: appDatabase)
        }
        .fileImporter(
            isPresented: $isUploadPresented,
            allowedContentTypes: BoundaryUploader.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            let outcome = BoundaryUploader.handle(result: result, destination: .newSet, appDatabase: appDatabase)
            switch outcome {
            case .success(_, let count, let name):
                errorMessage = nil
                successMessage = "Imported \(count) from \(name)"
                state.reload(appDatabase: appDatabase)
            case .failure(let message):
                successMessage = nil
                errorMessage = message
            }
        }
    }

    private struct Group {
        let setID: Int64
        let setName: String
        let items: [BoundaryWithSet]
    }

    private func groupedFiltered() -> [Group] {
        var out: [Group] = []
        var currentSetID: Int64 = -1
        var currentItems: [BoundaryWithSet] = []
        var currentName: String = ""
        for item in state.filteredOptions {
            if item.boundary.boundarySetID != currentSetID {
                if !currentItems.isEmpty {
                    out.append(Group(setID: currentSetID, setName: currentName, items: currentItems))
                }
                currentSetID = item.boundary.boundarySetID
                currentName = item.setName
                currentItems = [item]
            } else {
                currentItems.append(item)
            }
        }
        if !currentItems.isEmpty {
            out.append(Group(setID: currentSetID, setName: currentName, items: currentItems))
        }
        return out
    }
}

private struct BoundaryPickerRow: View {
    let item: BoundaryWithSet
    let isChecked: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Toggle(
                item.boundary.name,
                isOn: Binding(
                    get: { isChecked },
                    set: { _ in onToggle() }
                )
            )
            .toggleStyle(.checkbox)
            .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Selected boundaries chip strip

struct SelectedBoundariesStrip: View {
    let boundaries: [BoundaryWithSet]
    let onRemove: (Int64) -> Void
    let onSetColor: (Int64, BoundaryColor) -> Void
    let onAddTapped: () -> Void
    let addButtonLabel: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(boundaries) { item in
                    SelectedBoundaryChip(
                        item: item,
                        onRemove: { onRemove(item.id) },
                        onSetColor: { onSetColor(item.id, $0) }
                    )
                }

                Button(action: onAddTapped) {
                    Label(addButtonLabel, systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        }
    }
}

private struct SelectedBoundaryChip: View {
    let item: BoundaryWithSet
    let onRemove: () -> Void
    let onSetColor: (BoundaryColor) -> Void

    @State private var isColorPopoverPresented = false

    var body: some View {
        HStack(spacing: 4) {
            BoundaryColorCircle(color: item.boundary.color)
            Text(item.boundary.name)
                .font(.caption)
                .lineLimit(1)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.15))
        )
        .overlay {
            RightClickCatcher {
                isColorPopoverPresented = true
            }
        }
        .popover(isPresented: $isColorPopoverPresented, arrowEdge: .bottom) {
            BoundaryColorPickerPopoverView(
                currentColor: item.boundary.color,
                onSelect: onSetColor
            )
        }
    }
}
