//
//  AppDatabase+Offices.swift
//  Memor
//
//  Office CRUD for the Person Offices feature: the office table itself
//  (managed via the "Edit Offices" window and the editor's office picker),
//  plus the db-level holding/succession read helpers used by the Person save
//  engine and the built-in office query rendering.
//

import Foundation
import GRDB

/// One office row plus how many Person instances currently hold it.
nonisolated struct OfficeSummary: Identifiable, Hashable {
    let id: Int64
    let name: String
    let description: String
    let holderCount: Int
}

/// A suggestion row in the editor's office picker.
nonisolated struct OfficeCandidate: Identifiable, Hashable {
    let id: Int64
    let name: String
}

/// One (person, office) holding, as read for rendering and the editor.
nonisolated struct PersonOfficeHolding: Hashable {
    let personOfficeID: Int64
    let officeID: Int64
    let officeName: String
    let whenBegan: String
    let whenEnded: String
    let note: String
}

extension AppDatabase {

    // MARK: - Office CRUD

    /// Manager list + picker backing: every office (optionally name-filtered)
    /// with its holder count. nil/blank query lists all.
    func fetchOffices(matching query: String? = nil) throws -> [OfficeSummary] {
        try dbQueue.read { db in
            var whereClause = ""
            var arguments: [DatabaseValue] = []
            let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                whereClause = "WHERE o.name LIKE ? ESCAPE '\\'"
                arguments.append("%\(Self.escapedForLike(trimmed))%".databaseValue)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT o.id, o.name, o.description, COUNT(po.id) AS holderCount
                    FROM office o
                    LEFT JOIN person_office po ON po.office_id = o.id
                    \(whereClause)
                    GROUP BY o.id
                    ORDER BY o.name COLLATE NOCASE, o.id
                    """,
                arguments: StatementArguments(arguments)
            )
            return rows.map {
                OfficeSummary(id: $0["id"], name: $0["name"], description: $0["description"], holderCount: $0["holderCount"])
            }
        }
    }

    func fetchOffice(officeID: Int64) throws -> OfficeSummary? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT o.id, o.name, o.description, COUNT(po.id) AS holderCount
                    FROM office o
                    LEFT JOIN person_office po ON po.office_id = o.id
                    WHERE o.id = ?
                    GROUP BY o.id
                    """,
                arguments: [officeID]
            ).map {
                OfficeSummary(id: $0["id"], name: $0["name"], description: $0["description"], holderCount: $0["holderCount"])
            }
        }
    }

    /// Creates an office. Names are trimmed and unique case-insensitively
    /// (pre-checked for a friendly error; the unique index backstops races).
    @discardableResult
    func createOffice(name: String, description: String = "") throws -> Int64 {
        try dbQueue.write { db in
            let trimmed = try Self.validatedOfficeName(db: db, name: name, excludingOfficeID: nil)
            try db.execute(
                sql: "INSERT INTO office (name, description) VALUES (?, ?)",
                arguments: [trimmed, description]
            )
            return db.lastInsertedRowID
        }
    }

    /// Renames an office. Does NOT reset any queries — a rename is a text edit
    /// (like editing the office question HTML), not a connection change.
    func renameOffice(officeID: Int64, name: String) throws {
        try dbQueue.write { db in
            let trimmed = try Self.validatedOfficeName(db: db, name: name, excludingOfficeID: officeID)
            try db.execute(
                sql: "UPDATE office SET name = ? WHERE id = ?",
                arguments: [trimmed, officeID]
            )
            if db.changesCount == 0 {
                throw DatabaseError(message: "Office not found.")
            }
        }
    }

    func setOfficeDescription(officeID: Int64, description: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE office SET description = ? WHERE id = ?",
                arguments: [description, officeID]
            )
        }
    }

    /// Deletes an office. FK cascades remove every person's holding of it,
    /// all of its succession edges, and every per-office person_query row
    /// (irreversible SRS loss) — callers show the holder-count confirmation.
    func deleteOffice(officeID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM office WHERE id = ?", arguments: [officeID])
            if db.changesCount == 0 {
                throw DatabaseError(message: "Office not found.")
            }
        }
    }

    /// Suggestion rows for the editor's office picker. Empty query lists all.
    func fetchOfficeCandidates(matching query: String) throws -> [OfficeCandidate] {
        try dbQueue.read { db in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var whereClause = ""
            var arguments: [DatabaseValue] = []
            if !trimmed.isEmpty {
                whereClause = "WHERE name LIKE ? ESCAPE '\\'"
                arguments.append("%\(Self.escapedForLike(trimmed))%".databaseValue)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name FROM office
                    \(whereClause)
                    ORDER BY name COLLATE NOCASE, id
                    LIMIT 100
                    """,
                arguments: StatementArguments(arguments)
            )
            return rows.map { OfficeCandidate(id: $0["id"], name: $0["name"]) }
        }
    }

    /// Trims and validates an office name for create/rename: non-blank and
    /// unique case-insensitively (excluding the office being renamed).
    private nonisolated static func validatedOfficeName(
        db: Database,
        name: String,
        excludingOfficeID: Int64?
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError(message: "Office name cannot be blank.")
        }
        var sql = "SELECT id FROM office WHERE name = ? COLLATE NOCASE"
        var arguments: [DatabaseValue] = [trimmed.databaseValue]
        if let excludingOfficeID {
            sql += " AND id != ?"
            arguments.append(excludingOfficeID.databaseValue)
        }
        if try Int64.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) != nil {
            throw DatabaseError(message: "An office named \u{201C}\(trimmed)\u{201D} already exists.")
        }
        return trimmed
    }

    private nonisolated static func escapedForLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Holdings + succession (db-level reads)

    nonisolated static func fetchOfficeName(db: Database, officeID: Int64) throws -> String? {
        try String.fetchOne(db, sql: "SELECT name FROM office WHERE id = ?", arguments: [officeID])
    }

    /// One person's office holdings, in their own office order.
    nonisolated static func fetchPersonOfficeHoldings(db: Database, instanceID: Int64) throws -> [PersonOfficeHolding] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT po.id, po.office_id, o.name, po.when_began, po.when_ended, po.note
                FROM person_office po
                JOIN office o ON o.id = po.office_id
                WHERE po.instance_id = ?
                ORDER BY po.order_index, po.id
                """,
            arguments: [instanceID]
        ).map {
            PersonOfficeHolding(
                personOfficeID: $0["id"],
                officeID: $0["office_id"],
                officeName: $0["name"],
                whenBegan: $0["when_began"],
                whenEnded: $0["when_ended"],
                note: $0["note"]
            )
        }
    }

    /// One person's predecessors/successors in one office, each in edge-creation
    /// order (edge row ids are stable — the save engine only inserts/deletes
    /// exact edges, never rewrites surviving ones).
    nonisolated static func fetchOfficeSuccessionPeers(
        db: Database,
        instanceID: Int64,
        officeID: Int64
    ) throws -> (predecessors: [Int64], successors: [Int64]) {
        let predecessors = try Int64.fetchAll(
            db,
            sql: """
                SELECT predecessor_id FROM person_office_succession
                WHERE office_id = ? AND successor_id = ?
                ORDER BY id
                """,
            arguments: [officeID, instanceID]
        )
        let successors = try Int64.fetchAll(
            db,
            sql: """
                SELECT successor_id FROM person_office_succession
                WHERE office_id = ? AND predecessor_id = ?
                ORDER BY id
                """,
            arguments: [officeID, instanceID]
        )
        return (predecessors, successors)
    }
}
