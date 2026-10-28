//
//  SearchAutocomplete.swift
//  Memor
//
//  IDE-style completion for the search language's `collection:`/`col:`,
//  `type:`, `office:`, and `qt:` components: a popup under the caret listing
//  the matching names (with ids) that arrows navigate, Return/click choose,
//  and Escape dismisses. A SearchQueryTextField gets it by being handed a
//  SearchAutocompleteProvider; the field forwards text/selection changes and
//  the keys the popup claims to its SearchAutocompleteController. The pure
//  parts (what argument the caret is in, filtering, the replacement text)
//  live in SearchAutocompleteEngine.swift.
//
//  The popup is a borderless child NSPanel that can never become key, so the
//  search field keeps focus and every keystroke still goes to it; the panel
//  only receives clicks (its rows accept the first mouse). It is anchored once
//  per argument — just after the triggering colon — and does not move while
//  the argument is typed. Candidate lists are fetched fresh each time an
//  argument's popup opens, so new collections/types/offices show without a
//  restart.
//

import AppKit

/// Supplies candidate lists from the database. Handed to a SearchQueryTextField
/// to turn autocomplete on; nil turns it off (the Search window's Points &
/// Boundaries mode, where these components are rejected).
struct SearchAutocompleteProvider {
    let appDatabase: AppDatabase

    func candidates(for kind: SearchAutocompleteKind, queryTypeTypeArgument: String) -> [SearchAutocompleteCandidate] {
        switch kind {
        case .collection:
            return ((try? appDatabase.fetchCollections()) ?? []).map {
                SearchAutocompleteCandidate(name: $0.name, id: $0.id)
            }
        case .type, .queryTypeType:
            return ((try? appDatabase.fetchTypes()) ?? []).map {
                SearchAutocompleteCandidate(name: $0.name, id: $0.id)
            }
        case .office:
            return ((try? appDatabase.fetchOffices()) ?? []).map {
                SearchAutocompleteCandidate(name: $0.name, id: nil)
            }
        case .queryTypeName:
            return queryTypeNameCandidates(typeArgument: queryTypeTypeArgument)
        }
    }

    /// Everything `qt:` accepts after the type (see the parser's `.queryType`
    /// handling): the type's query types; for Person also the built-in kinds
    /// and every office (per-office queries); for the map types
    /// Forward/Reverse. The type argument may be a name (NOCASE) or an id. An
    /// unknown type offers nothing.
    private func queryTypeNameCandidates(typeArgument: String) -> [SearchAutocompleteCandidate] {
        let types = (try? appDatabase.fetchTypes()) ?? []
        let type: FlashcardType?
        if let first = typeArgument.first, first.isNumber {
            type = Int64(typeArgument).flatMap { id in types.first { $0.id == id } }
        } else {
            type = types.first { AppDatabase.sqliteNocaseEquals($0.name, typeArgument) }
        }
        guard let type else { return [] }

        var names: [String]
        if type.isBuiltin && (type.name == POINTMAP_TYPE_NAME || type.name == BOUNDARYMAP_TYPE_NAME) {
            names = ["Forward", "Reverse"]
        } else {
            names = ((try? appDatabase.fetchQueryTypes(forTypeID: type.id)) ?? []).map(\.name)
            if type.isBuiltin && type.name == PERSON_TYPE_NAME {
                names += PersonQueryKind.allCases.map(\.displayName)
                names += ((try? appDatabase.fetchOffices()) ?? []).map(\.name)
            }
        }
        // The parser matches these NOCASE, so a name listed twice (a user
        // query type named like a built-in) is one choice.
        var seen: Set<String> = []
        return names
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { SearchAutocompleteCandidate(name: $0, id: nil) }
    }
}

/// Drives one search field's completion popup. Owned by the field's
/// coordinator; the field forwards text/selection changes and the keys the
/// popup claims (↑/↓ wrap through the rows, Return chooses, Escape closes).
final class SearchAutocompleteController: NSObject {
    /// The controller whose popup is showing, if any — so a window-level
    /// Escape monitor (which sees the key before the field does) can close the
    /// popup instead of the window.
    private(set) static weak var active: SearchAutocompleteController?

    /// Closes the showing popup, if any. True when there was one.
    @discardableResult
    static func dismissActivePopup() -> Bool {
        guard let active, active.isPopupVisible else { return false }
        active.dismiss()
        return true
    }

    weak var textView: NSTextView?
    /// nil disables completion (and closes an open popup).
    var provider: SearchAutocompleteProvider? {
        didSet { if provider == nil { dismiss() } }
    }

    /// One argument's completion: fixed kind, anchor, and candidate list;
    /// refiltered as the typed text changes.
    private final class Session {
        let kind: SearchAutocompleteKind
        let anchorLocation: Int
        let candidates: [SearchAutocompleteCandidate]
        var context: SearchAutocompleteContext
        var matches: [SearchAutocompleteMatch] = []
        var selectedIndex = 0
        /// Screen point the popup hangs from, decided when it first shows and
        /// kept for the session so the popup never jumps.
        var anchorPoint: NSPoint?
        var opensUpward = false

        init(context: SearchAutocompleteContext, candidates: [SearchAutocompleteCandidate]) {
            kind = context.kind
            anchorLocation = context.anchorLocation
            self.candidates = candidates
            self.context = context
        }
    }

    private var session: Session?
    private var panel: SearchAutocompletePanel?
    /// Set by `choose` for the text change it causes: the caret is still
    /// inside the component just completed, so a popup of the same kind must
    /// not reopen (a qt: type choice lands in the query-type argument, a
    /// different kind, so that popup still opens).
    private var suppressedKind: SearchAutocompleteKind?
    private var mouseMonitor: Any?
    private weak var observedWindow: NSWindow?

    private static let observedWindowNotifications: [Notification.Name] = [
        NSWindow.didResignKeyNotification,
        NSWindow.willCloseNotification,
        NSWindow.didResizeNotification,
    ]

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    var isPopupVisible: Bool {
        session != nil && panel?.isVisible == true
    }

    // MARK: - Field events

    func textDidChange() {
        let suppressedKind = self.suppressedKind
        self.suppressedKind = nil
        refresh(mayOpen: true, suppressedKind: suppressedKind)
    }

    func selectionDidChange() {
        // Caret moves refilter an open popup (or close it when the caret
        // leaves the argument) but never open one — typing does that.
        refresh(mayOpen: false, suppressedKind: nil)
    }

    private func refresh(mayOpen: Bool, suppressedKind: SearchAutocompleteKind?) {
        guard let textView, let provider else {
            dismiss()
            return
        }
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let context = SearchAutocompleteEngine.context(in: textView.string, caretLocation: selection.location) else {
            dismiss()
            return
        }

        if let session, session.kind == context.kind, session.anchorLocation == context.anchorLocation {
            session.context = context
            session.matches = SearchAutocompleteEngine.matches(in: session.candidates, typedText: context.typedText)
            session.selectedIndex = 0
            presentPanel()
            return
        }

        guard mayOpen, context.kind != suppressedKind else {
            dismiss()
            return
        }
        dismiss()
        let session = Session(
            context: context,
            candidates: provider.candidates(for: context.kind, queryTypeTypeArgument: context.queryTypeTypeArgument)
        )
        session.matches = SearchAutocompleteEngine.matches(in: session.candidates, typedText: context.typedText)
        self.session = session
        presentPanel()
    }

    // MARK: - Keys

    func handleMoveDown() -> Bool {
        guard isPopupVisible, let session, !session.matches.isEmpty else { return false }
        session.selectedIndex = (session.selectedIndex + 1) % session.matches.count
        showSelection()
        return true
    }

    func handleMoveUp() -> Bool {
        guard isPopupVisible, let session, !session.matches.isEmpty else { return false }
        session.selectedIndex = (session.selectedIndex - 1 + session.matches.count) % session.matches.count
        showSelection()
        return true
    }

    func handleReturn() -> Bool {
        guard isPopupVisible, let session else { return false }
        choose(index: session.selectedIndex)
        return true
    }

    func handleEscape() -> Bool {
        guard isPopupVisible else { return false }
        dismiss()
        return true
    }

    // MARK: - Choosing

    private func choose(index: Int) {
        guard let session, let textView, session.matches.indices.contains(index) else { return }
        let match = session.matches[index]
        let (replacement, caretOffset) = SearchAutocompleteEngine.replacement(for: session.context, value: match.insertionText)
        let componentRange = session.context.componentRange
        guard NSMaxRange(componentRange) <= textView.string.utf16.count else {
            dismiss()
            return
        }

        dismiss()
        suppressedKind = session.kind
        textView.insertText(replacement, replacementRange: componentRange)
        textView.setSelectedRange(NSRange(location: componentRange.location + caretOffset, length: 0))
    }

    // MARK: - Popup

    func dismiss() {
        session = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        removeMonitors()
        if Self.active === self { Self.active = nil }
    }

    /// For the field's teardown: also drops the panel.
    func tearDown() {
        dismiss()
        panel?.close()
        panel = nil
    }

    private func presentPanel() {
        guard let session, let textView, let window = textView.window else {
            dismiss()
            return
        }
        guard !session.matches.isEmpty else {
            // Keep the session (a deletion may bring matches back), hide the popup.
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            return
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let popupView = panel.popupView
        popupView.update(
            header: headerText(for: session),
            rows: session.matches.map { match in
                SearchAutocompleteListView.Row(
                    name: match.candidate.name,
                    nameMatchRange: match.nameMatchRange,
                    idText: match.candidate.id.map { String($0) },
                    idMatchLength: match.idMatchLength
                )
            },
            selectedIndex: session.selectedIndex
        )

        let size = popupView.preferredSize
        let screen = window.screen ?? NSScreen.main
        if session.anchorPoint == nil {
            // Hang from the bottom of the caret line at the anchor. When even
            // the tallest popup wouldn't fit above the screen's bottom edge,
            // sit on the line's top edge instead — decided once per session.
            let caretRect = anchorRect(for: session.anchorLocation, in: textView)
            let tallest = SearchAutocompletePopupView.maxHeight
            if let screen, caretRect.minY - tallest < screen.visibleFrame.minY {
                session.opensUpward = true
                session.anchorPoint = NSPoint(x: caretRect.minX, y: caretRect.maxY)
            } else {
                session.anchorPoint = NSPoint(x: caretRect.minX, y: caretRect.minY)
            }
        }
        guard let anchorPoint = session.anchorPoint else { return }
        var frame = NSRect(origin: anchorPoint, size: size)
        if !session.opensUpward {
            frame.origin.y = anchorPoint.y - size.height
        }
        if let screen, frame.maxX > screen.visibleFrame.maxX {
            frame.origin.x = max(screen.visibleFrame.minX, screen.visibleFrame.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
        // Lay the rows out now so scrolling the selection into view sees the
        // list's real frame, not last session's.
        popupView.needsLayout = true
        popupView.layoutSubtreeIfNeeded()

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        Self.active = self
        installMonitors(for: window)
        showSelection()
    }

    private func headerText(for session: Session) -> String {
        let noun = session.kind.noun
        if session.context.typedText.isEmpty {
            return "\(session.candidates.count) \(noun)"
        }
        return "\(session.matches.count) of \(session.candidates.count) \(noun)"
    }

    private func showSelection() {
        guard let session, let popupView = panel?.popupView else { return }
        popupView.listView.selectedIndex = session.selectedIndex
        popupView.listView.scrollToVisible(popupView.listView.rect(forRow: session.selectedIndex))
    }

    /// Screen rect of the insertion point at `location` — its bottom edge is
    /// where the next typed character's baseline box ends.
    private func anchorRect(for location: Int, in textView: NSTextView) -> NSRect {
        let length = textView.string.utf16.count
        let clamped = min(max(0, location), length)
        let rect = textView.firstRect(forCharacterRange: NSRange(location: clamped, length: 0), actualRange: nil)
        if rect.height > 0 { return rect }
        // Fallback through the layout manager (zero-length ranges at the very
        // end of the text are the case firstRect is least reliable for).
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let window = textView.window else { return rect }
        let glyphIndex = clamped >= length
            ? layoutManager.numberOfGlyphs
            : layoutManager.glyphIndexForCharacter(at: clamped)
        var local = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 0), in: textContainer)
        local.origin.x += textView.textContainerOrigin.x
        local.origin.y += textView.textContainerOrigin.y
        return window.convertToScreen(textView.convert(local, to: nil))
    }

    private func makePanel() -> SearchAutocompletePanel {
        let panel = SearchAutocompletePanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let popupView = SearchAutocompletePopupView(frame: panel.contentRect(forFrameRect: panel.frame))
        popupView.listView.onChoose = { [weak self] index in
            self?.choose(index: index)
        }
        panel.contentView = popupView
        return panel
    }

    // MARK: - Dismissal triggers

    private func installMonitors(for window: NSWindow) {
        if mouseMonitor == nil {
            // Any click outside the popup — including into the field — closes it.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.window !== self.panel {
                    self.dismiss()
                }
                return event
            }
        }
        if observedWindow !== window {
            if let observedWindow {
                for name in Self.observedWindowNotifications {
                    NotificationCenter.default.removeObserver(self, name: name, object: observedWindow)
                }
            }
            observedWindow = window
            for name in Self.observedWindowNotifications {
                NotificationCenter.default.addObserver(self, selector: #selector(hostWindowChanged(_:)), name: name, object: window)
            }
        }
    }

    private func removeMonitors() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let observedWindow {
            for name in Self.observedWindowNotifications {
                NotificationCenter.default.removeObserver(self, name: name, object: observedWindow)
            }
            self.observedWindow = nil
        }
    }

    @objc private func hostWindowChanged(_ notification: Notification) {
        dismiss()
    }
}

/// Never key, never main: the search field keeps focus while the popup shows.
final class SearchAutocompletePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var popupView: SearchAutocompletePopupView {
        contentView as! SearchAutocompletePopupView
    }
}

/// Count header over a scrolling list of rows, on a popover-material
/// backdrop with rounded corners.
final class SearchAutocompletePopupView: NSView {
    static let headerHeight: CGFloat = 20
    static let maxVisibleRows = 10
    private static let minWidth: CGFloat = 220
    private static let maxWidth: CGFloat = 520
    private static let listTopInset: CGFloat = 2
    private static let listBottomInset: CGFloat = 2

    static var maxHeight: CGFloat {
        headerHeight + 1 + listTopInset + CGFloat(maxVisibleRows) * SearchAutocompleteListView.rowHeight + listBottomInset
    }

    private let backdrop = NSVisualEffectView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    let listView = SearchAutocompleteListView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        addSubview(backdrop)

        headerLabel.font = .systemFont(ofSize: 11)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        addSubview(headerLabel)

        separator.boxType = .separator
        addSubview(separator)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = listView
        addSubview(scrollView)

        updateBorderColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func update(header: String, rows: [SearchAutocompleteListView.Row], selectedIndex: Int) {
        headerLabel.stringValue = header
        listView.rows = rows
        listView.selectedIndex = selectedIndex
        needsLayout = true
    }

    /// Wide enough for the widest row (within limits), tall enough for the
    /// rows up to `maxVisibleRows`.
    var preferredSize: NSSize {
        let headerWidth = headerLabel.intrinsicContentSize.width + 16
        let rowsWidth = listView.preferredWidth + 24
        let width = min(Self.maxWidth, max(Self.minWidth, max(rowsWidth, headerWidth)))
        let visibleRows = min(listView.rows.count, Self.maxVisibleRows)
        let height = Self.headerHeight + 1 + Self.listTopInset
            + CGFloat(visibleRows) * SearchAutocompleteListView.rowHeight + Self.listBottomInset
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        let labelHeight = headerLabel.intrinsicContentSize.height
        headerLabel.frame = NSRect(
            x: 8,
            y: (Self.headerHeight - labelHeight) / 2,
            width: bounds.width - 16,
            height: labelHeight
        )
        separator.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: 1)
        let listTop = Self.headerHeight + 1 + Self.listTopInset
        scrollView.frame = NSRect(
            x: 0,
            y: listTop,
            width: bounds.width,
            height: max(0, bounds.height - listTop - Self.listBottomInset)
        )
        listView.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: CGFloat(listView.rows.count) * SearchAutocompleteListView.rowHeight
        )
    }
}

/// The rows: monospace name, the matched text in bold accent, the id (when
/// there is one) in gray after it; the selected row on a blue fill.
final class SearchAutocompleteListView: NSView {
    struct Row {
        let name: String
        let nameMatchRange: NSRange?
        let idText: String?
        let idMatchLength: Int
    }

    static let rowHeight: CGFloat = 18
    private static let textInset: CGFloat = 10

    var rows: [Row] = [] {
        didSet {
            preferredWidth = rows.map { attributedString(for: $0, isSelected: false).size().width + Self.textInset }.max() ?? 0
            needsDisplay = true
        }
    }
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }
    var onChoose: ((Int) -> Void)?
    private(set) var preferredWidth: CGFloat = 0

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    override var isFlipped: Bool { true }

    // The popup's window is never key; the first click must still choose.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func rect(forRow index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
    }

    private func attributedString(for row: Row, isSelected: Bool) -> NSAttributedString {
        let nameColor: NSColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        let emphasisColor: NSColor = isSelected ? .alternateSelectedControlTextColor : .controlAccentColor
        let idColor: NSColor = isSelected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75)
            : .secondaryLabelColor

        let result = NSMutableAttributedString(
            string: row.name,
            attributes: [.font: font, .foregroundColor: nameColor]
        )
        if let range = row.nameMatchRange, NSMaxRange(range) <= result.length {
            result.addAttributes([.font: boldFont, .foregroundColor: emphasisColor], range: range)
        }
        if let idText = row.idText {
            let id = NSMutableAttributedString(
                string: "  " + idText,
                attributes: [.font: font, .foregroundColor: idColor]
            )
            if row.idMatchLength > 0 {
                id.addAttributes(
                    [.font: boldFont, .foregroundColor: emphasisColor],
                    range: NSRange(location: 2, length: min(row.idMatchLength, idText.utf16.count))
                )
            }
            result.append(id)
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, row) in rows.enumerated() {
            let rowRect = rect(forRow: index)
            guard rowRect.intersects(dirtyRect) else { continue }
            let isSelected = index == selectedIndex
            if isSelected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 4, dy: 0), xRadius: 4, yRadius: 4).fill()
            }
            let text = attributedString(for: row, isSelected: isSelected)
            let size = text.size()
            text.draw(at: NSPoint(x: Self.textInset, y: rowRect.minY + (Self.rowHeight - size.height) / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(floor(point.y / Self.rowHeight))
        guard rows.indices.contains(index) else { return }
        onChoose?(index)
    }
}
