//
//  ShortcutLabel.swift
//  Memor
//
//  Renders "Title (⌘R)" style labels that update live when shortcuts change.
//

import SwiftUI

struct ShortcutLabel: View {
    let title: String
    let action: ShortcutAction
    @EnvironmentObject var shortcuts: ShortcutSettings

    var body: some View {
        Text("\(title) (\(shortcuts.binding(for: action).displayString))")
    }
}
