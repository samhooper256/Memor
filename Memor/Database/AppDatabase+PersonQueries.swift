//
//  AppDatabase+PersonQueries.swift
//  Memor
//
//  Built-in Person relationship queries: enablement, SRS apply/revert, and —
//  most importantly — makePersonStudyQuery, the SINGLE seam where a built-in
//  query's question/answer HTML is computed from relationship data. Study
//  mode, the Query Preview window, and the MCP render_query tool must all go
//  through it (directly or via fetchPersonQueryPreview) so every surface
//  renders identically. The HTML flows through the normal template/CSS
//  pipeline (StudyQuery.kind stays .standard).
//

import Foundation
import GRDB

extension AppDatabase {

    // MARK: - Customizable "details" HTML (shared by all built-in queries)

    /// The stored details HTML, or the default when the user hasn't customized it.
    func fetchPersonBuiltinQueryHTML() throws -> String {
        try dbQueue.read { db in try Self.personBuiltinQueryHTML(db: db) }
    }

    func setPersonBuiltinQueryHTML(_ html: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO globals (name, value) VALUES (?, ?)",
                arguments: [PERSON_BUILTIN_QUERY_HTML_GLOBAL_KEY, html]
            )
        }
    }

    nonisolated static func personBuiltinQueryHTML(db: Database) throws -> String {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM globals WHERE name = ?",
            arguments: [PERSON_BUILTIN_QUERY_HTML_GLOBAL_KEY]
        ) ?? PERSON_BUILTIN_QUERY_HTML_DEFAULT
    }

    // MARK: - Office question template (shared by .office and .allOffices)

    /// The stored office question HTML, or the default when not customized.
    /// Question side only — the office answer layout is fixed.
    func fetchPersonOfficeQueryHTML() throws -> String {
        try dbQueue.read { db in try Self.personOfficeQueryHTML(db: db) }
    }

    func setPersonOfficeQueryHTML(_ html: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO globals (name, value) VALUES (?, ?)",
                arguments: [PERSON_OFFICE_QUERY_HTML_GLOBAL_KEY, html]
            )
        }
    }

    nonisolated static func personOfficeQueryHTML(db: Database) throws -> String {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM globals WHERE name = ?",
            arguments: [PERSON_OFFICE_QUERY_HTML_GLOBAL_KEY]
        ) ?? PERSON_OFFICE_QUERY_HTML_DEFAULT
    }

    /// The stored office query footer HTML, or the (empty) default. Injected
    /// below the rendered office list on every built-in office query; empty ⇒
    /// nothing injected.
    func fetchPersonOfficeQueryFooterHTML() throws -> String {
        try dbQueue.read { db in try Self.personOfficeQueryFooterHTML(db: db) }
    }

    func setPersonOfficeQueryFooterHTML(_ html: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO globals (name, value) VALUES (?, ?)",
                arguments: [PERSON_OFFICE_QUERY_FOOTER_HTML_GLOBAL_KEY, html]
            )
        }
    }

    nonisolated static func personOfficeQueryFooterHTML(db: Database) throws -> String {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM globals WHERE name = ?",
            arguments: [PERSON_OFFICE_QUERY_FOOTER_HTML_GLOBAL_KEY]
        ) ?? PERSON_OFFICE_QUERY_FOOTER_HTML_DEFAULT
    }

    /// Appends the footer below an already-rendered office list; passes the
    /// list through untouched when no footer is set.
    private nonisolated static func appendingOfficeQueryFooter(
        db: Database,
        to officeListHTML: String
    ) throws -> String {
        let footerHTML = try personOfficeQueryFooterHTML(db: db)
        guard !footerHTML.isEmpty else { return officeListHTML }
        return officeListHTML + "\n" + footerHTML
    }

    /// Substitutes the per-holding {{@…}} tokens into the office question
    /// template. Runs BEFORE the normal {{FieldName}} pipeline (so e.g.
    /// {{Name}} in the template still resolves later); values are raw HTML by
    /// app convention, never escaped.
    private nonisolated static func renderedOfficeTemplate(
        _ template: String,
        holding: PersonOfficeHolding
    ) -> String {
        template
            .replacingOccurrences(of: "{{@Office}}", with: holding.officeName)
            .replacingOccurrences(of: "{{@WhenBegan}}", with: holding.whenBegan)
            .replacingOccurrences(of: "{{@WhenEnded}}", with: holding.whenEnded)
            .replacingOccurrences(of: "{{@Note}}", with: holding.note)
    }

    // MARK: - Enablement

    /// Enables/disables one built-in query (row existence = enabled).
    /// `partnershipID` is required exactly for .childrenWith; `officeID`
    /// exactly for .office. Both conditions use null-safe `IS ?` so a
    /// discriminator-less kind never touches discriminated rows.
    func setPersonQueryEnabled(
        instanceID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        officeID: Int64? = nil,
        enabled: Bool
    ) throws {
        try dbQueue.write { db in
            if enabled {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO person_query (instance_id, kind, partnership_id, office_id)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [instanceID, kind.rawValue, partnershipID, officeID]
                )
            } else {
                try db.execute(
                    sql: """
                        DELETE FROM person_query
                        WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                        """,
                    arguments: [instanceID, kind.rawValue, partnershipID, officeID]
                )
            }
        }
    }

    /// Batch enable/disable of ONE office's per-office queries across many
    /// people — the Instances tab's context-menu "Office…" action. Of
    /// `instanceIDs`, only current holders of the office are touched (the
    /// per-office query row may only exist while a holding does; enabling on
    /// a non-holder would orphan a row no other surface knows about). Returns
    /// how many of the instances hold the office and how many query rows
    /// actually changed (already-enabled/-disabled holders are no-ops).
    func setPersonOfficeQueryEnabled(
        officeID: Int64,
        instanceIDs: Set<Int64>,
        enabled: Bool
    ) throws -> (holders: Int, changed: Int) {
        guard !instanceIDs.isEmpty else { return (holders: 0, changed: 0) }
        return try dbQueue.write { db in
            let idList = instanceIDs.map(String.init).joined(separator: ",")
            let holderIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT instance_id FROM person_office
                    WHERE office_id = ? AND instance_id IN (\(idList))
                    """,
                arguments: [officeID]
            )
            var changed = 0
            for instanceID in holderIDs {
                if enabled {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO person_query (instance_id, kind, partnership_id, office_id)
                            VALUES (?, ?, NULL, ?)
                            """,
                        arguments: [instanceID, PersonQueryKind.office.rawValue, officeID]
                    )
                } else {
                    try db.execute(
                        sql: """
                            DELETE FROM person_query
                            WHERE instance_id = ? AND kind = ? AND partnership_id IS NULL AND office_id = ?
                            """,
                        arguments: [instanceID, PersonQueryKind.office.rawValue, officeID]
                    )
                }
                changed += db.changesCount
            }
            return (holders: holderIDs.count, changed: changed)
        }
    }

    /// Full built-in query list for one instance: the standalone kinds
    /// (including All Offices), one "Children with {partner}" per partnership
    /// (in this person's partner order), and one "Office: {name}" per
    /// DISTINCT held office (in first-stint order — the query is per office,
    /// however many stints), each with enablement + SRS state.
    func fetchPersonBuiltinQueryInfos(instanceID: Int64) throws -> [PersonBuiltinQueryInfo] {
        try dbQueue.read { db in
            try Self.fetchPersonBuiltinQueryInfos(db: db, instanceID: instanceID)
        }
    }

    nonisolated static func fetchPersonBuiltinQueryInfos(db: Database, instanceID: Int64) throws -> [PersonBuiltinQueryInfo] {
        var infos: [PersonBuiltinQueryInfo] = []

        func appendInfo(kind: PersonQueryKind, partnershipID: Int64?, officeID: Int64?, displayName: String) throws {
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT interval, query_state, last_answered_timestamp
                    FROM person_query
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                    """,
                arguments: [instanceID, kind.rawValue, partnershipID, officeID]
            )
            infos.append(PersonBuiltinQueryInfo(
                kind: kind,
                partnershipID: partnershipID,
                officeID: officeID,
                displayName: displayName,
                enabled: row != nil,
                interval: row?["interval"],
                queryState: (row?["query_state"] as Int?).flatMap(QueryState.init(rawValue:)),
                lastAnsweredTimestamp: row?["last_answered_timestamp"]
            ))
        }

        for kind in PersonQueryKind.standaloneKinds {
            try appendInfo(kind: kind, partnershipID: nil, officeID: nil, displayName: kind.displayName)
        }
        let partnerships = try fetchPersonPartnershipSummaries(db: db, personID: instanceID)
        for partnership in partnerships {
            try appendInfo(
                kind: .childrenWith,
                partnershipID: partnership.id,
                officeID: nil,
                displayName: try personChildrenWithDisplayName(db: db, partnerRef: partnership.partner)
            )
        }
        var seenOfficeIDs: Set<Int64> = []
        for holding in try fetchPersonOfficeHoldings(db: db, instanceID: instanceID)
        where seenOfficeIDs.insert(holding.officeID).inserted {
            try appendInfo(
                kind: .office,
                partnershipID: nil,
                officeID: holding.officeID,
                displayName: "Office: \(holding.officeName)"
            )
        }
        return infos
    }

    /// "Children with {partner display name}".
    nonisolated static func personChildrenWithDisplayName(db: Database, partnerRef: PersonRef) throws -> String {
        switch partnerRef {
        case .instance(let id):
            let name = try fetchInstanceDisplayValue(db: db, instanceID: id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "Children with \(name.isEmpty ? "#\(id)" : name)"
        case .bare(let name):
            return "Children with \(name)"
        }
    }

    /// Light partnership summaries for `personID`, in their partner order.
    nonisolated struct PersonPartnershipSummary {
        let id: Int64
        let partner: PersonRef
        let sideInstanceIDs: [Int64]
        let startText: String
        let endText: String
    }

    nonisolated static func fetchPersonPartnershipSummaries(db: Database, personID: Int64) throws -> [PersonPartnershipSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, a_id, b_id, b_bare, a_order_index, b_order_index, start_text, end_text
                FROM person_partnership
                WHERE a_id = ?1 OR b_id = ?1
                ORDER BY CASE WHEN a_id = ?1 THEN a_order_index ELSE b_order_index END, id
                """,
            arguments: [personID]
        )
        return rows.map { row in
            let aID = row["a_id"] as Int64
            let bID = row["b_id"] as Int64?
            let partner: PersonRef
            if aID == personID {
                partner = bID.map(PersonRef.instance) ?? .bare(row["b_bare"] as String? ?? "")
            } else {
                partner = .instance(aID)
            }
            var sides = [aID]
            if let bID { sides.append(bID) }
            return PersonPartnershipSummary(
                id: row["id"],
                partner: partner,
                sideInstanceIDs: sides,
                startText: row["start_text"] as String? ?? "",
                endText: row["end_text"] as String? ?? ""
            )
        }
    }

    /// The Partners answer's " (start–end)" date suffix for one stint — en
    /// dash like the TimePeriod/office ranges, one-sided stays one-sided
    /// ("1206–" / "–1227") — or nil when both dates are blank (no empty
    /// parentheses).
    private nonisolated static func partnershipDatesSuffixHTML(startText: String, endText: String) -> String? {
        let start = startText.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = endText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !start.isEmpty || !end.isEmpty else { return nil }
        return " <span class=\"person-partner-dates\">(\(start)\u{2013}\(end))</span>"
    }

    // MARK: - Enumeration (search / stacks / study MUST all use this FROM)

    /// The scan target for built-in Person queries: the Person type{N} table
    /// (so literal:/type:/collection:/id: conditions compile unchanged with
    /// tableAlias "instance_table") joined to person_query as `pq` (the
    /// srsAlias for `:new` and interval predicates). Every enumeration surface
    /// — query search, stack counts, due-day forecasts, study pools — must use
    /// this fragment with makeQuerySearchConditions(srsAlias: "pq") so they
    /// never diverge.
    nonisolated static func personQueryJoinFrom(personTypeID: Int64) -> String {
        """
        "type\(personTypeID)" AS instance_table
        JOIN person_query AS pq
            ON pq.instance_id = instance_table.id
        """
    }

    /// The Person type's InstanceSearchTypeInfo (field indices + display
    /// column) for callers that don't already have the full type list.
    nonisolated func personSearchTypeInfo(db: Database) throws -> InstanceSearchTypeInfo? {
        guard let personTypeID = try? Self.fetchPersonTypeID(db: db) else { return nil }
        return try fetchInstanceSearchTypeInfos(db: db).first { $0.typeID == personTypeID }
    }

    private nonisolated struct PersonQueryScanRow: FetchableRecord, Decodable {
        let instanceID: Int64
        let kind: String
        let partnershipID: Int64?
        let officeID: Int64?
        let interval: Int64
        let lastAnsweredTimestamp: Int64?
        let queryState: Int
        let displayValue: String
    }

    private nonisolated func fetchPersonQueryScanRows(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments,
        limitSQL: String = "",
        limitArguments: StatementArguments = StatementArguments()
    ) throws -> [PersonQueryScanRow] {
        let searchConditions = makeQuerySearchConditions(
            tableAlias: "instance_table",
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression,
            srsAlias: "pq"
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        arguments += limitArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"

        return try PersonQueryScanRow.fetchAll(
            db,
            sql: """
                SELECT
                    pq.instance_id AS instanceID,
                    pq.kind AS kind,
                    pq.partnership_id AS partnershipID,
                    pq.office_id AS officeID,
                    pq.interval AS interval,
                    pq.last_answered_timestamp AS lastAnsweredTimestamp,
                    pq.query_state AS queryState,
                    COALESCE(instance_table."field\(typeInfo.displayFieldIndex)", '') AS displayValue
                FROM \(Self.personQueryJoinFrom(personTypeID: typeInfo.typeID))
                WHERE \(searchSQL)
                ORDER BY displayValue COLLATE NOCASE, pq.instance_id, pq.kind, pq.partnership_id, pq.office_id
                \(limitSQL)
                """,
            arguments: arguments
        )
    }

    /// Query-search rows for the built-in queries ("Bob" + "Children with
    /// Alice", ...), merged by the caller into the Person type's section.
    func fetchPersonQuerySearchRows(
        db: Database,
        typeInfo: InstanceSearchTypeInfo,
        parsedQuery: QuerySearchQuery
    ) throws -> [QuerySearchResult] {
        let rows = try fetchPersonQueryScanRows(
            db: db,
            typeInfo: typeInfo,
            parsedQuery: parsedQuery,
            whereSQL: "1",
            additionalArguments: StatementArguments()
        )
        return try rows.map { row in
            let kind = PersonQueryKind(rawValue: row.kind) ?? .mother
            return QuerySearchResult(
                instanceID: row.instanceID,
                queryTypeID: 0,
                displayValue: row.displayValue,
                queryTypeName: try Self.personQueryTypeName(
                    db: db, personID: row.instanceID, kind: kind, partnershipID: row.partnershipID, officeID: row.officeID
                ),
                personKind: kind,
                personPartnershipID: row.partnershipID,
                personOfficeID: row.officeID
            )
        }
    }

    func fetchPersonStudyQueries(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> [StudyQuery] {
        guard let typeInfo = try personSearchTypeInfo(db: db) else { return [] }
        let rows = try fetchPersonQueryScanRows(
            db: db,
            typeInfo: typeInfo,
            parsedQuery: parsedQuery,
            whereSQL: whereSQL,
            additionalArguments: additionalArguments
        )
        return try rows.map { row in
            try Self.makePersonStudyQuery(
                db: db,
                instanceID: row.instanceID,
                kind: PersonQueryKind(rawValue: row.kind) ?? .mother,
                partnershipID: row.partnershipID,
                officeID: row.officeID,
                interval: row.interval,
                lastAnsweredTimestamp: row.lastAnsweredTimestamp,
                queryState: QueryState(rawValue: row.queryState) ?? .zero
            )
        }
    }

    func fetchPersonStudySummary(
        db: Database,
        parsedQuery: QuerySearchQuery
    ) throws -> PersonStudySummary? {
        guard let typeInfo = try personSearchTypeInfo(db: db) else { return nil }
        let searchConditions = makeQuerySearchConditions(
            tableAlias: "instance_table",
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression,
            srsAlias: "pq"
        )
        let whereClause = searchConditions.sql.isEmpty ? "1" : searchConditions.sql
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    COUNT(*) AS totalCount,
                    COALESCE(SUM(CASE WHEN pq.interval = 0 THEN 1 ELSE 0 END), 0) AS newCount,
                    MIN(CASE WHEN pq.interval != 0 THEN pq.last_answered_timestamp + pq.interval END) AS minimumSeenDueTimestamp
                FROM \(Self.personQueryJoinFrom(personTypeID: typeInfo.typeID))
                WHERE \(whereClause)
                """,
            arguments: searchConditions.arguments
        ) else {
            return nil
        }
        return PersonStudySummary(
            totalCount: row["totalCount"],
            newCount: row["newCount"],
            minimumSeenDueTimestamp: row["minimumSeenDueTimestamp"]
        )
    }

    func fetchPersonStudyQueryCount(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> Int {
        guard let typeInfo = try personSearchTypeInfo(db: db) else { return 0 }
        let searchConditions = makeQuerySearchConditions(
            tableAlias: "instance_table",
            typeName: typeInfo.typeName,
            typeID: typeInfo.typeID,
            fieldIndices: typeInfo.allFieldIndices,
            expression: parsedQuery.expression,
            srsAlias: "pq"
        )
        var arguments = searchConditions.arguments
        arguments += additionalArguments
        let searchSQL = searchConditions.sql.isEmpty ? whereSQL : "(\(searchConditions.sql)) AND (\(whereSQL))"
        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM \(Self.personQueryJoinFrom(personTypeID: typeInfo.typeID))
                WHERE \(searchSQL)
                """,
            arguments: arguments
        ) ?? 0
    }

    func fetchRandomPersonStudyQuery(
        db: Database,
        parsedQuery: QuerySearchQuery,
        whereSQL: String,
        additionalArguments: StatementArguments
    ) throws -> StudyQuery {
        guard let typeInfo = try personSearchTypeInfo(db: db) else {
            throw DatabaseError(message: "The built-in Person type is missing.")
        }
        let matchingCount = try fetchPersonStudyQueryCount(
            db: db,
            parsedQuery: parsedQuery,
            whereSQL: whereSQL,
            additionalArguments: additionalArguments
        )
        guard matchingCount > 0 else {
            throw DatabaseError(message: "No study query matched the requested criteria.")
        }
        let rows = try fetchPersonQueryScanRows(
            db: db,
            typeInfo: typeInfo,
            parsedQuery: parsedQuery,
            whereSQL: whereSQL,
            additionalArguments: additionalArguments,
            limitSQL: "LIMIT 1 OFFSET ?",
            limitArguments: [Int.random(in: 0..<matchingCount)]
        )
        guard let row = rows.first else {
            throw DatabaseError(message: "Failed to fetch the selected study query.")
        }
        return try Self.makePersonStudyQuery(
            db: db,
            instanceID: row.instanceID,
            kind: PersonQueryKind(rawValue: row.kind) ?? .mother,
            partnershipID: row.partnershipID,
            officeID: row.officeID,
            interval: row.interval,
            lastAnsweredTimestamp: row.lastAnsweredTimestamp,
            queryState: QueryState(rawValue: row.queryState) ?? .zero
        )
    }

    // MARK: - SRS apply / revert

    @discardableResult
    func applyPersonStudyResponse(
        instanceID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        officeID: Int64? = nil,
        rating: StudyResponseRating,
        answeredAtTimestamp: Int64,
        overrideInterval: Int64? = nil
    ) throws -> StudyResponseOutcome {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT interval, query_state FROM person_query
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                    """,
                arguments: [instanceID, kind.rawValue, partnershipID, officeID]
            ) else {
                throw DatabaseError(message: "Person query not found.")
            }

            let currentInterval = row["interval"] as Int64? ?? 0
            let currentState = QueryState(rawValue: row["query_state"] as Int? ?? 0) ?? .zero
            let outcome = studyResponseOutcome(
                currentState: currentState,
                currentInterval: currentInterval,
                rating: rating
            )
            let updatedInterval = overrideInterval ?? outcome.newInterval

            try db.execute(
                sql: """
                    UPDATE person_query
                    SET query_state = ?, last_answered_timestamp = ?, interval = ?
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                    """,
                arguments: [outcome.newState.rawValue, answeredAtTimestamp, updatedInterval, instanceID, kind.rawValue, partnershipID, officeID]
            )
            return StudyResponseOutcome(newState: outcome.newState, newInterval: updatedInterval)
        }
    }

    func revertPersonStudyResponse(
        instanceID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        officeID: Int64? = nil,
        originalInterval: Int64,
        originalLastAnsweredTimestamp: Int64?,
        originalQueryState: QueryState
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE person_query
                    SET query_state = ?, last_answered_timestamp = ?, interval = ?
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                    """,
                arguments: [
                    originalQueryState.rawValue,
                    originalLastAnsweredTimestamp,
                    originalInterval,
                    instanceID,
                    kind.rawValue,
                    partnershipID,
                    officeID,
                ]
            )
            // Surface undo of a since-deleted query instead of silently no-oping
            // (mirrors applyPersonStudyResponse's existence guard).
            if db.changesCount == 0 {
                throw DatabaseError(message: "Person query not found.")
            }
        }
    }

    // MARK: - Rendering (the single computed-HTML seam)

    /// Default styling for the computed answer markup, prepended to the Person
    /// type's CSS so user CSS overrides it at equal specificity.
    nonisolated static let personBuiltinQueryDefaultCSS = """
        .person-question-title { margin-bottom: 8px; }
        .person-self { color: #e6b422; }
        .person-na { color: gray; }
        .person-parent-label { color: gray; }
        .person-partner-dates { color: gray; }
        .person-children-group { margin: 4px 0; }
        .person-children-group-title { color: gray; }
        .office-succession { width: 100%; display: flex; align-items: stretch; text-align: center; }
        .office-succession-preds, .office-succession-succs { flex: 0 0 20%; }
        .office-succession-holder { flex: 0 0 60%; border-left: 1px solid white; border-right: 1px solid white; }
        .office-succession-note { color: gray; }
        .office-succession-dates { color: gray; }
        """

    /// Assembles one built-in Person query as a renderable StudyQuery: fixed
    /// question template + answer body computed from live relationship data,
    /// wrapped exactly like a standard answer so the global template and
    /// question reference resolve normally.
    nonisolated static func makePersonStudyQuery(
        db: Database,
        instanceID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        officeID: Int64? = nil,
        interval: Int64,
        lastAnsweredTimestamp: Int64?,
        queryState: QueryState
    ) throws -> StudyQuery {
        let personTypeID = try fetchPersonTypeID(db: db)

        let fields = try TypeField.fetchAll(
            db,
            sql: """
                SELECT
                    id,
                    type_id AS typeID,
                    name,
                    field_index AS fieldIndex,
                    field_display_index AS fieldDisplayIndex,
                    field_type AS fieldType
                FROM field
                WHERE type_id = ?
                ORDER BY field_display_index, id
                """,
            arguments: [personTypeID]
        )
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM \"type\(personTypeID)\" WHERE id = ?",
            arguments: [instanceID]
        ) else {
            throw DatabaseError(message: "Person instance not found.")
        }
        let fieldValuesByName = Dictionary(uniqueKeysWithValues: fields.map { field in
            (field.name, row["field\(field.fieldIndex)"] as String? ?? "")
        })
        let booleanFieldNames = Set(fields.filter { $0.fieldType == .boolean }.map(\.name))
        let typeCSS = try String.fetchOne(
            db,
            sql: "SELECT css FROM \"type\" WHERE id = ?",
            arguments: [personTypeID]
        ) ?? ""

        let queryTypeName = try personQueryTypeName(db: db, personID: instanceID, kind: kind, partnershipID: partnershipID, officeID: officeID)
        let questionHTML = try personQuestionHTML(
            db: db, personID: instanceID, kind: kind, partnershipID: partnershipID, officeID: officeID
        )
        let body = try personAnswerBody(db: db, personID: instanceID, kind: kind, partnershipID: partnershipID, officeID: officeID)
        let answerHTML = uniteQuestionAndAnswerWithDefaultSeparator(
            questionHTML: "{{#QuestionContent}}",
            answerHTML: body
        )

        return StudyQuery(
            instanceID: instanceID,
            queryTypeID: 0,
            interval: interval,
            maxInterval: nil,
            lastAnsweredTimestamp: lastAnsweredTimestamp,
            queryState: queryState,
            typeName: PERSON_TYPE_NAME,
            queryTypeName: queryTypeName,
            questionHTML: questionHTML,
            answerHTML: answerHTML,
            typeCSS: personBuiltinQueryDefaultCSS + "\n\n" + typeCSS,
            fieldValuesByName: fieldValuesByName,
            booleanFieldNames: booleanFieldNames,
            personQueryKind: kind,
            personPartnershipID: partnershipID,
            personOfficeID: officeID
        )
    }

    /// Preview a built-in query outside Study mode (Query Preview window and
    /// MCP render_query). Uses the row's live SRS state when enabled, zeroes
    /// otherwise.
    func fetchPersonQueryPreview(instanceID: Int64, kind: PersonQueryKind, partnershipID: Int64?, officeID: Int64? = nil) throws -> StudyQuery {
        try dbQueue.read { db in
            let srs = try Row.fetchOne(
                db,
                sql: """
                    SELECT interval, query_state, last_answered_timestamp FROM person_query
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                    """,
                arguments: [instanceID, kind.rawValue, partnershipID, officeID]
            )
            return try Self.makePersonStudyQuery(
                db: db,
                instanceID: instanceID,
                kind: kind,
                partnershipID: partnershipID,
                officeID: officeID,
                interval: srs?["interval"] ?? 0,
                lastAnsweredTimestamp: srs?["last_answered_timestamp"],
                queryState: (srs?["query_state"] as Int?).flatMap(QueryState.init(rawValue:)) ?? .zero
            )
        }
    }

    /// Preview ANY built-in Person query from the instance editor's CURRENT
    /// draft state instead of the database, so unsaved relationship and office
    /// edits render (both editor modes; saved-state rendering stays in
    /// makePersonStudyQuery, whose markup this mirrors exactly).
    /// `selfInstanceID` is the edited person's row in Edit mode — their own
    /// name renders as a real id: link — and nil in Add mode, where the person
    /// has no row yet: their name is the display field's {{FieldName}}
    /// placeholder, resolved by the live field values the caller supplies via
    /// `StudyQuery.withFieldValues` (fieldValuesByName is left empty here,
    /// like fetchQueryTypePreview). Drafted refs to OTHER people are persisted
    /// instances or bare names, so entries render exactly like the saved-state
    /// paths (id: links with the DisplayName preference, .person-bare-name
    /// spans). Full Siblings matches the DRAFTED parents against the database
    /// and always includes the edited person as .person-self. SRS state is
    /// zeroed — the preview is about content. `partnerIndex` addresses
    /// relations.partners exactly for .childrenWith; `officeIndex` addresses
    /// relations.offices exactly for .office.
    func fetchPersonDraftPreview(
        kind: PersonQueryKind,
        relations: PersonRelationsDraft,
        partnerIndex: Int?,
        officeIndex: Int?,
        selfInstanceID: Int64?
    ) throws -> StudyQuery {
        try dbQueue.read { db in
            let personTypeID = try Self.fetchPersonTypeID(db: db)
            let booleanFieldNames = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM field WHERE type_id = ? AND field_type = 'boolean'",
                arguments: [personTypeID]
            ))
            let typeCSS = try String.fetchOne(
                db,
                sql: "SELECT css FROM \"type\" WHERE id = ?",
                arguments: [personTypeID]
            ) ?? ""
            // Same display-field choice as fetchInstanceDisplayValue, but as a
            // placeholder — the draft person's typed name substitutes in.
            let displayFieldName = try String.fetchOne(
                db,
                sql: "SELECT name FROM field WHERE type_id = ? ORDER BY is_primary DESC, field_display_index ASC, id LIMIT 1",
                arguments: [personTypeID]
            )
            let selfPlaceholder = displayFieldName.map { "{{\($0)}}" } ?? ""
            let selfHTML = try selfInstanceID.map { try Self.personEntryHTML(db: db, ref: .instance($0)) }
                ?? selfPlaceholder

            let template = try Self.personOfficeQueryHTML(db: db)
            let holdings = try relations.offices.map { office in
                PersonOfficeHolding(
                    personOfficeID: office.personOfficeID ?? 0,
                    officeID: office.officeID,
                    officeName: try Self.fetchOfficeName(db: db, officeID: office.officeID) ?? "#\(office.officeID)",
                    whenBegan: office.whenBegan,
                    whenEnded: office.whenEnded,
                    note: office.note
                )
            }

            let draftPartner: PersonPartnerDraft?
            if kind == .childrenWith {
                guard let partnerIndex, relations.partners.indices.contains(partnerIndex) else {
                    throw DatabaseError(message: "Partner entry not found.")
                }
                draftPartner = relations.partners[partnerIndex]
            } else {
                draftPartner = nil
            }
            // officeIndex identifies the OFFICE (via the draft entry at that
            // index); the preview renders every stint of it, matching the
            // saved-state per-office answer.
            let draftOffice: PersonOfficeDraft?
            let officeStintIndices: [Int]
            if kind == .office {
                guard let officeIndex, relations.offices.indices.contains(officeIndex) else {
                    throw DatabaseError(message: "Office holding not found.")
                }
                draftOffice = relations.offices[officeIndex]
                officeStintIndices = relations.offices.indices.filter {
                    relations.offices[$0].officeID == relations.offices[officeIndex].officeID
                }
            } else {
                draftOffice = nil
                officeStintIndices = []
            }

            func entryHTML(_ ref: PersonRef) throws -> String {
                try Self.personEntryHTML(db: db, ref: ref)
            }
            func slotHTML(_ ref: PersonRef?) throws -> String {
                guard let ref else { return Self.personNAHTML }
                return try entryHTML(ref)
            }

            // Question: same shapes as personQuestionHTML, with the
            // childrenWith partner line drawn from the DRAFTED partner and
            // the office template rendered once per drafted stint.
            let questionHTML: String
            if kind == .office {
                questionHTML = try Self.appendingOfficeQueryFooter(
                    db: db,
                    to: officeStintIndices
                        .map { Self.renderedOfficeTemplate(template, holding: holdings[$0]) }
                        .joined(separator: "\n")
                )
            } else {
                var lines = ["<div class=\"person-question-title\">\(Self.personQuestionTitle(kind))</div>"]
                let detailsHTML = try Self.personBuiltinQueryHTML(db: db)
                if !detailsHTML.isEmpty {
                    lines.append(detailsHTML)
                }
                if let draftPartner {
                    let partnerHTML = try entryHTML(draftPartner.partner)
                    lines.append("<div class=\"person-partner-line\">with <span class=\"person-partner\">\(partnerHTML)</span></div>")
                }
                questionHTML = lines.joined(separator: "\n")
            }

            // Answer: personAnswerBody's markup, computed from the draft.
            let body: String
            switch kind {
            case .mother:
                body = try slotHTML(relations.mother)
            case .father:
                body = try slotHTML(relations.father)
            case .adoptiveMother:
                body = try slotHTML(relations.adoptiveMother)
            case .adoptiveFather:
                body = try slotHTML(relations.adoptiveFather)
            case .parents:
                body = """
                    <div class="person-parent"><span class="person-parent-label">Father:</span> \(try slotHTML(relations.father))</div>
                    <div class="person-parent"><span class="person-parent-label">Mother:</span> \(try slotHTML(relations.mother))</div>
                    """
            case .partners:
                body = relations.partners.isEmpty
                    ? Self.personNAHTML
                    : Self.personAnswerLines(try relations.partners.map { partner in
                        try entryHTML(partner.partner)
                            + (Self.partnershipDatesSuffixHTML(startText: partner.startText, endText: partner.endText) ?? "")
                    })
            case .children:
                var groups: [String] = []
                for partner in relations.partners where !partner.children.isEmpty {
                    let partnerHTML = try entryHTML(partner.partner)
                    let list = Self.personAnswerLines(try partner.children.map { try entryHTML($0.child) })
                    groups.append("""
                        <div class="person-children-group"><div class="person-children-group-title">With \(partnerHTML):</div><div class="person-children-group-list">\(list)</div></div>
                        """)
                }
                if !relations.ungroupedChildren.isEmpty {
                    let list = Self.personAnswerLines(try relations.ungroupedChildren.map { try entryHTML($0.child) })
                    groups.append("""
                        <div class="person-children-group person-children-ungrouped"><div class="person-children-group-list">\(list)</div></div>
                        """)
                }
                body = groups.isEmpty ? Self.personNAHTML : groups.joined(separator: "\n")
            case .childrenWith:
                let children = draftPartner?.children ?? []
                body = children.isEmpty
                    ? Self.personNAHTML
                    : Self.personAnswerLines(try children.map { try entryHTML($0.child) })
            case .fullSiblings:
                var slots: [PersonParentRole: PersonRef] = [:]
                slots[.mother] = relations.mother
                slots[.father] = relations.father
                body = try Self.personFullSiblingsBody(
                    db: db,
                    personID: selfInstanceID,
                    selfPlaceholderHTML: selfInstanceID == nil ? selfPlaceholder : nil,
                    slots: slots
                )
            case .office:
                // One row per drafted stint of the office, mirroring
                // personOfficeSuccessionBody (dates under the name only when
                // the office has several stints).
                body = try officeStintIndices.enumerated().map { stintIndex, draftIndex -> String in
                    let stint = relations.offices[draftIndex]
                    var center = selfHTML
                    if officeStintIndices.count > 1 {
                        center += "\n<div class=\"office-succession-dates\">\(Self.officeStintLabel(holdings[draftIndex], index: stintIndex))</div>"
                    }
                    return try Self.officeSuccessionRowHTML(
                        db: db,
                        predecessors: stint.predecessors,
                        successors: stint.successors,
                        centerHTML: center
                    )
                }
                .joined(separator: "\n")
            case .allOffices:
                body = holdings.isEmpty
                    ? Self.personNAHTML
                    : try Self.appendingOfficeQueryFooter(
                        db: db,
                        to: Self.personAnswerLines(holdings.map { Self.renderedOfficeTemplate(template, holding: $0) })
                    )
            }

            let queryTypeName: String
            if let draftPartner {
                queryTypeName = try Self.personChildrenWithDisplayName(db: db, partnerRef: draftPartner.partner)
            } else if kind == .office, let officeIndex {
                queryTypeName = "Office: \(holdings[officeIndex].officeName)"
            } else {
                queryTypeName = kind.displayName
            }

            return StudyQuery(
                instanceID: selfInstanceID ?? 0,
                queryTypeID: 0,
                interval: 0,
                maxInterval: nil,
                lastAnsweredTimestamp: nil,
                queryState: .zero,
                typeName: PERSON_TYPE_NAME,
                queryTypeName: queryTypeName,
                questionHTML: questionHTML,
                answerHTML: uniteQuestionAndAnswerWithDefaultSeparator(
                    questionHTML: "{{#QuestionContent}}",
                    answerHTML: body
                ),
                typeCSS: Self.personBuiltinQueryDefaultCSS + "\n\n" + typeCSS,
                fieldValuesByName: [:],
                booleanFieldNames: booleanFieldNames,
                personQueryKind: kind,
                personPartnershipID: draftPartner?.partnershipID,
                personOfficeID: draftOffice?.officeID
            )
        }
    }

    /// The display name shown in query search / the editor checklist
    /// ("Mother", "Children with Alice", "Office: U.S. President", ...).
    nonisolated static func personQueryTypeName(
        db: Database,
        personID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        officeID: Int64? = nil
    ) throws -> String {
        if kind == .office, let officeID {
            guard let officeName = try fetchOfficeName(db: db, officeID: officeID) else {
                return kind.displayName
            }
            return "Office: \(officeName)"
        }
        guard kind == .childrenWith, let partnershipID else { return kind.displayName }
        let partnerships = try fetchPersonPartnershipSummaries(db: db, personID: personID)
        guard let partnership = partnerships.first(where: { $0.id == partnershipID }) else {
            return kind.displayName
        }
        return try personChildrenWithDisplayName(db: db, partnerRef: partnership.partner)
    }

    // MARK: Question / answer synthesis

    private nonisolated static func personQuestionTitle(_ kind: PersonQueryKind) -> String {
        switch kind {
        case .mother: return "Who is the mother of:"
        case .father: return "Who is the father of:"
        case .parents: return "Who are the parents of:"
        case .adoptiveMother: return "Who is the adoptive mother of:"
        case .adoptiveFather: return "Who is the adoptive father of:"
        case .partners: return "Who are the romantic partners of:"
        case .children: return "Who are the children of:"
        case .childrenWith: return "Who are the children of:"
        case .fullSiblings: return "Who are the full siblings of:"
        case .office: return "" // .office questions are the rendered template alone
        case .allOffices: return "What are the offices of:"
        }
    }

    private nonisolated static func personQuestionHTML(
        db: Database,
        personID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        officeID: Int64? = nil
    ) throws -> String {
        // A per-office question is the rendered office template alone — no
        // fixed title and no details block, since both would name the person
        // the answer reveals. Rendered once per stint of the office, in the
        // person's office order (a multi-term holder sees every term's dates).
        if kind == .office {
            guard let officeID else {
                throw DatabaseError(message: "Office holding not found.")
            }
            let stints = try fetchOfficeStints(db: db, instanceID: personID, officeID: officeID)
            guard !stints.isEmpty else {
                throw DatabaseError(message: "Office holding not found.")
            }
            let template = try personOfficeQueryHTML(db: db)
            return try appendingOfficeQueryFooter(
                db: db,
                to: stints.map { renderedOfficeTemplate(template, holding: $0) }.joined(separator: "\n")
            )
        }

        var lines = ["<div class=\"person-question-title\">\(personQuestionTitle(kind))</div>"]
        // User-customizable "details" block (shared by every built-in kind);
        // {{FieldName}} placeholders resolve through the normal template pipeline.
        let detailsHTML = try personBuiltinQueryHTML(db: db)
        if !detailsHTML.isEmpty {
            lines.append(detailsHTML)
        }
        if kind == .childrenWith, let partnershipID {
            let partnerships = try fetchPersonPartnershipSummaries(db: db, personID: personID)
            if let partnership = partnerships.first(where: { $0.id == partnershipID }) {
                let partnerHTML = try personEntryHTML(db: db, ref: partnership.partner)
                lines.append("<div class=\"person-partner-line\">with <span class=\"person-partner\">\(partnerHTML)</span></div>")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One relationship entry as answer markup: instances render as id: links
    /// (Study/Preview navigation), bare names as plain spans. Link text
    /// prefers the optional DisplayName field, falling back to the standard
    /// display value (Name) when it is blank. Field values are raw HTML
    /// everywhere in this app, so names are not escaped.
    private nonisolated static func personEntryHTML(db: Database, ref: PersonRef) throws -> String {
        switch ref {
        case .instance(let id):
            let name = try personLinkDisplayValue(db: db, instanceID: id)
            return "<a href=\"id:\(id)\">\(name.isEmpty ? "#\(id)" : name)</a>"
        case .bare(let name):
            return "<span class=\"person-bare-name\">\(name)</span>"
        }
    }

    /// The name shown for a Person reference in computed query HTML AND in
    /// the editor's people labels (chips, Children box, checklist rows —
    /// via fetchPersonEditorData's display-name map): the DisplayName field's
    /// value when non-blank, else the standard display value (Name). Trimmed;
    /// may be empty (callers show "#id" then).
    nonisolated static func personLinkDisplayValue(db: Database, instanceID: Int64) throws -> String {
        if let personTypeID = try? fetchPersonTypeID(db: db),
           let fieldIndex = try Int64.fetchOne(
               db,
               sql: "SELECT field_index FROM field WHERE type_id = ? AND name = 'DisplayName'",
               arguments: [personTypeID]
           ) {
            let displayName = (try String.fetchOne(
                db,
                sql: "SELECT \"field\(fieldIndex)\" FROM \"type\(personTypeID)\" WHERE id = ?",
                arguments: [instanceID]
            ) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty {
                return displayName
            }
        }
        return try fetchInstanceDisplayValue(db: db, instanceID: instanceID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stacks a list of already-built entry fragments one per line (each wrapped
    /// in a block div) so built-in answers list names vertically, not comma-run.
    private nonisolated static func personAnswerLines(_ entriesHTML: [String]) -> String {
        entriesHTML
            .map { "<div class=\"person-answer-line\">\($0)</div>" }
            .joined(separator: "\n")
    }

    private nonisolated static let personNAHTML = "<span class=\"person-na\">N/A</span>"

    private nonisolated static func personAnswerBody(
        db: Database,
        personID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        officeID: Int64? = nil
    ) throws -> String {
        let slots = try fetchParentSlots(db: db, childID: personID)

        func slotHTML(_ role: PersonParentRole) throws -> String {
            guard let ref = slots[role] else { return personNAHTML }
            return try personEntryHTML(db: db, ref: ref)
        }

        switch kind {
        case .mother:
            return try slotHTML(.mother)
        case .father:
            return try slotHTML(.father)
        case .adoptiveMother:
            return try slotHTML(.adoptiveMother)
        case .adoptiveFather:
            return try slotHTML(.adoptiveFather)
        case .parents:
            let father = try slotHTML(.father)
            let mother = try slotHTML(.mother)
            return """
                <div class="person-parent"><span class="person-parent-label">Father:</span> \(father)</div>
                <div class="person-parent"><span class="person-parent-label">Mother:</span> \(mother)</div>
                """
        case .partners:
            let partnerships = try fetchPersonPartnershipSummaries(db: db, personID: personID)
            guard !partnerships.isEmpty else { return personNAHTML }
            return personAnswerLines(try partnerships.map { partnership in
                try personEntryHTML(db: db, ref: partnership.partner)
                    + (partnershipDatesSuffixHTML(startText: partnership.startText, endText: partnership.endText) ?? "")
            })
        case .children:
            return try personChildrenBody(db: db, personID: personID)
        case .childrenWith:
            guard let partnershipID else { return personNAHTML }
            let children = try fetchPersonGroupedChildRefs(db: db, partnershipID: partnershipID)
            guard !children.isEmpty else { return personNAHTML }
            return personAnswerLines(try children.map { try personEntryHTML(db: db, ref: $0) })
        case .fullSiblings:
            return try personFullSiblingsBody(db: db, personID: personID, slots: slots)
        case .office:
            guard let officeID else { return personNAHTML }
            return try personOfficeSuccessionBody(db: db, personID: personID, officeID: officeID)
        case .allOffices:
            return try personAllOfficesBody(db: db, personID: personID)
        }
    }

    /// The fixed per-office answer: one 20%/60%/20% three-panel row PER STINT
    /// of the office, in the person's office order — that stint's
    /// predecessors (one per line), the person's hyperlinked name, and that
    /// stint's successors — with thin white dividers on either side of the
    /// middle panel (see personBuiltinQueryDefaultCSS). A multi-term holder's
    /// rows carry the stint's dates under the name so the terms are tellable
    /// apart; a single-term holder keeps the bare name.
    private nonisolated static func personOfficeSuccessionBody(
        db: Database,
        personID: Int64,
        officeID: Int64
    ) throws -> String {
        let selfLink = try personEntryHTML(db: db, ref: .instance(personID))
        let stints = try fetchOfficeStints(db: db, instanceID: personID, officeID: officeID)
        guard !stints.isEmpty else { return personNAHTML }
        let rows = try stints.enumerated().map { index, stint -> String in
            var center = selfLink
            if stints.count > 1 {
                center += "\n<div class=\"office-succession-dates\">\(officeStintLabel(stint, index: index))</div>"
            }
            return try officeSuccessionRowHTML(db: db, holdingID: stint.personOfficeID, centerHTML: center)
        }
        return rows.joined(separator: "\n")
    }

    /// One 20%/60%/20% three-panel succession row for one stint:
    /// its predecessors | centerHTML | its successors, N/A on empty sides.
    private nonisolated static func officeSuccessionRowHTML(
        db: Database,
        holdingID: Int64,
        centerHTML: String
    ) throws -> String {
        let peers = try fetchOfficeSuccessionPeers(db: db, holdingID: holdingID)
        return try officeSuccessionRowHTML(
            db: db,
            predecessors: peers.predecessors,
            successors: peers.successors,
            centerHTML: centerHTML
        )
    }

    /// The same three-panel row from explicit peer lists — the draft-preview
    /// path supplies the editor's uncommitted predecessors/successors directly.
    /// Instance peers render as id: links, bare names as plain spans (like
    /// every other relationship answer entry); which STINT of a peer an edge
    /// binds to never shows in answers (the peer's name is the answer).
    private nonisolated static func officeSuccessionRowHTML(
        db: Database,
        predecessors: [PersonSuccessionPeer],
        successors: [PersonSuccessionPeer],
        centerHTML: String
    ) throws -> String {
        func entryHTML(_ peer: PersonSuccessionPeer) throws -> String {
            if let instanceID = peer.instanceID {
                return try personEntryHTML(db: db, ref: .instance(instanceID))
            }
            return "<span class=\"person-bare-name\">\(peer.bareName ?? "")</span>"
        }
        func panel(_ peers: [PersonSuccessionPeer]) throws -> String {
            guard !peers.isEmpty else { return personNAHTML }
            return personAnswerLines(try peers.map(entryHTML))
        }

        return """
            <div class="office-succession">
                <div class="office-succession-panel office-succession-preds">\(try panel(predecessors))</div>
                <div class="office-succession-panel office-succession-holder">\(centerHTML)</div>
                <div class="office-succession-panel office-succession-succs">\(try panel(successors))</div>
            </div>
            """
    }

    // MARK: The `_offices` element (user-defined Person query HTML)

    /// User-authored Person query HTML support: replaces the CONTENTS of the
    /// FIRST element with id "_offices" with one .office-succession row per
    /// office STINT the person holds, in the person's own office order (any
    /// later element with the id is left as typed). Unlike the built-in
    /// per-office answer, the middle panel shows "Office: began–ended" (just
    /// the name when both dates are blank) instead of the person's name, with
    /// the stint's note on a line beneath when present; the side panels are
    /// that stint's own predecessors/successors as usual. The element's own tag and
    /// attributes are kept so it can be styled. Called by
    /// buildRenderedQuestionHTML/buildRenderedAnswerHTML for every Person
    /// query, so it works in Study mode, Query Preview, and MCP render_query.
    func renderPersonOfficesElements(in html: String, instanceID: Int64) throws -> String {
        try dbQueue.read { db in
            try Self.substitutePersonOfficesElements(db: db, html: html, instanceID: instanceID)
        }
    }

    private nonisolated static func substitutePersonOfficesElements(
        db: Database,
        html: String,
        instanceID: Int64
    ) throws -> String {
        // Groups: 1 = opening tag, 2 = tag name, 3 = contents, 4 = closing tag.
        // Non-greedy contents match: an element nesting its own tag name inside
        // (e.g. a div inside the _offices div) is not supported.
        let pattern = "(<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*\\bid\\s*=\\s*[\"']_offices[\"'][^>]*>)([\\s\\S]*?)(</\\2\\s*>)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        let nsHTML = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)),
              let contentRange = Range(match.range(at: 3), in: html)
        else { return html }

        let contents = try personOfficesElementContents(db: db, personID: instanceID)
        var result = html
        result.replaceSubrange(contentRange, with: contents)
        return result
    }

    private nonisolated static func personOfficesElementContents(db: Database, personID: Int64) throws -> String {
        let holdings = try fetchPersonOfficeHoldings(db: db, instanceID: personID)
        return try holdings.map { holding -> String in
            let began = holding.whenBegan.trimmingCharacters(in: .whitespacesAndNewlines)
            let ended = holding.whenEnded.trimmingCharacters(in: .whitespacesAndNewlines)
            var center = (began.isEmpty && ended.isEmpty)
                ? holding.officeName
                : "\(holding.officeName): \(began)–\(ended)"
            let note = holding.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                center += "\n<div class=\"office-succession-note\">\(note)</div>"
            }
            return try officeSuccessionRowHTML(db: db, holdingID: holding.personOfficeID, centerHTML: center)
        }
        .joined(separator: "\n")
    }

    /// The All Offices answer: the office question template rendered once per
    /// holding, in the person's own office order.
    private nonisolated static func personAllOfficesBody(db: Database, personID: Int64) throws -> String {
        let holdings = try fetchPersonOfficeHoldings(db: db, instanceID: personID)
        guard !holdings.isEmpty else { return personNAHTML }
        let template = try personOfficeQueryHTML(db: db)
        return try appendingOfficeQueryFooter(
            db: db,
            to: personAnswerLines(holdings.map { renderedOfficeTemplate(template, holding: $0) })
        )
    }

    private nonisolated static func fetchPersonGroupedChildRefs(db: Database, partnershipID: Int64) throws -> [PersonRef] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT child_id, child_bare FROM person_partnership_child
                WHERE partnership_id = ?
                ORDER BY order_index, id
                """,
            arguments: [partnershipID]
        ).map { row in
            if let id = row["child_id"] as Int64? { return PersonRef.instance(id) }
            return PersonRef.bare(row["child_bare"] as String? ?? "")
        }
    }

    /// ALL children: grouped by partner (partners in this person's order,
    /// childless groups skipped, children in shared order), then the ungrouped
    /// tail. Empty overall → N/A.
    private nonisolated static func personChildrenBody(db: Database, personID: Int64) throws -> String {
        var groups: [String] = []
        let partnerships = try fetchPersonPartnershipSummaries(db: db, personID: personID)
        for partnership in partnerships {
            let children = try fetchPersonGroupedChildRefs(db: db, partnershipID: partnership.id)
            guard !children.isEmpty else { continue }
            let partnerHTML = try personEntryHTML(db: db, ref: partnership.partner)
            let list = personAnswerLines(try children.map { try personEntryHTML(db: db, ref: $0) })
            groups.append("""
                <div class="person-children-group"><div class="person-children-group-title">With \(partnerHTML):</div><div class="person-children-group-list">\(list)</div></div>
                """)
        }

        let ungrouped = try Row.fetchAll(
            db,
            sql: """
                SELECT child_id, child_bare FROM person_direct_child
                WHERE parent_id = ?
                ORDER BY order_index, id
                """,
            arguments: [personID]
        ).map { row -> PersonRef in
            if let id = row["child_id"] as Int64? { return .instance(id) }
            return .bare(row["child_bare"] as String? ?? "")
        }
        if !ungrouped.isEmpty {
            let list = personAnswerLines(try ungrouped.map { try personEntryHTML(db: db, ref: $0) })
            groups.append("""
                <div class="person-children-group person-children-ungrouped"><div class="person-children-group-list">\(list)</div></div>
                """)
        }

        guard !groups.isEmpty else { return personNAHTML }
        return groups.joined(separator: "\n")
    }

    /// People sharing BOTH the same mother and the same father (instances
    /// match by id, bare names by exact string; both slots must be present,
    /// else N/A). The person appears in the list styled as .person-self —
    /// force-included when `personID` is set, because a DRAFT's slots may not
    /// be materialized in person_parent yet; for an unsaved person (nil
    /// `personID`) `selfPlaceholderHTML` supplies their line instead. Order:
    /// the parents' shared partnership children order for members grouped
    /// there, then the mother's/father's ungrouped order, then id.
    private nonisolated static func personFullSiblingsBody(
        db: Database,
        personID: Int64?,
        selfPlaceholderHTML: String? = nil,
        slots: [PersonParentRole: PersonRef]
    ) throws -> String {
        guard let mother = slots[.mother], let father = slots[.father] else { return personNAHTML }

        func matchingChildIDs(role: PersonParentRole, ref: PersonRef) throws -> Set<Int64> {
            switch ref {
            case .instance(let parentID):
                return Set(try Int64.fetchAll(
                    db,
                    sql: "SELECT child_id FROM person_parent WHERE role = ? AND parent_id = ?",
                    arguments: [role.rawValue, parentID]
                ))
            case .bare(let name):
                return Set(try Int64.fetchAll(
                    db,
                    sql: "SELECT child_id FROM person_parent WHERE role = ? AND parent_bare = ?",
                    arguments: [role.rawValue, name]
                ))
            }
        }

        var siblingIDs = try matchingChildIDs(role: .mother, ref: mother)
            .intersection(matchingChildIDs(role: .father, ref: father))
        if let personID {
            siblingIDs.insert(personID)
        }
        guard !siblingIDs.isEmpty || selfPlaceholderHTML != nil else { return personNAHTML }

        // Rank: shared grouping order under the parents' partnership(s) first,
        // then the mother's (or father's) ungrouped order, then id.
        var rank: [Int64: Int] = [:]
        var nextRank = 0
        if case .instance(let motherID) = mother, case .instance(let fatherID) = father {
            let sharedPartnershipIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM person_partnership
                    WHERE (a_id = ?1 AND b_id = ?2) OR (a_id = ?2 AND b_id = ?1)
                    ORDER BY id
                    """,
                arguments: [motherID, fatherID]
            )
            for partnershipID in sharedPartnershipIDs {
                for ref in try fetchPersonGroupedChildRefs(db: db, partnershipID: partnershipID) {
                    if case .instance(let childID) = ref, rank[childID] == nil {
                        rank[childID] = nextRank
                        nextRank += 1
                    }
                }
            }
        }
        for parentRef in [mother, father] {
            guard case .instance(let parentID) = parentRef else { continue }
            let direct = try Int64.fetchAll(
                db,
                sql: """
                    SELECT child_id FROM person_direct_child
                    WHERE parent_id = ? AND child_id IS NOT NULL
                    ORDER BY order_index, id
                    """,
                arguments: [parentID]
            )
            for childID in direct where rank[childID] == nil {
                rank[childID] = nextRank
                nextRank += 1
            }
        }

        let ordered = siblingIDs.sorted { lhs, rhs in
            let l = rank[lhs] ?? Int.max
            let r = rank[rhs] ?? Int.max
            if l != r { return l < r }
            return lhs < rhs
        }

        var entries = try ordered.map { siblingID -> String in
            if siblingID == personID {
                // Same DisplayName-then-Name resolution as the sibling links
                // around it, so the list reads consistently.
                let name = try personLinkDisplayValue(db: db, instanceID: siblingID)
                return "<span class=\"person-self\">\(name.isEmpty ? "#\(siblingID)" : name)</span>"
            }
            return try personEntryHTML(db: db, ref: .instance(siblingID))
        }
        if let selfPlaceholderHTML {
            entries.append("<span class=\"person-self\">\(selfPlaceholderHTML)</span>")
        }
        return personAnswerLines(entries)
    }
}
