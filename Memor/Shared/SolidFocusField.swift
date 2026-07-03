//
//  SolidFocusField.swift
//  Memor
//
//  The app-standard flat text-field chrome: solid controlBackgroundColor fill,
//  rounded corners, and a 1pt hairline stroke that turns SOLID blue when the
//  field is focused. No focus ring, no glow, no animation. Replaces
//  .textFieldStyle(.roundedBorder) everywhere a field could show the native
//  macOS focus glow.
//

import SwiftUI

extension View {
    /// Full treatment for SwiftUI `TextField`s: plain style, system focus
    /// effect disabled, internal focus tracking, flat chrome. Caller-owned
    /// `.focused(...)` bindings keep working — multiple focused bindings on
    /// one field all update together.
    func solidFocusField(cornerRadius: CGFloat = 6) -> some View {
        modifier(SolidFocusFieldModifier(cornerRadius: cornerRadius))
    }

    /// Chrome-only variant for AppKit-backed fields (NSViewRepresentable)
    /// that report first-responder status via an explicit callback —
    /// @FocusState does not track NSTextField first responder, so those
    /// wrappers pass the flag in.
    func solidFocusFieldChrome(isFocused: Bool, cornerRadius: CGFloat = 6) -> some View {
        self
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        isFocused ? Color.blue : Color.secondary.opacity(0.15),
                        lineWidth: 1
                    )
            }
    }
}

private struct SolidFocusFieldModifier: ViewModifier {
    let cornerRadius: CGFloat
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .focused($isFocused)
            .solidFocusFieldChrome(isFocused: isFocused, cornerRadius: cornerRadius)
    }
}
