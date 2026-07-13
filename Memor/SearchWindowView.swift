//
//  SearchWindowView.swift
//  Memor
//
//  The unified "Search" window: one window with three switchable modes —
//  Instances, Queries, and Points & Boundaries — mirroring the ⌘K hyperlink
//  popup's mode switcher (Shift+Tab to cycle).
//

import AppKit
import Combine
import SwiftUI

enum SearchMode: Hashable, CaseIterable {
    case instances
    case queries
    case pointsAndBoundaries

    var next: SearchMode {
        switch self {
        case .instances: return .queries
        case .queries: return .pointsAndBoundaries
        case .pointsAndBoundaries: return .instances
        }
    }
}

@MainActor
final class SearchWindowState: ObservableObject {
    @Published private(set) var requestNonce = UUID()
    // Persists across window open/close (this object lives for the app's
    // lifetime as a @StateObject), but resets to .instances on relaunch.
    @Published var mode: SearchMode = .instances
    @Published private(set) var addToCollection: Collection?
    @Published private(set) var requestedSearchText: String?
    @Published var persistedSearchText: String = ""

    @Published private(set) var latestCollectionMembershipChange: CollectionInstanceMembershipChange?
    @Published private(set) var latestCollectionsDataChange = UUID()
    @Published private(set) var latestStacksDataChange = UUID()

    /// Opens the window preserving the last-used mode (⌘⇧S).
    func requestOpen() {
        addToCollection = nil
        requestedSearchText = nil
        requestNonce = UUID()
    }

    /// Opens the window forced to Queries mode, preserving the persisted text.
    func requestOpenQueries() {
        addToCollection = nil
        mode = .queries
        requestedSearchText = nil
        requestNonce = UUID()
    }

    /// Opens the window forced to Queries mode with the given text (⌘⌥S with an
    /// active study stack, Stacks row "Search").
    func requestOpen(searchText: String) {
        addToCollection = nil
        mode = .queries
        requestedSearchText = searchText
        requestNonce = UUID()
    }

    /// Opens the window forced to Instances mode in add-to-collection mode.
    func requestOpenForCollection(_ collection: Collection) {
        addToCollection = collection
        mode = .instances
        requestedSearchText = nil
        requestNonce = UUID()
    }

    func notifyCollectionMembershipChange(collectionID: Int64) {
        latestCollectionMembershipChange = CollectionInstanceMembershipChange(
            collectionID: collectionID,
            nonce: UUID()
        )
        latestCollectionsDataChange = UUID()
    }

    func notifyCollectionsDataChange() {
        latestCollectionsDataChange = UUID()
    }

    func notifyStacksDataChange() {
        latestStacksDataChange = UUID()
    }
}

struct SearchWindowView: View {
    @EnvironmentObject private var windowState: SearchWindowState
    @EnvironmentObject private var editInstanceWindowState: EditInstanceWindowState
    @EnvironmentObject private var addInstanceWindowState: AddInstanceWindowState
    @EnvironmentObject private var queryPreviewWindowState: QueryPreviewWindowState
    @EnvironmentObject private var stacksPageState: StacksPageState
    @EnvironmentObject private var quickStudyState: QuickStudyState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    @EnvironmentObject private var changeTypeWindowState: ChangeTypeWindowState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let appDatabase: AppDatabase

    @FocusState private var isStackNameFocused: Bool
    @FocusState private var resultsListFocused: Bool

    @State private var searchQuery = ""
    @State private var debouncedSearchQuery = ""
    @State private var errorMessage: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchFocusRequest = UUID()

    // Per-mode results.
    @State private var instanceSections: [InstanceSearchSection] = []
    @State private var querySections: [QuerySearchSection] = []
    @State private var mapElementSections: [MapElementSearchSection] = []

    // Selections.
    @State private var selectedInstanceIDs: Set<Int64> = []
    @State private var selectedQueryIDs: Set<String> = []
    @State private var selectedMapElementIDs: Set<String> = []

    // Instances mode: add-to-collection + deletion.
    @State private var instanceIDsInCollection: Set<Int64> = []
    @State private var pendingDeletionInstanceIDs: [Int64] = []
    @State private var isDeletionConfirmationPresented = false

    // Queries mode: stacks + reset/delete.
    @State private var isAddStackPopoverPresented = false
    @State private var newStackName = ""
    @State private var isResetDueDatesConfirmationPresented = false
    @State private var isDeleteQueriesConfirmationPresented = false
    @State private var queryIDsPendingReset: Set<String> = []
    @State private var queryIDsPendingDelete: Set<String> = []

    private var collectionInAddMode: Collection? { windowState.addToCollection }

    private var resultsCount: Int {
        switch windowState.mode {
        case .instances: return instanceSections.reduce(0) { $0 + $1.instances.count }
        case .queries: return querySections.reduce(0) { $0 + $1.queries.count }
        case .pointsAndBoundaries: return mapElementSections.reduce(0) { $0 + $1.elements.count }
        }
    }

    private var selectedCount: Int {
        switch windowState.mode {
        case .instances: return selectedInstanceIDs.count
        case .queries: return selectedQueryIDs.count
        case .pointsAndBoundaries: return selectedMapElementIDs.count
        }
    }

    private var resultsCountText: String {
        let noun = resultsCount == 1 ? "result" : "results"
        var text = "\(resultsCount) \(noun)"
        if selectedCount > 1 {
            text += " — \(selectedCount) selected"
        }
        return text
    }

    private var emptyStateText: String {
        switch windowState.mode {
        case .instances: return "No instances match the current search."
        case .queries: return "No queries match the current search."
        case .pointsAndBoundaries: return "No points or boundaries match the current search."
        }
    }

    private var helpWindowID: String {
        switch windowState.mode {
        case .instances: return "instance-search-help"
        case .queries: return "query-search-help"
        case .pointsAndBoundaries: return "map-element-search-help"
        }
    }

    private var deletionConfirmationTitle: String {
        let count = pendingDeletionInstanceIDs.count
        if count == 1 {
            return "Are you sure you want to delete this instance?"
        } else {
            return "Are you sure you want to delete these \(count) instances?"
        }
    }

    private var deletionConfirmationMessage: String {
        personDeletionConsequencesMessage(
            appDatabase: appDatabase,
            pendingInstanceIDs: pendingDeletionInstanceIDs
        )
    }

    private var resetDueDatesCount: Int {
        queryIDsPendingReset.isEmpty ? resultsCount : queryIDsPendingReset.count
    }

    private var duplicatableInstanceIDs: Set<Int64> {
        var result: Set<Int64> = []
        for section in instanceSections
        where section.typeName != POINTMAP_TYPE_NAME
            && section.typeName != BOUNDARYMAP_TYPE_NAME
            && section.typeName != PERSON_TYPE_NAME {
            for instance in section.instances {
                result.insert(instance.id)
            }
        }
        return result
    }

    // When every selected instance belongs to a single convertible type (not a
    // map, not Person — conversions never leave Person), returns that type plus
    // the selected ids; otherwise nil. Drives the "Change Type" context-menu item.
    private func convertibleSelection(_ items: Set<Int64>) -> (typeID: Int64, typeName: String, ids: [Int64])? {
        guard !items.isEmpty else { return nil }
        var matchingSections: [InstanceSearchSection] = []
        for section in instanceSections where section.instances.contains(where: { items.contains($0.id) }) {
            matchingSections.append(section)
        }
        guard matchingSections.count == 1, let section = matchingSections.first else { return nil }
        guard section.typeName != POINTMAP_TYPE_NAME,
              section.typeName != BOUNDARYMAP_TYPE_NAME,
              section.typeName != PERSON_TYPE_NAME else { return nil }
        let ids = section.instances.map(\.id).filter { items.contains($0) }
        return (section.typeID, section.typeName, ids)
    }

    // Instances reachable from the Queries results that can be duplicated — i.e.
    // not PointMap/BoundaryMap instances (whose editor doesn't support duplication).
    private var duplicatableQueryInstanceIDs: Set<Int64> {
        var result: Set<Int64> = []
        for section in querySections
        where section.typeName != POINTMAP_TYPE_NAME
            && section.typeName != BOUNDARYMAP_TYPE_NAME
            && section.typeName != PERSON_TYPE_NAME {
            for query in section.queries {
                result.insert(query.instanceID)
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            content

            if windowState.mode == .queries {
                Divider()
                queriesFooter
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(SearchWindowBacktabHandler { cycleMode() })
        .task {
            await resetAndFocusSearch()
        }
        .task(id: debouncedSearchQuery) {
            await runSearch(for: debouncedSearchQuery)
        }
        .onChange(of: searchQuery) { _, newValue in
            windowState.persistedSearchText = newValue
            scheduleDebouncedSearch(for: newValue)
        }
        .onChange(of: windowState.requestNonce) { _, _ in
            Task { await resetAndFocusSearch() }
        }
        .onChange(of: windowState.mode) { _, _ in
            clearSelections()
            Task { await runSearch(for: debouncedSearchQuery) }
        }
        .onChange(of: changeTypeWindowState.conversionNonce) { _, _ in
            Task { await runSearch(for: debouncedSearchQuery) }
        }
        .onChange(of: instanceSections) { _, newSections in
            let ids = Set(newSections.flatMap { $0.instances.map(\.id) })
            selectedInstanceIDs = selectedInstanceIDs.intersection(ids)
        }
        .onChange(of: querySections) { _, newSections in
            let ids = Set(newSections.flatMap { $0.queries.map(\.id) })
            selectedQueryIDs = selectedQueryIDs.intersection(ids)
        }
        .onChange(of: mapElementSections) { _, newSections in
            let ids = Set(newSections.flatMap { $0.elements.map(\.id) })
            selectedMapElementIDs = selectedMapElementIDs.intersection(ids)
        }
        .onChange(of: isAddStackPopoverPresented) { _, isPresented in
            if isPresented { selectedQueryIDs = [] }
        }
        .onDisappear {
            debounceTask?.cancel()
        }
        .onExitCommand {
            dismiss()
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
            Text(deletionConfirmationMessage)
        }
        .alert(
            "Are you sure you want to reset the due dates for \(resetDueDatesCount) \(resetDueDatesCount == 1 ? "query" : "queries")?",
            isPresented: $isResetDueDatesConfirmationPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset") {
                Task { await resetDueDates() }
            }
        } message: {
            Text("This action is irreversible.")
        }
        .alert(
            "Are you sure you want to delete \(queryIDsPendingDelete.count) \(queryIDsPendingDelete.count == 1 ? "query" : "queries")?",
            isPresented: $isDeleteQueriesConfirmationPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteQueries() }
            }
        } message: {
            Text("The selected queries will be disabled, but their associated instances will not be deleted. This action is irreversible.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if collectionInAddMode == nil {
                modeSwitcher
            }

            HStack(spacing: 8) {
                SearchQueryTextField(
                    searchFieldPlaceholder,
                    text: $searchQuery,
                    focusRequest: searchFocusRequest,
                    highlightsNoQueries: windowState.mode == .instances,
                    onFocusChange: { isFocused in
                        if isFocused { clearSelections() }
                    },
                    onBacktab: { cycleMode() },
                    onMoveDown: { moveFocusToResults() }
                )
                .searchCodeEditorStyle()

                SearchHelpButton(windowID: helpWindowID)
            }

            if let collection = collectionInAddMode {
                Text("Adding instances to \(collection.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(resultsCountText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.bar)
    }

    private var searchFieldPlaceholder: String {
        switch windowState.mode {
        case .instances: return "Search instances"
        case .queries: return "Search queries"
        case .pointsAndBoundaries: return "Search points & boundaries"
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 6) {
            Text("Searching:")
                .font(.caption)
                .foregroundStyle(.secondary)

            modeChip(label: "Instances", mode: .instances, color: .blue)
            modeChip(label: "Queries", mode: .queries, color: Color(nsColor: .magenta))
            modeChip(label: "Points & Boundaries", mode: .pointsAndBoundaries, color: .yellow)

            Text("(Shift+Tab)")
                .font(.caption)
                .foregroundStyle(.gray)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func modeChip(label: String, mode: SearchMode, color: Color) -> some View {
        let isSelected = windowState.mode == mode
        Button {
            guard windowState.mode != mode else { return }
            windowState.mode = mode
        } label: {
            Text(label)
                .font(.caption)
                .bold()
                .foregroundStyle(isSelected ? Color.white : color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? color : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
        } else if resultsCount == 0 {
            Text(emptyStateText)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
        } else {
            switch windowState.mode {
            case .instances: instancesList
            case .queries: queriesList
            case .pointsAndBoundaries: mapElementsList
            }
        }
    }

    private var instancesList: some View {
        List(selection: $selectedInstanceIDs) {
            // Identify sections by name (String), NOT by their Int64 typeID:
            // with a Set<Int64> selection, ⌘A (Select All) otherwise injects the
            // sections' Int64 ids into the selection, inflating the count with
            // phantom ids (any typeID not coinciding with a real instance id).
            ForEach(instanceSections, id: \.typeName) { section in
                Section(section.typeName) {
                    ForEach(section.instances) { instance in
                        InstanceSearchRowView(
                            instance: instance,
                            isSelectableForCollection: collectionInAddMode != nil,
                            isInCollection: instanceIDsInCollection.contains(instance.id),
                            onSelectionChange: { isSelected in
                                Task { await setMembership(isSelected, for: instance.id) }
                            }
                        )
                        .tag(instance.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($resultsListFocused)
        .contextMenu(forSelectionType: Int64.self) { items in
            if items.count == 1, let instanceID = items.first {
                Button("Edit") {
                    editInstanceWindowState.requestOpen(instanceID: instanceID)
                    openWindow(id: "edit-instance")
                }
            }
            if items.count == 1,
               let instanceID = items.first,
               duplicatableInstanceIDs.contains(instanceID) {
                Button("Duplicate") {
                    addInstanceWindowState.requestOpenForDuplication(sourceInstanceID: instanceID)
                    openWindow(id: "add-instance")
                }
            }
            if items.count == 1, let instanceID = items.first {
                Button("Copy ID") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("\(instanceID)", forType: .string)
                }
            }
            if let selection = convertibleSelection(items) {
                Button("Change Type") {
                    changeTypeWindowState.requestOpen(instanceIDs: selection.ids, sourceTypeID: selection.typeID)
                    openWindow(id: "change-type")
                }
            }
            if !items.isEmpty {
                Divider()
                Button("Delete", role: .destructive) {
                    promptToDeleteInstances(items)
                }
            }
        } primaryAction: { clickedIDs in
            guard let instanceID = clickedIDs.first else { return }
            editInstanceWindowState.requestOpen(instanceID: instanceID)
            openWindow(id: "edit-instance")
        }
        .onDeleteCommand {
            promptToDeleteInstances(selectedInstanceIDs)
        }
    }

    private var queriesList: some View {
        List(selection: $selectedQueryIDs) {
            ForEach(querySections) { section in
                Section(section.typeName) {
                    ForEach(section.queries) { query in
                        QuerySearchRowView(query: query)
                            .tag(query.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($resultsListFocused)
        .contextMenu(forSelectionType: String.self) { items in
            if items.count == 1,
               let queryID = items.first,
               let instanceIDPart = queryID.split(separator: ":").first,
               let instanceID = Int64(instanceIDPart) {
                let idParts = queryID.split(separator: ":")
                if idParts.count >= 2, let queryTypeID = Int64(idParts[1]) {
                    Button("Preview") {
                        queryPreviewWindowState.requestOpen(instanceID: instanceID, queryTypeID: queryTypeID)
                        openWindow(id: "query-preview")
                    }
                }
                Button("Edit Instance") {
                    editInstanceWindowState.requestOpen(instanceID: instanceID)
                    openWindow(id: "edit-instance")
                }
                if duplicatableQueryInstanceIDs.contains(instanceID) {
                    Button("Duplicate instance") {
                        addInstanceWindowState.requestOpenForDuplication(sourceInstanceID: instanceID)
                        openWindow(id: "add-instance")
                    }
                }
                Divider()
            }
            if !items.isEmpty {
                Button(items.count == 1 ? "Reset Due Date" : "Reset Due Dates") {
                    queryIDsPendingReset = items
                    isResetDueDatesConfirmationPresented = true
                }
                Button(items.count == 1 ? "Delete Query" : "Delete Queries", role: .destructive) {
                    queryIDsPendingDelete = items
                    isDeleteQueriesConfirmationPresented = true
                }
            }
        } primaryAction: { clickedIDs in
            guard let queryID = clickedIDs.first,
                  let instanceIDPart = queryID.split(separator: ":").first,
                  let instanceID = Int64(instanceIDPart) else { return }
            editInstanceWindowState.requestOpen(instanceID: instanceID)
            openWindow(id: "edit-instance")
        }
    }

    private var mapElementsList: some View {
        List(selection: $selectedMapElementIDs) {
            ForEach(mapElementSections) { section in
                Section(section.typeName) {
                    ForEach(section.elements) { element in
                        MapElementSearchRowView(element: element)
                            .tag(element.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($resultsListFocused)
        .contextMenu(forSelectionType: String.self) { _ in
            // No actions in Points & Boundaries mode.
        } primaryAction: { clickedIDs in
            guard let id = clickedIDs.first, let element = mapElement(forID: id) else { return }
            openMapElementEditor(element)
        }
    }

    private var queriesFooter: some View {
        HStack {
            Button {
                queryIDsPendingReset = selectedQueryIDs
                isResetDueDatesConfirmationPresented = true
            } label: {
                ShortcutLabel(title: "Reset Due Dates", action: .searchResetDueDates)
            }
            .buttonStyle(.bordered)
            .shortcut(.searchResetDueDates, settings: shortcutSettings)

            Spacer()

            Button("Quick Study this search") {
                quickStudyState.request(searchText: searchQuery)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .help("Study the queries in this search without making a new Stack.")

            Button("Add Stack with this search") {
                newStackName = ""
                isAddStackPopoverPresented = true
            }
            .buttonStyle(.borderedProminent)
            .popover(isPresented: $isAddStackPopoverPresented, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add Stack")
                        .font(.headline)

                    TextField("Stack Name", text: $newStackName)
                        .solidFocusField()
                        .focused($isStackNameFocused)
                        .onSubmit {
                            Task { await addStack() }
                        }

                    HStack {
                        Spacer()

                        Button("Cancel") {
                            isAddStackPopoverPresented = false
                        }

                        Button("Add") {
                            Task { await addStack() }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newStackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(16)
                .frame(width: 280)
                .onAppear {
                    DispatchQueue.main.async { isStackNameFocused = true }
                }
            }
        }
        .padding(24)
        .background(.bar)
    }

    // MARK: - Mode switching

    private func cycleMode() {
        guard collectionInAddMode == nil else { return }
        windowState.mode = windowState.mode.next
    }

    private func clearSelections() {
        selectedInstanceIDs = []
        selectedQueryIDs = []
        selectedMapElementIDs = []
    }

    // Down arrow from the focused search box: highlight the first result and move focus
    // to the results list. No-op (search box keeps focus) when there are no results.
    private func moveFocusToResults() {
        switch windowState.mode {
        case .instances:
            guard let firstID = instanceSections.first?.instances.first?.id else { return }
            selectedInstanceIDs = [firstID]
        case .queries:
            guard let firstID = querySections.first?.queries.first?.id else { return }
            selectedQueryIDs = [firstID]
        case .pointsAndBoundaries:
            guard let firstID = mapElementSections.first?.elements.first?.id else { return }
            selectedMapElementIDs = [firstID]
        }
        resultsListFocused = true
    }

    // MARK: - Search

    @MainActor
    private func resetAndFocusSearch() async {
        debounceTask?.cancel()
        let initialText = windowState.requestedSearchText ?? windowState.persistedSearchText
        searchQuery = initialText
        debouncedSearchQuery = initialText
        searchFocusRequest = UUID()
        await loadCollectionMembershipIfNeeded()
        await runSearch(for: initialText)
    }

    private func scheduleDebouncedSearch(for query: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await MainActor.run { debouncedSearchQuery = query }
        }
    }

    @MainActor
    private func runSearch(for query: String) async {
        do {
            switch windowState.mode {
            case .instances:
                instanceSections = try appDatabase.searchInstances(query: query)
            case .queries:
                querySections = try appDatabase.searchQueries(query: query)
            case .pointsAndBoundaries:
                mapElementSections = try appDatabase.searchMapElements(query: query)
            }
            errorMessage = nil
        } catch {
            instanceSections = []
            querySections = []
            mapElementSections = []
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Instances mode

    @MainActor
    private func loadCollectionMembershipIfNeeded() async {
        guard let collection = collectionInAddMode else {
            instanceIDsInCollection = []
            return
        }
        do {
            instanceIDsInCollection = try appDatabase.fetchInstanceIDs(inCollectionID: collection.id)
            errorMessage = nil
        } catch {
            instanceIDsInCollection = []
            errorMessage = "Failed to load collection membership."
        }
    }

    @MainActor
    private func setMembership(_ isMember: Bool, for instanceID: Int64) async {
        guard let collection = collectionInAddMode else { return }
        do {
            if isMember {
                try appDatabase.addInstance(instanceID, toCollectionID: collection.id)
                instanceIDsInCollection.insert(instanceID)
            } else {
                try appDatabase.removeInstance(instanceID, fromCollectionID: collection.id)
                instanceIDsInCollection.remove(instanceID)
            }
            windowState.notifyCollectionMembershipChange(collectionID: collection.id)
            errorMessage = nil
        } catch {
            errorMessage = isMember
                ? "Failed to add instance to collection."
                : "Failed to remove instance from collection."
        }
    }

    private func promptToDeleteInstances(_ instanceIDs: Set<Int64>) {
        guard !instanceIDs.isEmpty else { return }
        pendingDeletionInstanceIDs = Array(instanceIDs)
        isDeletionConfirmationPresented = true
    }

    @MainActor
    private func deleteInstances(_ instanceIDsToDelete: [Int64]) async {
        guard !instanceIDsToDelete.isEmpty else { return }
        var deletedAny = false
        do {
            let shouldNotifyCollectionChange = collectionInAddMode != nil
            for instanceID in instanceIDsToDelete {
                try appDatabase.deleteInstance(instanceID: instanceID)
                deletedAny = true
            }
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            windowState.notifyCollectionsDataChange()
            if shouldNotifyCollectionChange {
                await loadCollectionMembershipIfNeeded()
            }
            selectedInstanceIDs = []
            pendingDeletionInstanceIDs = []
            isDeletionConfirmationPresented = false
            await runSearch(for: debouncedSearchQuery)
            errorMessage = nil
        } catch {
            // A mid-batch failure still deleted the earlier instances.
            if deletedAny {
                NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
                windowState.notifyCollectionsDataChange()
            }
            pendingDeletionInstanceIDs = []
            isDeletionConfirmationPresented = false
            errorMessage = "Failed to delete instance."
        }
    }

    private func confirmPendingDeletion() {
        let instanceIDsToDelete = pendingDeletionInstanceIDs
        Task { await deleteInstances(instanceIDsToDelete) }
    }

    // MARK: - Queries mode

    /// Builds reset/disable targets from selected query result rows, deriving the
    /// table (standard / point / boundary) from each row's section and the
    /// direction from the row's `isReverse`. When `ids` is nil, targets every
    /// displayed result.
    private func collectQueryTargets(selecting ids: Set<String>?) -> [QueryTarget] {
        var targets: [QueryTarget] = []
        for section in querySections {
            let sectionKind: QueryTargetKind
            switch section.typeName {
            case POINTMAP_TYPE_NAME: sectionKind = .point
            case BOUNDARYMAP_TYPE_NAME: sectionKind = .boundary
            default: sectionKind = .standard
            }
            for query in section.queries where ids == nil || ids!.contains(query.id) {
                // The Person section mixes standard (user-defined) rows with
                // built-in rows, so the kind is per row.
                if let personKind = query.personKind {
                    targets.append(QueryTarget(
                        instanceID: query.instanceID,
                        queryTypeID: 0,
                        isReverse: false,
                        kind: .person,
                        personKind: personKind,
                        personPartnershipID: query.personPartnershipID,
                        personOfficeID: query.personOfficeID
                    ))
                } else {
                    targets.append(QueryTarget(
                        instanceID: query.instanceID,
                        queryTypeID: query.queryTypeID,
                        isReverse: query.isReverse,
                        kind: sectionKind
                    ))
                }
            }
        }
        return targets
    }

    @MainActor
    private func addStack() async {
        let trimmedStackName = newStackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStackName.isEmpty else { return }
        do {
            let stack = try appDatabase.createStack(name: trimmedStackName, search: searchQuery)
            try await stacksPageState.refreshQueryCounts(for: stack, appDatabase: appDatabase)
            windowState.notifyStacksDataChange()
            isAddStackPopoverPresented = false
            dismiss()
        } catch {
            errorMessage = "Failed to add stack."
        }
    }

    @MainActor
    private func resetDueDates() async {
        let targets = collectQueryTargets(selecting: queryIDsPendingReset.isEmpty ? nil : queryIDsPendingReset)
        do {
            try appDatabase.resetQueryDueDates(targets: targets)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            await runSearch(for: debouncedSearchQuery)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to reset due dates."
        }
    }

    @MainActor
    private func deleteQueries() async {
        let targets = collectQueryTargets(selecting: queryIDsPendingDelete)
        guard !targets.isEmpty else { return }
        do {
            try appDatabase.disableQueries(targets: targets)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            await runSearch(for: debouncedSearchQuery)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to delete queries."
        }
    }

    // MARK: - Points & Boundaries mode

    private func mapElement(forID id: String) -> MapElementSearchResult? {
        for section in mapElementSections {
            if let element = section.elements.first(where: { $0.id == id }) {
                return element
            }
        }
        return nil
    }

    private func openMapElementEditor(_ element: MapElementSearchResult) {
        switch element.kind {
        case .point:
            editInstanceWindowState.requestOpen(instanceID: element.instanceID, autoEditPointID: element.elementID)
        case .boundary:
            editInstanceWindowState.requestOpen(instanceID: element.instanceID)
        }
        openWindow(id: "edit-instance")
    }
}

extension View {
    func searchCodeEditorStyle() -> some View {
        self
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
    }
}

private struct InstanceSearchRowView: View {
    let instance: InstanceSearchResult
    let isSelectableForCollection: Bool
    let isInCollection: Bool
    let onSelectionChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isSelectableForCollection {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isInCollection },
                        set: { onSelectionChange($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
            }

            Text(formatFieldDisplayValue(instance.displayValue))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct QuerySearchRowView: View {
    let query: QuerySearchResult

    var body: some View {
        HStack(spacing: 8) {
            Text(formatFieldDisplayValue(query.displayValue))
                .foregroundStyle(.primary)

            Text(query.queryTypeName)
                .foregroundStyle(Color(nsColor: .magenta))

            Spacer(minLength: 0)
        }
    }
}

private struct MapElementSearchRowView: View {
    let element: MapElementSearchResult

    var body: some View {
        HStack(spacing: 8) {
            Text(formatFieldDisplayValue(element.displayValue))
                .foregroundStyle(.primary)

            Text(element.elementName)
                .foregroundStyle(.yellow)

            Spacer(minLength: 0)
        }
    }
}

/// Captures Shift+Tab at the window level (for when focus is in the result list,
/// not the search field) so the user can still cycle search modes.
private struct SearchWindowBacktabHandler: NSViewRepresentable {
    let onBacktab: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onBacktab = onBacktab
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onBacktab = onBacktab
    }

    final class MonitorView: NSView {
        var onBacktab: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil, window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    // Tab keyCode 48 with Shift = Shift+Tab.
                    if event.keyCode == 48, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift {
                        self.onBacktab?()
                        return nil
                    }
                    return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
