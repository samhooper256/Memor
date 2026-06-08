//
//  ShortcutSettings.swift
//  Memor
//
//  ObservableObject store for user-customizable keyboard shortcuts.
//  Persists via UserDefaults under `com.sam.Memor.shortcuts`.
//

import Combine
import Foundation
import SwiftUI

final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    private static let userDefaultsKey = "com.sam.Memor.shortcuts"

    @Published private(set) var bindings: [ShortcutAction: KeyBinding]

    private init() {
        self.bindings = Self.loadFromUserDefaults()
    }

    func binding(for action: ShortcutAction) -> KeyBinding {
        bindings[action] ?? action.default
    }

    func set(_ binding: KeyBinding, for action: ShortcutAction) {
        bindings[action] = binding
        persist()
    }

    func reset(_ action: ShortcutAction) {
        bindings.removeValue(forKey: action)
        persist()
    }

    func resetAll() {
        bindings.removeAll()
        persist()
    }

    func isDefault(_ action: ShortcutAction) -> Bool {
        guard let current = bindings[action] else { return true }
        return current == action.default
    }

    /// Returns the action that currently uses the same binding (if any), excluding `excluding`.
    func conflictingAction(for binding: KeyBinding, excluding: ShortcutAction) -> ShortcutAction? {
        for action in ShortcutAction.allCases where action != excluding {
            if self.binding(for: action) == binding {
                return action
            }
        }
        return nil
    }

    // MARK: - Persistence

    private func persist() {
        let encodable: [String: KeyBinding] = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    private static func loadFromUserDefaults() -> [ShortcutAction: KeyBinding] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data)
        else { return [:] }

        var result: [ShortcutAction: KeyBinding] = [:]
        for (rawKey, binding) in decoded {
            if let action = ShortcutAction(rawValue: rawKey) {
                result[action] = binding
            }
        }
        return result
    }
}
