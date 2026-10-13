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
    func setInstancePriority(instanceIDs: some Swift.Collection<Int64>, priority: Int) throws {
        guard !instanceIDs.isEmpty else { return }
        let priority = clampedPriority(priority)
        try dbQueue.write { db in
            for instanceID in instanceIDs {
                try db.execute(
                    sql: "UPDATE instance_id_type_id SET priority = ? WHERE instance_id = ?",
                    arguments: [priority, instanceID]
                )
            }
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

    /// Sets the stored priority of specific query targets (any kind; one
    /// direction for map queries). Never touches instance priorities.
    func setQueryPriority(targets: [QueryTarget], priority: Int) throws {
        guard !targets.isEmpty else { return }
        let priority = clampedPriority(priority)
        try dbQueue.write { db in
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
            }
        }
    }
}
