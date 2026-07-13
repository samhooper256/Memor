//
//  InstancesPageView.swift
//  Memor
//
//  Instances page: sidebar of types, table of instances, and key commands.
//

import AppKit
import SwiftUI

struct InstancesPageView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var addInstanceWindowState: AddInstanceWindowState
    @EnvironmentObject private var editInstanceWindowState: EditInstanceWindowState
    @EnvironmentObject private var navigationState: AppNavigationState

    let appDatabase: AppDatabase
    @ObservedObject var pageState: InstancesPageState

    @StateObject private var typePickerController = TypePickerController()
    @State private var selectedTypeID: Int64?
    @State private var types: [FlashcardType] = []
    @State private var pageData: TypeInstancesPageData?
    @State private var errorMessage: String?
    @State private var selectedInstanceIDs = Set<Int64>()
    @State private var pendingDeletionInstanceIDs: [Int64] = []
    @State private var isDeletionConfirmationPresented = false
    @State private var deletionConfirmationMessage = ""
    @State private var pendingMaxIntervalInstanceIDs: Set<Int64> = []
    @State private var isSetMaxIntervalPresented = false
    @State private var maxIntervalInput: String = ""
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var searchQuery = ""
    @State private var searchFocusRequest: UUID?
    @State private var debouncedSearchQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Instances")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                HelpWindowButton(windowID: "instances-help", tooltip: "Learn what instances are")
            }

            HSplitView {
                List(types, selection: $selectedTypeID) { type in
                    InstancesSidebarRowView(
                        type: type,
                        onEditType: {
                            navigationState.navigateToTypeDetail(typeID: type.id)
                        },
                        onAddInstance: {
                            addInstanceWindowState.requestOpen(preselectedTypeID: type.id)
                            openWindow(id: "add-instance")
                        }
                    )
                        .tag(Optional(type.id))
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)

                Group {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if types.isEmpty {
                        Text("You have no types.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if selectedType != nil, let pageData {
                        VStack(alignment: .leading, spacing: 8) {
                            // Indented to match the Table's built-in leading
                            // content inset, so these align with the row text.
                            Group {
                                HStack(spacing: 8) {
                                    SearchQueryTextField("Search instances", text: $searchQuery, focusRequest: searchFocusRequest)
                                        .searchCodeEditorStyle()

                                    HelpWindowButton(windowID: "instance-search-help", tooltip: "Show search syntax help")
                                }

                                if let searchErrorMessage {
                                    Text(searchErrorMessage)
                                        .font(.subheadline)
                                        .foregroundStyle(.red)
                                }

                                Text(resultsCountText(for: pageData))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 16)

                            TypeInstancesTableView(
                                pageData: pageData,
                                canDuplicate: !(selectedType?.isBuiltin ?? true),
                                selectedInstanceIDs: $selectedInstanceIDs,
                                onToggleQuery: { instanceID, queryTypeID, isEnabled in
                                    await setQueryEnabled(isEnabled, instanceID: instanceID, queryTypeID: queryTypeID)
                                },
                                onOpenInstance: { instanceID in
                                    openInstanceEditor(instanceID: instanceID)
                                },
                                onApplyQueryChange: { isEnabled, queryTypeID, instanceIDs in
                                    await applyQueryChange(
                                        isEnabled: isEnabled,
                                        queryTypeID: queryTypeID,
                                        instanceIDs: instanceIDs
                                    )
                                },
                                onRequestSetMaxInterval: { instanceIDs in
                                    pendingMaxIntervalInstanceIDs = instanceIDs
                                    maxIntervalInput = ""
                                    isSetMaxIntervalPresented = true
                                },
                                onDuplicateInstance: { instanceID in
                                    addInstanceWindowState.requestOpenForDuplication(sourceInstanceID: instanceID)
                                    openWindow(id: "add-instance")
                                },
                                onRequestDelete: { instanceIDs in
                                    promptToDeleteInstances(instanceIDs)
                                }
                            )
                        }
                    } else {
                        Text("Select a type.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            InstancesPageKeyCommandHandler(
                isEnabled: !selectedInstanceIDs.isEmpty,
                onCommandL: copySelectedInstanceLink,
                onDelete: promptToDeleteSelectedInstances,
                onCommandT: presentTypePicker,
                onCommandF: focusSearchField
            )
        }
        .task {
            selectedTypeID = pageState.selectedTypeID
            await loadTypes()
        }
        .task(id: selectedTypeID) {
            await loadPageData()
        }
        .task(id: debouncedSearchQuery) {
            await loadPageData()
        }
        .onChange(of: selectedTypeID) { _, newValue in
            pageState.selectedTypeID = newValue
            debounceTask?.cancel()
            searchQuery = ""
            debouncedSearchQuery = ""
            searchErrorMessage = nil
            if newValue != nil {
                searchFocusRequest = UUID()
            }
        }
        .onChange(of: searchQuery) { _, newValue in
            scheduleDebouncedSearch(for: newValue)
        }
        .onDisappear {
            debounceTask?.cancel()
        }
        .onChange(of: editInstanceWindowState.latestSaveNonce) { _, _ in
            Task {
                await loadPageData()
            }
        }
        .onChange(of: addInstanceWindowState.latestAddNonce) { _, _ in
            guard addInstanceWindowState.latestAddedTypeID == selectedTypeID else { return }
            Task {
                await loadTypes()
                await loadPageData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memorDidChangeDatabase)) { _ in
            Task {
                await loadTypes()
                await loadPageData()
            }
        }
        .overlay(alignment: .topTrailing) {
            if let toastMessage {
                InstancesToastView(message: toastMessage)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
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
            Text(deletionConfirmationMessage)
        }
        .alert(
            setMaxIntervalAlertTitle,
            isPresented: $isSetMaxIntervalPresented
        ) {
            TextField("", text: $maxIntervalInput)
                .onChange(of: maxIntervalInput) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    if digitsOnly != newValue {
                        maxIntervalInput = digitsOnly
                    }
                }
            Button("Apply") {
                let value = Int64(maxIntervalInput)
                let ids = pendingMaxIntervalInstanceIDs
                Task {
                    await applyMaxInterval(value: value, to: ids)
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave blank for no max interval.")
        }
    }

    private var selectedType: FlashcardType? {
        guard let selectedTypeID else { return nil }
        return types.first(where: { $0.id == selectedTypeID })
    }

    private func resultsCountText(for pageData: TypeInstancesPageData) -> String {
        let count = pageData.rows.count
        let noun = count == 1 ? "result" : "results"
        return "\(count) \(noun)"
    }

    @MainActor
    private func loadTypes() async {
        do {
            let loadedTypes = try appDatabase.fetchTypes()
            types = loadedTypes
            if let selectedTypeID,
               loadedTypes.contains(where: { $0.id == selectedTypeID }) {
                errorMessage = nil
                return
            }

            selectedTypeID = loadedTypes.first?.id
            errorMessage = nil
        } catch {
            types = []
            selectedTypeID = nil
            pageData = nil
            errorMessage = "Failed to load types."
        }
    }

    @MainActor
    private func loadPageData() async {
        guard let selectedTypeID else {
            pageData = nil
            return
        }

        do {
            pageData = try appDatabase.fetchTypeInstancesPageData(
                forTypeID: selectedTypeID,
                searchQuery: debouncedSearchQuery
            )
            selectedInstanceIDs = []
            errorMessage = nil
            searchErrorMessage = nil
        } catch {
            let hasSearchQuery = !debouncedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            selectedInstanceIDs = []
            if hasSearchQuery {
                searchErrorMessage = error.localizedDescription
            } else {
                pageData = nil
                searchErrorMessage = nil
                errorMessage = "Failed to load instances."
            }
        }
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
    private func applyQueryChange(isEnabled: Bool, queryTypeID: Int64, instanceIDs: Set<Int64>) async {
        guard var pageData else { return }
        let previousRows = pageData.rows

        var changedInstanceIDs: [Int64] = []
        for instanceID in instanceIDs {
            guard let rowIndex = pageData.rows.firstIndex(where: { $0.id == instanceID }) else { continue }
            let alreadyEnabled = pageData.rows[rowIndex].enabledQueryTypeIDs.contains(queryTypeID)
            if isEnabled != alreadyEnabled {
                changedInstanceIDs.append(instanceID)
            }
        }

        guard !changedInstanceIDs.isEmpty else { return }

        for instanceID in changedInstanceIDs {
            guard let rowIndex = pageData.rows.firstIndex(where: { $0.id == instanceID }) else { continue }
            var enabledQueryTypeIDs = pageData.rows[rowIndex].enabledQueryTypeIDs
            if isEnabled {
                enabledQueryTypeIDs.insert(queryTypeID)
            } else {
                enabledQueryTypeIDs.remove(queryTypeID)
            }
            pageData.rows[rowIndex] = TypeInstancesPageRow(
                id: pageData.rows[rowIndex].id,
                displayValue: pageData.rows[rowIndex].displayValue,
                enabledQueryTypeIDs: enabledQueryTypeIDs
            )
        }
        self.pageData = pageData

        do {
            for instanceID in changedInstanceIDs {
                try appDatabase.setQueryEnabled(isEnabled, instanceID: instanceID, queryTypeID: queryTypeID)
            }
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            errorMessage = nil
            let count = changedInstanceIDs.count
            let noun = count == 1 ? "query" : "queries"
            showToast("\(count) \(noun) \(isEnabled ? "enabled" : "disabled")")
        } catch {
            var revertedPageData = pageData
            revertedPageData.rows = previousRows
            self.pageData = revertedPageData
            errorMessage = "Failed to update query."
        }
    }

    @MainActor
    private func setQueryEnabled(_ isEnabled: Bool, instanceID: Int64, queryTypeID: Int64) async {
        guard var pageData else { return }

        let previousRows = pageData.rows
        guard let rowIndex = pageData.rows.firstIndex(where: { $0.id == instanceID }) else { return }

        var enabledQueryTypeIDs = pageData.rows[rowIndex].enabledQueryTypeIDs
        if isEnabled {
            enabledQueryTypeIDs.insert(queryTypeID)
        } else {
            enabledQueryTypeIDs.remove(queryTypeID)
        }

        pageData.rows[rowIndex] = TypeInstancesPageRow(
            id: pageData.rows[rowIndex].id,
            displayValue: pageData.rows[rowIndex].displayValue,
            enabledQueryTypeIDs: enabledQueryTypeIDs
        )
        self.pageData = pageData

        do {
            try appDatabase.setQueryEnabled(isEnabled, instanceID: instanceID, queryTypeID: queryTypeID)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            errorMessage = nil
        } catch {
            var revertedPageData = pageData
            revertedPageData.rows = previousRows
            self.pageData = revertedPageData
            errorMessage = "Failed to update query."
        }
    }

    private func openInstanceEditor(instanceID: Int64) {
        editInstanceWindowState.requestOpen(instanceID: instanceID)
        openWindow(id: "edit-instance")
    }

    @MainActor
    private func focusSearchField() {
        searchFocusRequest = UUID()
    }

    @MainActor
    private func presentTypePicker() {
        guard !types.isEmpty else { return }
        typePickerController.present(
            types: types,
            currentTypeID: nil,            // nil ⇒ no green text, no checkmark
            from: NSApp.keyWindow
        ) { typeID in
            selectedTypeID = typeID
        }
    }

    @MainActor
    private func copySelectedInstanceLink() {
        guard let instanceID = selectedInstanceIDs.sorted().first else { return }
        let link = #"<a href="id:\#(instanceID)"></a>"#
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        showToast("Link copied")
    }

    private var deletionConfirmationTitle: String {
        let count = pendingDeletionInstanceIDs.count
        if count == 1 {
            return "Are you sure you want to delete this instance?"
        } else {
            return "Are you sure you want to delete these \(count) instances?"
        }
    }

    private var setMaxIntervalAlertTitle: String {
        let count = pendingMaxIntervalInstanceIDs.count
        if count == 1 {
            return "Set max interval for this instance"
        } else {
            return "Set max interval for these \(count) instances"
        }
    }

    @MainActor
    private func applyMaxInterval(value: Int64?, to instanceIDs: Set<Int64>) async {
        guard !instanceIDs.isEmpty else { return }
        do {
            for instanceID in instanceIDs {
                try appDatabase.setMaxInterval(forInstanceID: instanceID, maxInterval: value)
            }
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to set max interval."
        }
    }

    @MainActor
    private func promptToDeleteSelectedInstances() {
        promptToDeleteInstances(selectedInstanceIDs)
    }

    @MainActor
    private func promptToDeleteInstances(_ instanceIDs: Set<Int64>) {
        guard !instanceIDs.isEmpty else { return }
        pendingDeletionInstanceIDs = Array(instanceIDs)
        // Computed once here, not in the alert body — the message runs a DB
        // query, and alert closures re-evaluate on every body render.
        deletionConfirmationMessage = personDeletionConsequencesMessage(
            appDatabase: appDatabase,
            pendingInstanceIDs: pendingDeletionInstanceIDs
        )
        isDeletionConfirmationPresented = true
    }

    @MainActor
    private func confirmPendingDeletion() {
        let idsToDelete = Set(pendingDeletionInstanceIDs)
        pendingDeletionInstanceIDs = []
        isDeletionConfirmationPresented = false
        var deletedAny = false
        do {
            for instanceID in idsToDelete {
                try appDatabase.deleteInstance(instanceID: instanceID)
                deletedAny = true
            }
            pageData?.rows.removeAll { idsToDelete.contains($0.id) }
            selectedInstanceIDs = []
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
        } catch {
            // A mid-batch failure still deleted the earlier instances.
            if deletedAny {
                NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            }
            Task {
                await loadPageData()
            }
        }
    }

    @MainActor
    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }
}

private struct InstancesSidebarRowView: View {
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    let type: FlashcardType
    let onEditType: () -> Void
    let onAddInstance: () -> Void

    @State private var isHovered = false
    @State private var isEditButtonHovered = false
    @State private var isAddButtonHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: type.kindIcon.name)
                .foregroundStyle(type.kindIcon.color)

            Text(type.name)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered {
                Button(action: onEditType) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isEditButtonHovered ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isEditButtonHovered = hovering
                }
                .help("Edit Type")

                Button(action: onAddInstance) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isAddButtonHovered ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isAddButtonHovered = hovering
                }
                .help("Add Instance (\(shortcutSettings.binding(for: .openAddInstance).displayString))")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if !hovering {
                isEditButtonHovered = false
                isAddButtonHovered = false
            }
        }
    }
}

private struct TypeInstancesTableView: View {
    let pageData: TypeInstancesPageData
    let canDuplicate: Bool
    @Binding var selectedInstanceIDs: Set<Int64>
    let onToggleQuery: (Int64, Int64, Bool) async -> Void
    let onOpenInstance: (Int64) -> Void
    let onApplyQueryChange: (_ isEnabled: Bool, _ queryTypeID: Int64, _ instanceIDs: Set<Int64>) async -> Void
    let onRequestSetMaxInterval: (Set<Int64>) -> Void
    let onDuplicateInstance: (Int64) -> Void
    let onRequestDelete: (Set<Int64>) -> Void

    var body: some View {
        Table(pageData.rows, selection: $selectedInstanceIDs) {
            TableColumn(pageData.displayFieldName) { row in
                Text(formatFieldDisplayValue(row.displayValue))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 220, ideal: 280)

            TableColumnForEach(pageData.queryTypes) { queryType in
                TableColumn(queryType.name) { row in
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { row.enabledQueryTypeIDs.contains(queryType.id) },
                            set: { isEnabled in
                                Task {
                                    await onToggleQuery(row.id, queryType.id, isEnabled)
                                }
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .width(min: 80, ideal: 110)
            }
        }
        .contextMenu(forSelectionType: Int64.self) { items in
            if canDuplicate, items.count == 1, let instanceID = items.first {
                Button("Duplicate Instance") {
                    onDuplicateInstance(instanceID)
                }
            }
            if items.count == 1, let instanceID = items.first {
                Button("Copy ID") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("\(instanceID)", forType: .string)
                }
            }
            if !pageData.queryTypes.isEmpty {
                Menu("Enable Queries") {
                    ForEach(pageData.queryTypes) { queryType in
                        Button(queryType.name) {
                            Task {
                                await onApplyQueryChange(true, queryType.id, items)
                            }
                        }
                    }
                }
                Menu("Disable Queries") {
                    ForEach(pageData.queryTypes) { queryType in
                        Button(queryType.name) {
                            Task {
                                await onApplyQueryChange(false, queryType.id, items)
                            }
                        }
                    }
                }
            }
            Button("Set Max Interval") {
                onRequestSetMaxInterval(items)
            }
            if !items.isEmpty {
                Divider()
                Button("Delete", role: .destructive) {
                    onRequestDelete(items)
                }
            }
        } primaryAction: { selectedInstanceIDs in
            guard let instanceID = selectedInstanceIDs.first else { return }
            onOpenInstance(instanceID)
        }
    }
}

private struct InstancesToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.green)
            .clipShape(Capsule())
            .shadow(radius: 8, y: 3)
    }
}

private struct InstancesPageKeyCommandHandler: NSViewRepresentable {
    let isEnabled: Bool
    let onCommandL: () -> Void
    let onDelete: () -> Void
    let onCommandT: () -> Void
    let onCommandF: () -> Void

    func makeNSView(context: Context) -> KeyCommandHandlingView {
        let view = KeyCommandHandlingView()
        view.isEnabled = isEnabled
        view.onCommandL = onCommandL
        view.onDelete = onDelete
        view.onCommandT = onCommandT
        view.onCommandF = onCommandF
        return view
    }

    func updateNSView(_ nsView: KeyCommandHandlingView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onCommandL = onCommandL
        nsView.onDelete = onDelete
        nsView.onCommandT = onCommandT
        nsView.onCommandF = onCommandF
    }

    final class KeyCommandHandlingView: NSView {
        var isEnabled = false
        var onCommandL: (() -> Void)?
        var onDelete: (() -> Void)?
        var onCommandT: (() -> Void)?
        var onCommandF: (() -> Void)?

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
                guard let self, event.window === self.window else {
                    return event
                }

                // ⌘T opens the type picker regardless of instance selection.
                if self.isCommandT(event) {
                    self.onCommandT?()
                    return nil
                }

                // ⌘F focuses the search box regardless of instance selection.
                if self.isCommandF(event) {
                    self.onCommandF?()
                    return nil
                }

                guard self.isEnabled else {
                    return event
                }

                if self.isCommandL(event) {
                    self.onCommandL?()
                    return nil
                }

                if self.isDelete(event) {
                    self.onDelete?()
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

        private func isCommandL(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "l"
        }

        private func isCommandT(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "t"
        }

        private func isCommandF(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "f"
        }

        private func isDelete(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags.isEmpty else { return false }
            return event.keyCode == 51 || event.keyCode == 117
        }
    }
}

