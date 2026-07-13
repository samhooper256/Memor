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
    @ObservedObject private var developerState = DeveloperState.shared
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
                    if developerState.isDeveloperModeEnabled {
                        ScrollView([.vertical, .horizontal]) {
                            Text(renderedAnswerHTML)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        QueryHTMLView(
                            html: renderedAnswerHTML,
                            disableUserInteraction: true,
                            onInstanceLinkActivated: navigateToInstance,
                            onQueryLinkActivated: navigateToQuery
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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
            loadPreview()
        }
        .onChange(of: windowState.requestNonce) { _, _ in
            if !isInternalNavigation {
                historyStack = []
            }
            isInternalNavigation = false
            if isPreviewWindowVisible() {
                // Window already open: load synchronously so the new query's state
                // lands in the same update cycle as the request — deferring to a
                // Task lets an intermediate render (and any further navigation)
                // observe the previous query's state.
                loadPreview()
            } else {
                // Fresh open of a closed window: unmount the previous session's
                // web view first, then load after the blank state applies, so the
                // window can never appear showing the old query.
                query = nil
                renderedAnswerHTML = ""
                errorMessage = nil
                Task { loadPreview() }
            }
        }
        .onExitCommand {
            dismiss()
        }
        .onDisappear {
            // A Window scene preserves @State across close/reopen; without this
            // the reopened window shows the previous session's query until the
            // new one commits.
            query = nil
            renderedAnswerHTML = ""
            errorMessage = nil
            historyStack = []
            isInternalNavigation = false
        }
    }

    private func loadPreview() {
        do {
            let baseQuery: StudyQuery
            if let personKind = windowState.requestedPersonKind,
               let instanceID = windowState.requestedInstanceID {
                // Built-in Person query: computed HTML.
                baseQuery = try appDatabase.fetchPersonQueryPreview(
                    instanceID: instanceID,
                    kind: personKind,
                    partnershipID: windowState.requestedPersonPartnershipID,
                    officeID: windowState.requestedPersonOfficeID
                )
            } else if let typeID = windowState.requestedTypeID,
               let queryTypeID = windowState.requestedQueryTypeID {
                // Draft preview from the Add Instance window: no instance row yet.
                baseQuery = try appDatabase.fetchQueryTypePreview(
                    typeID: typeID,
                    queryTypeID: queryTypeID
                )
            } else if let instanceID = windowState.requestedInstanceID {
                baseQuery = if let queryTypeID = windowState.requestedQueryTypeID {
                    try appDatabase.fetchQueryPreview(instanceID: instanceID, queryTypeID: queryTypeID)
                } else {
                    try appDatabase.fetchFirstQueryPreview(instanceID: instanceID)
                }
            } else {
                query = nil
                renderedAnswerHTML = ""
                errorMessage = "No query preview selected."
                return
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
        // A draft preview (from the Add Instance window) has no persisted instance
        // to edit — its instanceID is 0.
        guard let query, query.instanceID != 0, !isEditInstanceWindowOpen() else { return }
        let autoEditPointID: Int64? = query.kind == .pointMap ? query.pointMapPayload?.pointID : nil
        editInstanceWindowState.requestOpen(instanceID: query.instanceID, autoEditPointID: autoEditPointID)
        openWindow(id: "edit-instance")
    }

    private func isEditInstanceWindowOpen() -> Bool {
        NSApp.windows.contains { window in
            // A minimized window still holds the editor's (possibly unsaved)
            // content, so count it as open alongside visible windows.
            (window.isVisible || window.isMiniaturized)
                && (window.identifier?.rawValue == "edit-instance" || window.title == "Edit Instance")
        }
    }

    private func isPreviewWindowVisible() -> Bool {
        NSApp.windows.contains { window in
            (window.isVisible || window.isMiniaturized)
                && (window.identifier?.rawValue == "query-preview" || window.title == "Query Preview")
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
