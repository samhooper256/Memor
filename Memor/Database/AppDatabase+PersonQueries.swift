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

    // MARK: - Enablement

    /// Enables/disables one built-in query (row existence = enabled).
    /// `partnershipID` is required exactly for .childrenWith.
    func setPersonQueryEnabled(
        instanceID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        enabled: Bool
    ) throws {
        try dbQueue.write { db in
            if enabled {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO person_query (instance_id, kind, partnership_id)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [instanceID, kind.rawValue, partnershipID]
                )
            } else {
                let partnershipCondition = partnershipID == nil ? "partnership_id IS NULL" : "partnership_id = ?"
                var arguments: [DatabaseValue] = [instanceID.databaseValue, kind.rawValue.databaseValue]
                if let partnershipID { arguments.append(partnershipID.databaseValue) }
                try db.execute(
                    sql: "DELETE FROM person_query WHERE instance_id = ? AND kind = ? AND \(partnershipCondition)",
                    arguments: StatementArguments(arguments)!
                )
            }
        }
    }

    /// Full built-in query list for one instance: the standalone kinds plus one
    /// "Children with {partner}" per partnership (in this person's partner
    /// order), each with enablement + SRS state.
    func fetchPersonBuiltinQueryInfos(instanceID: Int64) throws -> [PersonBuiltinQueryInfo] {
        try dbQueue.read { db in
            try Self.fetchPersonBuiltinQueryInfos(db: db, instanceID: instanceID)
        }
    }

    nonisolated static func fetchPersonBuiltinQueryInfos(db: Database, instanceID: Int64) throws -> [PersonBuiltinQueryInfo] {
        var infos: [PersonBuiltinQueryInfo] = []

        func appendInfo(kind: PersonQueryKind, partnershipID: Int64?, displayName: String) throws {
            let partnershipCondition = partnershipID == nil ? "partnership_id IS NULL" : "partnership_id = ?"
            var arguments: [DatabaseValue] = [instanceID.databaseValue, kind.rawValue.databaseValue]
            if let partnershipID { arguments.append(partnershipID.databaseValue) }
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT interval, query_state, last_answered_timestamp
                    FROM person_query
                    WHERE instance_id = ? AND kind = ? AND \(partnershipCondition)
                    """,
                arguments: StatementArguments(arguments)!
            )
            infos.append(PersonBuiltinQueryInfo(
                kind: kind,
                partnershipID: partnershipID,
                displayName: displayName,
                enabled: row != nil,
                interval: row?["interval"],
                queryState: (row?["query_state"] as Int?).flatMap(QueryState.init(rawValue:)),
                lastAnsweredTimestamp: row?["last_answered_timestamp"]
            ))
        }

        for kind in PersonQueryKind.standaloneKinds {
            try appendInfo(kind: kind, partnershipID: nil, displayName: kind.displayName)
        }
        let partnerships = try fetchPersonPartnershipSummaries(db: db, personID: instanceID)
        for partnership in partnerships {
            try appendInfo(
                kind: .childrenWith,
                partnershipID: partnership.id,
                displayName: try personChildrenWithDisplayName(db: db, partnerRef: partnership.partner)
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
    }

    nonisolated static func fetchPersonPartnershipSummaries(db: Database, personID: Int64) throws -> [PersonPartnershipSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, a_id, b_id, b_bare, a_order_index, b_order_index
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
            return PersonPartnershipSummary(id: row["id"], partner: partner, sideInstanceIDs: sides)
        }
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
                    pq.interval AS interval,
                    pq.last_answered_timestamp AS lastAnsweredTimestamp,
                    pq.query_state AS queryState,
                    COALESCE(instance_table."field\(typeInfo.displayFieldIndex)", '') AS displayValue
                FROM \(Self.personQueryJoinFrom(personTypeID: typeInfo.typeID))
                WHERE \(searchSQL)
                ORDER BY displayValue COLLATE NOCASE, pq.instance_id, pq.kind, pq.partnership_id
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
                    db: db, personID: row.instanceID, kind: kind, partnershipID: row.partnershipID
                ),
                personKind: kind,
                personPartnershipID: row.partnershipID
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
        rating: StudyResponseRating,
        answeredAtTimestamp: Int64,
        overrideInterval: Int64? = nil
    ) throws -> StudyResponseOutcome {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT interval, query_state FROM person_query
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ?
                    """,
                arguments: [instanceID, kind.rawValue, partnershipID]
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
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ?
                    """,
                arguments: [outcome.newState.rawValue, answeredAtTimestamp, updatedInterval, instanceID, kind.rawValue, partnershipID]
            )
            return StudyResponseOutcome(newState: outcome.newState, newInterval: updatedInterval)
        }
    }

    func revertPersonStudyResponse(
        instanceID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        originalInterval: Int64,
        originalLastAnsweredTimestamp: Int64?,
        originalQueryState: QueryState
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE person_query
                    SET query_state = ?, last_answered_timestamp = ?, interval = ?
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ?
                    """,
                arguments: [
                    originalQueryState.rawValue,
                    originalLastAnsweredTimestamp,
                    originalInterval,
                    instanceID,
                    kind.rawValue,
                    partnershipID,
                ]
            )
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
        .person-children-group { margin: 4px 0; }
        .person-children-group-title { color: gray; }
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

        let queryTypeName = try personQueryTypeName(db: db, personID: instanceID, kind: kind, partnershipID: partnershipID)
        let questionHTML = try personQuestionHTML(
            db: db, personID: instanceID, kind: kind, partnershipID: partnershipID
        )
        let body = try personAnswerBody(db: db, personID: instanceID, kind: kind, partnershipID: partnershipID)
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
            personPartnershipID: partnershipID
        )
    }

    /// Preview a built-in query outside Study mode (Query Preview window and
    /// MCP render_query). Uses the row's live SRS state when enabled, zeroes
    /// otherwise.
    func fetchPersonQueryPreview(instanceID: Int64, kind: PersonQueryKind, partnershipID: Int64?) throws -> StudyQuery {
        try dbQueue.read { db in
            let srs = try Row.fetchOne(
                db,
                sql: """
                    SELECT interval, query_state, last_answered_timestamp FROM person_query
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ?
                    """,
                arguments: [instanceID, kind.rawValue, partnershipID]
            )
            return try Self.makePersonStudyQuery(
                db: db,
                instanceID: instanceID,
                kind: kind,
                partnershipID: partnershipID,
                interval: srs?["interval"] ?? 0,
                lastAnsweredTimestamp: srs?["last_answered_timestamp"],
                queryState: (srs?["query_state"] as Int?).flatMap(QueryState.init(rawValue:)) ?? .zero
            )
        }
    }

    /// The display name shown in query search / the editor checklist
    /// ("Mother", "Children with Alice", ...).
    nonisolated static func personQueryTypeName(
        db: Database,
        personID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?
    ) throws -> String {
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
        case .partners: return "Who were all the romantic partners of:"
        case .children: return "Who are the children of:"
        case .childrenWith: return "Who are the children of:"
        case .fullSiblings: return "Who are the full siblings of:"
        }
    }

    private nonisolated static func personQuestionHTML(
        db: Database,
        personID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?
    ) throws -> String {
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
    /// (Study/Preview navigation), bare names as plain spans. Field values are
    /// raw HTML everywhere in this app, so names are not escaped.
    private nonisolated static func personEntryHTML(db: Database, ref: PersonRef) throws -> String {
        switch ref {
        case .instance(let id):
            let name = try fetchInstanceDisplayValue(db: db, instanceID: id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "<a href=\"id:\(id)\">\(name.isEmpty ? "#\(id)" : name)</a>"
        case .bare(let name):
            return "<span class=\"person-bare-name\">\(name)</span>"
        }
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
        partnershipID: Int64?
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
            let mother = try slotHTML(.mother)
            let father = try slotHTML(.father)
            return """
                <div class="person-parent"><span class="person-parent-label">Mother:</span> \(mother)</div>
                <div class="person-parent"><span class="person-parent-label">Father:</span> \(father)</div>
                """
        case .partners:
            let partnerships = try fetchPersonPartnershipSummaries(db: db, personID: personID)
            guard !partnerships.isEmpty else { return personNAHTML }
            return personAnswerLines(try partnerships.map { try personEntryHTML(db: db, ref: $0.partner) })
        case .children:
            return try personChildrenBody(db: db, personID: personID)
        case .childrenWith:
            guard let partnershipID else { return personNAHTML }
            let children = try fetchPersonGroupedChildRefs(db: db, partnershipID: partnershipID)
            guard !children.isEmpty else { return personNAHTML }
            return personAnswerLines(try children.map { try personEntryHTML(db: db, ref: $0) })
        case .fullSiblings:
            return try personFullSiblingsBody(db: db, personID: personID, slots: slots)
        }
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

    /// People sharing BOTH the same mother and the same father as `personID`
    /// (instances match by id, bare names by exact string; both slots must be
    /// present, else N/A). The person appears in the list styled as
    /// .person-self. Order: the parents' shared partnership children order for
    /// members grouped there, then the mother's/father's ungrouped order, then id.
    private nonisolated static func personFullSiblingsBody(
        db: Database,
        personID: Int64,
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

        let siblingIDs = try matchingChildIDs(role: .mother, ref: mother)
            .intersection(matchingChildIDs(role: .father, ref: father))
        guard !siblingIDs.isEmpty else { return personNAHTML }

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

        let entries = try ordered.map { siblingID -> String in
            if siblingID == personID {
                let name = try fetchInstanceDisplayValue(db: db, instanceID: siblingID)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "<span class=\"person-self\">\(name.isEmpty ? "#\(siblingID)" : name)</span>"
            }
            return try personEntryHTML(db: db, ref: .instance(siblingID))
        }
        return personAnswerLines(entries)
    }
}
