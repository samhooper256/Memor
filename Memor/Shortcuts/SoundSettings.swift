//
//  SoundSettings.swift
//  Memor
//
//  Persisted, app-wide sound preferences (singleton, UserDefaults-backed).
//

import Combine
import Foundation

final class SoundSettings: ObservableObject {
    static let shared = SoundSettings()
    private static let userDefaultsKey = "com.sam.Memor.soundSettings"

    @Published var soundEffectsEnabled: Bool {
        didSet { persist() }
    }

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) ?? [:]
        soundEffectsEnabled = (raw["soundEffectsEnabled"] as? Bool) ?? true
    }

    private func persist() {
        UserDefaults.standard.set(
            ["soundEffectsEnabled": soundEffectsEnabled],
            forKey: Self.userDefaultsKey
        )
    }
}
