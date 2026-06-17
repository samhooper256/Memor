//
//  StacksPageView.swift
//  Memor
//
//  Stacks page: list of stacks, stack row with per-color query counts, and stack detail view.
//

import AppKit
import SwiftUI

struct StacksPageView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var searchWindowState: SearchWindowState
    @EnvironmentObject private var stackStatsWindowState: StackStatsWindowState
    @EnvironmentObject private var stacksPageState: StacksPageState
    @EnvironmentObject private var navigationState: AppNavigationState
    @EnvironmentObject private var timeZoneSettings: TimeZoneSettings

    let appDatabase: AppDatabase
    let onSelectStack: (Stack) -> Void

    @State private var stacks: [Stack] = []
    @State private var errorMessage: String?
    @State private var stackPendingDeletion: Stack?
    @State private var selectedStack: Stack?

    private var lastRefreshedFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a z"
        formatter.timeZone = timeZoneSettings.timeZone
        return formatter
    }

    private var titleText: String {
        let count = stacks.count
        let noun = count == 1 ? "Stack" : "Stacks"
        return "\(count) \(noun)"
    }

    var body: some View {
        Group {
            if let selectedStack {
                StackDetailPageView(
                    stack: selectedStack,
                    appDatabase: appDatabase,
                    onBack: {
                        self.selectedStack = nil
                    }
                )
            } else {
                stackListBody
            }
        }
        .task(id: selectedStack?.id) {
            guard selectedStack == nil else { return }
            await loadStacks()
        }
        .onChange(of: navigationState.resetToHomeNonce) { _, _ in
            selectedStack = nil
        }
        .onChange(of: searchWindowState.latestStacksDataChange) { _, _ in
            guard selectedStack == nil else { return }
            Task {
                await loadStacks()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memorDidChangeDatabase)) { _ in
            guard selectedStack == nil else { return }
            Task { await loadStacks() }
        }
        .alert(
            "Are you sure you want to delete \(stackPendingDeletion?.name ?? "this stack")?",
            isPresented: Binding(
                get: { stackPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        stackPendingDeletion = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                stackPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                guard let stackPendingDeletion else { return }
                Task {
                    await deleteStack(stackPendingDeletion)
                }
            }
        } message: {
            Text("This action is irreversible.")
        }
    }

    private var stackListBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(titleText)
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                HStack(spacing: 12) {
                    Button("Add Stack") {
                        searchWindowState.requestOpenQueries()
                        openWindow(id: "search")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Refresh (⌘R)") {
                        Task {
                            await refreshStacks()
                        }
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("r", modifiers: .command)

                    if let lastUpdatedTimestamp = stacksPageState.lastUpdatedTimestamp {
                        Text("Last refreshed: \(lastRefreshedFormatter.string(from: lastUpdatedTimestamp))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if let averageQueryInterval = stacksPageState.averageQueryInterval {
                        HStack(spacing: 4) {
                            Text("Average interval:")
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2fd", averageQueryInterval / 86_400))
                                .foregroundStyle(Color(nsColor: .magenta))
                        }
                        .font(.subheadline)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else if stacks.isEmpty {
                    Text("You have no stacks yet.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(stacks) { stack in
                            StackRowView(
                                stack: stack,
                                queryCounts: stacksPageState.queryCounts(for: stack.id),
                                isRefreshing: stacksPageState.isRefreshing,
                                onOpen: {
                                    Task {
                                        await openStudyMode(for: stack)
                                    }
                                },
                                onEdit: {
                                    selectedStack = stack
                                },
                                onStats: {
                                    stackStatsWindowState.requestOpen(stackName: stack.name, stackSearch: stack.search)
                                    openWindow(id: "stack-stats")
                                },
                                onSearch: {
                                    searchWindowState.requestOpen(searchText: stack.search)
                                    openWindow(id: "search")
                                },
                                onDelete: {
                                    stackPendingDeletion = stack
                                },
                                onTogglePin: {
                                    Task { await togglePin(for: stack) }
                                }
                            )
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @MainActor
    private func loadStacks() async {
        do {
            stacks = try appDatabase.fetchStacks()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load stacks."
        }
    }

    @MainActor
    private func togglePin(for stack: Stack) async {
        do {
            try appDatabase.setStackPinned(id: stack.id, isPinned: !stack.isPinned)
            await loadStacks()
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
        } catch {
            errorMessage = "Failed to update stack."
        }
    }

    @MainActor
    private func refreshStacks() async {
        do {
            try await stacksPageState.refresh(appDatabase: appDatabase)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to refresh stacks."
        }
    }

    @MainActor
    private func openStudyMode(for stack: Stack) async {
        do {
            try await stacksPageState.refreshQueryCounts(for: stack, appDatabase: appDatabase)
            errorMessage = nil
            onSelectStack(stack)
        } catch {
            errorMessage = "Failed to refresh this stack."
        }
    }

    @MainActor
    private func deleteStack(_ stack: Stack) async {
        do {
            try appDatabase.deleteStack(id: stack.id)
            stacks.removeAll { $0.id == stack.id }
            errorMessage = nil
            stackPendingDeletion = nil
        } catch {
            errorMessage = "Failed to delete stack."
        }
    }
}

private struct StackRowView: View {
    let stack: Stack
    let queryCounts: StackQueryCounts?
    let isRefreshing: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onStats: () -> Void
    let onSearch: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovered = false
    @State private var isPinButtonHovered = false
    @State private var isEditButtonHovered = false
    @State private var isStatsButtonHovered = false
    @State private var isSearchButtonHovered = false
    @State private var isDeleteButtonHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onTogglePin) {
                Image(systemName: stack.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(stack.isPinned ? Color.blue : Color.secondary)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isPinButtonHovered ? Color.blue.opacity(0.14) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isPinButtonHovered = hovering
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(stack.name)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(highlightedSearchQuery(stack.search))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                DescriptionDisplay(stack.description)
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                Button(action: onEdit) {
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

                Button(action: onStats) {
                    Image(systemName: "chart.bar")
                        .foregroundStyle(.blue)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isStatsButtonHovered ? Color.blue.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isStatsButtonHovered = hovering
                }

                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.blue)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSearchButtonHovered ? Color.blue.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isSearchButtonHovered = hovering
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
            }
            .opacity(isHovered ? 1 : 0)

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else if let queryCounts {
                HStack(spacing: 12) {
                    Text("\(queryCounts.magentaQueryCount)")
                        .foregroundStyle(queryCounts.magentaQueryCount == 0 ? Color.secondary : Color(nsColor: .magenta))

                    Text("\(queryCounts.greenQueryCount)")
                        .foregroundStyle(queryCounts.greenQueryCount == 0 ? Color.secondary : .green)

                    Text("\(queryCounts.redQueryCount)")
                        .foregroundStyle(queryCounts.redQueryCount == 0 ? Color.secondary : .red)

                    Text("\(queryCounts.blueQueryCount)")
                        .foregroundStyle(queryCounts.blueQueryCount == 0 ? Color.secondary : .blue)
                }
                .font(.title2)
                .fontWeight(.bold)
            } else {
                Text("ERROR")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .pointerStyle(isHovered ? .link : .default)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
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

private struct StackDetailPageView: View {
    let stack: Stack
    let appDatabase: AppDatabase
    let onBack: () -> Void

    @State private var searchQuery: String
    @State private var searchSaveTask: Task<Void, Never>?
    @State private var searchErrorMessage: String?
    @State private var description: String
    @State private var descriptionSaveTask: Task<Void, Never>?
    @State private var isRenamePopoverPresented = false
    @State private var renamedStackName: String = ""
    @State private var displayedName: String
    @FocusState private var isRenameFieldFocused: Bool

    init(stack: Stack, appDatabase: AppDatabase, onBack: @escaping () -> Void) {
        self.stack = stack
        self.appDatabase = appDatabase
        self.onBack = onBack
        self._searchQuery = State(initialValue: stack.search)
        self._displayedName = State(initialValue: stack.name)
        self._description = State(initialValue: stack.description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: onBack) {
                    Label(AppTab.stacks.title, systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(displayedName)
                        .font(.largeTitle)
                        .fontWeight(.semibold)

                    Button {
                        renamedStackName = displayedName
                        isRenamePopoverPresented = true
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isRenamePopoverPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Edit Stack Name")
                                .font(.headline)

                            TextField("Stack Name", text: $renamedStackName)
                                .textFieldStyle(.roundedBorder)
                                .focused($isRenameFieldFocused)
                                .onSubmit {
                                    renameStack()
                                }

                            HStack {
                                Spacer()

                                Button("Cancel") {
                                    isRenamePopoverPresented = false
                                }

                                Button("Save") {
                                    renameStack()
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(renamedStackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Search Query")
                        .font(.headline)

                    SearchQueryTextField("Search query", text: $searchQuery, highlightsNoQueries: false)
                        .searchCodeEditorStyle()

                    if let searchErrorMessage {
                        Text(searchErrorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                DescriptionEditor(text: $description)
            }
            .padding(24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand(perform: onBack)
        .onChange(of: searchQuery) { _, newValue in
            searchSaveTask?.cancel()
            searchSaveTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await saveSearch(newValue)
            }
        }
        .onChange(of: description) { _, newValue in
            descriptionSaveTask?.cancel()
            descriptionSaveTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                try? appDatabase.updateStackDescription(id: stack.id, description: newValue)
            }
        }
    }

    @MainActor
    private func saveSearch(_ newSearch: String) {
        do {
            // Validate the search query first
            _ = try appDatabase.searchQueries(query: newSearch)
            try appDatabase.updateStackSearch(id: stack.id, search: newSearch)
            searchErrorMessage = nil
        } catch {
            searchErrorMessage = error.localizedDescription
        }
    }

    private func renameStack() {
        let trimmed = renamedStackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try appDatabase.updateStackName(id: stack.id, name: trimmed)
            displayedName = trimmed
            isRenamePopoverPresented = false
        } catch {
            // silently fail
        }
    }
}

private struct StackCardView: View {
    let stack: Stack
    let queryCounts: StackQueryCounts?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stack.name)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(highlightedSearchQuery(stack.search))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                DescriptionDisplay(stack.description)
            }

            Spacer(minLength: 0)

            if let queryCounts {
                HStack(spacing: 12) {
                    Text("\(queryCounts.magentaQueryCount)")
                        .foregroundStyle(queryCounts.magentaQueryCount == 0 ? Color.secondary : Color(nsColor: .magenta))

                    Text("\(queryCounts.greenQueryCount)")
                        .foregroundStyle(queryCounts.greenQueryCount == 0 ? Color.secondary : .green)

                    Text("\(queryCounts.redQueryCount)")
                        .foregroundStyle(queryCounts.redQueryCount == 0 ? Color.secondary : .red)

                    Text("\(queryCounts.blueQueryCount)")
                        .foregroundStyle(queryCounts.blueQueryCount == 0 ? Color.secondary : .blue)
                }
                .font(.title2)
                .fontWeight(.bold)
            } else {
                Text("ERROR")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}


