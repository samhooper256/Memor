//
//  QueryPreviewWindowView.swift
//  Memor
//
//  Created by Sam Hooper on 4/10/26.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct QueryPreviewWindowView: View {
    @EnvironmentObject private var windowState: QueryPreviewWindowState
    @EnvironmentObject private var editInstanceWindowState: EditInstanceWindowState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let appDatabase: AppDatabase

    @State private var query: StudyQuery?
    @State private var renderedAnswerHTML = ""
    @State private var errorMessage: String?
    @State private var historyStack: [(query: StudyQuery, html: String)] = []
    @State private var isInternalNavigation = false

    var body: some View {
        VStack(spacing: 0) {
            QueryPreviewHeaderBar(query: query)

            Group {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(24)
                } else if let query, query.kind == .pointMap, let payload = query.pointMapPayload {
                    PointMapQueryView(payload: payload, revealName: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let query, query.kind == .boundaryMap, let payload = query.boundaryMapPayload {
                    BoundaryMapQueryView(payload: payload, revealName: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !renderedAnswerHTML.isEmpty {
                    QueryHTMLView(
                        html: renderedAnswerHTML,
                        disableUserInteraction: true,
                        onInstanceLinkActivated: navigateToInstance,
                        onQueryLinkActivated: navigateToQuery
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, minHeight: 500)
        .background {
            WindowKeyCommandHandler(
                onEscape: { dismiss() },
                onCommandReturn: nil,
                onCommandS: nil,
                onCommandI: nil,
                onCommandO: nil
            )
            QueryPreviewKeyHandler(
                shortcutSettings: shortcutSettings,
                onBack: goBack,
                onEdit: handleEdit,
                onArrowLinkShortcut: handleArrowLinkShortcut
            )
        }
        .task {
            historyStack = []
            await loadPreview()
        }
        .onChange(of: windowState.requestNonce) { _, _ in
            if !isInternalNavigation {
                historyStack = []
            }
            isInternalNavigation = false
            Task {
                await loadPreview()
            }
        }
        .onExitCommand {
            dismiss()
        }
    }

    @MainActor
    private func loadPreview() async {
        guard let instanceID = windowState.requestedInstanceID else {
            query = nil
            renderedAnswerHTML = ""
            errorMessage = "No query preview selected."
            return
        }

        do {
            let baseQuery = if let queryTypeID = windowState.requestedQueryTypeID {
                try appDatabase.fetchQueryPreview(instanceID: instanceID, queryTypeID: queryTypeID)
            } else {
                try appDatabase.fetchFirstQueryPreview(instanceID: instanceID)
            }
            let query: StudyQuery
            if let overrides = windowState.requestedFieldValuesByName {
                query = baseQuery.withFieldValues(overrides)
            } else {
                query = baseQuery
            }
            self.query = query
            if query.kind == .pointMap || query.kind == .boundaryMap {
                renderedAnswerHTML = ""
            } else {
                renderedAnswerHTML = try buildRenderedAnswerHTML(appDatabase: appDatabase, query: query)
            }
            errorMessage = nil
        } catch {
            self.query = nil
            renderedAnswerHTML = ""
            errorMessage = "Failed to load query preview."
        }
    }

    private func goBack() {
        guard let previous = historyStack.popLast() else { return }
        query = previous.query
        renderedAnswerHTML = previous.html
        errorMessage = nil
    }

    private func navigateToInstance(_ instanceID: Int64) {
        if let query {
            historyStack.append((query: query, html: renderedAnswerHTML))
        }
        isInternalNavigation = true
        windowState.requestOpenFirstQuery(instanceID: instanceID)
    }

    private func navigateToQuery(_ instanceID: Int64, _ queryTypeID: Int64) {
        if let query {
            historyStack.append((query: query, html: renderedAnswerHTML))
        }
        isInternalNavigation = true
        windowState.requestOpen(instanceID: instanceID, queryTypeID: queryTypeID)
    }

    /// Edit key (E): open the Edit Instance window for the previewed instance.
    /// Does nothing if that window is already open (so an in-progress edit isn't
    /// clobbered).
    private func handleEdit() {
        guard let query, !isEditInstanceWindowOpen() else { return }
        let autoEditPointID: Int64? = query.kind == .pointMap ? query.pointMapPayload?.pointID : nil
        editInstanceWindowState.requestOpen(instanceID: query.instanceID, autoEditPointID: autoEditPointID)
        openWindow(id: "edit-instance")
    }

    private func isEditInstanceWindowOpen() -> Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && (window.identifier?.rawValue == "edit-instance" || window.title == "Edit Instance")
        }
    }

    /// Plain left/right arrow -> instance link shortcuts. Returns true if the event was handled.
    private func handleArrowLinkShortcut(_ key: LinkShortcutKey) -> Bool {
        guard let query else { return false }
        switch resolveLinkShortcut(key, fieldValues: query.fieldValuesByName) {
        case .none:
            return false
        case .collision:
            presentLinkShortcutCollisionAlert(key)
            return true
        case .navigate(.instance(let instanceID)):
            navigateToInstance(instanceID)
            return true
        case .navigate(.query(let instanceID, let queryTypeID)):
            navigateToQuery(instanceID, queryTypeID)
            return true
        }
    }
}

private struct QueryPreviewKeyHandler: NSViewRepresentable {
    let shortcutSettings: ShortcutSettings
    let onBack: () -> Void
    let onEdit: () -> Void
    let onArrowLinkShortcut: (LinkShortcutKey) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.shortcutSettings = shortcutSettings
        view.onBack = onBack
        view.onEdit = onEdit
        view.onArrowLinkShortcut = onArrowLinkShortcut
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.shortcutSettings = shortcutSettings
        nsView.onBack = onBack
        nsView.onEdit = onEdit
        nsView.onArrowLinkShortcut = onArrowLinkShortcut
    }

    final class KeyView: NSView {
        var shortcutSettings: ShortcutSettings?
        var onBack: (() -> Void)?
        var onEdit: (() -> Void)?
        var onArrowLinkShortcut: ((LinkShortcutKey) -> Bool)?

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
                    .subtracting([.numericPad, .function])
                // ⌘← navigates back through link history.
                if flags == .command, event.keyCode == 123 {
                    self.onBack?()
                    return nil
                }
                // Edit key (E) -> open the Edit Instance window.
                if self.shortcutSettings?.binding(for: .studyEditInstance).matches(event) == true {
                    self.onEdit?()
                    return nil
                }
                // Plain left/right arrow -> instance link shortcuts.
                if flags.isEmpty, let key = LinkShortcutKey.fromKeyCode(event.keyCode),
                   self.onArrowLinkShortcut?(key) == true {
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

private struct QueryPreviewHeaderBar: View {
    let query: StudyQuery?

    var body: some View {
        HStack(spacing: 0) {
            if let query {
                Text(query.typeName)
                    .foregroundStyle(.blue)

                Text(":")
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 4)

                Text(query.queryTypeName)
                    .foregroundStyle(Color(nsColor: .magenta))
            }

            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
