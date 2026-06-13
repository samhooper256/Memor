//
//  PlainTextEditor.swift
//  Memor
//
//  Lightweight NSTextView wrapper for plain (non-rich) multi-line text editing.
//

import AppKit
import SwiftUI

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onBeginEditing: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onBeginEditing: onBeginEditing)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = text

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onBeginEditing = onBeginEditing
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onBeginEditing: (() -> Void)?
        weak var textView: NSTextView?

        init(text: Binding<String>, onBeginEditing: (() -> Void)?) {
            _text = text
            self.onBeginEditing = onBeginEditing
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            onBeginEditing?()
        }
    }
}
