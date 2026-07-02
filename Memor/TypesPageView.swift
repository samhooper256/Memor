//
//  TypesPageView.swift
//  Memor
//
//  Created by Codex on 4/1/26.
//

import AppKit
import GRDB
import SwiftUI
import WebKit
import WebKit

struct TypesPageView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var navigationState: AppNavigationState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    let appDatabase: AppDatabase

    @State private var selectedType: FlashcardType?
    @State private var autoRenameTypeID: Int64?
    @State private var types: [FlashcardType] = []
    @State private var highlightedTypeID: Int64?
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var typePendingDeletion: FlashcardType?

    @State private var isAddTypePopoverPresented = false
    @State private var newTypeName = ""
    @State private var addTypeError: String?
    @FocusState private var isNewTypeNameFocused: Bool
    @FocusState private var isSearchFocused: Bool

    private var filteredTypes: [FlashcardType] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return types }
        return types.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    // The keyboard-selected ("currently selected") type on the list page.
    private var highlightedType: FlashcardType? {
        filteredTypes.first { $0.id == highlightedTypeID }
    }

    // Moves the keyboard selection up (-1) or down (+1) through filteredTypes,
    // clamped at both ends (no wraparound).
    private func moveHighlight(by delta: Int) {
        guard !filteredTypes.isEmpty else { return }
        let current = filteredTypes.firstIndex { $0.id == highlightedTypeID } ?? 0
        let next = min(max(current + delta, 0), filteredTypes.count - 1)
        highlightedTypeID = filteredTypes[next].id
    }

    var body: some View {
        Group {
            if let selectedType {
                TypeDetailPageView(
                    type: selectedType,
                    appDatabase: appDatabase,
                    shouldAutoPresentRenamePopover: autoRenameTypeID == selectedType.id,
                    onAutoRenamePopoverPresented: {
                        autoRenameTypeID = nil
                    },
                    onBack: { self.selectedType = nil }
                )
            } else {
                typesListPage
            }
        }
        .task(id: selectedType?.id) {
            guard selectedType == nil else { return }
            await loadTypes()
            if let typeID = navigationState.requestedTypeDetailID,
               let type = types.first(where: { $0.id == typeID }) {
                navigationState.requestedTypeDetailID = nil
                selectedType = type
            }
            // When the list page is shown (tab switch or back-from-detail):
            // select the first type and focus the search box.
            if selectedType == nil {
                highlightedTypeID = filteredTypes.first?.id
                isSearchFocused = true
            }
        }
        .onChange(of: searchText) { _, _ in
            // Keep the selection on the top match as filtering changes.
            highlightedTypeID = filteredTypes.first?.id
        }
        .onChange(of: navigationState.resetToHomeNonce) { _, _ in
            selectedType = nil
        }
        .onChange(of: navigationState.requestedTypeDetailID) { _, typeID in
            guard let typeID else { return }
            navigationState.requestedTypeDetailID = nil
            if let type = types.first(where: { $0.id == typeID }) {
                selectedType = type
            } else {
                Task {
                    await loadTypes()
                    if let type = types.first(where: { $0.id == typeID }) {
                        selectedType = type
                    }
                }
            }
        }
        .alert(
            "Are you sure you want to delete this type?",
            isPresented: Binding(
                get: { typePendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        typePendingDeletion = nil
                    }
                }
            ),
            presenting: typePendingDeletion
        ) { type in
            Button("Delete", role: .destructive) {
                Task {
                    await deleteType(type)
                }
            }
            Button("Cancel", role: .cancel) {
                typePendingDeletion = nil
            }
        } message: { _ in
            Text("This action is irreversible. All instances of this type will be deleted.")
        }
    }

    private var typesListPage: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(AppTab.types.title)
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                HStack(spacing: 12) {
                    Button("Edit Global HTML") {
                        openWindow(id: "global-html-editor")
                    }
                    .buttonStyle(.bordered)

                    Button("Edit Global CSS") {
                        openWindow(id: "global-css-editor")
                    }
                    .buttonStyle(.bordered)

                    TextField("Search types", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .frame(maxWidth: .infinity)
                }

                Button("Add Type") {
                    newTypeName = ""
                    addTypeError = nil
                    isAddTypePopoverPresented = true
                }
                .buttonStyle(.borderedProminent)
                .popover(isPresented: $isAddTypePopoverPresented, arrowEdge: .bottom) {
                    addTypePopover
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else if filteredTypes.isEmpty && !types.isEmpty {
                    Text("No types match your search.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredTypes) { type in
                            TypeRowView(
                                type: type,
                                isHighlighted: type.id == highlightedTypeID,
                                onOpen: {
                                    selectedType = type
                                },
                                onDelete: {
                                    typePendingDeletion = type
                                }
                            )
                            .id(type.id)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: highlightedTypeID) { _, id in
            guard let id else { return }
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
        .background {
            FindShortcutKeyHandler(shortcutSettings: shortcutSettings) {
                isSearchFocused = true
            }
        }
        .background {
            TypesListKeyNavigationHandler(
                isEnabled: !isAddTypePopoverPresented && typePendingDeletion == nil,
                onMoveUp: { moveHighlight(by: -1) },
                onMoveDown: { moveHighlight(by: 1) },
                onOpen: {
                    if let type = highlightedType, !type.isBuiltin {
                        selectedType = type
                    }
                }
            )
        }
        }
    }

    private var addTypePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Type")
                .font(.headline)

            TextField("Type Name", text: $newTypeName)
                .textFieldStyle(.roundedBorder)
                .focused($isNewTypeNameFocused)
                .onSubmit {
                    Task { await addType() }
                }

            if let addTypeError {
                Text(addTypeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isAddTypePopoverPresented = false
                }
                Button("Create") {
                    Task { await addType() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            isNewTypeNameFocused = true
        }
    }

    @MainActor
    private func loadTypes() async {
        do {
            types = try appDatabase.fetchTypes()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load types."
        }
    }

    @MainActor
    private func addType() async {
        let trimmedName = newTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        do {
            let newType = try appDatabase.createType(name: trimmedName)
            types = try appDatabase.fetchTypes()
            isAddTypePopoverPresented = false
            selectedType = newType
            errorMessage = nil
        } catch {
            addTypeError = (error as? DatabaseError)?.message ?? "Failed to add type."
        }
    }

    @MainActor
    private func deleteType(_ type: FlashcardType) async {
        do {
            try appDatabase.deleteType(typeID: type.id)
            types = try appDatabase.fetchTypes()
            typePendingDeletion = nil
            errorMessage = nil
        } catch {
            errorMessage = "Failed to delete type."
        }
    }
}

extension FlashcardType {
    var isMapType: Bool {
        isBuiltin && (name == POINTMAP_TYPE_NAME || name == BOUNDARYMAP_TYPE_NAME)
    }

    // SF Symbol + color indicating the type's kind. Shared by the Types tab and
    // the Instances tab sidebar.
    var kindIcon: (name: String, color: Color) {
        if isMapType {
            return ("map.fill", .yellow)
        } else {
            return ("doc.text.fill", .blue)
        }
    }
}

private struct TypeRowView: View {
    let type: FlashcardType
    let isHighlighted: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isDeleteButtonHovered = false

    private var instanceCountText: String {
        let noun = type.instanceCount == 1 ? "instance" : "instances"
        return "\(type.instanceCount) \(noun)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: type.kindIcon.name)
                .foregroundStyle(type.kindIcon.color)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(type.name)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    if type.isBuiltin {
                        Text("(built-in)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text(instanceCountText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                DescriptionDisplay(type.description)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .pointerStyle(isHovered && !type.isBuiltin ? .link : .default)
        .overlay {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isHighlighted ? Color.blue : Color.secondary.opacity(0.15),
                        lineWidth: isHighlighted ? 2 : 1
                    )

                if isHovered && !type.isBuiltin {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isDeleteButtonHovered ? Color.red.opacity(0.14) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .onHover { hovering in
                        isDeleteButtonHovered = hovering
                    }
                }
            }
        }
        .onTapGesture {
            guard !type.isBuiltin else { return }
            isHovered = false
            onOpen()
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
                isDeleteButtonHovered = false
            }
        }
    }
}

