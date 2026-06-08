//
//  ContentView.swift
//  Flashcards2
//
//  Created by Sam Hooper on 4/1/26.
//

import AppKit
import Combine
import SwiftUI
import WebKit

enum AppTab: Int, CaseIterable, Identifiable {
    case stacks
    case instances
    case collections
    case types
    case graph

    var id: Self { self }

    var shortcutAction: ShortcutAction {
        switch self {
        case .stacks: return .goToStacksTab
        case .instances: return .goToInstancesTab
        case .collections: return .goToCollectionsTab
        case .types: return .goToTypesTab
        case .graph: return .goToGraphTab
        }
    }

    var title: String {
        switch self {
        case .stacks:
            "Stacks"
        case .instances:
            "Instances"
        case .collections:
            "Collections"
        case .types:
            "Types"
        case .graph:
            "Graph"
        }
    }
}

final class AppNavigationState: ObservableObject {
    @Published var selectedTab: AppTab = .stacks
    @Published var requestedTypeDetailID: Int64?
    @Published private(set) var resetToHomeNonce = UUID()

    func select(_ tab: AppTab) {
        if selectedTab == tab {
            resetToHomeNonce = UUID()
        }
        selectedTab = tab
    }

    func navigateToTypeDetail(typeID: Int64) {
        requestedTypeDetailID = typeID
        selectedTab = .types
    }
}

@MainActor
final class StacksPageState: ObservableObject {
    @Published private(set) var queryCountsByStackID: [Int64: StackQueryCounts?] = [:]
    @Published private(set) var lastUpdatedTimestamp: Date?
    @Published private(set) var averageQueryInterval: Double?

    func refresh(appDatabase: AppDatabase) async throws {
        queryCountsByStackID = try appDatabase.refreshStackQueryCounts()
        lastUpdatedTimestamp = try appDatabase.fetchStacksLastUpdatedTimestamp()
        averageQueryInterval = try appDatabase.fetchAverageQueryInterval()
    }

    func loadLastUpdatedTimestamp(appDatabase: AppDatabase) async throws {
        lastUpdatedTimestamp = try appDatabase.fetchStacksLastUpdatedTimestamp()
    }

    func refreshQueryCounts(for stack: Stack, appDatabase: AppDatabase) async throws {
        queryCountsByStackID[stack.id] = try appDatabase.refreshStackQueryCounts(for: stack)
    }

    func queryCounts(for stackID: Int64) -> StackQueryCounts? {
        queryCountsByStackID[stackID] ?? StackQueryCounts(
            blueQueryCount: 0,
            redQueryCount: 0,
            greenQueryCount: 0,
            magentaQueryCount: 0
        )
    }
}

@MainActor
final class InstancesPageState: ObservableObject {
    @Published var selectedTypeID: Int64?
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var navigationState: AppNavigationState
    @EnvironmentObject private var searchWindowState: SearchWindowState
    @EnvironmentObject private var stacksPageState: StacksPageState
    @EnvironmentObject private var quickStudyState: QuickStudyState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    let appDatabase: AppDatabase
    @State private var activeStudyStack: Stack?
    @State private var isActiveStudyQuickStudy: Bool = false
    @StateObject private var instancesPageState = InstancesPageState()

    var body: some View {
        Group {
            if let activeStudyStack {
                StudyModeView(
                    stack: activeStudyStack,
                    appDatabase: appDatabase,
                    onExit: { exitStudyMode(for: activeStudyStack) }
                )
            } else {
                VStack(spacing: 0) {
                    tabBar
                    Divider()
                    currentPage
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background {
            MainWindowQuerySearchShortcutHandler(shortcutSettings: shortcutSettings) {
                if let activeStudyStack {
                    searchWindowState.requestOpen(searchText: activeStudyStack.search)
                } else {
                    searchWindowState.requestOpenQueries()
                }
                openWindow(id: "search")
            }
        }
        .onChange(of: quickStudyState.pendingSearch) { _, newValue in
            guard let searchText = newValue else { return }
            quickStudyState.pendingSearch = nil
            startQuickStudySession(searchText: searchText)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    navigationState.select(tab)
                } label: {
                    Text(tab.title)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(tabBackground(for: tab))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(tab == navigationState.selectedTab ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                        }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
                .shortcut(tab.shortcutAction, settings: shortcutSettings)
            }
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch navigationState.selectedTab {
        case .stacks:
            StacksPageView(
                appDatabase: appDatabase,
                onSelectStack: { activeStudyStack = $0 }
            )
        case .instances:
            InstancesPageView(
                appDatabase: appDatabase,
                pageState: instancesPageState
            )
        case .collections:
            CollectionsPageView(appDatabase: appDatabase)
        case .types:
            TypesPageView(appDatabase: appDatabase)
        case .graph:
            GraphPageView(appDatabase: appDatabase)
        }
    }

    private func tabBackground(for tab: AppTab) -> some ShapeStyle {
        if tab == navigationState.selectedTab {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        } else {
            return AnyShapeStyle(.clear)
        }
    }

    private func exitStudyMode(for stack: Stack) {
        let wasQuickStudy = isActiveStudyQuickStudy
        isActiveStudyQuickStudy = false
        activeStudyStack = nil

        if wasQuickStudy {
            navigationState.select(.stacks)
            return
        }

        Task {
            do {
                try await stacksPageState.refreshQueryCounts(for: stack, appDatabase: appDatabase)
            } catch {
                print("Failed to refresh stack counts after study mode: \(error)")
            }
        }
    }

    private func startQuickStudySession(searchText: String) {
        let synthetic = Stack(
            id: -1,
            name: "",
            search: searchText,
            isPinned: false,
            blueQueryCount: 0,
            redQueryCount: 0,
            greenQueryCount: 0,
            magentaQueryCount: 0
        )
        isActiveStudyQuickStudy = true
        activeStudyStack = synthetic
    }
}

private struct MainWindowQuerySearchShortcutHandler: NSViewRepresentable {
    let shortcutSettings: ShortcutSettings
    let onTriggered: () -> Void

    func makeNSView(context: Context) -> KeyHandlingView {
        let view = KeyHandlingView()
        view.shortcutSettings = shortcutSettings
        view.onTriggered = onTriggered
        return view
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        nsView.shortcutSettings = shortcutSettings
        nsView.onTriggered = onTriggered
    }

    final class KeyHandlingView: NSView {
        var shortcutSettings: ShortcutSettings?
        var onTriggered: (() -> Void)?

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

                if let binding = self.shortcutSettings?.binding(for: .openSearchQueries),
                   binding.matches(event) {
                    self.onTriggered?()
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

private struct TabPageView: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Graph Page



#Preview {
    ContentView(appDatabase: try! AppDatabase())
        .environmentObject(AppNavigationState())
}
