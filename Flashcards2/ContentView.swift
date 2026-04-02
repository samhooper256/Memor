//
//  ContentView.swift
//  Flashcards2
//
//  Created by Sam Hooper on 4/1/26.
//

import Combine
import SwiftUI

enum AppTab: Int, CaseIterable, Identifiable {
    case decks
    case collections
    case types
    case graph

    var id: Self { self }

    var title: String {
        switch self {
        case .decks:
            "Decks"
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
    @Published var selectedTab: AppTab = .decks

    func select(_ tab: AppTab) {
        selectedTab = tab
    }
}

struct ContentView: View {
    @EnvironmentObject private var navigationState: AppNavigationState

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            currentPage
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            }
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch navigationState.selectedTab {
        case .decks:
            TabPageView(title: AppTab.decks.title)
        case .collections:
            TabPageView(title: AppTab.collections.title)
        case .types:
            TabPageView(title: AppTab.types.title)
        case .graph:
            TabPageView(title: AppTab.graph.title)
        }
    }

    private func tabBackground(for tab: AppTab) -> some ShapeStyle {
        if tab == navigationState.selectedTab {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        } else {
            return AnyShapeStyle(.clear)
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

#Preview {
    ContentView()
        .environmentObject(AppNavigationState())
}
