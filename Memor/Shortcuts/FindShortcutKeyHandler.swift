//
//  FindShortcutKeyHandler.swift
//  Memor
//
//  Background NSEvent monitor that fires `onTriggered` when the user's
//  `.findInList` shortcut is pressed while the hosting view's window is key.
//  Used by list pages (Collections, Types) and the Search window to focus
//  their search box.
//

import AppKit
import SwiftUI

struct FindShortcutKeyHandler: NSViewRepresentable {
    let shortcutSettings: ShortcutSettings
    let onTriggered: () -> Void

    func makeNSView(context: Context) -> KeyHandlingView {
        let view = KeyHandlingView()
        view.shortcutSettings = shortcutSettings
        view.onTriggered = onTriggered
        return view
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        nsView.shortcutSettings = shortcutSettings
        nsView.onTriggered = onTriggered
    }

    final class KeyHandlingView: NSView {
        var shortcutSettings: ShortcutSettings?
        var onTriggered: (() -> Void)?

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
                if let binding = self.shortcutSettings?.binding(for: .findInList),
                   binding.matches(event) {
                    self.onTriggered?()
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
