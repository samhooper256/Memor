//
//  EditorSettings.swift
//  Memor
//
//  Persisted, app-wide editor-behavior preferences (singleton, UserDefaults-backed).
//

import Combine
import Foundation

@MainActor
final class EditorSettings: ObservableObject {
    static let shared = EditorSettings()
    private static let userDefaultsKey = "com.sam.Memor.editorSettings"

    @Published var autoReplaceHTMLEntities: Bool {
        didSet { persist() }
    }

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) ?? [:]
        autoReplaceHTMLEntities = (raw["autoReplaceHTMLEntities"] as? Bool) ?? false
    }

    private func persist() {
        UserDefaults.standard.set(
            ["autoReplaceHTMLEntities": autoReplaceHTMLEntities],
            forKey: Self.userDefaultsKey
        )
    }
}
