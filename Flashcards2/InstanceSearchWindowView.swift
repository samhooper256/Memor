//
//  InstanceSearchWindowView.swift
//  Flashcards2
//
//  Created by Codex on 4/4/26.
//

import AppKit
import Combine
import SwiftUI

enum InstanceSearchMode: Hashable {
    case normal
    case addToCollection(Collection)
}

@MainActor
final class InstanceSearchWindowState: ObservableObject {
    @Published private(set) var requestNonce = UUID()
    @Published private(set) var mode: InstanceSearchMode = .normal
    @Published private(set) var latestCollectionMembershipChange: CollectionInstanceMembershipChange?
    @Published private(set) var latestCollectionsDataChange = UUID()
    @Published var persistedSearchText: String = ""

    func requestOpen() {
        mode = .normal
        requestNonce = UUID()
    }

    func requestOpenForCollection(_ collection: Collection) {
        mode = .addToCollection(collection)
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
}

struct InstanceSearchWindowView: View {
    @EnvironmentObject private var windowState: InstanceSearchWindowState
    @EnvironmentObject private var editInstanceWindowState: EditInstanceWindowState
    @EnvironmentObject private var addInstanceWindowState: AddInstanceWindowState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let appDatabase: AppDatabase

    @State private var searchQuery = ""
    @State private var debouncedSearchQuery = ""
    @State private var sections: [InstanceSearchSection] = []
    @State private var errorMessage: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var instanceIDsInCollection: Set<Int64> = []
    @State private var selectedInstanceIDs: Set<Int64> = []
    @State private var pendingDeletionInstanceIDs: [Int64] = []
    @State private var isDeletionConfirmationPresented = false
    @State private var searchFocusRequest = UUID()

    private var collectionInAddMode: Collection? {
        if case let .addToCollection(collection) = windowState.mode {
            return collection
        }
        return nil
    }

    private var resultsCount: Int {
        sections.reduce(0) { $0 + $1.instances.count }
    }

    private var resultsCountText: String {
        let noun = resultsCount == 1 ? "result" : "results"
        return "\(resultsCount) \(noun)"
    }

    private var deletionConfirmationTitle: String {
        let count = pendingDeletionInstanceIDs.count
        if count == 1 {
            return "Are you sure you want to delete this instance?"
        }
        else {
            return "Are you sure you want to delete these \(count) instances?"
        }
    }

    private var duplicatableInstanceIDs: Set<Int64> {
        var result: Set<Int64> = []
        for section in sections where section.typeName != POINTMAP_TYPE_NAME && section.typeName != BOUNDARYMAP_TYPE_NAME {
            for instance in section.instances {
                result.insert(instance.id)
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(24)
            } else if sections.isEmpty {
                Text("No instances match the current search.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(24)
            } else {
                List(selection: $selectedInstanceIDs) {
                    ForEach(sections) { section in
                        Section(section.typeName) {
                            ForEach(section.instances) { instance in
                                InstanceSearchRowView(
                                    instance: instance,
                                    isSelectableForCollection: collectionInAddMode != nil,
                                    isInCollection: instanceIDsInCollection.contains(instance.id),
                                    onSelectionChange: { isSelected in
                                        Task {
                                            await setMembership(isSelected, for: instance.id)
                                        }
                                    }
                                )
                                .tag(instance.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: Int64.self) { items in
                    if items.count == 1,
                       let instanceID = items.first,
                       duplicatableInstanceIDs.contains(instanceID) {
                        Button("Duplicate Instance") {
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
                    promptToDeleteSelectedInstances()
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
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
            Task {
                await resetAndFocusSearch()
            }
        }
        .onChange(of: sections) { _, newSections in
            let instanceIDs = Set(newSections.flatMap { $0.instances.map(\.id) })
            selectedInstanceIDs = selectedInstanceIDs.intersection(instanceIDs)
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
            Button("Delete", role: .confirm) {
                confirmPendingDeletion()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action is irreversible.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SearchQueryTextField("Search instances", text: $searchQuery, focusRequest: searchFocusRequest, onFocusChange: { isFocused in
                        if isFocused { selectedInstanceIDs = [] }
                    })
                    .searchCodeEditorStyle()

                SearchHelpButton(windowID: "instance-search-help")
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

    @MainActor
    private func resetAndFocusSearch() async {
        debounceTask?.cancel()
        let initialText = windowState.persistedSearchText
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
            await MainActor.run {
                debouncedSearchQuery = query
            }
        }
    }

    @MainActor
    private func runSearch(for query: String) async {
        do {
            sections = try appDatabase.searchInstances(query: query)
            errorMessage = nil
        } catch {
            sections = []
            errorMessage = error.localizedDescription
        }
    }

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

    private func promptToDeleteSelectedInstances() {
        promptToDeleteInstances(selectedInstanceIDs)
    }

    private func promptToDeleteInstances(_ instanceIDs: Set<Int64>) {
        guard !instanceIDs.isEmpty else { return }
        pendingDeletionInstanceIDs = Array(instanceIDs)
        isDeletionConfirmationPresented = true
    }

    @MainActor
    private func deleteInstances(_ instanceIDsToDelete: [Int64]) async {
        guard !instanceIDsToDelete.isEmpty else { return }

        do {
            let shouldNotifyCollectionChange = collectionInAddMode != nil

            for instanceID in instanceIDsToDelete {
                try appDatabase.deleteInstance(instanceID: instanceID)
            }
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
            pendingDeletionInstanceIDs = []
            isDeletionConfirmationPresented = false
            print("Failed to delete instance: \(error)")
            errorMessage = "Failed to delete instance."
        }
    }

    private func confirmPendingDeletion() {
        let instanceIDsToDelete = pendingDeletionInstanceIDs
        Task {
            await deleteInstances(instanceIDsToDelete)
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

@MainActor
final class QuerySearchWindowState: ObservableObject {
    @Published private(set) var requestNonce = UUID()
    @Published private(set) var latestStacksDataChange = UUID()
    @Published private(set) var requestedSearchText: String?
    @Published var persistedSearchText: String = ""

    func requestOpen() {
        requestedSearchText = nil
        requestNonce = UUID()
    }

    func requestOpen(searchText: String) {
        requestedSearchText = searchText
        requestNonce = UUID()
    }

    func notifyStacksDataChange() {
        latestStacksDataChange = UUID()
    }
}

struct QuerySearchWindowView: View {
    @EnvironmentObject private var windowState: QuerySearchWindowState
    @EnvironmentObject private var editInstanceWindowState: EditInstanceWindowState
    @EnvironmentObject private var stacksPageState: StacksPageState
    @EnvironmentObject private var quickStudyState: QuickStudyState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let appDatabase: AppDatabase

    @FocusState private var isStackNameFocused: Bool
    @State private var searchQuery = ""
    @State private var debouncedSearchQuery = ""
    @State private var sections: [QuerySearchSection] = []
    @State private var errorMessage: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var isAddStackPopoverPresented = false
    @State private var newStackName = ""
    @State private var isResetDueDatesConfirmationPresented = false
    @State private var isDeleteQueriesConfirmationPresented = false
    @State private var selectedQueryIDs: Set<String> = []
    // The query IDs the pending reset confirmation will act on. Empty means
    // "all queries matching the current search".
    @State private var queryIDsPendingReset: Set<String> = []
    // The query IDs the pending delete confirmation will disable.
    @State private var queryIDsPendingDelete: Set<String> = []
    @State private var searchFocusRequest = UUID()

    private var resultsCount: Int {
        sections.reduce(0) { $0 + $1.queries.count }
    }

    private var resultsCountText: String {
        let noun = resultsCount == 1 ? "result" : "results"
        return "\(resultsCount) \(noun)"
    }

    private var resetDueDatesCount: Int {
        queryIDsPendingReset.isEmpty ? resultsCount : queryIDsPendingReset.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(24)
            } else if sections.isEmpty {
                Text("No queries match the current search.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(24)
            } else {
                List(selection: $selectedQueryIDs) {
                    ForEach(sections) { section in
                        Section(section.typeName) {
                            ForEach(section.queries) { query in
                                QuerySearchRowView(query: query)
                                    .tag(query.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { items in
                    if !items.isEmpty {
                        Button("Reset Due Dates") {
                            queryIDsPendingReset = items
                            isResetDueDatesConfirmationPresented = true
                        }
                        Button("Delete Queries", role: .destructive) {
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

            Divider()

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
                            .textFieldStyle(.roundedBorder)
                            .focused($isStackNameFocused)
                            .onSubmit {
                                Task {
                                    await addStack()
                                }
                            }

                        HStack {
                            Spacer()

                            Button("Cancel") {
                                isAddStackPopoverPresented = false
                            }

                            Button("Add") {
                                Task {
                                    await addStack()
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(newStackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(16)
                    .frame(width: 280)
                    .onAppear {
                        DispatchQueue.main.async {
                            isStackNameFocused = true
                        }
                    }
                }
            }
            .padding(24)
            .background(.bar)
        }
        .frame(minWidth: 560, minHeight: 520)
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
            Task {
                await resetAndFocusSearch()
            }
        }
        .onChange(of: sections) { _, newSections in
            let queryIDs = Set(newSections.flatMap { $0.queries.map(\.id) })
            selectedQueryIDs = selectedQueryIDs.intersection(queryIDs)
        }
        .onChange(of: isAddStackPopoverPresented) { _, isPresented in
            if isPresented {
                selectedQueryIDs = []
            }
        }
        .alert(
            "Are you sure you want to reset the due dates for \(resetDueDatesCount) \(resetDueDatesCount == 1 ? "query" : "queries")?",
            isPresented: $isResetDueDatesConfirmationPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset") {
                Task {
                    await resetDueDates()
                }
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
                Task {
                    await deleteQueries()
                }
            }
        } message: {
            Text("The selected queries will be disabled, but their associated instances will not be deleted. This action is irreversible.")
        }
        .onDisappear {
            debounceTask?.cancel()
        }
        .onExitCommand {
            dismiss()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SearchQueryTextField("Search queries", text: $searchQuery, focusRequest: searchFocusRequest, highlightsNoQueries: false, onFocusChange: { isFocused in
                        if isFocused { selectedQueryIDs = [] }
                    })
                    .searchCodeEditorStyle()

                SearchHelpButton(windowID: "query-search-help")
            }

            Text(resultsCountText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.bar)
    }

    @MainActor
    private func resetAndFocusSearch() async {
        debounceTask?.cancel()
        let initialText = windowState.requestedSearchText ?? windowState.persistedSearchText
        searchQuery = initialText
        debouncedSearchQuery = initialText
        searchFocusRequest = UUID()
        await runSearch(for: initialText)
    }

    private func scheduleDebouncedSearch(for query: String) {
        debounceTask?.cancel()

        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debouncedSearchQuery = query
            }
        }
    }

    @MainActor
    private func runSearch(for query: String) async {
        do {
            sections = try appDatabase.searchQueries(query: query)
            errorMessage = nil
        } catch {
            sections = []
            errorMessage = error.localizedDescription
        }
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
        do {
            if queryIDsPendingReset.isEmpty {
                try appDatabase.resetQueryDueDates(query: debouncedSearchQuery)
            } else {
                let pairs = queryIDsPendingReset.compactMap { id -> (instanceID: Int64, queryTypeID: Int64)? in
                    let parts = id.split(separator: ":")
                    guard parts.count == 2,
                          let instanceID = Int64(parts[0]),
                          let queryTypeID = Int64(parts[1]) else { return nil }
                    return (instanceID: instanceID, queryTypeID: queryTypeID)
                }
                try appDatabase.resetQueryDueDates(instanceIDAndQueryTypeIDPairs: pairs)
            }
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            await runSearch(for: debouncedSearchQuery)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to reset due dates."
        }
    }

    @MainActor
    private func deleteQueries() async {
        let pairs = queryIDsPendingDelete.compactMap { id -> (instanceID: Int64, queryTypeID: Int64)? in
            let parts = id.split(separator: ":")
            guard parts.count == 2,
                  let instanceID = Int64(parts[0]),
                  let queryTypeID = Int64(parts[1]) else { return nil }
            return (instanceID: instanceID, queryTypeID: queryTypeID)
        }
        guard !pairs.isEmpty else { return }
        do {
            try appDatabase.disableQueries(instanceIDAndQueryTypeIDPairs: pairs)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            await runSearch(for: debouncedSearchQuery)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to delete queries."
        }
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
