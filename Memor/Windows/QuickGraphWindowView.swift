//
//  QuickGraphWindowView.swift
//  Memor
//
//  Study mode's "Quick Graph": a lightweight window showing just the graph
//  panel — the connected component holding the current instance, drawn with
//  a preset's settings or the defaults. No search box, field filter or
//  settings; pan/zoom and ⌘I (info mode) work as on the Graph tab; Escape
//  closes. Opened from the shown query's context menu or ⌘G.
//

import AppKit
import Combine
import SwiftUI

/// What the window should show, set by Study mode before it opens the
/// window. A fresh value each time, so a repeat for the same instance and
/// option reloads.
struct QuickGraphRequest: Equatable {
    let id = UUID()
    let instanceID: Int64
    let selection: QuickGraphSelection
}

final class QuickGraphWindowState: ObservableObject {
    @Published var request: QuickGraphRequest?

    func requestOpen(instanceID: Int64, selection: QuickGraphSelection) {
        request = QuickGraphRequest(instanceID: instanceID, selection: selection)
    }
}

struct QuickGraphWindowView: View {
    let appDatabase: AppDatabase

    @EnvironmentObject private var windowState: QuickGraphWindowState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    @EnvironmentObject private var editInstanceWindowState: EditInstanceWindowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var graphSettings = GraphSettingsStore.shared

    @State private var settingsName = ""
    @State private var layoutMode: GraphLayoutMode = .tree
    @State private var colors = QuickGraphSettings.defaults.colors
    @State private var graphData: GraphData?
    @State private var markups: [Int64: GraphNodeMarkup] = [:]
    @State private var message: String?
    @State private var layoutProgress: Double?
    @State private var loadedRequestID: UUID?

    var body: some View {
        graphArea
            .frame(minWidth: 480, minHeight: 360)
            .navigationTitle(settingsName.isEmpty ? "Quick Graph" : "Quick Graph — \(settingsName)")
            .background {
                // Info mode, as on the Graph tab (the shared session flag).
                ShortcutActionsKeyHandler(
                    shortcutSettings: shortcutSettings,
                    handlers: [(.graphToggleInfoMode, { graphSettings.isInfoModeEnabled.toggle() })]
                )
            }
            .onExitCommand { dismiss() }
            .background(
                // Reliable Escape-to-close even while the web view is focused.
                Button("", action: { dismiss() })
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            )
            .onReceive(windowState.$request) { request in
                // The publisher replays its value on subscription; the id
                // keeps a replay from reloading.
                guard let request, request.id != loadedRequestID else { return }
                loadedRequestID = request.id
                load(request)
            }
    }

    @ViewBuilder
    private var graphArea: some View {
        if let message {
            Text(message)
                .foregroundStyle(.secondary)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let graphData {
            GraphWebView(
                graphData: graphData,
                layoutMode: layoutMode,
                nodeColors: colors,
                markups: markups,
                infoMode: graphSettings.isInfoModeEnabled,
                findQuery: nil,
                onLayoutProgress: { progress in
                    layoutProgress = progress < 1 ? progress : nil
                },
                onEditInstance: { instanceID in
                    editInstanceWindowState.requestOpen(instanceID: instanceID)
                    openWindow(id: "edit-instance")
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if let layoutProgress {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Laying out… \(Int(layoutProgress * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Runs the option's search, keeps the component holding the instance,
    /// and resolves the option's markups against it.
    private func load(_ request: QuickGraphRequest) {
        let settings = graphSettings.quickGraphSettings(for: request.selection)
        settingsName = settings.name
        layoutMode = settings.layoutMode
        colors = settings.colors
        graphData = nil
        markups = [:]
        message = nil
        layoutProgress = nil
        do {
            let data = try appDatabase.fetchGraphData(query: settings.query, fieldFilter: settings.fieldFilter)
            guard let component = data.connectedComponent(containing: request.instanceID) else {
                message = request.selection == .default
                    ? "This instance has no node in the graph."
                    : "This instance isn't among the “\(settings.name)” preset's search results."
                return
            }
            markups = resolveGraphMarkups(settings.markups, for: component, appDatabase: appDatabase)
            layoutProgress = 0
            graphData = component
        } catch {
            message = error.localizedDescription
        }
    }
}
