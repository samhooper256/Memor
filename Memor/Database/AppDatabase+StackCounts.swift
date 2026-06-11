//
//  AppDatabase+StackCounts.swift
//  Memor
//
//  Stack query-count refresh helpers. The Stacks-tab refresh used to run one
//  count statement per (stack, type) pair; the helpers here let it prune scan
//  targets a stack's search can never match and batch the rest.
//

import Foundation
import GRDB

extension AppDatabase {
    /// ASCII-only case-insensitive equality, matching SQLite's built-in NOCASE
    /// collation (which folds only A–Z, unlike Swift's Unicode-aware
    /// caseInsensitiveCompare).
    nonisolated static func sqliteNocaseEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = a.utf8
        let bBytes = b.utf8
        guard aBytes.count == bBytes.count else { return false }

        func folded(_ byte: UInt8) -> UInt8 {
            (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
        }

        return zip(aBytes, bBytes).allSatisfy { folded($0) == folded($1) }
    }

    /// Statically evaluates a search expression against a known scan target
    /// (a type table, or one of the two map scans). Returns `true` when the
    /// expression provably matches every row, `false` when it provably matches
    /// none (the scan can be skipped for this expression), and `nil` when the
    /// outcome is row-dependent.
    ///
    /// Sound because the only folded leaves compile to row-independent SQL:
    /// `.type` becomes `? = ? COLLATE NOCASE` over two bound constants, and
    /// `.new` becomes the constant `0` in the map condition builders. Unknown
    /// over-approximates {true, false, NULL}, and the Kleene connectives below
    /// agree with SQL three-valued logic on the known cases.
    nonisolated static func staticTruthValue(
        of expression: SearchExpression?,
        typeName: String,
        newIsAlwaysFalse: Bool
    ) -> Bool? {
        guard let expression else { return true }

        func evaluate(_ expression: SearchExpression) -> Bool? {
            switch expression {
            case .literal, .collection, .id, .noQueries:
                return nil
            case .type(let searchedTypeName):
                return sqliteNocaseEquals(typeName, searchedTypeName)
            case .new:
                return newIsAlwaysFalse ? false : nil
            case .and(let left, let right):
                let l = evaluate(left)
                let r = evaluate(right)
                if l == false || r == false { return false }
                if l == true && r == true { return true }
                return nil
            case .or(let left, let right):
                let l = evaluate(left)
                let r = evaluate(right)
                if l == true || r == true { return true }
                if l == false && r == false { return false }
                return nil
            case .not(let inner):
                return evaluate(inner).map { !$0 }
            }
        }

        return evaluate(expression)
    }
}
