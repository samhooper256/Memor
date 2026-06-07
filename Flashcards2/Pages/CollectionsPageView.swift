//
//  CollectionsPageView.swift
//  Memor
//
//  Collections page: list/detail views, row, and key commands for multi-select removal.
//

import AppKit
import SwiftUI

struct CollectionsPageView: View {
    @EnvironmentObject private var instanceSearchWindowState: InstanceSearchWindowState
    @EnvironmentObject private var navigationState: AppNavigationState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings

    let appDatabase: AppDatabase

    @FocusState private var isCollectionNameFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @State private var selectedCollection: Collection?
    @State private var collections: [Collection] = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isAddCollectionSheetPresented = false
    @State private var newCollectionName = ""
    @State private var collectionPendingDeletion: Collection?

    private var titleText: String {
        let count = collections.count
        let noun = count == 1 ? "Collection" : "Collections"
        return "\(count) \(noun)"
    }

    private var filteredCollections: [Collection] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return collections }
        return collections.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Group {
            if let selectedCollection {
                CollectionDetailPageView(
                    collection: selectedCollection,
                    appDatabase: appDatabase,
                    onBack: { self.selectedCollection = nil }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(titleText)
                            .font(.largeTitle)
                            .fontWeight(.semibold)

                        HStack(spacing: 12) {
                            Button("Add Collection") {
                                newCollectionName = ""
                                isAddCollectionSheetPresented = true
                            }
                            .buttonStyle(.borderedProminent)

                            TextField("Search collections", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .focused($isSearchFocused)
                                .frame(maxWidth: .infinity)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        } else if collections.isEmpty {
                            Text("You have no collections.")
                                .foregroundStyle(.secondary)
                        } else if filteredCollections.isEmpty {
                            Text("No collections match your search.")
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(filteredCollections) { collection in
                                    CollectionRowView(
                                        collection: collection,
                                        onOpen: {
                                            selectedCollection = collection
                                        },
                                        onDelete: {
                                            collectionPendingDeletion = collection
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background {
                    FindShortcutKeyHandler(shortcutSettings: shortcutSettings) {
                        isSearchFocused = true
                    }
                }
            }
        }
        .task(id: selectedCollection?.id) {
            guard selectedCollection == nil else { return }
            await loadCollections()
        }
        .onChange(of: navigationState.resetToHomeNonce) { _, _ in
            selectedCollection = nil
        }
        .onChange(of: instanceSearchWindowState.latestCollectionsDataChange) { _, _ in
            guard selectedCollection == nil else { return }
            Task {
                await loadCollections()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memorDidChangeDatabase)) { _ in
            guard selectedCollection == nil else { return }
            Task { await loadCollections() }
        }
        .sheet(isPresented: $isAddCollectionSheetPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Collection")
                    .font(.headline)

                TextField("Collection Name", text: $newCollectionName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isCollectionNameFocused)
                    .onSubmit {
                        Task {
                            await addCollection()
                        }
                    }

                HStack {
                    Spacer()

                    Button("Cancel") {
                        isAddCollectionSheetPresented = false
                    }

                    Button("Add") {
                        Task {
                            await addCollection()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 320)
            .onAppear {
                isCollectionNameFocused = true
            }
        }
        .alert(
            "Are you sure you want to delete \(collectionPendingDeletion?.name ?? "this collection")?",
            isPresented: Binding(
                get: { collectionPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        collectionPendingDeletion = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                collectionPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                guard let collectionPendingDeletion else { return }
                Task {
                    await deleteCollection(collectionPendingDeletion)
                }
            }
        } message: {
            Text("This action is irreversible.")
        }
    }

    @MainActor
    private func loadCollections() async {
        do {
            collections = try appDatabase.fetchCollections()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load collections."
        }
    }

    @MainActor
    private func addCollection() async {
        let trimmedCollectionName = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCollectionName.isEmpty else { return }

        do {
            _ = try appDatabase.createCollection(name: trimmedCollectionName)
            collections = try appDatabase.fetchCollections()
            errorMessage = nil
            isAddCollectionSheetPresented = false
        } catch {
            errorMessage = "Failed to add collection."
        }
    }

    @MainActor
    private func deleteCollection(_ collection: Collection) async {
        do {
            try appDatabase.deleteCollection(id: collection.id)
            collections.removeAll { $0.id == collection.id }
            errorMessage = nil
            collectionPendingDeletion = nil
        } catch {
            errorMessage = "Failed to delete collection."
        }
    }
}

private struct CollectionDetailPageView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var instanceSearchWindowState: InstanceSearchWindowState
    @EnvironmentObject private var editInstanceWindowState: EditInstanceWindowState

    let collection: Collection
    let appDatabase: AppDatabase
    let onBack: () -> Void

    @State private var instances: [CollectionInstanceSummary] = []
    @State private var selectedInstanceIDs = Set<Int64>()
    @State private var errorMessage: String?
    @State private var description: String = ""
    @State private var descriptionSaveTask: Task<Void, Never>?
    @State private var visibleBeforeAnswer: Bool = true
    @State private var isRenamePopoverPresented = false
    @State private var renamedCollectionName: String = ""
    @State private var displayedName: String
    @State private var isIDCopyButtonHovered = false
    @State private var pendingRemovalInstanceIDs: [Int64] = []
    @State private var isRemovalConfirmationPresented = false
    @FocusState private var isRenameFieldFocused: Bool

    init(collection: Collection, appDatabase: AppDatabase, onBack: @escaping () -> Void) {
        self.collection = collection
        self.appDatabase = appDatabase
        self.onBack = onBack
        self._displayedName = State(initialValue: collection.name)
    }

    private var instanceCountText: String {
        let count = instances.count
        let noun = count == 1 ? "instance" : "instances"
        return "\(count) \(noun)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: onBack) {
                    Label(AppTab.collections.title, systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(displayedName)
                        .font(.largeTitle)
                        .fontWeight(.semibold)

                    Button {
                        renamedCollectionName = displayedName
                        isRenamePopoverPresented = true
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isRenamePopoverPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Edit Collection Name")
                                .font(.headline)

                            TextField("Collection Name", text: $renamedCollectionName)
                                .textFieldStyle(.roundedBorder)
                                .focused($isRenameFieldFocused)
                                .onSubmit {
                                    renameCollection()
                                }

                            HStack {
                                Spacer()

                                Button("Cancel") {
                                    isRenamePopoverPresented = false
                                }

                                Button("Save") {
                                    renameCollection()
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(renamedCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(16)
                        .frame(width: 280)
                        .onAppear {
                            DispatchQueue.main.async {
                                isRenameFieldFocused = true
                            }
                        }
                    }

                    Text(instanceCountText)
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text("ID: \(collection.id)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(String(collection.id), forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isIDCopyButtonHovered ? Color.secondary.opacity(0.18) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Copy ID")
                    .onHover { hovering in
                        isIDCopyButtonHovered = hovering
                    }
                }
                .frame(maxWidth: .infinity)

                ZStack(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Description")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                    PlainTextEditor(text: $description)
                        .frame(minHeight: 60)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                }
                .onChange(of: description) { _, newValue in
                    descriptionSaveTask?.cancel()
                    descriptionSaveTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                        try? appDatabase.updateCollectionDescription(id: collection.id, description: newValue)
                    }
                }

                Toggle("Visible before answer is revealed", isOn: $visibleBeforeAnswer)
                    .onChange(of: visibleBeforeAnswer) { _, newValue in
                        try? appDatabase.updateCollectionVisibleBeforeAnswer(id: collection.id, visibleBeforeAnswer: newValue)
                    }

                Button("Add Instances") {
                    instanceSearchWindowState.requestOpenForCollection(collection)
                    openWindow(id: "instance-search")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if instances.isEmpty {
                Text("This collection has no instances.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Table(instances, selection: $selectedInstanceIDs) {
                    TableColumn("Instance") { instance in
                        Text(formatFieldDisplayValue(instance.displayValue))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contextMenu(forSelectionType: Int64.self) { items in
                    if !items.isEmpty {
                        Button("Remove from Collection", role: .destructive) {
                            promptToRemoveInstances(items)
                        }
                    }
                } primaryAction: { selectedIDs in
                    guard let instanceID = selectedIDs.first else { return }
                    editInstanceWindowState.requestOpen(instanceID: instanceID)
                    openWindow(id: "edit-instance")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            CollectionDetailKeyCommandHandler(
                hasSelection: !selectedInstanceIDs.isEmpty,
                onDelete: { promptToRemoveInstances(selectedInstanceIDs) },
                onEscape: onBack
            )
        }
        .alert(
            removalConfirmationTitle,
            isPresented: $isRemovalConfirmationPresented
        ) {
            Button("Remove", role: .destructive) {
                confirmPendingRemoval()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the instance from this collection. The instance itself is not deleted.")
        }
        .onExitCommand(perform: onBack)
        .task {
            description = collection.description
            visibleBeforeAnswer = collection.visibleBeforeAnswer
            await loadInstances()
        }
        .onChange(of: instanceSearchWindowState.latestCollectionMembershipChange) { _, change in
            guard change?.collectionID == collection.id else { return }
            Task {
                await loadInstances()
            }
        }
        .onChange(of: instanceSearchWindowState.latestCollectionsDataChange) { _, _ in
            Task {
                await loadInstances()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memorDidChangeDatabase)) { _ in
            Task { await loadInstances() }
        }
    }

    @MainActor
    private func loadInstances() async {
        do {
            instances = try appDatabase.fetchCollectionInstances(collectionID: collection.id)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load instances."
        }
    }

    private func renameCollection() {
        let trimmed = renamedCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try appDatabase.renameCollection(id: collection.id, to: trimmed)
            displayedName = trimmed
            isRenamePopoverPresented = false
        } catch {
            // silently fail
        }
    }

    private var removalConfirmationTitle: String {
        let count = pendingRemovalInstanceIDs.count
        if count == 1 {
            return "Remove this instance from the collection?"
        } else {
            return "Remove these \(count) instances from the collection?"
        }
    }

    private func promptToRemoveInstances(_ instanceIDs: Set<Int64>) {
        guard !instanceIDs.isEmpty else { return }
        pendingRemovalInstanceIDs = Array(instanceIDs)
        isRemovalConfirmationPresented = true
    }

    private func confirmPendingRemoval() {
        let idsToRemove = Set(pendingRemovalInstanceIDs)
        pendingRemovalInstanceIDs = []
        isRemovalConfirmationPresented = false
        guard !idsToRemove.isEmpty else { return }
        for instanceID in idsToRemove {
            try? appDatabase.removeInstance(instanceID, fromCollectionID: collection.id)
        }
        instances.removeAll { idsToRemove.contains($0.id) }
        selectedInstanceIDs.subtract(idsToRemove)
    }
}

private struct CollectionDetailKeyCommandHandler: NSViewRepresentable {
    let hasSelection: Bool
    let onDelete: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.hasSelection = hasSelection
        view.onDelete = onDelete
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.hasSelection = hasSelection
        nsView.onDelete = onDelete
        nsView.onEscape = onEscape
    }

    final class KeyView: NSView {
        var hasSelection = false
        var onDelete: (() -> Void)?
        var onEscape: (() -> Void)?

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                if flags.isEmpty && (event.keyCode == 51 || event.keyCode == 117) && self.hasSelection {
                    self.onDelete?()
                    return nil
                }

                if event.keyCode == 53 {
                    self.onEscape?()
                    return nil
                }

                return event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

private struct CollectionRowView: View {
    let collection: Collection
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isEditButtonHovered = false
    @State private var isDeleteButtonHovered = false
    @State private var isCopyButtonHovered = false

    private var instanceCountText: String {
        let count = collection.instanceCount
        let noun = count == 1 ? "instance" : "instances"
        return "\(count) \(noun)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(collection.name)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text(instanceCountText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !collection.description.isEmpty {
                    Text(collection.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                Button(action: onOpen) {
                    Image(systemName: "pencil")
                        .foregroundStyle(.blue)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isEditButtonHovered ? Color.blue.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isEditButtonHovered = hovering
                }

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
                .onHover { hovering in
                    isDeleteButtonHovered = hovering
                }

                Text("ID: \(collection.id)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.leading, 6)

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(String(collection.id), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isCopyButtonHovered ? Color.secondary.opacity(0.18) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Copy ID")
                .padding(.leading, 4)
                .onHover { hovering in
                    isCopyButtonHovered = hovering
                }
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
    }
}
