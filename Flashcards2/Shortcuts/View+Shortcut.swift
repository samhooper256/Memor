//
//  View+Shortcut.swift
//  Memor
//
//  Apply a user-customizable shortcut to a SwiftUI view.
//

import SwiftUI

extension View {
    /// Attach the user's current binding for the given action as a SwiftUI `.keyboardShortcut`.
    /// The caller must observe `ShortcutSettings` (via `@ObservedObject`/`@EnvironmentObject`)
    /// so that rebinding triggers a re-render.
    func shortcut(_ action: ShortcutAction, settings: ShortcutSettings) -> some View {
        let binding = settings.binding(for: action)
        return self.keyboardShortcut(binding.swiftUIKeyEquivalent, modifiers: binding.swiftUIModifiers)
    }
}
