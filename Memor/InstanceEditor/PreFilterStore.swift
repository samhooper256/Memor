//
//  PreFilterStore.swift
//  Memor
//
//  Persisted list of hyperlink-popup "pre-filters" — saved search strings that are
//  AND-ed with the user's search input (singleton, UserDefaults-backed).
//

import Combine
import Foundation

@MainActor
final class PreFilterStore: ObservableObject {
    static let shared = PreFilterStore()
    private static let userDefaultsKey = "com.sam.Memor.preFilters"

    @Published private(set) var preFilters: [String]   // insertion order

    private init() {
        preFilters = (UserDefaults.standard.array(forKey: Self.userDefaultsKey) as? [String]) ?? []
    }

    func add(_ s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !preFilters.contains(trimmed) else { return }
        preFilters.append(trimmed)
        persist()
    }

    func remove(_ s: String) {
        guard let index = preFilters.firstIndex(of: s) else { return }
        preFilters.remove(at: index)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(preFilters, forKey: Self.userDefaultsKey)
    }
}
