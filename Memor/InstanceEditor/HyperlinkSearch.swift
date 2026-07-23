//
//  HyperlinkSearch.swift
//  Memor
//
//  Popup for inserting <a href="id:...">…</a> hyperlinks over selected text
//  inside the instance editor's rich-text fields.
//

import AppKit
import Combine
import SwiftUI

final class HyperlinkSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum HyperlinkSearchMode: Hashable {
    case instances
    case queries
    case pointsAndBoundaries

    var next: HyperlinkSearchMode {
        switch self {
        case .instances: return .queries
        case .queries: return .pointsAndBoundaries
        case .pointsAndBoundaries: return .instances
        }
    }
}

// The popup has two pages: the default "Link" page (search + 3 search modes) and the
// "Pre-Filters" page (⌘P) for picking the saved search string AND-ed into every search.
enum HyperlinkSearchPage: Hashable {
    case link
    case preFilters
}

@MainActor
final class HyperlinkSearchController: ObservableObject {
    private weak var panel: HyperlinkSearchPanel?
    private var popupState: HyperlinkSearchPopupState?

    func present(appDatabase: AppDatabase, from textView: InstanceTextView.CommandAwareTextView) {
        // A zero-length selection (bare caret) is allowed: the popup opens
        // with a blank search box and the chosen link is inserted empty, with
        // the caret placed between the tags (see insertHyperlink).
        let selectedRange = textView.selectedRange()
        guard let stringRange = Range(selectedRange, in: textView.string) else {
            NSSound.beep()
            return
        }

        let selectedText = String(textView.string[stringRange])
        let initialQuery = selectedText.isEmpty ? "" : makeInitialQuery(for: selectedText)
        let anchorRect = textView.firstRect(forCharacterRange: selectedRange, actualRange: nil)
        let selectionContext = HyperlinkSelectionContext(
            textView: textView,
            selectedRange: selectedRange,
            selectedText: selectedText
        )

        close()

        let popupState = HyperlinkSearchPopupState(
            appDatabase: appDatabase,
            initialQuery: initialQuery,
            onSelectInstance: { [weak self] instanceID in
                self?.insertHyperlink(instanceID: instanceID)
            },
            onSelectQuery: { [weak self] instanceID, queryTypeID in
                self?.insertHyperlink(instanceID: instanceID, queryTypeID: queryTypeID)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        self.popupState = popupState

        let panel = HyperlinkSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = popupState
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: HyperlinkSearchPopupView(state: popupState))
        panel.setFrameTopLeftPoint(NSPoint(x: anchorRect.minX, y: anchorRect.minY))
        panel.orderFront(nil)
        panel.makeKey()

        popupState.selectionContext = selectionContext
        popupState.panel = panel
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        popupState = nil
    }

    private func insertHyperlink(instanceID: Int64) {
        insertHyperlink(href: "id:\(instanceID)")
    }

    private func insertHyperlink(instanceID: Int64, queryTypeID: Int64) {
        insertHyperlink(href: "id:\(instanceID):\(queryTypeID)")
    }

    private func insertHyperlink(href: String) {
        guard let selectionContext = popupState?.selectionContext,
              let textView = selectionContext.textView else {
            close()
            return
        }

        let openingTag = #"<a href="\#(href)">"#
        let hyperlink = openingTag + selectionContext.selectedText + "</a>"
        let selectedRange = selectionContext.selectedRange
        guard NSMaxRange(selectedRange) <= textView.string.utf16.count else {
            close()
            return
        }

        close()
        textView.window?.makeFirstResponder(textView)

        // Empty link text (⌘K at a bare caret): land the caret between the
        // tags so the user types the text next; otherwise after the </a>.
        let caretLocation = selectionContext.selectedText.isEmpty
            ? selectedRange.location + (openingTag as NSString).length
            : selectedRange.location + (hyperlink as NSString).length
        textView.insertText(hyperlink, replacementRange: selectedRange)
        textView.setSelectedRange(NSRange(location: caretLocation, length: 0))

        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            textView.setSelectedRange(NSRange(location: caretLocation, length: 0))
        }
    }

    private func makeInitialQuery(for selectedText: String) -> String {
        let sanitizedText = selectedText.replacingOccurrences(of: "\"", with: "\\\"")
        return #""literal:\#(sanitizedText)""#
    }
}

@MainActor
final class HyperlinkSearchPopupState: NSObject, ObservableObject, NSWindowDelegate {
    static var lastUsedMode: HyperlinkSearchMode = .instances
    // Persists the active pre-filter across reopening the popup within a launch (mirrors
    // lastUsedMode); not persisted across launches, so it defaults to nil = "(no pre-filter)".
    static var lastActivePreFilter: String?

    @Published var searchQuery: String
    @Published var mode: HyperlinkSearchMode = HyperlinkSearchPopupState.lastUsedMode
    @Published private(set) var instanceResults: [InstanceSearchResult] = []
    @Published private(set) var queryResults: [QuerySearchResult] = []
    @Published private(set) var mapElementResults: [MapElementSearchResult] = []
    @Published private(set) var totalResultCount = 0
    @Published private(set) var errorMessage: String?
    @Published var highlightedID: String?
    @Published var isSearchFieldFocused = false
    @Published var searchFieldFocusRequest = UUID()

    // Page + pre-filter state.
    @Published var page: HyperlinkSearchPage = .link
    @Published var activePreFilter: String? = HyperlinkSearchPopupState.lastActivePreFilter
    @Published var preFilterSearchQuery = ""
    @Published var preFilterHighlightedID: String?
    @Published var preFilterFocusRequest = UUID()

    let appDatabase: AppDatabase
    let onSelectInstance: (Int64) -> Void
    let onSelectQuery: (Int64, Int64) -> Void
    let onClose: () -> Void

    weak var panel: NSPanel?
    var selectionContext: HyperlinkSelectionContext?
    private var searchTask: Task<Void, Never>?

    init(
        appDatabase: AppDatabase,
        initialQuery: String,
        onSelectInstance: @escaping (Int64) -> Void,
        onSelectQuery: @escaping (Int64, Int64) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.appDatabase = appDatabase
        self.searchQuery = initialQuery
        self.onSelectInstance = onSelectInstance
        self.onSelectQuery = onSelectQuery
        self.onClose = onClose
        super.init()
    }

    private var currentResultIDs: [String] {
        switch mode {
        case .instances: return instanceResults.map { String($0.id) }
        case .queries: return queryResults.map(\.id)
        case .pointsAndBoundaries: return mapElementResults.map(\.id)
        }
    }

    var currentResultsIsEmpty: Bool {
        switch mode {
        case .instances: return instanceResults.isEmpty
        case .queries: return queryResults.isEmpty
        case .pointsAndBoundaries: return mapElementResults.isEmpty
        }
    }

    // The query actually run: the active pre-filter AND-ed with the user's input. Each side
    // is wrapped in parens so a pre-filter (or input) containing a top-level OR doesn't
    // mis-associate against the other side (space = AND, OR is explicit in the grammar).
    private func effectiveQuery() -> String {
        let pf = (activePreFilter ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let user = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (pf.isEmpty, user.isEmpty) {
        case (true, _): return searchQuery
        case (false, true): return "(\(pf))"
        case (false, false): return "(\(pf)) (\(user))"
        }
    }

    func performSearch() {
        let query = effectiveQuery()
        let activeMode = mode
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch activeMode {
                case .instances:
                    let sections = try appDatabase.searchInstances(query: query)
                    let all = sections.flatMap(\.instances)
                    totalResultCount = all.count
                    instanceResults = Array(all.prefix(100))
                    queryResults = []
                    mapElementResults = []
                case .queries:
                    let sections = try appDatabase.searchQueries(query: query)
                    let all = sections.flatMap(\.queries)
                    totalResultCount = all.count
                    queryResults = Array(all.prefix(100))
                    instanceResults = []
                    mapElementResults = []
                case .pointsAndBoundaries:
                    let sections = try appDatabase.searchMapElements(query: query)
                    let all = sections.flatMap(\.elements)
                    totalResultCount = all.count
                    mapElementResults = Array(all.prefix(100))
                    instanceResults = []
                    queryResults = []
                }
                let ids = currentResultIDs
                if let highlightedID, ids.contains(highlightedID) {
                    self.highlightedID = highlightedID
                } else {
                    highlightedID = ids.first
                }
                if isSearchFieldFocused {
                    searchFieldFocusRequest = UUID()
                }
                errorMessage = nil
            } catch {
                instanceResults = []
                queryResults = []
                mapElementResults = []
                totalResultCount = 0
                highlightedID = nil
                errorMessage = "Invalid search query."
            }
        }
    }

    func setMode(_ newMode: HyperlinkSearchMode) {
        guard mode != newMode else { return }
        mode = newMode
        Self.lastUsedMode = newMode
        highlightedID = nil
        performSearch()
    }

    func toggleMode() {
        setMode(mode.next)
    }

    func select(instanceID: Int64) {
        onSelectInstance(instanceID)
    }

    func select(instanceID: Int64, queryTypeID: Int64) {
        onSelectQuery(instanceID, queryTypeID)
    }

    func close() {
        onClose()
    }

    var resultCountText: String {
        if totalResultCount >= 100 {
            return "100+ results"
        }
        return "\(totalResultCount) result" + (totalResultCount == 1 ? "" : "s")
    }

    func focusSearchField(clearHighlight: Bool) {
        if clearHighlight {
            highlightedID = nil
        }
        isSearchFieldFocused = true
        searchFieldFocusRequest = UUID()
    }

    func searchFieldDidReceiveManualFocus() {
        highlightedID = nil
        isSearchFieldFocused = true
    }

    func searchFieldDidBecomeFocused() {
        isSearchFieldFocused = true
    }

    func moveSelectionDown() {
        let ids = currentResultIDs
        guard !ids.isEmpty else { return }
        if let highlightedID, let currentIndex = ids.firstIndex(of: highlightedID) {
            // Wrap to the top when moving down past the last result, mirroring
            // moveSelectionUp's wrap from the top to the bottom.
            let nextIndex = currentIndex + 1
            self.highlightedID = nextIndex < ids.count ? ids[nextIndex] : ids.first
        } else {
            highlightedID = ids.first
        }
    }

    @discardableResult
    func moveSelectionUp() -> Bool {
        let ids = currentResultIDs
        guard !ids.isEmpty else { return true }
        if let highlightedID,
           let currentIndex = ids.firstIndex(of: highlightedID),
           currentIndex > 0 {
            self.highlightedID = ids[currentIndex - 1]
            return false
        }
        self.highlightedID = ids.last
        return false
    }

    func chooseHighlightedResult() {
        guard let highlightedID else { return }
        switch mode {
        case .instances:
            if let instanceID = Int64(highlightedID) {
                select(instanceID: instanceID)
            }
        case .queries:
            // Query ids are "instanceID:queryTypeID:f|r"; ignore the direction —
            // a point/boundary query links to its point/boundary.
            let parts = highlightedID.split(separator: ":")
            guard parts.count >= 2,
                  let instanceID = Int64(parts[0]),
                  let queryTypeID = Int64(parts[1]) else { return }
            select(instanceID: instanceID, queryTypeID: queryTypeID)
        case .pointsAndBoundaries:
            // Map-element ids are "instanceID:elementID:kind"; link to the
            // point/boundary (elementID).
            let parts = highlightedID.split(separator: ":")
            guard parts.count >= 2,
                  let instanceID = Int64(parts[0]),
                  let elementID = Int64(parts[1]) else { return }
            select(instanceID: instanceID, queryTypeID: elementID)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - Pre-Filters page

    func filteredPreFilters() -> [String] {
        let needle = preFilterSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return PreFilterStore.shared.preFilters }
        return PreFilterStore.shared.preFilters.filter {
            $0.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    // Row IDs for the Pre-Filters list: "none" (clear), "pf:<index-in-filtered>", "add".
    func preFilterRowIDs() -> [String] {
        ["none"] + filteredPreFilters().indices.map { "pf:\($0)" } + ["add"]
    }

    func switchToPreFiltersPage() {
        page = .preFilters
        preFilterSearchQuery = ""
        preFilterHighlightedID = preFilterRowIDs().first
        preFilterFocusRequest = UUID()
    }

    func returnToLinkPage() {
        page = .link
        performSearch()
        focusSearchField(clearHighlight: false)
    }

    func moveSelectionDownPreFilters() {
        let ids = preFilterRowIDs()
        guard !ids.isEmpty else { return }
        if let preFilterHighlightedID, let currentIndex = ids.firstIndex(of: preFilterHighlightedID) {
            let nextIndex = currentIndex + 1
            self.preFilterHighlightedID = nextIndex < ids.count ? ids[nextIndex] : ids.first
        } else {
            preFilterHighlightedID = ids.first
        }
    }

    func moveSelectionUpPreFilters() {
        let ids = preFilterRowIDs()
        guard !ids.isEmpty else { return }
        if let preFilterHighlightedID,
           let currentIndex = ids.firstIndex(of: preFilterHighlightedID),
           currentIndex > 0 {
            self.preFilterHighlightedID = ids[currentIndex - 1]
        } else {
            self.preFilterHighlightedID = ids.last
        }
    }

    func selectPreFilter(rowID: String) {
        let filtered = filteredPreFilters()
        switch rowID {
        case "none":
            activePreFilter = nil
        case "add":
            let trimmed = preFilterSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            PreFilterStore.shared.add(trimmed)
            activePreFilter = trimmed
        default:
            guard rowID.hasPrefix("pf:"),
                  let index = Int(rowID.dropFirst(3)),
                  index < filtered.count else { return }
            activePreFilter = filtered[index]
        }
        Self.lastActivePreFilter = activePreFilter
        returnToLinkPage()
    }

    func chooseHighlightedPreFilter() {
        guard let preFilterHighlightedID else { return }
        selectPreFilter(rowID: preFilterHighlightedID)
    }

    // Returns true if a real pre-filter row was highlighted and removed.
    @discardableResult
    func deleteHighlightedPreFilter() -> Bool {
        guard let highlighted = preFilterHighlightedID, highlighted.hasPrefix("pf:"),
              let index = Int(highlighted.dropFirst(3)) else { return false }
        let filtered = filteredPreFilters()
        guard index < filtered.count else { return false }
        PreFilterStore.shared.remove(filtered[index])
        // Re-clamp the highlight to a valid neighbor in the now-shorter list.
        let ids = preFilterRowIDs()
        if ids.contains(highlighted) {
            preFilterHighlightedID = highlighted
        } else {
            let fallbackIndex = min(index, filteredPreFilters().count - 1)
            preFilterHighlightedID = fallbackIndex >= 0 ? "pf:\(fallbackIndex)" : "none"
        }
        return true
    }
}

struct HyperlinkSelectionContext {
    weak var textView: NSTextView?
    let selectedRange: NSRange
    let selectedText: String
}

struct HyperlinkSearchPopupView: View {
    @ObservedObject var state: HyperlinkSearchPopupState
    // Observed so the Pre-Filters list re-renders live when entries are added/removed.
    @ObservedObject private var preFilterStore = PreFilterStore.shared

    var body: some View {
        Group {
            switch state.page {
            case .link:
                linkPage
            case .preFilters:
                preFiltersPage
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background {
            WindowKeyCommandHandler(
                // Escape on the Pre-Filters page returns to the Link page; on the Link
                // page it closes the popup.
                onEscape: { state.page == .preFilters ? state.returnToLinkPage() : state.close() },
                onCommandReturn: nil,
                onCommandS: nil,
                onCommandI: nil,
                onCommandO: nil
            )
        }
        .onAppear {
            state.performSearch()
            state.focusSearchField(clearHighlight: false)
        }
        .onChange(of: state.searchQuery) { _, _ in
            state.performSearch()
        }
    }

    private var linkPage: some View {
        VStack(spacing: 0) {
            HyperlinkSearchTextField(
                text: $state.searchQuery,
                focusRequest: state.searchFieldFocusRequest,
                canMoveDownToResults: { !state.currentResultsIsEmpty },
                onMoveDown: state.moveSelectionDown,
                onMoveUp: state.moveSelectionUp,
                onSubmit: state.chooseHighlightedResult,
                onToggleMode: state.toggleMode,
                onSwitchToPreFilters: state.switchToPreFiltersPage,
                onManualFocus: state.searchFieldDidReceiveManualFocus,
                onFocus: state.searchFieldDidBecomeFocused
            )
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))

            // Active pre-filter status row (⌘P to change).
            HStack(spacing: 0) {
                Text(state.activePreFilter ?? "(no pre-filter)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(state.activePreFilter == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Color(nsColor: .windowBackgroundColor))

            HStack(spacing: 6) {
                Text("Searching:")
                    .font(.caption)
                    .foregroundStyle(.white)

                modeChip(label: "Instances", mode: .instances, color: .blue)
                modeChip(label: "Queries", mode: .queries, color: Color(nsColor: .magenta))
                modeChip(label: "Points & Boundaries", mode: .pointsAndBoundaries, color: .yellow)

                Text("(Shift+Tab)")
                    .font(.caption)
                    .foregroundStyle(.gray)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(nsColor: .windowBackgroundColor))

            HStack {
                Spacer()
                Text(state.resultCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            .frame(height: 20)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let errorMessage = state.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        switch state.mode {
                        case .instances:
                            ForEach(state.instanceResults) { result in
                                let isHighlighted = state.highlightedID == String(result.id)
                                Button {
                                    state.select(instanceID: result.id)
                                } label: {
                                    Text(formatFieldDisplayValue(result.displayValue))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 1)
                                        .background(isHighlighted ? Color.accentColor.opacity(0.75) : Color.clear)
                                        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .id(String(result.id))
                            }
                        case .queries:
                            ForEach(state.queryResults, id: \.id) { result in
                                let isHighlighted = state.highlightedID == result.id
                                Button {
                                    state.select(instanceID: result.instanceID, queryTypeID: result.queryTypeID)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(formatFieldDisplayValue(result.displayValue))
                                            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                                        Text(result.queryTypeName)
                                            .foregroundStyle(isHighlighted ? Color.white : Color(nsColor: .magenta))
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 1)
                                    .background(isHighlighted ? Color.accentColor.opacity(0.75) : Color.clear)
                                }
                                .buttonStyle(.plain)
                                .id(result.id)
                            }
                        case .pointsAndBoundaries:
                            ForEach(state.mapElementResults, id: \.id) { result in
                                let isHighlighted = state.highlightedID == result.id
                                Button {
                                    state.select(instanceID: result.instanceID, queryTypeID: result.elementID)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(formatFieldDisplayValue(result.displayValue))
                                            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                                        Text(result.elementName)
                                            .foregroundStyle(isHighlighted ? Color.white : Color.yellow)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 1)
                                    .background(isHighlighted ? Color.accentColor.opacity(0.75) : Color.clear)
                                }
                                .buttonStyle(.plain)
                                .id(result.id)
                            }
                        }
                    }
                }
            }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(Color(nsColor: .controlBackgroundColor))
              .onChange(of: state.highlightedID) { _, newID in
                  guard let newID else { return }
                  // Scroll the minimal amount to bring the highlighted row into
                  // view (anchor: nil). Handles arrow-key navigation up and down
                  // as well as wrap-around from top↔bottom.
                  proxy.scrollTo(newID, anchor: nil)
              }
            }
        }
    }

    private var preFiltersPage: some View {
        VStack(spacing: 0) {
            HyperlinkSearchTextField(
                text: $state.preFilterSearchQuery,
                focusRequest: state.preFilterFocusRequest,
                canMoveDownToResults: { true },
                onMoveDown: state.moveSelectionDownPreFilters,
                onMoveUp: { state.moveSelectionUpPreFilters(); return false },
                onSubmit: state.chooseHighlightedPreFilter,
                onToggleMode: {},
                onSwitchToPreFilters: nil,
                onDeleteHighlighted: { state.deleteHighlightedPreFilter() },
                onManualFocus: {},
                onFocus: {}
            )
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))

            HStack(spacing: 6) {
                Text("Pre-Filters")
                    .font(.caption)
                    .foregroundStyle(.white)
                Text("(Esc to go back)")
                    .font(.caption)
                    .foregroundStyle(.gray)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    preFilterRow(id: "none", label: "(no pre-filter)", isBold: false, isMono: false)
                    let filtered = state.filteredPreFilters()
                    ForEach(Array(filtered.enumerated()), id: \.offset) { index, preFilter in
                        preFilterRow(id: "pf:\(index)", label: preFilter, isBold: false, isMono: true)
                    }
                    preFilterRow(id: "add", label: "+ add new pre-filter", isBold: true, isMono: false)
                }
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(Color(nsColor: .controlBackgroundColor))
              .onChange(of: state.preFilterHighlightedID) { _, newID in
                  guard let newID else { return }
                  proxy.scrollTo(newID, anchor: nil)
              }
            }
        }
    }

    @ViewBuilder
    private func preFilterRow(id: String, label: String, isBold: Bool, isMono: Bool) -> some View {
        let isHighlighted = state.preFilterHighlightedID == id
        Button {
            state.selectPreFilter(rowID: id)
        } label: {
            Text(label)
                .font(isMono ? .system(size: 12, design: .monospaced) : .body)
                .bold(isBold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(isHighlighted ? Color.green.opacity(0.75) : Color.clear)
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .id(id)
    }

    @ViewBuilder
    private func modeChip(label: String, mode: HyperlinkSearchMode, color: Color) -> some View {
        let isSelected = state.mode == mode
        Button {
            state.setMode(mode)
        } label: {
            Text(label)
                .font(.caption)
                .bold()
                .foregroundStyle(isSelected ? Color.white : color)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? color : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

struct HyperlinkSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let canMoveDownToResults: () -> Bool
    let onMoveDown: () -> Void
    let onMoveUp: () -> Bool
    let onSubmit: () -> Void
    let onToggleMode: () -> Void
    // ⌘P switches to the Pre-Filters page (Link-page field only); Delete on an empty field
    // deletes the highlighted pre-filter (Pre-Filters-page field only). Both default to nil.
    var onSwitchToPreFilters: (() -> Void)? = nil
    var onDeleteHighlighted: (() -> Bool)? = nil
    let onManualFocus: () -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            canMoveDownToResults: canMoveDownToResults,
            onMoveDown: onMoveDown,
            onMoveUp: onMoveUp,
            onSubmit: onSubmit,
            onToggleMode: onToggleMode,
            onDeleteHighlighted: onDeleteHighlighted,
            onManualFocus: onManualFocus,
            onFocus: onFocus
        )
    }

    func makeNSView(context: Context) -> HyperlinkSearchField {
        let textField = HyperlinkSearchField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.stringValue = text
        textField.commandHandler = context.coordinator.handleCommand
        textField.onMoveDown = onMoveDown
        textField.onMoveUp = onMoveUp
        textField.onSubmit = onSubmit
        textField.onToggleMode = onToggleMode
        textField.onSwitchToPreFilters = onSwitchToPreFilters
        textField.onDeleteHighlighted = onDeleteHighlighted
        textField.onManualFocus = onManualFocus
        textField.onFocus = onFocus
        context.coordinator.textField = textField
        return textField
    }

    func updateNSView(_ nsView: HyperlinkSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.commandHandler = context.coordinator.handleCommand
        nsView.onMoveDown = onMoveDown
        nsView.onMoveUp = onMoveUp
        nsView.onSubmit = onSubmit
        nsView.onToggleMode = onToggleMode
        nsView.onSwitchToPreFilters = onSwitchToPreFilters
        nsView.onDeleteHighlighted = onDeleteHighlighted
        nsView.onManualFocus = onManualFocus
        nsView.onFocus = onFocus
        context.coordinator.applyFocusRequest(focusRequest)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, NSControlTextEditingDelegate {
        @Binding private var text: String
        let canMoveDownToResults: () -> Bool
        let onMoveDown: () -> Void
        let onMoveUp: () -> Bool
        let onSubmit: () -> Void
        let onToggleMode: () -> Void
        let onDeleteHighlighted: (() -> Bool)?
        let onManualFocus: () -> Void
        let onFocus: () -> Void
        weak var textField: HyperlinkSearchField?
        private var lastAppliedFocusRequest: UUID?

        init(
            text: Binding<String>,
            canMoveDownToResults: @escaping () -> Bool,
            onMoveDown: @escaping () -> Void,
            onMoveUp: @escaping () -> Bool,
            onSubmit: @escaping () -> Void,
            onToggleMode: @escaping () -> Void,
            onDeleteHighlighted: (() -> Bool)?,
            onManualFocus: @escaping () -> Void,
            onFocus: @escaping () -> Void
        ) {
            _text = text
            self.canMoveDownToResults = canMoveDownToResults
            self.onMoveDown = onMoveDown
            self.onMoveUp = onMoveUp
            self.onSubmit = onSubmit
            self.onToggleMode = onToggleMode
            self.onDeleteHighlighted = onDeleteHighlighted
            self.onManualFocus = onManualFocus
            self.onFocus = onFocus
        }

        func controlTextDidChange(_ obj: Notification) {
            text = textField?.stringValue ?? ""
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let handled = handleCommand(selector)
            if handled, selector == #selector(NSResponder.moveUp(_:)) {
                let length = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: length, length: 0))
            }
            return handled
        }

        func handleCommand(_ selector: Selector) -> Bool {
            if selector == #selector(NSResponder.moveDown(_:)) {
                guard canMoveDownToResults() else {
                    return true
                }
                onMoveDown()
                return true
            }
            if selector == #selector(NSResponder.moveUp(_:)) {
                _ = onMoveUp()
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                onToggleMode()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.insertLineBreak(_:))
                || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                onSubmit()
                return true
            }
            if selector == #selector(NSResponder.deleteBackward(_:)), let onDeleteHighlighted {
                // Delete deletes the highlighted pre-filter, but only when the field is empty
                // so normal text deletion in a non-empty search box is unaffected.
                let editorText = textField?.currentEditor()?.string ?? textField?.stringValue ?? ""
                if editorText.isEmpty, onDeleteHighlighted() {
                    return true
                }
            }
            return false
        }

        func applyFocusRequest(_ focusRequest: UUID) {
            guard lastAppliedFocusRequest != focusRequest, let textField else { return }
            lastAppliedFocusRequest = focusRequest
            DispatchQueue.main.async {
                guard let window = textField.window else { return }
                // If the field is already being edited, leave its caret/selection
                // alone. performSearch re-issues the focus request on every
                // keystroke; without this guard, repositioning the caret to the
                // end teleports it whenever the user edits mid-string.
                if textField.currentEditor() != nil {
                    return
                }
                window.makeFirstResponder(textField)
                if let editor = textField.currentEditor() {
                    let length = (textField.stringValue as NSString).length
                    editor.selectedRange = NSRange(location: length, length: 0)
                }
            }
        }
    }
}

final class HyperlinkSearchField: NSTextField {
    var commandHandler: ((Selector) -> Bool)?
    var onMoveDown: (() -> Void)?
    var onMoveUp: (() -> Bool)?
    var onSubmit: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var onSwitchToPreFilters: (() -> Void)?
    var onDeleteHighlighted: (() -> Bool)?
    var onManualFocus: (() -> Void)?
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            DispatchQueue.main.async { [onFocus] in
                onFocus?()
            }
        }
        return didBecome
    }

    override func mouseDown(with event: NSEvent) {
        DispatchQueue.main.async { [onManualFocus] in
            onManualFocus?()
        }
        super.mouseDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if commandHandler?(selector) == true {
            return
        }
        super.doCommand(by: selector)
    }

    // ⌘P → Pre-Filters page. Handled here (not keyDown) because while the field is being
    // edited the field editor is first responder, so command-key events arrive via
    // performKeyEquivalent rather than the field's own keyDown. Only the Link-page field
    // sets onSwitchToPreFilters; the Pre-Filters-page field leaves it nil and returns false.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "p",
           let onSwitchToPreFilters {
            onSwitchToPreFilters()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 125:
            onMoveDown?()
        case 126:
            _ = onMoveUp?()
        case 36, 76:
            onSubmit?()
        default:
            super.keyDown(with: event)
        }
    }
}

struct HyperlinkSearchPopupKeyHandler: NSViewRepresentable {
    let isSearchFieldFocused: Bool
    let onMoveDown: () -> Void
    let onMoveUp: () -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> KeyHandlingView {
        let view = KeyHandlingView()
        view.isSearchFieldFocused = isSearchFieldFocused
        view.onMoveDown = onMoveDown
        view.onMoveUp = onMoveUp
        view.onSubmit = onSubmit
        return view
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        nsView.isSearchFieldFocused = isSearchFieldFocused
        nsView.onMoveDown = onMoveDown
        nsView.onMoveUp = onMoveUp
        nsView.onSubmit = onSubmit
    }

    final class KeyHandlingView: NSView {
        var isSearchFieldFocused = false
        var onMoveDown: (() -> Void)?
        var onMoveUp: (() -> Void)?
        var onSubmit: (() -> Void)?
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
                guard !self.isSearchFieldFocused else { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers.isEmpty else { return event }

                if event.keyCode == 125 {
                    self.onMoveDown?()
                    return nil
                }
                if event.keyCode == 126 {
                    self.onMoveUp?()
                    return nil
                }
                if event.keyCode == 36 || event.keyCode == 76 {
                    self.onSubmit?()
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
