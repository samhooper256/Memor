//
//  SearchHighlightingTextView.swift
//  Memor
//
//  NSTextStorage highlighting for search-query syntax, plus the `SearchQueryTextField` wrapper.
//

import AppKit
import SwiftUI

private let searchOperatorRegex = try! NSRegularExpression(pattern: #"\b(literal|col|collection|type|id):"#)
private let searchFlagRegex = try! NSRegularExpression(pattern: #":noqueries\b"#)
private let searchNewFlagRegex = try! NSRegularExpression(pattern: #":new\b"#)
private let searchLogicalOperatorRegex = try! NSRegularExpression(pattern: #"\b(OR|NOT)\b"#)
private let searchQuoteRegex = try! NSRegularExpression(pattern: #"(?:^"|"$|(?<=\s)"|"(?=\s))"#, options: .anchorsMatchLines)
private let searchParenRegex = try! NSRegularExpression(pattern: #"[()]"#)

func applySearchQueryHighlighting(to textStorage: NSTextStorage, baseFont: NSFont, baseColor: NSColor = .labelColor, highlightsNoQueries: Bool = true) {
    let fullRange = NSRange(location: 0, length: textStorage.length)
    let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: baseColor
    ]

    textStorage.beginEditing()
    textStorage.setAttributes(defaultAttributes, range: fullRange)

    let string = textStorage.string

    // Operators (blue)
    searchOperatorRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
        guard let match else { return }
        textStorage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
    }

    // Argument-less flag components (blue). `:noqueries` is instance-search only;
    // `:new` is query-search only.
    if highlightsNoQueries {
        searchFlagRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match else { return }
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
        }
    } else {
        searchNewFlagRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match else { return }
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
        }
    }

    // Logical operators (green)
    searchLogicalOperatorRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
        guard let match else { return }
        textStorage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
    }

    // Quotes (gray)
    searchQuoteRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
        guard let match else { return }
        textStorage.addAttribute(.foregroundColor, value: NSColor.systemGray, range: match.range)
    }

    // Parentheses (gray)
    searchParenRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
        guard let match else { return }
        textStorage.addAttribute(.foregroundColor, value: NSColor.systemGray, range: match.range)
    }

    textStorage.endEditing()
}

func highlightedSearchQuery(_ search: String) -> AttributedString {
    let nsString = search as NSString
    let fullRange = NSRange(location: 0, length: nsString.length)

    let result = NSMutableAttributedString(string: search)

    // Operators (blue)
    searchOperatorRegex.enumerateMatches(in: search, range: fullRange) { match, _, _ in
        guard let match else { return }
        result.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
    }

    // Note: `:noqueries` is deliberately not highlighted here — this renders
    // stack (query) searches, where the instance-only flag is not valid. `:new`
    // is a query-search flag, so it IS highlighted here.
    searchNewFlagRegex.enumerateMatches(in: search, range: fullRange) { match, _, _ in
        guard let match else { return }
        result.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
    }

    // Logical operators (green)
    searchLogicalOperatorRegex.enumerateMatches(in: search, range: fullRange) { match, _, _ in
        guard let match else { return }
        result.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
    }

    // Quotes (gray)
    searchQuoteRegex.enumerateMatches(in: search, range: fullRange) { match, _, _ in
        guard let match else { return }
        result.addAttribute(.foregroundColor, value: NSColor.systemGray, range: match.range)
    }

    // Parentheses (gray)
    searchParenRegex.enumerateMatches(in: search, range: fullRange) { match, _, _ in
        guard let match else { return }
        result.addAttribute(.foregroundColor, value: NSColor.systemGray, range: match.range)
    }

    return try! AttributedString(result, including: \.appKit)
}

struct SearchQueryTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: (() -> Void)?
    var focusRequest: UUID?
    var onFocusChange: ((Bool) -> Void)?
    var highlightsNoQueries: Bool
    var onBacktab: (() -> Void)?
    var onMoveDown: (() -> Void)?

    init(_ placeholder: String, text: Binding<String>, onSubmit: (() -> Void)? = nil, focusRequest: UUID? = nil, highlightsNoQueries: Bool = true, onFocusChange: ((Bool) -> Void)? = nil, onBacktab: (() -> Void)? = nil, onMoveDown: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
        self.focusRequest = focusRequest
        self.highlightsNoQueries = highlightsNoQueries
        self.onFocusChange = onFocusChange
        self.onBacktab = onBacktab
        self.onMoveDown = onMoveDown
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onFocusChange: onFocusChange, highlightsNoQueries: highlightsNoQueries)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let textView = SearchHighlightingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.disableAutomaticSubstitutions()
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.height]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 2, height: 0)
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = text
        textView.onSubmit = onSubmit
        textView.placeholderString = placeholder
        textView.onFocusChange = onFocusChange
        textView.onBacktab = onBacktab
        textView.onMoveDown = onMoveDown

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textContainer.maximumNumberOfLines = 1
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applySyntaxHighlighting()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onFocusChange = onFocusChange
        (textView as? SearchHighlightingTextView)?.onSubmit = onSubmit
        (textView as? SearchHighlightingTextView)?.onFocusChange = onFocusChange
        (textView as? SearchHighlightingTextView)?.onBacktab = onBacktab
        (textView as? SearchHighlightingTextView)?.onMoveDown = onMoveDown
        if textView.string != text {
            textView.string = text
            context.coordinator.applySyntaxHighlighting()
        }
        if let focusRequest {
            context.coordinator.applyFocusRequest(focusRequest)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var onSubmit: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var highlightsNoQueries: Bool
        weak var textView: NSTextView?
        private let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        private var lastAppliedFocusRequest: UUID?

        init(text: Binding<String>, onSubmit: (() -> Void)?, onFocusChange: ((Bool) -> Void)?, highlightsNoQueries: Bool) {
            _text = text
            self.onSubmit = onSubmit
            self.onFocusChange = onFocusChange
            self.highlightsNoQueries = highlightsNoQueries
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            applySyntaxHighlighting()
        }

        func applySyntaxHighlighting() {
            guard let textView, let textStorage = textView.textStorage else { return }
            let selectedRanges = textView.selectedRanges
            applySearchQueryHighlighting(to: textStorage, baseFont: baseFont, highlightsNoQueries: highlightsNoQueries)
            textView.selectedRanges = selectedRanges
        }

        func applyFocusRequest(_ focusRequest: UUID) {
            guard lastAppliedFocusRequest != focusRequest, let textView else { return }
            lastAppliedFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class SearchHighlightingTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var onBacktab: (() -> Void)?
        var onMoveDown: (() -> Void)?
        var placeholderString: String = ""

        override func keyDown(with event: NSEvent) {
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            if isReturnKey {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }

        override func doCommand(by selector: Selector) {
            // Shift+Tab arrives as insertBacktab. When a handler is installed,
            // consume it (used to cycle the Search window's mode) instead of
            // moving focus.
            if selector == #selector(NSResponder.insertBacktab(_:)), let onBacktab {
                onBacktab()
                return
            }
            // Down arrow moves focus/selection into the results list (when there is one).
            // Consume it either way so the caret doesn't move within the search text.
            if selector == #selector(NSResponder.moveDown(_:)), let onMoveDown {
                onMoveDown()
                return
            }
            super.doCommand(by: selector)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty {
                drawPlaceholder(dirtyRect)
            }
        }

        override func didChangeText() {
            super.didChangeText()
            // The placeholder spans more than the glyph rects a keystroke
            // invalidates; repaint fully so it appears/disappears whole.
            needsDisplay = true
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { onFocusChange?(true) }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { onFocusChange?(false) }
            return result
        }

        private func drawPlaceholder(_ dirtyRect: NSRect) {
            guard !placeholderString.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor
            ]
            let inset = textContainerInset
            let origin = NSPoint(
                x: inset.width + (textContainer?.lineFragmentPadding ?? 0),
                y: inset.height
            )
            NSAttributedString(string: placeholderString, attributes: attrs).draw(at: origin)
        }
    }
}

