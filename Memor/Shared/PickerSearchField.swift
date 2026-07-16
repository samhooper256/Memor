//
//  PickerSearchField.swift
//  Memor
//
//  The keyboard-navigable search box used by picker popups (the Person
//  relationship picker, the PointMap move-points picker): an NSTextField that
//  stays focused (and typeable) while ↑/↓ move the row highlight and Return
//  chooses the highlighted row — the same interaction as the ⌘K
//  hyperlink-search field. Arrow/Return keys are intercepted in the field
//  editor's doCommandBy, so the caret and all normal text editing are
//  untouched.
//

import AppKit
import SwiftUI

struct PickerSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let onMoveDown: () -> Void
    let onMoveUp: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            onMoveDown: onMoveDown,
            onMoveUp: onMoveUp,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onFocusChange = context.coordinator.setFocused
        return field
    }

    func updateNSView(_ nsView: Field, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        @Binding private var isFocused: Bool
        var onMoveDown: () -> Void
        var onMoveUp: () -> Void
        var onSubmit: () -> Void
        var onCancel: () -> Void

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onMoveDown: @escaping () -> Void,
            onMoveUp: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            _text = text
            _isFocused = isFocused
            self.onMoveDown = onMoveDown
            self.onMoveUp = onMoveUp
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func setFocused(_ focused: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.isFocused = focused
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            text = (obj.object as? NSTextField)?.stringValue ?? ""
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            setFocused(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.moveDown(_:)) {
                onMoveDown()
                return true
            }
            if selector == #selector(NSResponder.moveUp(_:)) {
                onMoveUp()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.insertLineBreak(_:))
                || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                onSubmit()
                return true
            }
            // Escape must be consumed HERE: a popover's responder chain
            // continues into the anchor view's window, so an unhandled
            // cancelOperation reaches the editor window's onExitCommand and
            // closes the whole editor instead of just this popup. (Esc can
            // also arrive as complete: in a field editor.)
            if selector == #selector(NSResponder.cancelOperation(_:))
                || selector == #selector(NSStandardKeyBindingResponding.complete(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }

    final class Field: NSTextField {
        var onFocusChange: ((Bool) -> Void)?
        private var hasAutoFocused = false

        // Focus the search box as soon as the popup appears so arrows and
        // typing work immediately.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !hasAutoFocused else { return }
            hasAutoFocused = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func becomeFirstResponder() -> Bool {
            let didBecome = super.becomeFirstResponder()
            if didBecome {
                onFocusChange?(true)
            }
            return didBecome
        }
    }
}
