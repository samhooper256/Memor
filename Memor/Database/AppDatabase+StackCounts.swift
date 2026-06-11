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

    /// One search expression shared by every stack whose search parses to it
    /// (identical and empty searches collapse into a single group), so each
    /// scan target is read once per refresh instead of once per stack.
    nonisolated private struct StackCountGroup {
        let expression: SearchExpression?
        var stackIDs: [Int64]
    }

    nonisolated private struct GroupCountTotals {
        var blue = 0
        var red = 0
        var green = 0
        var magenta = 0

        var stackQueryCounts: StackQueryCounts {
            StackQueryCounts(
                blueQueryCount: blue,
                redQueryCount: red,
                greenQueryCount: green,
                magentaQueryCount: magenta
            )
        }
    }

    func refreshStackQueryCounts() throws -> [Int64: StackQueryCounts?] {
        let startOfTomorrowTimestamp = TimeZoneSettings.shared.startOfTomorrowTimestamp()
        let countsByStackID = try dbQueue.write { db -> [Int64: StackQueryCounts?] in
            let countsByStackID = try computeAllStackQueryCounts(
                db: db,
                startOfTomorrowTimestamp: startOfTomorrowTimestamp
            )

            try db.execute(
                sql: """
                    UPDATE globals
                    SET value = ?
                    WHERE name = ?
                    """,
                arguments: [
                    String(Int(Date().timeIntervalSince1970)),
                    "stacks_last_updated_timestamp"
                ]
            )

            return countsByStackID
        }

        #if DEBUG
        do {
            let legacyCountsByStackID = try legacyRefreshStackQueryCounts()
            if legacyCountsByStackID != countsByStackID {
                print("⚠️ Stack count parity mismatch — batched: \(countsByStackID), legacy: \(legacyCountsByStackID)")
            }
        } catch {
            print("⚠️ Stack count parity oracle failed: \(error)")
        }
        #endif

        return countsByStackID
    }

    func refreshStackQueryCounts(for stack: Stack) throws -> StackQueryCounts {
        let startOfTomorrowTimestamp = TimeZoneSettings.shared.startOfTomorrowTimestamp()
        return try dbQueue.read { db in
            let parsedQuery = try parseQuerySearchQuery(stack.search)
            try validateCollectionSearchComponents(Self.collectionNames(in: parsedQuery.expression), db: db)

            return try computeQueryCountGroups(
                db: db,
                groups: [parsedQuery.expression],
                typeInfos: fetchInstanceSearchTypeInfos(db: db),
                startOfTomorrowTimestamp: startOfTomorrowTimestamp
            )[0]
        }
    }

    nonisolated private func computeAllStackQueryCounts(
        db: Database,
        startOfTomorrowTimestamp: Int64
    ) throws -> [Int64: StackQueryCounts?] {
        let stackRows = try Row.fetchAll(db, sql: "SELECT id, search FROM stack")
        let typeInfos = try fetchInstanceSearchTypeInfos(db: db)

        var countsByStackID: [Int64: StackQueryCounts?] = [:]
        var groups: [StackCountGroup] = []
        var groupIndexByExpression: [SearchExpression?: Int] = [:]
        var validatedCollectionNames: Set<String> = []

        for stackRow in stackRows {
            let stackID: Int64 = stackRow["id"]
            let search: String = stackRow["search"] ?? ""
            do {
                let parsedQuery = try parseQuerySearchQuery(search)
                let unvalidatedNames = Self.collectionNames(in: parsedQuery.expression)
                    .filter { !validatedCollectionNames.contains($0) }
                try validateCollectionSearchComponents(unvalidatedNames, db: db)
                validatedCollectionNames.formUnion(unvalidatedNames)

                if let groupIndex = groupIndexByExpression[parsedQuery.expression] {
                    groups[groupIndex].stackIDs.append(stackID)
                } else {
                    groupIndexByExpression[parsedQuery.expression] = groups.count
                    groups.append(StackCountGroup(expression: parsedQuery.expression, stackIDs: [stackID]))
                }
            } catch {
                // A stack whose search fails to parse or references a missing
                // collection gets nil counts and is excluded from the batches,
                // so it cannot poison the other stacks' refresh.
                countsByStackID[stackID] = nil as StackQueryCounts?
            }
        }

        let groupCounts = try computeQueryCountGroups(
            db: db,
            groups: groups.map(\.expression),
            typeInfos: typeInfos,
            startOfTomorrowTimestamp: startOfTomorrowTimestamp
        )
        for (group, counts) in zip(groups, groupCounts) {
            for stackID in group.stackIDs {
                countsByStackID[stackID] = counts
            }
        }

        return countsByStackID
    }

    /// Computes the four color-bucket counts for every expression in `groups`,
    /// scanning each type table at most once for all groups combined.
    nonisolated func computeQueryCountGroups(
        db: Database,
        groups: [SearchExpression?],
        typeInfos: [InstanceSearchTypeInfo],
        startOfTomorrowTimestamp: Int64
    ) throws -> [StackQueryCounts] {
        var totals = [GroupCountTotals](repeating: GroupCountTotals(), count: groups.count)

        for typeInfo in typeInfos {
            var includedGroups: [(groupIndex: Int, sql: String, arguments: StatementArguments)] = []
            for (groupIndex, expression) in groups.enumerated() {
                switch Self.staticTruthValue(
                    of: expression,
                    typeName: typeInfo.typeName,
                    newIsAlwaysFalse: false
                ) {
                case .some(false):
                    continue
                case .some(true):
                    includedGroups.append((groupIndex, "1", StatementArguments()))
                case .none:
                    let condition = makeQuerySearchConditions(
                        tableAlias: "instance_table",
                        typeName: typeInfo.typeName,
                        fieldIndices: typeInfo.allFieldIndices,
                        expression: expression
                    )
                    includedGroups.append((groupIndex, condition.sql, condition.arguments))
                }
            }

            try addBatchedCategoryCounts(
                db: db,
                fromClause: """
                    FROM "type\(typeInfo.typeID)" AS instance_table
                    JOIN query
                        ON query.instance_id = instance_table.id
                    """,
                srsAlias: "query",
                includedGroups: includedGroups,
                startOfTomorrowTimestamp: startOfTomorrowTimestamp,
                totals: &totals
            )
        }

        var pointMapGroups: [(groupIndex: Int, sql: String, arguments: StatementArguments)] = []
        var boundaryMapGroups: [(groupIndex: Int, sql: String, arguments: StatementArguments)] = []
        for (groupIndex, expression) in groups.enumerated() {
            switch Self.staticTruthValue(
                of: expression,
                typeName: POINTMAP_TYPE_NAME,
                newIsAlwaysFalse: true
            ) {
            case .some(false):
                break
            case .some(true):
                pointMapGroups.append((groupIndex, "1", StatementArguments()))
            case .none:
                let condition = makePointMapSearchConditions(
                    expression: expression,
                    pointAlias: "pp",
                    instanceAlias: "pi",
                    includePointName: true
                )
                pointMapGroups.append((groupIndex, condition.sql, condition.arguments))
            }

            switch Self.staticTruthValue(
                of: expression,
                typeName: BOUNDARYMAP_TYPE_NAME,
                newIsAlwaysFalse: true
            ) {
            case .some(false):
                break
            case .some(true):
                boundaryMapGroups.append((groupIndex, "1", StatementArguments()))
            case .none:
                let condition = makeBoundaryMapSearchConditions(
                    expression: expression,
                    attachmentAlias: "bq",
                    instanceAlias: "bi",
                    boundaryAlias: "b",
                    includeBoundaryName: true
                )
                boundaryMapGroups.append((groupIndex, condition.sql, condition.arguments))
            }
        }

        try addBatchedCategoryCounts(
            db: db,
            fromClause: """
                FROM \(Self.pointMapDirectionalFrom) AS pp
                JOIN pointmap_instance AS pi
                    ON pi.instance_id = pp.instance_id
                """,
            srsAlias: "pp",
            includedGroups: pointMapGroups,
            startOfTomorrowTimestamp: startOfTomorrowTimestamp,
            totals: &totals
        )

        try addBatchedCategoryCounts(
            db: db,
            fromClause: """
                FROM \(Self.boundaryMapDirectionalFrom) AS bq
                JOIN boundarymap_instance AS bi
                    ON bi.instance_id = bq.instance_id
                JOIN boundary AS b
                    ON b.id = bq.boundary_id
                """,
            srsAlias: "bq",
            includedGroups: boundaryMapGroups,
            startOfTomorrowTimestamp: startOfTomorrowTimestamp,
            totals: &totals
        )

        return totals.map(\.stackQueryCounts)
    }

    /// Runs one statement (or a few, if SQLite limits force chunking) over
    /// `fromClause`, computing each row's color bucket once and a 0/1 match
    /// flag per group, and adds the 4-per-group SUM results into `totals`.
    /// `srsAlias` is the alias exposing `interval` and `last_answered_timestamp`.
    nonisolated private func addBatchedCategoryCounts(
        db: Database,
        fromClause: String,
        srsAlias: String,
        includedGroups: [(groupIndex: Int, sql: String, arguments: StatementArguments)],
        startOfTomorrowTimestamp: Int64,
        totals: inout [GroupCountTotals]
    ) throws {
        guard !includedGroups.isEmpty else { return }

        // Stay far below SQLite's bound-parameter and result-column limits.
        // All condition arguments are positional, so the placeholder count in
        // the SQL text is exactly the argument count.
        let maxArgumentsPerStatement = 500
        let maxGroupsPerStatement = 120

        var chunk: [(groupIndex: Int, sql: String, arguments: StatementArguments)] = []
        var chunkArgumentCount = 0

        func flushChunk() throws {
            guard !chunk.isEmpty else { return }

            var matchColumns: [String] = []
            var sumColumns: [String] = []
            var arguments = StatementArguments([startOfTomorrowTimestamp, startOfTomorrowTimestamp])
            for (chunkIndex, group) in chunk.enumerated() {
                matchColumns.append("(\(group.sql)) AS m\(chunkIndex)")
                for bucket in 0...3 {
                    sumColumns.append("COALESCE(SUM(CASE WHEN m\(chunkIndex) AND bucket = \(bucket) THEN 1 ELSE 0 END), 0)")
                }
                arguments += group.arguments
            }

            let sql = """
                SELECT
                    \(sumColumns.joined(separator: ",\n        "))
                FROM (
                    SELECT
                        CASE
                            WHEN \(srsAlias).interval = 0 THEN 0
                            WHEN \(srsAlias).interval <= \(QUERY_STARTER_DELAY_GOOD) THEN 1
                            WHEN \(srsAlias).last_answered_timestamp + \(srsAlias).interval < ? THEN 2
                            WHEN \(srsAlias).last_answered_timestamp + \(srsAlias).interval >= ? THEN 3
                            ELSE -1
                        END AS bucket,
                        \(matchColumns.joined(separator: ",\n            "))
                    \(fromClause)
                )
                """

            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else {
                throw DatabaseError(message: "Failed to fetch batched stack query counts.")
            }
            for (chunkIndex, group) in chunk.enumerated() {
                totals[group.groupIndex].blue += row[chunkIndex * 4]
                totals[group.groupIndex].red += row[chunkIndex * 4 + 1]
                totals[group.groupIndex].green += row[chunkIndex * 4 + 2]
                totals[group.groupIndex].magenta += row[chunkIndex * 4 + 3]
            }

            chunk = []
            chunkArgumentCount = 0
        }

        for group in includedGroups {
            let argumentCount = group.sql.count(where: { $0 == "?" })
            if !chunk.isEmpty,
               chunk.count >= maxGroupsPerStatement
                || chunkArgumentCount + argumentCount > maxArgumentsPerStatement {
                try flushChunk()
            }
            chunk.append(group)
            chunkArgumentCount += argumentCount
        }
        try flushChunk()
    }
}
