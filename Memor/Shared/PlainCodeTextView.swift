//
//  PlainCodeTextView.swift
//  Memor
//
//  Shared code editor (NSTextView-based) plus HTML/CSS editor panes, the split-pane wrapper,
//  and radio-selection toggle used on the Types page and in the Global Code Editor window.
//

import AppKit
import SwiftUI

enum HTMLContentMode {
    case query
    case answer
}

enum FocusedEditor: Hashable {
    case html
    case css
}

private struct QueryTypeEditorPane: View {
    @Binding var activeEditor: FocusedEditor?
    let editor: FocusedEditor
    let title: String
    @Binding var text: String
    let highlightedTokens: Set<String>
    let fieldNames: Set<String>
    let booleanFieldNames: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            PlainCodeTextView(
                text: $text,
                highlightedTokens: highlightedTokens,
                fieldNames: fieldNames,
                booleanFieldNames: booleanFieldNames,
                isFocused: Binding(
                    get: { activeEditor == editor },
                    set: { isFocused in
                        if isFocused {
                            activeEditor = editor
                        } else if activeEditor == editor {
                            activeEditor = nil
                        }
                    }
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlainCodeTextView: NSViewRepresentable {
    @Binding var text: String
    let highlightedTokens: Set<String>
    let fieldNames: Set<String>
    let booleanFieldNames: Set<String>
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            highlightedTokens: highlightedTokens,
            fieldNames: fieldNames,
            booleanFieldNames: booleanFieldNames,
            isFocused: $isFocused
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = FocusTrackingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.disableAutomaticSubstitutions()
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = text
        textView.onFocusChange = { isFocused in
            DispatchQueue.main.async {
                context.coordinator.isFocused = isFocused
            }
        }

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applySyntaxHighlighting()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            textView.string = text
            context.coordinator.applySyntaxHighlighting()
        }

        context.coordinator.highlightedTokens = highlightedTokens
        context.coordinator.fieldNames = fieldNames
        context.coordinator.booleanFieldNames = booleanFieldNames
        context.coordinator.applySyntaxHighlighting()

        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var highlightedTokens: Set<String>
        var fieldNames: Set<String>
        var booleanFieldNames: Set<String>
        @Binding var isFocused: Bool
        weak var textView: NSTextView?
        private let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        private let baseColor = NSColor.labelColor

        init(
            text: Binding<String>,
            highlightedTokens: Set<String>,
            fieldNames: Set<String>,
            booleanFieldNames: Set<String>,
            isFocused: Binding<Bool>
        ) {
            _text = text
            self.highlightedTokens = highlightedTokens
            self.fieldNames = fieldNames
            self.booleanFieldNames = booleanFieldNames
            _isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            applySyntaxHighlighting()
            DispatchQueue.main.async {
                self.isFocused = true
            }
        }

        func applySyntaxHighlighting() {
            guard let textView, let textStorage = textView.textStorage else { return }

            let selectedRanges = textView.selectedRanges
            let fullRange = NSRange(location: 0, length: textStorage.length)
            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: baseColor
            ]

            textStorage.beginEditing()
            textStorage.setAttributes(defaultAttributes, range: fullRange)

            for highlightedToken in highlightedTokens where !highlightedToken.isEmpty {
                let tokenNSString = textStorage.string as NSString
                var searchRange = NSRange(location: 0, length: tokenNSString.length)

                while true {
                    let matchRange = tokenNSString.range(of: highlightedToken, options: [], range: searchRange)
                    if matchRange.location == NSNotFound {
                        break
                    }

                    textStorage.addAttribute(
                        .foregroundColor,
                        value: NSColor.systemPink,
                        range: matchRange
                    )

                    let nextLocation = matchRange.location + matchRange.length
                    searchRange = NSRange(location: nextLocation, length: tokenNSString.length - nextLocation)
                }
            }

            if !fieldNames.isEmpty {
                let placeholderRegex = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
                let fullStringRange = NSRange(location: 0, length: textStorage.length)
                placeholderRegex?.enumerateMatches(in: textStorage.string, range: fullStringRange) { match, _, _ in
                    guard
                        let match,
                        match.numberOfRanges >= 2,
                        match.range.location != NSNotFound,
                        let range = Range(match.range(at: 1), in: textStorage.string)
                    else {
                        return
                    }

                    let content = String(textStorage.string[range])
                    // Plain {{FieldName}} for any field, plus the Boolean-only colon
                    // forms {{BoolField:bit}} and {{BoolField:value_if_true:value_if_false}}
                    // (recognized by the part before the first colon being a boolean field).
                    let isPlaceholder: Bool
                    if fieldNames.contains(content) {
                        isPlaceholder = true
                    } else if let colonIndex = content.firstIndex(of: ":") {
                        isPlaceholder = booleanFieldNames.contains(String(content[..<colonIndex]))
                    } else {
                        isPlaceholder = false
                    }
                    guard isPlaceholder else { return }

                    textStorage.addAttribute(
                        .foregroundColor,
                        value: NSColor.systemBlue,
                        range: match.range
                    )
                }
            }

            textStorage.endEditing()
            textView.selectedRanges = selectedRanges
        }
    }

    final class FocusTrackingTextView: NSTextView {
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let didBecomeFirstResponder = super.becomeFirstResponder()
            if didBecomeFirstResponder {
                onFocusChange?(true)
            }
            return didBecomeFirstResponder
        }

        override func resignFirstResponder() -> Bool {
            let didResignFirstResponder = super.resignFirstResponder()
            if didResignFirstResponder {
                onFocusChange?(false)
            }
            return didResignFirstResponder
        }
    }
}

struct RadioSelectionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                Text(title)
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

struct QueryTypeEditorsSplitView: View {
    @Binding var htmlText: String
    @Binding var cssText: String
    let fieldNames: Set<String>
    let booleanFieldNames: Set<String>
    @Binding var activeEditor: FocusedEditor?
    @Binding var splitRatio: CGFloat

    @State private var dragStartDividerX: CGFloat?

    private let dividerWidth: CGFloat = 12
    private let minimumPaneWidth: CGFloat = 160

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let clampedDividerX = clampDividerX(in: availableWidth)
            let leftPaneWidth = clampedDividerX
            let rightPaneWidth = max(
                availableWidth - leftPaneWidth - dividerWidth,
                minimumPaneWidth
            )

            HStack(spacing: 0) {
                QueryTypeEditorPane(
                    activeEditor: $activeEditor,
                    editor: .html,
                    title: "HTML",
                    text: $htmlText,
                    highlightedTokens: ["{{#QuestionContent}}", "{{#Tags}}"],
                    fieldNames: fieldNames,
                    booleanFieldNames: booleanFieldNames
                )
                    .frame(width: leftPaneWidth)

                Rectangle()
                    .fill(.clear)
                    .frame(width: dividerWidth)
                    .overlay {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 1)
                    }
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        if isHovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStartDividerX == nil {
                                    dragStartDividerX = leftPaneWidth
                                }

                                updateSplitRatio(
                                    for: (dragStartDividerX ?? leftPaneWidth) + value.translation.width,
                                    totalWidth: availableWidth
                                )
                            }
                            .onEnded { _ in
                                dragStartDividerX = nil
                            }
                    )

                QueryTypeEditorPane(
                    activeEditor: $activeEditor,
                    editor: .css,
                    title: "CSS",
                    text: $cssText,
                    highlightedTokens: [],
                    fieldNames: [],
                    booleanFieldNames: []
                )
                    .frame(width: rightPaneWidth)
            }
        }
    }

    private func clampDividerX(in totalWidth: CGFloat) -> CGFloat {
        let maximumDividerX = max(totalWidth - minimumPaneWidth - dividerWidth, minimumPaneWidth)
        let proposedDividerX = totalWidth * splitRatio
        return min(max(proposedDividerX, minimumPaneWidth), maximumDividerX)
    }

    private func updateSplitRatio(for dividerX: CGFloat, totalWidth: CGFloat) {
        let maximumDividerX = max(totalWidth - minimumPaneWidth - dividerWidth, minimumPaneWidth)
        let clampedDividerX = min(max(dividerX, minimumPaneWidth), maximumDividerX)
        splitRatio = clampedDividerX / totalWidth
    }
}

