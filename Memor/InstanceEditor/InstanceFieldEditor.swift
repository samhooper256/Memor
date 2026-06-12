//
//  InstanceFieldEditor.swift
//  Memor
//
//  Per-field editor surface inside the instance editor: the styled text view,
//  its focus/routing controller, and the labeled container view.
//

import AppKit
import Combine
import SwiftUI

final class AddInstanceFieldFocusController: ObservableObject {
    private final class WeakTextView {
        weak var value: NSTextView?

        init(_ value: NSTextView) {
            self.value = value
        }
    }

    private var textViewsByFieldID: [Int64: WeakTextView] = [:]
    private(set) var activeFieldID: Int64?
    private(set) var lastFocusedFieldID: Int64?
    private var pendingFocusedFieldID: Int64?
    weak var collectionSearchField: NSTextField?

    func register(_ textView: NSTextView, fieldID: Int64) {
        textViewsByFieldID[fieldID] = WeakTextView(textView)

        if pendingFocusedFieldID == fieldID {
            pendingFocusedFieldID = nil
            focusField(fieldID)
        }
    }

    func setActiveField(_ fieldID: Int64?) {
        activeFieldID = fieldID
        if let fieldID {
            lastFocusedFieldID = fieldID
        }
    }

    func focusField(_ fieldID: Int64?) {
        activeFieldID = fieldID

        guard let fieldID else {
            pendingFocusedFieldID = nil
            return
        }

        guard let textView = textViewsByFieldID[fieldID]?.value else {
            pendingFocusedFieldID = fieldID
            return
        }

        pendingFocusedFieldID = nil
        textView.window?.makeFirstResponder(textView)
    }

    func focusCollectionSearch() {
        activeFieldID = nil
        pendingFocusedFieldID = nil
        guard let collectionSearchField else { return }
        collectionSearchField.window?.makeFirstResponder(collectionSearchField)
    }

    func reset(with fieldIDs: [Int64]) {
        let validIDs = Set(fieldIDs)
        textViewsByFieldID = textViewsByFieldID.filter { validIDs.contains($0.key) && $0.value.value != nil }

        if let activeFieldID, !validIDs.contains(activeFieldID) {
            self.activeFieldID = nil
        }

        if let pendingFocusedFieldID, !validIDs.contains(pendingFocusedFieldID) {
            self.pendingFocusedFieldID = nil
        }

        if let lastFocusedFieldID, !validIDs.contains(lastFocusedFieldID) {
            self.lastFocusedFieldID = nil
        }
    }

    func insertTextAtFocusedField(_ insertedText: String) -> Bool {
        guard let targetFieldID = activeFieldID ?? lastFocusedFieldID,
              let textView = textViewsByFieldID[targetFieldID]?.value else {
            return false
        }

        let selectedRange = textView.selectedRange()
        textView.insertText(insertedText, replacementRange: selectedRange)
        textView.window?.makeFirstResponder(textView)
        setActiveField(targetFieldID)
        return true
    }

    func wrapFocusedSelection(openTag: String, closeTag: String) -> Bool {
        guard let targetFieldID = activeFieldID,
              let textView = textViewsByFieldID[targetFieldID]?.value else {
            return false
        }

        let selectedRange = textView.selectedRange()
        let replacementString: String
        let resultingCaretLocation: Int

        if selectedRange.length == 0 {
            replacementString = openTag + closeTag
            resultingCaretLocation = selectedRange.location + (openTag as NSString).length
        } else {
            let nsString = textView.string as NSString
            let selectedText = nsString.substring(with: selectedRange)
            replacementString = openTag + selectedText + closeTag
            resultingCaretLocation = selectedRange.location
                + (openTag as NSString).length
                + (selectedText as NSString).length
        }

        guard textView.shouldChangeText(in: selectedRange, replacementString: replacementString) else {
            return false
        }

        let replacementAttributes = textView.typingAttributes
        let replacementAttributedString = NSAttributedString(
            string: replacementString,
            attributes: replacementAttributes
        )
        textView.textStorage?.replaceCharacters(in: selectedRange, with: replacementAttributedString)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: resultingCaretLocation, length: 0))
        textView.window?.makeFirstResponder(textView)
        setActiveField(targetFieldID)
        return true
    }

}

struct InstanceFieldEditor: View {
    private static let minimumEditorHeight: CGFloat = 64

    let fieldName: String
    @Binding var text: String
    let focusController: AddInstanceFieldFocusController
    let fieldID: Int64
    let isSticky: Bool
    let showStickyToggle: Bool
    let onToggleSticky: () -> Void
    let onSubmit: () -> Void
    let onRequestHyperlink: ((InstanceTextView.CommandAwareTextView) -> Void)?
    let onMoveToNextField: () -> Void
    let onMoveToPreviousField: () -> Void
    @State private var editorHeight: CGFloat = minimumEditorHeight
    @State private var isStickyHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(fieldName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                Spacer(minLength: 0)

                if showStickyToggle {
                    Button(action: onToggleSticky) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(isSticky ? .blue : Color.secondary.opacity(0.4))
                            .rotationEffect(.degrees(45))
                            .frame(width: 20, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isStickyHovered ? Color.secondary.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isStickyHovered = hovering
                    }
                    .help(isSticky ? "Unstick field (⌘S)" : "Stick field (⌘S)")
                    .padding(.trailing, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            InstanceTextView(
                text: $text,
                focusController: focusController,
                fieldID: fieldID,
                onSubmit: onSubmit,
                onRequestHyperlink: onRequestHyperlink,
                onContentHeightChange: { contentHeight in
                    editorHeight = max(Self.minimumEditorHeight, contentHeight)
                },
                onMoveToNextField: onMoveToNextField,
                onMoveToPreviousField: onMoveToPreviousField
            )
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.minimumEditorHeight,
                    idealHeight: editorHeight,
                    maxHeight: editorHeight,
                    alignment: .topLeading
                )
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}

struct InstanceTextView: NSViewRepresentable {
    @Binding var text: String
    let focusController: AddInstanceFieldFocusController
    let fieldID: Int64
    let onSubmit: () -> Void
    let onRequestHyperlink: ((CommandAwareTextView) -> Void)?
    let onContentHeightChange: (CGFloat) -> Void
    let onMoveToNextField: () -> Void
    let onMoveToPreviousField: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focusController: focusController,
            fieldID: fieldID,
            onSubmit: onSubmit,
            onRequestHyperlink: onRequestHyperlink,
            onContentHeightChange: onContentHeightChange,
            onMoveToNextField: onMoveToNextField,
            onMoveToPreviousField: onMoveToPreviousField
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AutoSizingTextScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none

        let textView = CommandAwareTextView()
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = text
        textView.fieldID = fieldID
        textView.focusController = focusController
        textView.commandHandler = { selector in
            context.coordinator.handleCommand(selector)
        }
        textView.onRequestHyperlink = onRequestHyperlink

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        scrollView.onLayout = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.updateContentHeight(for: textView)
        }
        context.coordinator.textView = textView
        focusController.register(textView, fieldID: fieldID)
        context.coordinator.applySyntaxHighlighting()
        context.coordinator.updateContentHeight(for: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            textView.string = text
            // External reset (instance load, save-and-clear, type change) invalidates
            // undo entries' ranges into the old text.
            textView.undoManager?.removeAllActions()
            context.coordinator.applySyntaxHighlighting()
            if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
                layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: (text as NSString).length), actualCharacterRange: nil)
                layoutManager.ensureLayout(for: textContainer)
            }
        }
        (textView as? CommandAwareTextView)?.onRequestHyperlink = onRequestHyperlink
        focusController.register(textView, fieldID: fieldID)
        context.coordinator.updateContentHeight(for: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        let focusController: AddInstanceFieldFocusController
        let fieldID: Int64
        let onSubmit: () -> Void
        let onRequestHyperlink: ((CommandAwareTextView) -> Void)?
        let onContentHeightChange: (CGFloat) -> Void
        let onMoveToNextField: () -> Void
        let onMoveToPreviousField: () -> Void
        weak var textView: NSTextView?
        private let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        private let baseColor = NSColor.labelColor
        private static let htmlTagRegex = try! NSRegularExpression(pattern: #"</?[a-zA-Z][^>]*>"#)
        private static let htmlEntityRegex = try! NSRegularExpression(
            pattern: #"&(?:[a-zA-Z][a-zA-Z0-9]*|#[0-9]+|#[xX][0-9a-fA-F]+);"#
        )
        private static let htmlTagColor = NSColor(srgbRed: 0xf9/255.0, green: 0x26/255.0, blue: 0x72/255.0, alpha: 1.0)

        init(
            text: Binding<String>,
            focusController: AddInstanceFieldFocusController,
            fieldID: Int64,
            onSubmit: @escaping () -> Void,
            onRequestHyperlink: ((CommandAwareTextView) -> Void)?,
            onContentHeightChange: @escaping (CGFloat) -> Void,
            onMoveToNextField: @escaping () -> Void,
            onMoveToPreviousField: @escaping () -> Void
        ) {
            _text = text
            self.focusController = focusController
            self.fieldID = fieldID
            self.onSubmit = onSubmit
            self.onRequestHyperlink = onRequestHyperlink
            self.onContentHeightChange = onContentHeightChange
            self.onMoveToNextField = onMoveToNextField
            self.onMoveToPreviousField = onMoveToPreviousField
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            applySyntaxHighlighting()
            updateContentHeight(for: textView)
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

            Self.htmlTagRegex.enumerateMatches(in: textStorage.string, range: fullRange) { match, _, _ in
                guard let match else { return }
                textStorage.addAttribute(.foregroundColor, value: Self.htmlTagColor, range: match.range)
            }

            Self.htmlEntityRegex.enumerateMatches(in: textStorage.string, range: fullRange) { match, _, _ in
                guard let match else { return }
                textStorage.addAttribute(.foregroundColor, value: Self.htmlTagColor, range: match.range)
            }

            textStorage.endEditing()
            textView.selectedRanges = selectedRanges
        }

        func updateContentHeight(for textView: NSTextView) {
            guard let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let contentHeight = ceil(usedHeight + (textView.textContainerInset.height * 2))
            DispatchQueue.main.async { [onContentHeightChange] in
                onContentHeightChange(contentHeight)
            }
        }

        func handleCommand(_ selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertLineBreak(_:))
                || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                || selector == #selector(NSResponder.insertParagraphSeparator(_:)) {
                onSubmit()
                return true
            }

            if selector == #selector(NSResponder.insertTab(_:)) {
                onMoveToNextField()
                return true
            }

            if selector == #selector(NSResponder.insertBacktab(_:)) {
                onMoveToPreviousField()
                return true
            }

            return false
        }
    }

    final class CommandAwareTextView: NSTextView {
        weak var focusController: AddInstanceFieldFocusController?
        var fieldID: Int64?
        var commandHandler: ((Selector) -> Bool)?
        var onRequestHyperlink: ((CommandAwareTextView) -> Void)?

        private struct PendingEntityRevert {
            let entityRange: NSRange
            let originalString: String
        }
        private var pendingRevert: PendingEntityRevert?

        override func becomeFirstResponder() -> Bool {
            let didBecomeFirstResponder = super.becomeFirstResponder()
            if didBecomeFirstResponder, let fieldID {
                focusController?.setActiveField(fieldID)
            }
            return didBecomeFirstResponder
        }

        override func resignFirstResponder() -> Bool {
            pendingRevert = nil
            let didResignFirstResponder = super.resignFirstResponder()
            if didResignFirstResponder, focusController?.activeFieldID == fieldID {
                focusController?.setActiveField(nil)
            }
            return didResignFirstResponder
        }

        override func setSelectedRanges(
            _ ranges: [NSValue],
            affinity: NSSelectionAffinity,
            stillSelecting: Bool
        ) {
            pendingRevert = nil
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }

        private func previousCharacter() -> String? {
            guard let storage = textStorage else { return nil }
            let caret = selectedRange().location
            guard caret > 0, caret <= storage.length else { return nil }
            let nsString = storage.string as NSString
            let range = NSRange(location: caret - 1, length: 1)
            guard range.location + range.length <= nsString.length else { return nil }
            return nsString.substring(with: range)
        }

        override func insertText(_ string: Any, replacementRange: NSRange) {
            let s = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
            if EditorSettings.shared.autoReplaceHTMLEntities,
               (s == "<" || s == ">"),
               selectedRange().length == 0,
               let storage = textStorage,
               let prev = previousCharacter(),
               prev == s {
                let entity = (s == "<") ? "&lt;" : "&gt;"
                let original = (s == "<") ? "<<" : ">>"
                let priorRange = NSRange(location: selectedRange().location - 1, length: 1)
                let entityNSLength = (entity as NSString).length
                if shouldChangeText(in: priorRange, replacementString: entity) {
                    let attributed = NSAttributedString(string: entity, attributes: typingAttributes)
                    storage.replaceCharacters(in: priorRange, with: attributed)
                    didChangeText()
                    let caretLocation = priorRange.location + entityNSLength
                    setSelectedRange(NSRange(location: caretLocation, length: 0))
                    pendingRevert = PendingEntityRevert(
                        entityRange: NSRange(location: priorRange.location, length: entityNSLength),
                        originalString: original
                    )
                    return
                }
            }
            pendingRevert = nil
            super.insertText(string, replacementRange: replacementRange)
        }

        override func deleteBackward(_ sender: Any?) {
            if let pending = pendingRevert,
               selectedRange() == NSRange(
                   location: pending.entityRange.location + pending.entityRange.length,
                   length: 0
               ),
               let storage = textStorage,
               shouldChangeText(in: pending.entityRange, replacementString: pending.originalString) {
                let attributed = NSAttributedString(
                    string: pending.originalString,
                    attributes: typingAttributes
                )
                storage.replaceCharacters(in: pending.entityRange, with: attributed)
                didChangeText()
                let caretLocation = pending.entityRange.location
                    + (pending.originalString as NSString).length
                pendingRevert = nil
                setSelectedRange(NSRange(location: caretLocation, length: 0))
                return
            }
            pendingRevert = nil
            super.deleteBackward(sender)
        }

        override func doCommand(by selector: Selector) {
            if commandHandler?(selector) == true {
                return
            }

            super.doCommand(by: selector)
        }

        override func keyDown(with event: NSEvent) {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifierFlags == [.command], event.charactersIgnoringModifiers?.lowercased() == "k" {
                onRequestHyperlink?(self)
                return
            }

            // Return key (36) and numpad Enter (76)
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            if isReturnKey {
                if modifierFlags == [] {
                    // Plain Return: insert <br> then a newline
                    insertText("<br>\n", replacementRange: selectedRange())
                    return
                } else if modifierFlags == [.shift] {
                    // Shift+Return: insert a plain newline
                    insertText("\n", replacementRange: selectedRange())
                    return
                }
            }

            super.keyDown(with: event)
        }

        override func paste(_ sender: Any?) {
            guard let pastedString = NSPasteboard.general.string(forType: .string),
                  pastedString.hasPrefix("https://") else {
                super.paste(sender)
                return
            }

            let linkText = pastedString.removingPercentEncoding ?? pastedString
            let linkedString = #"<a href="\#(pastedString)">\#(linkText)</a>"#
            let selectedRange = selectedRange()
            guard shouldChangeText(in: selectedRange, replacementString: linkedString) else {
                return
            }

            let replacementAttributedString = NSAttributedString(
                string: linkedString,
                attributes: typingAttributes
            )
            textStorage?.replaceCharacters(in: selectedRange, with: replacementAttributedString)
            didChangeText()
            let caretLocation = selectedRange.location + (linkedString as NSString).length
            setSelectedRange(NSRange(location: caretLocation, length: 0))
        }
    }

    final class AutoSizingTextScrollView: NSScrollView {
        var onLayout: (() -> Void)?

        override func layout() {
            super.layout()
            onLayout?()
        }
    }
}
