//
//  TypesListKeyNavigationHandler.swift
//  Memor
//
//  Background NSEvent monitor for the Types list page: bare ↑/↓ move the
//  keyboard-selected type and Return/Enter opens it. A window-scoped local
//  monitor fires before the event reaches the focused field editor, so these
//  keys work even while the "Search types" box has focus — and consuming them
//  (returning nil) leaves that focus untouched (the search box keeps its caret).
//

import AppKit
import SwiftUI

struct TypesListKeyNavigationHandler: NSViewRepresentable {
    let isEnabled: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onOpen: () -> Void

    func makeNSView(context: Context) -> KeyHandlingView {
        let view = KeyHandlingView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: KeyHandlingView) {
        view.isEnabled = isEnabled
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.onOpen = onOpen
    }

    final class KeyHandlingView: NSView {
        var isEnabled = false
        var onMoveUp: (() -> Void)?
        var onMoveDown: (() -> Void)?
        var onOpen: (() -> Void)?

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
                guard let self, self.isEnabled, event.window === self.window else { return event }
                // Only grab bare keys — leave anything with ⌘/⌥/⌃/⇧ to other handlers.
                // NB: arrow keys always carry .function and .numericPad, so we must
                // ignore those (and .capsLock) rather than require *no* modifiers.
                let blockingModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                guard event.modifierFlags.intersection(blockingModifiers).isEmpty else { return event }

                switch event.keyCode {
                case 126: // up arrow
                    self.onMoveUp?()
                    return nil
                case 125: // down arrow
                    self.onMoveDown?()
                    return nil
                case 36, 76: // Return / keypad Enter
                    self.onOpen?()
                    return nil
                default:
                    return event
                }
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
