//
//  MemorApp.swift
//  Memor
//
//  Created by Sam Hooper on 4/1/26.
//

import Combine
import SwiftUI

@MainActor
final class QuickStudyState: ObservableObject {
    @Published var pendingSearch: String?

    func request(searchText: String) {
        pendingSearch = searchText
    }
}

/// Study-mode state shared with the menu bar: which type the showing instance
/// belongs to (nil when not studying, or on built-in map queries, which have no
/// type detail page), and an "Edit Type" request flowing menu → StudyModeView.
final class StudyModeState: ObservableObject {
    @Published var currentTypeID: Int64?
    @Published private(set) var editTypeRequestNonce = UUID()

    func requestEditType() {
        editTypeRequestNonce = UUID()
    }
}

@main
struct MemorApp: App {
    @StateObject private var navigationState = AppNavigationState()
    @StateObject private var addInstanceWindowState = AddInstanceWindowState()
    @StateObject private var editInstanceWindowState = EditInstanceWindowState()
    @StateObject private var queryPreviewWindowState = QueryPreviewWindowState()
    @StateObject private var searchWindowState = SearchWindowState()
    @StateObject private var changeTypeWindowState = ChangeTypeWindowState()
    @StateObject private var stacksPageState = StacksPageState()
    @StateObject private var manageBoundariesWindowState = ManageBoundariesWindowState()
    @StateObject private var manageOfficesWindowState = ManageOfficesWindowState()
    @StateObject private var stackStatsWindowState = StackStatsWindowState()
    @StateObject private var quickStudyState = QuickStudyState()
    @StateObject private var studyModeState = StudyModeState()
    @StateObject private var shortcutSettings = ShortcutSettings.shared
    @StateObject private var timeZoneSettings = TimeZoneSettings.shared
    @StateObject private var developerState = DeveloperState.shared
    @State private var hasPerformedInitialStacksRefresh = false
    @Environment(\.openWindow) private var openWindow
    private let appDatabase: AppDatabase
    private let mcpServer: MemorMCPServer

    init() {
        registerSubstitutionKillDefaults()
        do {
            appDatabase = try AppDatabase()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
        mcpServer = MemorMCPServer(appDatabase: appDatabase)
        mcpServer.start()
    }

    var body: some Scene {
        WindowGroup("Memor") {
            ContentView(appDatabase: appDatabase)
                .environmentObject(navigationState)
                .environmentObject(addInstanceWindowState)
                .environmentObject(editInstanceWindowState)
                .environmentObject(queryPreviewWindowState)
                .environmentObject(searchWindowState)
                .environmentObject(stacksPageState)
                .environmentObject(stackStatsWindowState)
                .environmentObject(quickStudyState)
                .environmentObject(studyModeState)
                .environmentObject(shortcutSettings)
                .environmentObject(timeZoneSettings)
                // The Type detail page's "Edit Offices" button lives in the
                // main window, so its window state flows through here too.
                .environmentObject(manageOfficesWindowState)
                .task {
                    guard !hasPerformedInitialStacksRefresh else { return }
                    hasPerformedInitialStacksRefresh = true

                    do {
                        try await stacksPageState.refresh(appDatabase: appDatabase)
                    } catch {
                        print("Failed to refresh stacks on launch: \(error)")
                    }
                }
        }

        Window("Add Instance", id: "add-instance") {
            AddInstanceWindowView(appDatabase: appDatabase)
                .environmentObject(addInstanceWindowState)
                .environmentObject(queryPreviewWindowState)
                .environmentObject(shortcutSettings)
        }

        Window("Edit Instance", id: "edit-instance") {
            EditInstanceWindowView(appDatabase: appDatabase)
                .environmentObject(editInstanceWindowState)
                .environmentObject(queryPreviewWindowState)
                .environmentObject(shortcutSettings)
        }

        Window("Query Preview", id: "query-preview") {
            QueryPreviewWindowView(appDatabase: appDatabase)
                .environmentObject(queryPreviewWindowState)
                .environmentObject(editInstanceWindowState)
                .environmentObject(shortcutSettings)
        }

        Window("Search", id: "search") {
            SearchWindowView(appDatabase: appDatabase)
                .environmentObject(searchWindowState)
                .environmentObject(editInstanceWindowState)
                .environmentObject(addInstanceWindowState)
                .environmentObject(queryPreviewWindowState)
                .environmentObject(stacksPageState)
                .environmentObject(quickStudyState)
                .environmentObject(shortcutSettings)
                .environmentObject(changeTypeWindowState)
        }

        Window("Change Type", id: "change-type") {
            ChangeTypeWindowView(appDatabase: appDatabase)
                .environmentObject(changeTypeWindowState)
        }
        .windowResizability(.contentSize)

        Window("Instance Search Help", id: "instance-search-help") {
            InstanceSearchHelpWindowView()
        }
        .windowResizability(.contentSize)

        Window("Query Search Help", id: "query-search-help") {
            QuerySearchHelpWindowView()
        }
        .windowResizability(.contentSize)

        Window("Point & Boundary Search Help", id: "map-element-search-help") {
            MapElementSearchHelpWindowView()
        }
        .windowResizability(.contentSize)

        Window("Edit Global HTML", id: "global-html-editor") {
            GlobalCodeEditorWindowView(
                appDatabase: appDatabase,
                kind: .html
            )
            .environmentObject(shortcutSettings)
        }

        Window("Edit Global CSS", id: "global-css-editor") {
            GlobalCodeEditorWindowView(
                appDatabase: appDatabase,
                kind: .css
            )
            .environmentObject(shortcutSettings)
        }

        Window("Manage Boundaries", id: "manage-boundaries") {
            ManageBoundariesWindowView(appDatabase: appDatabase)
                .environmentObject(manageBoundariesWindowState)
                .environmentObject(shortcutSettings)
        }

        Window("Manage Offices", id: "manage-offices") {
            ManageOfficesWindowView(appDatabase: appDatabase)
                .environmentObject(manageOfficesWindowState)
                .environmentObject(shortcutSettings)
        }

        Window("Stats", id: "stack-stats") {
            StackStatsWindowView(appDatabase: appDatabase)
                .environmentObject(stackStatsWindowState)
        }

        Window("Settings", id: "settings") {
            SettingsWindowView(shortcuts: shortcutSettings, appDatabase: appDatabase)
                .environmentObject(shortcutSettings)
        }
        .commands {
            CommandMenu("Navigate") {
                Button(AppTab.stacks.title) {
                    navigationState.select(.stacks)
                }
                .shortcut(.goToStacksTab, settings: shortcutSettings)

                Button(AppTab.instances.title) {
                    navigationState.select(.instances)
                }
                .shortcut(.goToInstancesTab, settings: shortcutSettings)

                Button(AppTab.collections.title) {
                    navigationState.select(.collections)
                }
                .shortcut(.goToCollectionsTab, settings: shortcutSettings)

                Button(AppTab.types.title) {
                    navigationState.select(.types)
                }
                .shortcut(.goToTypesTab, settings: shortcutSettings)

                Button(AppTab.graph.title) {
                    navigationState.select(.graph)
                }
                .shortcut(.goToGraphTab, settings: shortcutSettings)
            }

            CommandMenu("Instances") {
                Button("Add Instance") {
                    addInstanceWindowState.requestOpen()
                    openWindow(id: "add-instance")
                }
                .shortcut(.openAddInstance, settings: shortcutSettings)

                Button("Search") {
                    searchWindowState.requestOpen()
                    openWindow(id: "search")
                }
                .shortcut(.openSearchInstances, settings: shortcutSettings)

                Button("Edit Type") {
                    studyModeState.requestEditType()
                }
                .shortcut(.studyEditType, settings: shortcutSettings)
                .disabled(studyModeState.currentTypeID == nil)

                Divider()

                Button("Manage Boundaries…") {
                    manageBoundariesWindowState.requestOpen()
                    openWindow(id: "manage-boundaries")
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openWindow(id: "settings")
                }
                .shortcut(.openSettings, settings: shortcutSettings)
            }

            CommandMenu("Developer") {
                Button(developerState.isDeveloperModeEnabled
                       ? "Turn Off Developer Mode"
                       : "Turn On Developer Mode") {
                    developerState.toggleDeveloperMode()
                }
                .shortcut(.toggleDeveloperMode, settings: shortcutSettings)
                .disabled(!developerState.allowDeveloperModeAccess)
            }
        }
    }
}
