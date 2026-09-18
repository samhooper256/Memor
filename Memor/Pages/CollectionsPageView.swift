//
//  CollectionsPageView.swift
//  Memor
//
//  Collections page: list/detail views, row, and key commands for multi-select removal.
//

import AppKit
import SwiftUI

/// Sort order for the Collections list page. Persisted across launches in
/// UserDefaults (`userDefaultsKey`); A–Z is the default.
enum CollectionSortOrder: String, CaseIterable, Identifiable {
    case nameAscending
    case nameDescending
    case largestFirst
    case smallestFirst

    static let userDefaultsKey = "com.sam.Memor.collectionsSortOrder"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nameAscending: "A–Z"
        case .nameDescending: "Z–A"
        case .largestFirst: "Largest first"
        case .smallestFirst: "Smallest first"
        }
    }

    /// Sorts `collections` in this order. Size orders break ties by name A–Z
    /// and name orders break ties by id, so the result is stable across
    /// refreshes.
    func sorted(_ collections: [Collection]) -> [Collection] {
        collections.sorted { lhs, rhs in
            switch self {
            case .nameAscending:
                return Self.compareNames(lhs, rhs) == .orderedAscending
            case .nameDescending:
                return Self.compareNames(lhs, rhs) == .orderedDescending
            case .largestFirst:
                if lhs.instanceCount != rhs.instanceCount {
                    return lhs.instanceCount > rhs.instanceCount
                }
                return Self.compareNames(lhs, rhs) == .orderedAscending
            case .smallestFirst:
                if lhs.instanceCount != rhs.instanceCount {
                    return lhs.instanceCount < rhs.instanceCount
                }
                return Self.compareNames(lhs, rhs) == .orderedAscending
            }
        }
    }

    private static func compareNames(_ lhs: Collection, _ rhs: Collection) -> ComparisonResult {
        let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        guard byName == .orderedSame else { return byName }
        if lhs.id == rhs.id { return .orderedSame }
        return lhs.id < rhs.id ? .orderedAscending : .orderedDescending
    }
}

struct CollectionsPageView: View {
    @EnvironmentObject private var searchWindowState: SearchWindowState
    @EnvironmentObject private var navigationState: AppNavigationState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings

    let appDatabase: AppDatabase

    @FocusState private var isCollectionNameFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @State private var selectedCollection: Collection?
    @State private var collections: [Collection] = []
    @State private var highlightedCollectionID: Int64?
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isAddCollectionSheetPresented = false
    @State private var newCollectionName = ""
    @State private var collectionPendingDeletion: Collection?
    @AppStorage(CollectionSortOrder.userDefaultsKey) private var sortOrder: CollectionSortOrder = .nameAscending

    private var titleText: String {
        let count = collections.count
        let noun = count == 1 ? "Collection" : "Collections"
        return "\(count) \(noun)"
    }

    // The rows shown on the list page: the search filter applied, then the
    // chosen sort order.
    private var filteredCollections: [Collection] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = trimmed.isEmpty
            ? collections
            : collections.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        return sortOrder.sorted(matching)
    }

    // The keyboard-selected ("currently selected") collection on the list page.
    private var highlightedCollection: Collection? {
        filteredCollections.first { $0.id == highlightedCollectionID }
    }

    // Moves the keyboard selection up (-1) or down (+1) through
    // filteredCollections, clamped at both ends (no wraparound).
    private func moveHighlight(by delta: Int) {
        guard !filteredCollections.isEmpty else { return }
        let current = filteredCollections.firstIndex { $0.id == highlightedCollectionID } ?? 0
        let next = min(max(current + delta, 0), filteredCollections.count - 1)
        highlightedCollectionID = filteredCollections[next].id
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
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Text(titleText)
                                .font(.largeTitle)
                                .fontWeight(.semibold)

                            HelpWindowButton(windowID: "collections-help", tooltip: "Learn what collections are")
                        }

                        HStack(spacing: 12) {
                            Button("Add Collection") {
                                newCollectionName = ""
                                isAddCollectionSheetPresented = true
                            }
                            .buttonStyle(.borderedProminent)

                            TextField("Search collections (⌘F)", text: $searchText)
                                .solidFocusField()
                                .focused($isSearchFocused)
                                .frame(maxWidth: .infinity)

                            Picker("Sort:", selection: $sortOrder) {
                                ForEach(CollectionSortOrder.allCases) { order in
                                    Text(order.displayName).tag(order)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
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
                                        isHighlighted: collection.id == highlightedCollectionID,
                                        onOpen: {
                                            selectedCollection = collection
                                        },
                                        onDelete: {
                                            collectionPendingDeletion = collection
                                        }
                                    )
                                    .id(collection.id)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: highlightedCollectionID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .background {
                    FindShortcutKeyHandler(shortcutSettings: shortcutSettings) {
                        isSearchFocused = true
                    }
                }
                .background {
                    ListKeyNavigationHandler(
                        isEnabled: !isAddCollectionSheetPresented && collectionPendingDeletion == nil,
                        onMoveUp: { moveHighlight(by: -1) },
                        onMoveDown: { moveHighlight(by: 1) },
                        onOpen: {
                            if let collection = highlightedCollection {
                                selectedCollection = collection
                            }
                        }
                    )
                }
                }
            }
        }
        .task(id: selectedCollection?.id) {
            guard selectedCollection == nil else { return }
            await loadCollections()
            // When the list page is shown (tab switch or back-from-detail):
            // select the first collection and focus the search box. The focus
            // set is deferred: arriving from a tab whose own search field was
            // focused, that field's teardown lands after this task starts and
            // swallows an immediate focus set.
            if selectedCollection == nil {
                highlightedCollectionID = filteredCollections.first?.id
                try? await Task.sleep(for: .milliseconds(50))
                isSearchFocused = true
            }
        }
        .onChange(of: searchText) { _, _ in
            // Keep the selection on the top match as filtering changes.
            highlightedCollectionID = filteredCollections.first?.id
        }
        .onChange(of: sortOrder) { _, _ in
            // A re-sort reshuffles the rows, so restart the keyboard selection
            // at the top like a filter change does.
            highlightedCollectionID = filteredCollections.first?.id
        }
        .onChange(of: navigationState.resetToHomeNonce) { _, _ in
            selectedCollection = nil
        }
        .onChange(of: searchWindowState.latestCollectionsDataChange) { _, _ in
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
                    .solidFocusField()
                    .focused($isCollectionNameFocused)
                    .onSubmit {
                        Task {
                            await addCollection()
                        }
                    }

                if AppDatabase.nameStartsWithDigit(newCollectionName) {
                    Text("A collection name cannot start with a digit.")
                        .font(.caption)
                        .foregroundStyle(.red)
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
                    .disabled(
                        newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || AppDatabase.nameStartsWithDigit(newCollectionName)
                    )
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
        if AppDatabase.nameStartsWithDigit(trimmedCollectionName) {
            errorMessage = "A collection name cannot start with a digit."
            return
        }

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
    @EnvironmentObject private var searchWindowState: SearchWindowState
    @EnvironmentObject private var editInstanceWindowState: EditInstanceWindowState
    @EnvironmentObject private var addInstanceWindowState: AddInstanceWindowState

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
    @State private var pendingDeletionInstanceIDs: [Int64] = []
    @State private var isDeletionConfirmationPresented = false
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
                                .solidFocusField()
                                .focused($isRenameFieldFocused)
                                .onSubmit {
                                    renameCollection()
                                }

                            if AppDatabase.nameStartsWithDigit(renamedCollectionName) {
                                Text("A collection name cannot start with a digit.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
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
                                .disabled(
                                    renamedCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        || AppDatabase.nameStartsWithDigit(renamedCollectionName)
                                )
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

                DescriptionEditor(text: $description, onBeginEditing: {
                    // Deselect instance rows so the window's delete-key monitor
                    // doesn't remove an instance while editing the description.
                    selectedInstanceIDs.removeAll()
                })
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
                    searchWindowState.requestOpenForCollection(collection)
                    openWindow(id: "search")
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
                    if items.count == 1, let instanceID = items.first {
                        Button("Duplicate") {
                            addInstanceWindowState.requestOpenForDuplication(sourceInstanceID: instanceID)
                            openWindow(id: "add-instance")
                        }
                    }
                    if !items.isEmpty {
                        Button("Remove from Collection", role: .destructive) {
                            promptToRemoveInstances(items)
                        }
                        Button("Delete", role: .destructive) {
                            promptToDeleteInstances(items)
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
        .alert(
            deletionConfirmationTitle,
            isPresented: $isDeletionConfirmationPresented
        ) {
            Button("Delete", role: .destructive) {
                confirmPendingDeletion()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the instance from the database. This action is irreversible.")
        }
        .onExitCommand(perform: onBack)
        .task {
            description = collection.description
            visibleBeforeAnswer = collection.visibleBeforeAnswer
            await loadInstances()
        }
        .onChange(of: searchWindowState.latestCollectionMembershipChange) { _, change in
            guard change?.collectionID == collection.id else { return }
            Task {
                await loadInstances()
            }
        }
        .onChange(of: searchWindowState.latestCollectionsDataChange) { _, _ in
            Task {
                await loadInstances()
            }
        }
        .onChange(of: addInstanceWindowState.latestAddNonce) { _, _ in
            Task { await loadInstances() }
        }
        .onChange(of: editInstanceWindowState.latestSaveNonce) { _, _ in
            Task { await loadInstances() }
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
        guard !AppDatabase.nameStartsWithDigit(trimmed) else { return }
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

    private var deletionConfirmationTitle: String {
        let count = pendingDeletionInstanceIDs.count
        if count == 1 {
            return "Are you sure you want to delete this instance?"
        } else {
            return "Are you sure you want to delete these \(count) instances?"
        }
    }

    private func promptToDeleteInstances(_ instanceIDs: Set<Int64>) {
        guard !instanceIDs.isEmpty else { return }
        pendingDeletionInstanceIDs = Array(instanceIDs)
        isDeletionConfirmationPresented = true
    }

    private func confirmPendingDeletion() {
        let idsToDelete = Set(pendingDeletionInstanceIDs)
        pendingDeletionInstanceIDs = []
        isDeletionConfirmationPresented = false
        guard !idsToDelete.isEmpty else { return }
        for instanceID in idsToDelete {
            try? appDatabase.deleteInstance(instanceID: instanceID)
        }
        instances.removeAll { idsToDelete.contains($0.id) }
        selectedInstanceIDs.subtract(idsToDelete)
        // A hard delete affects other views (Instances tab, Stacks counts), so
        // tell them to refresh.
        NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
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

                if flags.isEmpty && (event.keyCode == 51 || event.keyCode == 117)
                    && self.hasSelection && !self.isEditingText {
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

        /// True when a text view (the description box, search field, or rename
        /// popover) is editing, so Delete should reach it instead of removing an
        /// instance. NSTextField editing routes through the window's field editor,
        /// which is itself an NSTextView, so this one check covers all of them.
        private var isEditingText: Bool {
            window?.firstResponder is NSTextView
        }
    }
}

private struct CollectionRowView: View {
    let collection: Collection
    let isHighlighted: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
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

                DescriptionDisplay(collection.description)
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
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
        .pointerStyle(isHovered ? .link : .default)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isHighlighted ? Color.blue : Color.secondary.opacity(0.15),
                    lineWidth: isHighlighted ? 2 : 1
                )
        }
        .onTapGesture {
            isHovered = false
            onOpen()
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
