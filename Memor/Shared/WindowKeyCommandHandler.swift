//
//  WindowKeyCommandHandler.swift
//  Memor
//
//  Background NSView that installs a local key monitor and routes ⌘-prefixed chords to closures.
//

import AppKit
import SwiftUI

struct WindowKeyCommandHandler: NSViewRepresentable {
    let onEscape: () -> Void
    let onCommandReturn: (() -> Void)?
    let onCommandS: (() -> Void)?
    var onCommandB: (() -> Void)? = nil
    let onCommandI: (() -> Void)?
    let onCommandO: (() -> Void)?
    var onCommandJ: (() -> Void)? = nil
    var onCommandL: (() -> Void)? = nil
    var onCommandT: (() -> Void)? = nil
    var onFocusCollectionSearch: (() -> Void)? = nil
    var shortcutSettings: ShortcutSettings? = nil

    func makeNSView(context: Context) -> KeyCommandHandlingView {
        let view = KeyCommandHandlingView()
        view.onEscape = onEscape
        view.onCommandReturn = onCommandReturn
        view.onCommandS = onCommandS
        view.onCommandB = onCommandB
        view.onCommandI = onCommandI
        view.onCommandO = onCommandO
        view.onCommandJ = onCommandJ
        view.onCommandL = onCommandL
        view.onCommandT = onCommandT
        view.onFocusCollectionSearch = onFocusCollectionSearch
        view.shortcutSettings = shortcutSettings
        return view
    }

    func updateNSView(_ nsView: KeyCommandHandlingView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onCommandReturn = onCommandReturn
        nsView.onCommandS = onCommandS
        nsView.onCommandB = onCommandB
        nsView.onCommandI = onCommandI
        nsView.onCommandO = onCommandO
        nsView.onCommandJ = onCommandJ
        nsView.onCommandL = onCommandL
        nsView.onCommandT = onCommandT
        nsView.onFocusCollectionSearch = onFocusCollectionSearch
        nsView.shortcutSettings = shortcutSettings
    }

    final class KeyCommandHandlingView: NSView {
        var onEscape: (() -> Void)?
        var onCommandReturn: (() -> Void)?
        var onCommandS: (() -> Void)?
        var onCommandB: (() -> Void)?
        var onCommandI: (() -> Void)?
        var onCommandO: (() -> Void)?
        var onCommandJ: (() -> Void)?
        var onCommandL: (() -> Void)?
        var onCommandT: (() -> Void)?
        var onFocusCollectionSearch: (() -> Void)?
        var shortcutSettings: ShortcutSettings?

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
                guard let self, event.window === self.window else {
                    return event
                }

                if self.isEscape(event) {
                    self.onEscape?()
                    return nil
                }

                if self.isCommandReturn(event) {
                    self.onCommandReturn?()
                    return nil
                }

                if self.isCommandS(event) {
                    self.onCommandS?()
                    return nil
                }

                if self.isCommandB(event) {
                    self.onCommandB?()
                    return nil
                }

                if self.isCommandI(event) {
                    self.onCommandI?()
                    return nil
                }

                if self.matchesInsertImage(event) {
                    self.onCommandO?()
                    return nil
                }

                if self.isCommandJ(event) {
                    self.onCommandJ?()
                    return nil
                }

                if self.isCommandL(event) {
                    self.onCommandL?()
                    return nil
                }

                if self.isCommandT(event) {
                    self.onCommandT?()
                    return nil
                }

                if self.onFocusCollectionSearch != nil, self.matchesFocusCollectionSearch(event) {
                    self.onFocusCollectionSearch?()
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

        private func isEscape(_ event: NSEvent) -> Bool {
            event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}"
        }

        private func isCommandReturn(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }

            return event.keyCode == 36
                || event.keyCode == 76
                || event.charactersIgnoringModifiers == "\r"
                || event.charactersIgnoringModifiers == "\u{3}"
        }

        private func isCommandB(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "b"
        }

        private func isCommandS(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "s"
        }

        private func isCommandI(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "i"
        }

        private func matchesInsertImage(_ event: NSEvent) -> Bool {
            if let settings = shortcutSettings {
                return settings.binding(for: .editorInsertImage).matches(event)
            }
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "o"
        }

        private func isCommandJ(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "j"
        }

        private func isCommandL(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "l"
        }

        private func isCommandT(_ event: NSEvent) -> Bool {
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifierFlags == [.command] else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "t"
        }

        private func matchesFocusCollectionSearch(_ event: NSEvent) -> Bool {
            guard let settings = shortcutSettings else { return false }
            return settings.binding(for: .editorFocusCollectionSearch).matches(event)
        }
    }
}
