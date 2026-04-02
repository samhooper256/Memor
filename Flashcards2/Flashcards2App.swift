//
//  Flashcards2App.swift
//  Flashcards2
//
//  Created by Sam Hooper on 4/1/26.
//

import SwiftUI

@main
struct Flashcards2App: App {
    @StateObject private var navigationState = AppNavigationState()
    private let appDatabase: AppDatabase

    init() {
        do {
            appDatabase = try AppDatabase()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(navigationState)
        }
        .commands {
            CommandMenu("Navigate") {
                Button(AppTab.decks.title) {
                    navigationState.select(.decks)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button(AppTab.collections.title) {
                    navigationState.select(.collections)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button(AppTab.types.title) {
                    navigationState.select(.types)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button(AppTab.graph.title) {
                    navigationState.select(.graph)
                }
                .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}
