//
//  KeyBinding.swift
//  Memor
//
//  Represents a user-configurable keyboard shortcut.
//

import AppKit
import SwiftUI

struct KeyBinding: Codable, Equatable, Hashable {
    /// Canonical key token: a single uppercase letter ("A".."Z"), a digit ("0".."9"),
    /// or a named key ("Space", "Return", "Escape", "Tab", "Comma", "Period", "Slash",
    /// "Backtick", "Minus", "Equal", "LeftBracket", "RightBracket", "Backslash",
    /// "Semicolon", "Quote").
    let key: String

    /// SwiftUI EventModifiers rawValue bit field.
    let modifiers: UInt32

    init(key: String, modifiers: EventModifiers = []) {
        self.key = key
        self.modifiers = UInt32(modifiers.rawValue)
    }

    var swiftUIModifiers: EventModifiers {
        EventModifiers(rawValue: Int(modifiers))
    }

    var swiftUIKeyEquivalent: KeyEquivalent {
        switch key {
        case "Space": return KeyEquivalent(" ")
        case "Return": return .return
        case "Escape": return .escape
        case "Tab": return .tab
        case "Delete": return .delete
        case "LeftArrow": return .leftArrow
        case "RightArrow": return .rightArrow
        case "UpArrow": return .upArrow
        case "DownArrow": return .downArrow
        case "Comma": return KeyEquivalent(",")
        case "Period": return KeyEquivalent(".")
        case "Slash": return KeyEquivalent("/")
        case "Backtick": return KeyEquivalent("`")
        case "Minus": return KeyEquivalent("-")
        case "Equal": return KeyEquivalent("=")
        case "LeftBracket": return KeyEquivalent("[")
        case "RightBracket": return KeyEquivalent("]")
        case "Backslash": return KeyEquivalent("\\")
        case "Semicolon": return KeyEquivalent(";")
        case "Quote": return KeyEquivalent("'")
        default:
            if let scalar = key.unicodeScalars.first, key.count == 1 {
                return KeyEquivalent(Character(scalar).lowercased().first ?? Character(scalar))
            }
            return KeyEquivalent(Character("?"))
        }
    }

    /// A human-readable display string like "⌘⇧A" or "Space" or "⌘1".
    var displayString: String {
        var result = ""
        let mods = swiftUIModifiers
        if mods.contains(.control) { result += "⌃" }
        if mods.contains(.option) { result += "⌥" }
        if mods.contains(.shift) { result += "⇧" }
        if mods.contains(.command) { result += "⌘" }
        result += keyDisplayName
        return result
    }

    private var keyDisplayName: String {
        switch key {
        case "Space": return "Space"
        case "Return": return "⏎"
        case "Escape": return "⎋"
        case "Tab": return "⇥"
        case "Delete": return "⌫"
        case "LeftArrow": return "←"
        case "RightArrow": return "→"
        case "UpArrow": return "↑"
        case "DownArrow": return "↓"
        case "Comma": return ","
        case "Period": return "."
        case "Slash": return "/"
        case "Backtick": return "`"
        case "Minus": return "-"
        case "Equal": return "="
        case "LeftBracket": return "["
        case "RightBracket": return "]"
        case "Backslash": return "\\"
        case "Semicolon": return ";"
        case "Quote": return "'"
        default: return key
        }
    }

    /// Matches an NSEvent keyDown to this binding.
    func matches(_ event: NSEvent) -> Bool {
        let requiredFlags: NSEvent.ModifierFlags = Self.nsModifierFlags(from: swiftUIModifiers)
        let eventFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock, .help])
        guard eventFlags == requiredFlags else { return false }

        // Named keys are matched by keyCode (modifier-independent).
        if let expectedKeyCode = Self.keyCode(for: key) {
            return event.keyCode == expectedKeyCode
        }

        // Letters/digits/punctuation: compare charactersIgnoringModifiers.
        // Strip Shift when comparing so "⌘⇧A" matches "A" not "a".
        var compareEvent = event.charactersIgnoringModifiers ?? ""
        if !requiredFlags.contains(.shift) {
            compareEvent = compareEvent.lowercased()
        }
        return compareEvent == key.lowercased() || compareEvent == key
    }

    private static func nsModifierFlags(from mods: EventModifiers) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if mods.contains(.command) { result.insert(.command) }
        if mods.contains(.shift) { result.insert(.shift) }
        if mods.contains(.option) { result.insert(.option) }
        if mods.contains(.control) { result.insert(.control) }
        return result
    }

    static func keyCode(for named: String) -> UInt16? {
        switch named {
        case "Space": return 49
        case "Return": return 36
        case "Escape": return 53
        case "Tab": return 48
        case "Delete": return 51
        case "LeftArrow": return 123
        case "RightArrow": return 124
        case "DownArrow": return 125
        case "UpArrow": return 126
        default: return nil
        }
    }

    /// Build a `KeyBinding` from a captured `NSEvent` keyDown. Returns nil for unrecognized keys.
    static func fromEvent(_ event: NSEvent) -> KeyBinding? {
        let modifierFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock, .help])

        var swiftUIMods: EventModifiers = []
        if modifierFlags.contains(.command) { swiftUIMods.insert(.command) }
        if modifierFlags.contains(.shift) { swiftUIMods.insert(.shift) }
        if modifierFlags.contains(.option) { swiftUIMods.insert(.option) }
        if modifierFlags.contains(.control) { swiftUIMods.insert(.control) }

        if let named = namedKey(for: event.keyCode) {
            return KeyBinding(key: named, modifiers: swiftUIMods)
        }

        guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return nil }
        let character = raw.first!
        if character.isLetter {
            return KeyBinding(key: String(character).uppercased(), modifiers: swiftUIMods)
        }
        if character.isNumber {
            return KeyBinding(key: String(character), modifiers: swiftUIMods)
        }
        switch character {
        case ",": return KeyBinding(key: "Comma", modifiers: swiftUIMods)
        case ".": return KeyBinding(key: "Period", modifiers: swiftUIMods)
        case "/": return KeyBinding(key: "Slash", modifiers: swiftUIMods)
        case "`": return KeyBinding(key: "Backtick", modifiers: swiftUIMods)
        case "-": return KeyBinding(key: "Minus", modifiers: swiftUIMods)
        case "=": return KeyBinding(key: "Equal", modifiers: swiftUIMods)
        case "[": return KeyBinding(key: "LeftBracket", modifiers: swiftUIMods)
        case "]": return KeyBinding(key: "RightBracket", modifiers: swiftUIMods)
        case "\\": return KeyBinding(key: "Backslash", modifiers: swiftUIMods)
        case ";": return KeyBinding(key: "Semicolon", modifiers: swiftUIMods)
        case "'": return KeyBinding(key: "Quote", modifiers: swiftUIMods)
        default: return nil
        }
    }

    private static func namedKey(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 53: return "Escape"
        case 48: return "Tab"
        case 51: return "Delete"
        case 123: return "LeftArrow"
        case 124: return "RightArrow"
        case 125: return "DownArrow"
        case 126: return "UpArrow"
        default: return nil
        }
    }
}
