//
//  DeveloperState.swift
//  Memor
//
//  App-wide Developer mode state (singleton). The opt-in ("Allow Developer Mode
//  access") is persisted in UserDefaults; whether Developer mode is currently
//  active is runtime-only and always starts off on launch.
//

import Combine
import Foundation

@MainActor
final class DeveloperState: ObservableObject {
    static let shared = DeveloperState()
    private static let userDefaultsKey = "com.sam.Memor.developerSettings"

    /// Persisted opt-in. Disabling it immediately exits Developer mode.
    @Published var allowDeveloperModeAccess: Bool {
        didSet {
            persist()
            if !allowDeveloperModeAccess {
                isDeveloperModeEnabled = false
            }
        }
    }

    /// Runtime only — always false on startup, never persisted. Only `toggleDeveloperMode()`
    /// flips it, so the access gate can't be bypassed.
    @Published private(set) var isDeveloperModeEnabled = false

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) ?? [:]
        allowDeveloperModeAccess = (raw["allowDeveloperModeAccess"] as? Bool) ?? false
    }

    /// Toggles Developer mode, but only when access is allowed; otherwise a no-op.
    func toggleDeveloperMode() {
        guard allowDeveloperModeAccess else { return }
        isDeveloperModeEnabled.toggle()
    }

    private func persist() {
        UserDefaults.standard.set(
            ["allowDeveloperModeAccess": allowDeveloperModeAccess],
            forKey: Self.userDefaultsKey
        )
    }
}
