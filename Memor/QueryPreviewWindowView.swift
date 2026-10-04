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
    /// The draft state the shown query was rendered with (`.none` for saved
    /// queries); kept so arrow-key office navigation follows the draft too.
    @State private var renderOverrides = QueryRenderOverrides.none
    @State private var historyStack: [(query: StudyQuery, html: String, overrides: QueryRenderOverrides)] = []
    @State private var isInternalNavigation = false
    /// True once the webview has committed a non-empty page this session.
    /// Gates the loading spinner: the webview is transparent until its first
    /// commit, so gating on renderedAnswerHTML alone would drop the spinner
    /// while the window is still visibly blank.
    @State private var hasCommittedContent = false
    /// Fresh on every Play Audio key press; QueryHTMLView plays the previewed page's first
    /// <audio> once per id (restarting from 0). Silencing on window close is the container's
    /// own job (it observes its window's willClose), not these resets'.
    @State private var playFirstAudioRequestID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            QueryPreviewHeaderBar(query: query)

            Group {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(24)
                } else {
                    let pointMapPayload = query?.kind == .pointMap ? query?.pointMapPayload : nil
                    let boundaryMapPayload = query?.kind == .boundaryMap ? query?.boundaryMapPayload : nil
                    let showsMap = pointMapPayload != nil || boundaryMapPayload != nil
                    let showsSource = !showsMap && developerState.isDeveloperModeEnabled && !renderedAnswerHTML.isEmpty
                    ZStack {
                        if !showsSource {
                            // Mounted while renderedAnswerHTML is still empty (the old
                            // gate was `!renderedAnswerHTML.isEmpty`), so WKWebView
                            // creation + WebContent-process attach overlap the DB fetch
                            // and HTML build instead of only starting after them. The
                            // superseded empty-page load is harmless: its cancellation
                            // is NSURLErrorCancelled, which the recovery machinery
                            // explicitly ignores.
                            //
                            // Also kept mounted — hidden, on a blank page — while a map
                            // query is previewed, so navigating map → HTML reuses the
                            // web view's WebContent process instead of spawning one
                            // (see StudyModeView.queryContent; `isObscured` hides the
                            // NSView itself, the SwiftUI modifiers are belt and braces).
                            QueryHTMLView(
                                html: renderedAnswerHTML,
                                disableUserInteraction: true,
                                onInstanceLinkActivated: navigateToInstance,
                                onQueryLinkActivated: navigateToQuery,
                                onContentCommitted: { hasCommittedContent = !$0.isEmpty },
                                isObscured: showsMap,
                                playFirstAudioRequestID: playFirstAudioRequestID
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay {
                                // The hidden web view's blank commit resets the flag during
                                // a map preview; don't leave a spinner animating under the map.
                                if !hasCommittedContent && !showsMap {
                                    ProgressView()
                                }
                            }
                            .opacity(showsMap ? 0 : 1)
                            .allowsHitTesting(!showsMap)
                            .accessibilityHidden(showsMap)
                        }

                        if let payload = pointMapPayload {
                            PointMapQueryView(payload: payload, revealName: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let payload = boundaryMapPayload {
                            BoundaryMapQueryView(payload: payload, revealName: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if showsSource {
                            ScrollView([.vertical, .horizontal]) {
                                Text(renderedAnswerHTML)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                onPlayAudio: handlePlayAudio,
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
                // Fresh open of a closed window: blank the (still-mounted) web
                // view first, then load after the blank state applies, so the
                // window can never appear showing the old query.
                query = nil
                renderOverrides = .none
                renderedAnswerHTML = ""
                errorMessage = nil
                hasCommittedContent = false
                playFirstAudioRequestID = nil
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
            renderOverrides = .none
            renderedAnswerHTML = ""
            errorMessage = nil
            historyStack = []
            isInternalNavigation = false
            hasCommittedContent = false
            playFirstAudioRequestID = nil
        }
    }

    private func loadPreview() {
        do {
            let query: StudyQuery
            let overrides: QueryRenderOverrides
            switch windowState.request {
            case .saved(let instanceID, let queryTypeID)?:
                query = if let queryTypeID {
                    try appDatabase.fetchQueryPreview(instanceID: instanceID, queryTypeID: queryTypeID)
                } else {
                    try appDatabase.fetchFirstQueryPreview(instanceID: instanceID)
                }
                overrides = .none
            case .draft(let snapshot, let target)?:
                // Instance-editor preview: built from the draft snapshot alone
                // (never the edited instance's saved row), both modes.
                let baseQuery: StudyQuery
                switch target {
                case .queryType(let queryTypeID):
                    baseQuery = try appDatabase.fetchQueryTypePreview(
                        typeID: snapshot.typeID,
                        queryTypeID: queryTypeID,
                        instanceID: snapshot.instanceID
                    )
                case .personBuiltin(let kind, let partnerIndex, let officeIndex):
                    guard let relations = snapshot.personRelations else {
                        self.query = nil
                        renderOverrides = .none
                        renderedAnswerHTML = ""
                        errorMessage = "Failed to load query preview."
                        return
                    }
                    baseQuery = try appDatabase.fetchPersonDraftPreview(
                        kind: kind,
                        relations: relations,
                        partnerIndex: partnerIndex,
                        officeIndex: officeIndex,
                        selfInstanceID: snapshot.instanceID,
                        fieldValuesByName: snapshot.fieldValuesByName
                    )
                }
                query = baseQuery.withFieldValues(snapshot.fieldValuesByName)
                overrides = snapshot.renderOverrides
            case nil:
                self.query = nil
                renderedAnswerHTML = ""
                errorMessage = "No query preview selected."
                return
            }

            self.query = query
            renderOverrides = overrides
            if query.kind == .pointMap || query.kind == .boundaryMap {
                renderedAnswerHTML = ""
            } else {
                renderedAnswerHTML = try buildRenderedAnswerHTML(
                    appDatabase: appDatabase,
                    query: query,
                    overrides: overrides
                )
            }
            errorMessage = nil
        } catch {
            self.query = nil
            renderOverrides = .none
            renderedAnswerHTML = ""
            errorMessage = "Failed to load query preview."
        }
    }

    private func goBack() {
        guard let previous = historyStack.popLast() else { return }
        query = previous.query
        renderedAnswerHTML = previous.html
        renderOverrides = previous.overrides
        errorMessage = nil
    }

    private func pushHistory() {
        if let query {
            historyStack.append((query: query, html: renderedAnswerHTML, overrides: renderOverrides))
        }
    }

    private func navigateToInstance(_ instanceID: Int64) {
        pushHistory()
        isInternalNavigation = true
        windowState.requestOpenFirstQuery(instanceID: instanceID)
    }

    private func navigateToQuery(_ instanceID: Int64, _ queryTypeID: Int64) {
        pushHistory()
        isInternalNavigation = true
        windowState.requestOpen(instanceID: instanceID, queryTypeID: queryTypeID)
    }

    /// Edit key (E): open the Edit Instance window for the previewed instance.
    /// Does nothing if that window is already open (so an in-progress edit isn't
    /// clobbered).
    private func handleEdit() {
        // An Add-mode draft preview has no persisted instance to edit.
        guard let query, let instanceID = query.persistedInstanceID, !isEditInstanceWindowOpen() else { return }
        let autoEditPointID: Int64? = query.kind == .pointMap ? query.pointMapPayload?.pointID : nil
        editInstanceWindowState.requestOpen(instanceID: instanceID, autoEditPointID: autoEditPointID)
        openWindow(id: "edit-instance")
    }

    /// Play Audio key (A): restart and play the first <audio> on the previewed page. No-op for
    /// the map branch (the web view stays mounted but on a blank page) and for the error and
    /// developer-mode raw-HTML branches (no web view at all) — hence the .standard gate.
    private func handlePlayAudio() {
        guard let query, query.kind == .standard, !renderedAnswerHTML.isEmpty else { return }
        playFirstAudioRequestID = UUID()
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
            // No authored data-shortcut for this key: fall back to office
            // succession navigation (← predecessor, → successor).
            guard let neighborID = resolveOfficeSuccessionShortcut(
                key, query: query, appDatabase: appDatabase, draftOffices: renderOverrides.personOffices
            ) else { return false }
            navigateToInstance(neighborID)
            return true
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
    let onPlayAudio: () -> Void
    let onArrowLinkShortcut: (LinkShortcutKey) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.shortcutSettings = shortcutSettings
        view.onBack = onBack
        view.onEdit = onEdit
        view.onPlayAudio = onPlayAudio
        view.onArrowLinkShortcut = onArrowLinkShortcut
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.shortcutSettings = shortcutSettings
        nsView.onBack = onBack
        nsView.onEdit = onEdit
        nsView.onPlayAudio = onPlayAudio
        nsView.onArrowLinkShortcut = onArrowLinkShortcut
    }

    final class KeyView: NSView {
        var shortcutSettings: ShortcutSettings?
        var onBack: (() -> Void)?
        var onEdit: (() -> Void)?
        var onPlayAudio: (() -> Void)?
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
                // Play Audio key (A) -> restart and play the first <audio> on the page. This
                // monitor has no isARepeat pass like Study's, so swallow auto-repeats inline —
                // a held key would otherwise restart the track many times a second.
                if self.shortcutSettings?.binding(for: .studyPlayAudio).matches(event) == true {
                    if !event.isARepeat {
                        self.onPlayAudio?()
                    }
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
