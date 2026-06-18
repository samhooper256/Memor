//
//  TableInsertSizeStore.swift
//  Memor
//
//  Remembers the last table size inserted via the "Insert Table" popup, for the
//  duration of the app session. Runtime-only — resets to 2x2 on each launch.
//

import Foundation

@MainActor
final class TableInsertSizeStore {
    static let shared = TableInsertSizeStore()

    var lastRows = 2
    var lastCols = 2

    private init() {}
}
