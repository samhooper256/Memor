//
//  AppDatabase+Priority.swift
//  Memor
//
//  Study priority (1–10, default 1). Every instance (instance_id_type_id) and
//  every query row (query / person_query / pointmap_query / boundarymap_query)
//  stores its OWN priority; the two are never written through to each other.
//  A query's EFFECTIVE priority — what Study selection and the Stacks tab use
//  — is MAX(query priority, instance priority).
//

import Foundation
import GRDB

extension AppDatabase {
    /// SQL for the effective priority of a scanned query row. `srsAlias` names
    /// a row exposing the query's own `priority` and its `instance_id`: the
    /// `query` table, `pq` (person_query), or the directional `pp`/`bq`
    /// derived tables (pointMapDirectionalFrom / boundaryMapDirectionalFrom).
    nonisolated static func effectivePrioritySQL(srsAlias: String) -> String {
        """
        MAX(\(srsAlias).priority, COALESCE((SELECT prio_iit.priority FROM instance_id_type_id AS prio_iit \
        WHERE prio_iit.instance_id = \(srsAlias).instance_id), \(QUERY_PRIORITY_DEFAULT)))
        """
    }

    // MARK: - Instance priority

    func fetchInstancePriority(instanceID: Int64) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT priority FROM instance_id_type_id WHERE instance_id = ?",
                arguments: [instanceID]
            ) ?? QUERY_PRIORITY_DEFAULT
        }
    }

    /// The priority every given instance shares, or nil when they differ —
    /// the "Set Priority" submenus checkmark it. Large selections (beyond one
    /// statement's comfortable parameter count) also return nil.
    func fetchSharedInstancePriority(instanceIDs: some Swift.Collection<Int64>) -> Int? {
        guard !instanceIDs.isEmpty, instanceIDs.count <= 500 else { return nil }
        let placeholders = repeatElement("?", count: instanceIDs.count).joined(separator: ", ")
        let priorities = (try? dbQueue.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT DISTINCT priority FROM instance_id_type_id WHERE instance_id IN (\(placeholders))",
                arguments: StatementArguments(Array(instanceIDs))
            )
        }) ?? []
        return priorities.count == 1 ? priorities[0] : nil
    }

    /// Sets the instances' own priority. Never touches their queries' stored
    /// priorities (the instance value only raises their effective priority).
    /// Returns how many instance rows exist among `instanceIDs` (unknown ids
    /// are skipped).
    @discardableResult
    func setInstancePriority(instanceIDs: some Swift.Collection<Int64>, priority: Int) throws -> Int {
        guard !instanceIDs.isEmpty else { return 0 }
        let priority = clampedPriority(priority)
        return try dbQueue.write { db in
            var updatedCount = 0
            for instanceID in instanceIDs {
                try db.execute(
                    sql: "UPDATE instance_id_type_id SET priority = ? WHERE instance_id = ?",
                    arguments: [priority, instanceID]
                )
                updatedCount += db.changesCount
            }
            return updatedCount
        }
    }

    /// The ids among `instanceIDs` that name existing instances.
    func existingInstanceIDs(among instanceIDs: some Swift.Collection<Int64>) throws -> Set<Int64> {
        try dbQueue.read { db in
            var existing: Set<Int64> = []
            for instanceID in Set(instanceIDs) where try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM instance_id_type_id WHERE instance_id = ?",
                arguments: [instanceID]
            ) != nil {
                existing.insert(instanceID)
            }
            return existing
        }
    }

    /// Sets the own priority of every instance matching an INSTANCE-search
    /// expression (the Search window's Instances mode language). Returns the
    /// number of instances updated.
    @discardableResult
    func setInstancePriority(instanceSearch: String, priority: Int) throws -> Int {
        let instanceIDs = try searchInstances(query: instanceSearch).flatMap { $0.instances.map(\.id) }
        return try setInstancePriority(instanceIDs: instanceIDs, priority: priority)
    }

    // MARK: - Collection default priority

    /// Raises the instance's own priority to the collection's default
    /// priority when the default is higher; never lowers it. Call right after
    /// inserting a NEW membership row — re-asserting an existing membership
    /// must not re-raise a priority the user has since lowered.
    nonisolated static func raiseInstancePriorityToCollectionDefault(
        db: Database,
        instanceID: Int64,
        collectionID: Int64
    ) throws {
        try db.execute(
            sql: """
                UPDATE instance_id_type_id
                SET priority = (SELECT default_priority FROM collection WHERE id = ?)
                WHERE instance_id = ?
                    AND priority < (SELECT default_priority FROM collection WHERE id = ?)
                """,
            arguments: [collectionID, instanceID, collectionID]
        )
    }

    func fetchCollectionDefaultPriority(collectionID: Int64) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT default_priority FROM collection WHERE id = ?",
                arguments: [collectionID]
            ) ?? QUERY_PRIORITY_DEFAULT
        }
    }

    /// Sets a collection's default priority. Applies to FUTURE additions only;
    /// current members keep their priorities.
    func setCollectionDefaultPriority(collectionID: Int64, priority: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE collection SET default_priority = ? WHERE id = ?",
                arguments: [clampedPriority(priority), collectionID]
            )
        }
    }

    // MARK: - Query priority

    /// Stored priority of each enabled standard (`query` table) query on the
    /// instance, keyed by query type id.
    func fetchQueryPriorities(forInstanceID instanceID: Int64) throws -> [Int64: Int] {
        try dbQueue.read { db in
            var result: [Int64: Int] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT query_type_id, priority FROM query WHERE instance_id = ?",
                arguments: [instanceID]
            ) {
                guard let queryTypeID = row["query_type_id"] as Int64? else { continue }
                result[queryTypeID] = row["priority"] as Int? ?? QUERY_PRIORITY_DEFAULT
            }
            return result
        }
    }

    /// Writes the given standard queries' priorities. Query types without a
    /// row on the instance (not enabled) are skipped silently.
    func setQueryPriorities(instanceID: Int64, prioritiesByQueryTypeID: [Int64: Int]) throws {
        guard !prioritiesByQueryTypeID.isEmpty else { return }
        try dbQueue.write { db in
            for (queryTypeID, priority) in prioritiesByQueryTypeID {
                try db.execute(
                    sql: "UPDATE query SET priority = ? WHERE instance_id = ? AND query_type_id = ?",
                    arguments: [clampedPriority(priority), instanceID, queryTypeID]
                )
            }
        }
    }

    /// The stored priority every given query target shares, or nil when they
    /// differ (or the selection is very large) — for submenu checkmarks.
    func fetchSharedQueryPriority(targets: [QueryTarget]) -> Int? {
        guard !targets.isEmpty, targets.count <= 500 else { return nil }
        let priorities: Set<Int>? = try? dbQueue.read { db in
            var priorities: Set<Int> = []
            for target in targets {
                let priority: Int?
                switch target.kind {
                case .standard:
                    priority = try Int.fetchOne(
                        db,
                        sql: "SELECT priority FROM query WHERE instance_id = ? AND query_type_id = ?",
                        arguments: [target.instanceID, target.queryTypeID]
                    )
                case .point:
                    priority = try Int.fetchOne(
                        db,
                        sql: "SELECT priority FROM pointmap_query WHERE point_id = ? AND is_reverse = ?",
                        arguments: [target.queryTypeID, target.isReverse ? 1 : 0]
                    )
                case .boundary:
                    priority = try Int.fetchOne(
                        db,
                        sql: "SELECT priority FROM boundarymap_query WHERE attachment_id = ? AND is_reverse = ?",
                        arguments: [target.queryTypeID, target.isReverse ? 1 : 0]
                    )
                case .person:
                    priority = try Int.fetchOne(
                        db,
                        sql: """
                            SELECT priority FROM person_query
                            WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                            """,
                        arguments: [target.instanceID, target.personKind?.rawValue, target.personPartnershipID, target.personOfficeID]
                    )
                }
                if let priority { priorities.insert(priority) }
                if priorities.count > 1 { break }
            }
            return priorities
        }
        guard let priorities, priorities.count == 1 else { return nil }
        return priorities.first
    }

    /// The reset/disable/priority target for each result row of a
    /// query search. The table comes from the row's section (PointMap /
    /// BoundaryMap sections hold map queries) or, in the Person section, the
    /// row's own built-in kind.
    nonisolated static func queryTargets(from sections: [QuerySearchSection]) -> [QueryTarget] {
        sections.flatMap { section in
            section.queries.map { query in
                query.queryTarget(sectionTypeName: section.typeName)
            }
        }
    }

    /// Sets the stored priority of every query matching a QUERY-search
    /// expression — the Stacks language, so a stack's search text targets
    /// exactly that stack's queries. Returns the number of queries updated.
    @discardableResult
    func setQueryPriority(querySearch: String, priority: Int) throws -> Int {
        try setQueryPriority(targets: Self.queryTargets(from: searchQueries(query: querySearch)), priority: priority)
    }

    /// Sets the stored priority of specific query targets (any kind; one
    /// direction for map queries). Never touches instance priorities.
    /// Returns how many query rows were updated (targets without a row —
    /// disabled queries — are skipped).
    @discardableResult
    func setQueryPriority(targets: [QueryTarget], priority: Int) throws -> Int {
        guard !targets.isEmpty else { return 0 }
        let priority = clampedPriority(priority)
        return try dbQueue.write { db in
            var updatedCount = 0
            for target in targets {
                switch target.kind {
                case .standard:
                    try db.execute(
                        sql: "UPDATE query SET priority = ? WHERE instance_id = ? AND query_type_id = ?",
                        arguments: [priority, target.instanceID, target.queryTypeID]
                    )
                case .point:
                    try db.execute(
                        sql: """
                            UPDATE pointmap_query SET priority = ?
                            WHERE is_reverse = ? AND point_id IN (
                                SELECT id FROM pointmap_point WHERE id = ? AND instance_id = ?
                            )
                            """,
                        arguments: [priority, target.isReverse ? 1 : 0, target.queryTypeID, target.instanceID]
                    )
                case .boundary:
                    try db.execute(
                        sql: """
                            UPDATE boundarymap_query SET priority = ?
                            WHERE is_reverse = ? AND attachment_id IN (
                                SELECT id FROM boundarymap_attachment WHERE id = ? AND instance_id = ?
                            )
                            """,
                        arguments: [priority, target.isReverse ? 1 : 0, target.queryTypeID, target.instanceID]
                    )
                case .person:
                    guard let personKind = target.personKind else { continue }
                    try db.execute(
                        sql: """
                            UPDATE person_query SET priority = ?
                            WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                            """,
                        arguments: [priority, target.instanceID, personKind.rawValue, target.personPartnershipID, target.personOfficeID]
                    )
                }
                updatedCount += db.changesCount
            }
            return updatedCount
        }
    }
}

extension QuerySearchResult {
    /// This row's query target; `sectionTypeName` is the name of the search
    /// section holding it (map sections hold point/boundary queries).
    nonisolated func queryTarget(sectionTypeName: String) -> QueryTarget {
        // The Person section mixes standard (user-defined) rows with built-in
        // rows, so the kind is per row.
        if let personKind {
            return QueryTarget(
                instanceID: instanceID,
                queryTypeID: 0,
                isReverse: false,
                kind: .person,
                personKind: personKind,
                personPartnershipID: personPartnershipID,
                personOfficeID: personOfficeID
            )
        }
        let kind: QueryTargetKind
        switch sectionTypeName {
        case POINTMAP_TYPE_NAME: kind = .point
        case BOUNDARYMAP_TYPE_NAME: kind = .boundary
        default: kind = .standard
        }
        return QueryTarget(instanceID: instanceID, queryTypeID: queryTypeID, isReverse: isReverse, kind: kind)
    }
}
