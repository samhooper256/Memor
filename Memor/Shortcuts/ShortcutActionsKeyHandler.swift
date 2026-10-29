//
//  ShortcutActionsKeyHandler.swift
//  Memor
//
//  Background NSEvent monitor that runs the handler of whichever listed
//  action's CURRENT binding matches a key press in the hosting view's window
//  — the multi-action generalization of FindShortcutKeyHandler. Drop it in a
//  `.background` of the view whose lifetime the shortcuts should share: the
//  monitor is installed when the view joins a window and removed when it
//  leaves. The first listed match wins and the event is consumed. Bindings
//  are read live, so a rebinding in Settings takes effect at once.
//

import AppKit
import SwiftUI

struct ShortcutActionsKeyHandler: NSViewRepresentable {
    let shortcutSettings: ShortcutSettings
    let handlers: [(action: ShortcutAction, handler: () -> Void)]

    func makeNSView(context: Context) -> KeyHandlingView {
        let view = KeyHandlingView()
        view.shortcutSettings = shortcutSettings
        view.handlers = handlers
        return view
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        nsView.shortcutSettings = shortcutSettings
        nsView.handlers = handlers
    }

    final class KeyHandlingView: NSView {
        var shortcutSettings: ShortcutSettings?
        var handlers: [(action: ShortcutAction, handler: () -> Void)] = []

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
                guard let self, event.window === self.window, let settings = self.shortcutSettings else {
                    return event
                }
                for entry in self.handlers where settings.binding(for: entry.action).matches(event) {
                    entry.handler()
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
