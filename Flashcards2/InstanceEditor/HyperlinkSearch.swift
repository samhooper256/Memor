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

@MainActor
final class HyperlinkSearchController: ObservableObject {
    private weak var panel: HyperlinkSearchPanel?
    private var popupState: HyperlinkSearchPopupState?

    func present(appDatabase: AppDatabase, from textView: InstanceTextView.CommandAwareTextView) {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0,
              let stringRange = Range(selectedRange, in: textView.string) else {
            NSSound.beep()
            return
        }

        let selectedText = String(textView.string[stringRange])
        let initialQuery = makeInitialQuery(for: selectedText)
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
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

        let hyperlink = #"<a href="\#(href)">\#(selectionContext.selectedText)</a>"#
        let selectedRange = selectionContext.selectedRange
        guard NSMaxRange(selectedRange) <= textView.string.utf16.count else {
            close()
            return
        }

        close()
        textView.window?.makeFirstResponder(textView)

        let caretLocation = selectedRange.location + (hyperlink as NSString).length
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

    func performSearch() {
        let query = searchQuery
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
            let nextIndex = min(currentIndex + 1, ids.count - 1)
            self.highlightedID = ids[nextIndex]
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
}

struct HyperlinkSelectionContext {
    weak var textView: NSTextView?
    let selectedRange: NSRange
    let selectedText: String
}

struct HyperlinkSearchPopupView: View {
    @ObservedObject var state: HyperlinkSearchPopupState

    var body: some View {
        VStack(spacing: 0) {
            HyperlinkSearchTextField(
                text: $state.searchQuery,
                focusRequest: state.searchFieldFocusRequest,
                canMoveDownToResults: { !state.currentResultsIsEmpty },
                onMoveDown: state.moveSelectionDown,
                onMoveUp: state.moveSelectionUp,
                onSubmit: state.chooseHighlightedResult,
                onToggleMode: state.toggleMode,
                onManualFocus: state.searchFieldDidReceiveManualFocus,
                onFocus: state.searchFieldDidBecomeFocused
            )
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))

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
                                        .padding(.vertical, 6)
                                        .background(isHighlighted ? Color.accentColor.opacity(0.75) : Color.clear)
                                        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
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
                                    .padding(.vertical, 6)
                                    .background(isHighlighted ? Color.accentColor.opacity(0.75) : Color.clear)
                                }
                                .buttonStyle(.plain)
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
                                    .padding(.vertical, 6)
                                    .background(isHighlighted ? Color.accentColor.opacity(0.75) : Color.clear)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
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
                onEscape: state.close,
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
            onManualFocus: @escaping () -> Void,
            onFocus: @escaping () -> Void
        ) {
            _text = text
            self.canMoveDownToResults = canMoveDownToResults
            self.onMoveDown = onMoveDown
            self.onMoveUp = onMoveUp
            self.onSubmit = onSubmit
            self.onToggleMode = onToggleMode
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
            return false
        }

        func applyFocusRequest(_ focusRequest: UUID) {
            guard lastAppliedFocusRequest != focusRequest, let textField else { return }
            lastAppliedFocusRequest = focusRequest
            DispatchQueue.main.async {
                guard let window = textField.window else { return }
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
