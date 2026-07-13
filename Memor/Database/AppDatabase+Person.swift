//
//  AppDatabase+Person.swift
//  Memor
//
//  The built-in Person type's relationship engine: editor fetch, the save
//  transaction (diff → conflict collection → propagation), the convert-to-bare
//  deletion cascade, the person picker search, and the reset-on-connection-
//  change consumer.
//
//  Relationships between two Person INSTANCES are stored once (see the DDL in
//  AppDatabase+Schema.swift), so both people's views agree by construction.
//  The save routine materializes grouping-implied parents into person_parent
//  and keeps person_direct_child as a projection of it, per the invariants
//  documented on the tables. A save that would overwrite an occupied 0-or-1
//  slot on ANOTHER instance with a different value (or violate a sex/role
//  rule) throws PersonSaveError with every conflict collected — nothing is
//  written (GRDB rolls the transaction back).
//

import Foundation
import GRDB

/// A row in the person picker popover.
nonisolated struct PersonCandidate: Identifiable, Hashable {
    let id: Int64
    let displayValue: String
    let sex: String
}

extension AppDatabase {

    // MARK: - Person type identity

    nonisolated static func fetchPersonTypeID(db: Database) throws -> Int64 {
        guard let typeID = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM "type" WHERE name = ? AND is_builtin = 1
                """,
            arguments: [PERSON_TYPE_NAME]
        ) else {
            throw DatabaseError(message: "The built-in Person type is missing.")
        }
        return typeID
    }

    func fetchPersonTypeID() throws -> Int64 {
        try dbQueue.read { db in
            try Self.fetchPersonTypeID(db: db)
        }
    }

    // MARK: - Low-level reads

    private nonisolated struct PartnershipRow {
        let id: Int64
        var aID: Int64
        var bID: Int64?
        var bBare: String?
        var isMarried: Bool
        var startText: String
        var endText: String
        var aOrder: Int
        var bOrder: Int?

        func side(of personID: Int64) -> Bool? {
            if aID == personID { return true }
            if bID == personID { return false }
            return nil
        }

        func partnerRef(relativeTo personID: Int64) -> PersonRef {
            if aID == personID {
                if let bID { return .instance(bID) }
                return .bare(bBare ?? "")
            }
            return .instance(aID)
        }

        func orderIndex(of personID: Int64) -> Int {
            aID == personID ? aOrder : (bOrder ?? 0)
        }

        var sideInstanceIDs: [Int64] {
            var ids = [aID]
            if let bID { ids.append(bID) }
            return ids
        }
    }

    private nonisolated static func makePartnershipRow(_ row: Row) -> PartnershipRow {
        PartnershipRow(
            id: row["id"],
            aID: row["a_id"],
            bID: row["b_id"],
            bBare: row["b_bare"],
            isMarried: (row["is_married"] as Int64) != 0,
            startText: row["start_text"],
            endText: row["end_text"],
            aOrder: Int(row["a_order_index"] as Int64),
            bOrder: (row["b_order_index"] as Int64?).map(Int.init)
        )
    }

    private nonisolated static func fetchPartnershipRow(db: Database, id: Int64) throws -> PartnershipRow? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM person_partnership WHERE id = ?",
            arguments: [id]
        ).map(makePartnershipRow)
    }

    /// All partnerships in which `personID` sits on either side, ordered by
    /// this person's own side order.
    private nonisolated static func fetchPartnershipsInvolving(db: Database, personID: Int64) throws -> [PartnershipRow] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM person_partnership WHERE a_id = ? OR b_id = ?",
            arguments: [personID, personID]
        ).map(makePartnershipRow)
        return rows.sorted { lhs, rhs in
            let l = lhs.orderIndex(of: personID)
            let r = rhs.orderIndex(of: personID)
            if l != r { return l < r }
            return lhs.id < rhs.id
        }
    }

    private nonisolated static func fetchGroupedChildRows(
        db: Database,
        partnershipID: Int64
    ) throws -> [(rowID: Int64, ref: PersonRef)] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, child_id, child_bare
                FROM person_partnership_child
                WHERE partnership_id = ?
                ORDER BY order_index, id
                """,
            arguments: [partnershipID]
        ).map { row in
            (row["id"] as Int64, makeRef(instanceID: row["child_id"], bare: row["child_bare"]))
        }
    }

    private nonisolated static func fetchDirectChildRows(
        db: Database,
        parentID: Int64
    ) throws -> [(rowID: Int64, ref: PersonRef)] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, child_id, child_bare
                FROM person_direct_child
                WHERE parent_id = ?
                ORDER BY order_index, id
                """,
            arguments: [parentID]
        ).map { row in
            (row["id"] as Int64, makeRef(instanceID: row["child_id"], bare: row["child_bare"]))
        }
    }

    nonisolated static func fetchParentSlots(db: Database, childID: Int64) throws -> [PersonParentRole: PersonRef] {
        var slots: [PersonParentRole: PersonRef] = [:]
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT role, parent_id, parent_bare FROM person_parent WHERE child_id = ?",
            arguments: [childID]
        )
        for row in rows {
            guard let role = PersonParentRole(rawValue: row["role"]) else { continue }
            slots[role] = makeRef(instanceID: row["parent_id"], bare: row["parent_bare"])
        }
        return slots
    }

    private nonisolated static func makeRef(instanceID: Int64?, bare: String?) -> PersonRef {
        if let instanceID { return .instance(instanceID) }
        return .bare(bare ?? "")
    }

    private nonisolated static func personSexFieldIndex(db: Database, personTypeID: Int64) throws -> Int {
        guard let index = try Int.fetchOne(
            db,
            sql: "SELECT field_index FROM field WHERE type_id = ? AND field_type = 'sex'",
            arguments: [personTypeID]
        ) else {
            throw DatabaseError(message: "The Person type is missing its Sex field.")
        }
        return index
    }

    nonisolated static func fetchPersonSex(db: Database, personTypeID: Int64, instanceID: Int64) throws -> String {
        let sexIndex = try personSexFieldIndex(db: db, personTypeID: personTypeID)
        let raw = try String.fetchOne(
            db,
            sql: "SELECT COALESCE(\"field\(sexIndex)\", 'Male') FROM \"type\(personTypeID)\" WHERE id = ?",
            arguments: [instanceID]
        )
        return raw == "Female" ? "Female" : "Male"
    }

    /// Human description of a slot occupant for conflict messages.
    private nonisolated static func refDescription(db: Database, _ ref: PersonRef) throws -> String {
        switch ref {
        case .instance(let id):
            let name = try fetchInstanceDisplayValue(db: db, instanceID: id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "instance #\(id)" : name
        case .bare(let name):
            return "“\(name)”"
        }
    }

    private nonisolated static func displayNameOrUnknown(db: Database, instanceID: Int64) throws -> String {
        let name = try fetchInstanceDisplayValue(db: db, instanceID: instanceID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Unknown" : name
    }

    // MARK: - Editor fetch

    func fetchPersonEditorData(instanceID: Int64) throws -> PersonEditorData {
        let base = try fetchInstanceEditorData(instanceID: instanceID)
        return try dbQueue.read { db in
            let personTypeID = try Self.fetchPersonTypeID(db: db)
            guard base.typeID == personTypeID else {
                throw DatabaseError(message: "Instance \(instanceID) is not a Person.")
            }

            let slots = try Self.fetchParentSlots(db: db, childID: instanceID)
            let partnershipRows = try Self.fetchPartnershipsInvolving(db: db, personID: instanceID)

            var partners: [PersonPartnerDraft] = []
            for row in partnershipRows {
                let children = try Self.fetchGroupedChildRows(db: db, partnershipID: row.id)
                let queryEnabled = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM person_query
                        WHERE instance_id = ? AND kind = 'children_with' AND partnership_id = ?
                        """,
                    arguments: [instanceID, row.id]
                ) ?? 0 > 0
                partners.append(PersonPartnerDraft(
                    partnershipID: row.id,
                    partner: row.partnerRef(relativeTo: instanceID),
                    isMarried: row.isMarried,
                    startText: row.startText,
                    endText: row.endText,
                    children: children.map { PersonChildDraft(rowID: $0.rowID, child: $0.ref) },
                    isChildrenQueryEnabled: queryEnabled
                ))
            }

            let ungrouped = try Self.fetchDirectChildRows(db: db, parentID: instanceID)

            // Office holdings + their succession peers + per-office enablement.
            var officeNamesByID: [Int64: String] = [:]
            var offices: [PersonOfficeDraft] = []
            for holding in try Self.fetchPersonOfficeHoldings(db: db, instanceID: instanceID) {
                officeNamesByID[holding.officeID] = holding.officeName
                let peers = try Self.fetchOfficeSuccessionPeers(db: db, instanceID: instanceID, officeID: holding.officeID)
                let queryEnabled = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM person_query
                        WHERE instance_id = ? AND kind = 'office' AND office_id = ?
                        """,
                    arguments: [instanceID, holding.officeID]
                ) ?? 0 > 0
                offices.append(PersonOfficeDraft(
                    personOfficeID: holding.personOfficeID,
                    officeID: holding.officeID,
                    whenBegan: holding.whenBegan,
                    whenEnded: holding.whenEnded,
                    note: holding.note,
                    predecessors: peers.predecessors,
                    successors: peers.successors,
                    isQueryEnabled: queryEnabled
                ))
            }

            let relations = PersonRelationsDraft(
                mother: slots[.mother],
                father: slots[.father],
                adoptiveMother: slots[.adoptiveMother],
                adoptiveFather: slots[.adoptiveFather],
                partners: partners,
                ungroupedChildren: ungrouped.map { PersonChildDraft(rowID: $0.rowID, child: $0.ref) },
                offices: offices
            )

            // Display names + sexes for every referenced instance (chip labels,
            // same-sex child blocking in the editor). Succession peers ride the
            // same loop so their chips have names too.
            var referencedIDs: Set<Int64> = []
            for ref in [relations.mother, relations.father, relations.adoptiveMother, relations.adoptiveFather] {
                if let id = ref?.instanceID { referencedIDs.insert(id) }
            }
            for partner in relations.partners {
                if let id = partner.partner.instanceID { referencedIDs.insert(id) }
                for child in partner.children {
                    if let id = child.child.instanceID { referencedIDs.insert(id) }
                }
            }
            for child in relations.ungroupedChildren {
                if let id = child.child.instanceID { referencedIDs.insert(id) }
            }
            for office in relations.offices {
                referencedIDs.formUnion(office.predecessors)
                referencedIDs.formUnion(office.successors)
            }

            var displayNames: [Int64: String] = [:]
            var sexes: [Int64: String] = [:]
            for id in referencedIDs {
                displayNames[id] = try Self.fetchInstanceDisplayValue(db: db, instanceID: id)
                sexes[id] = try Self.fetchPersonSex(db: db, personTypeID: personTypeID, instanceID: id)
            }

            var builtinQueries: [PersonBuiltinQueryInfo] = []
            for kind in PersonQueryKind.standaloneKinds {
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT interval, query_state, last_answered_timestamp
                        FROM person_query
                        WHERE instance_id = ? AND kind = ? AND partnership_id IS NULL AND office_id IS NULL
                        """,
                    arguments: [instanceID, kind.rawValue]
                )
                builtinQueries.append(PersonBuiltinQueryInfo(
                    kind: kind,
                    partnershipID: nil,
                    officeID: nil,
                    displayName: kind.displayName,
                    enabled: row != nil,
                    interval: row?["interval"],
                    queryState: (row?["query_state"] as Int?).flatMap(QueryState.init(rawValue:)),
                    lastAnsweredTimestamp: row?["last_answered_timestamp"]
                ))
            }
            // One `.office` info per holding (interval display on the editor's
            // office checklist rows; enablement itself rides PersonOfficeDraft).
            for office in relations.offices {
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT interval, query_state, last_answered_timestamp
                        FROM person_query
                        WHERE instance_id = ? AND kind = 'office' AND office_id = ?
                        """,
                    arguments: [instanceID, office.officeID]
                )
                builtinQueries.append(PersonBuiltinQueryInfo(
                    kind: .office,
                    partnershipID: nil,
                    officeID: office.officeID,
                    displayName: "Office: \(officeNamesByID[office.officeID] ?? "#\(office.officeID)")",
                    enabled: row != nil,
                    interval: row?["interval"],
                    queryState: (row?["query_state"] as Int?).flatMap(QueryState.init(rawValue:)),
                    lastAnsweredTimestamp: row?["last_answered_timestamp"]
                ))
            }

            return PersonEditorData(
                instanceID: instanceID,
                typeID: base.typeID,
                fieldValuesByFieldID: base.fieldValuesByFieldID,
                enabledQueryTypeIDs: base.enabledQueryTypeIDs,
                maxInterval: base.maxInterval,
                relations: relations,
                displayNamesByInstanceID: displayNames,
                sexesByInstanceID: sexes,
                officeNamesByID: officeNamesByID,
                builtinQueries: builtinQueries
            )
        }
    }

    // MARK: - Save

    /// Saves a Person instance: field values, user query rows, relationship
    /// slots, office holdings + succession edges, and built-in query
    /// enablement, in ONE transaction (a thrown error writes nothing).
    ///
    /// IMPORTANT: `relations` is FULL-STATE — anything absent is removed.
    /// Every caller must originate the draft from fetchPersonEditorData (the
    /// UI editor and both MCP paths do); building a PersonRelationsDraft from
    /// scratch for an existing person would wipe their relationships AND
    /// office holdings (deleting per-office SRS and succession links).
    func savePersonInstance(
        instanceID: Int64?,
        fieldValuesByFieldID: [Int64: String],
        queryTypeIDs: Set<Int64>,
        relations: PersonRelationsDraft,
        builtinEnabledKinds: Set<PersonQueryKind>
    ) throws -> PersonSaveResult {
        try dbQueue.write { db in
            let personTypeID = try Self.fetchPersonTypeID(db: db)

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
                    ORDER BY field_index, id
                    """,
                arguments: [personTypeID]
            )
            guard let sexField = fields.first(where: { $0.fieldType == .sex }) else {
                throw DatabaseError(message: "The Person type is missing its Sex field.")
            }

            // 1. Create or update the instance row + field values + user query rows.
            let personID: Int64
            let oldSex: String
            if let instanceID {
                let typeID = try Int64.fetchOne(
                    db,
                    sql: "SELECT type_id FROM instance_id_type_id WHERE instance_id = ?",
                    arguments: [instanceID]
                )
                guard typeID == personTypeID else {
                    throw DatabaseError(message: "Instance \(instanceID) is not a Person.")
                }
                personID = instanceID
                oldSex = try Self.fetchPersonSex(db: db, personTypeID: personTypeID, instanceID: instanceID)

                let assignments = fields.map { "\"field\($0.fieldIndex)\" = ?" }.joined(separator: ", ")
                var arguments: [DatabaseValue] = fields.map { field in
                    Self.normalizedFieldValue(fieldValuesByFieldID[field.id] ?? "", kind: field.fieldType).databaseValue
                }
                arguments.append(personID.databaseValue)
                try db.execute(
                    sql: "UPDATE \"type\(personTypeID)\" SET \(assignments) WHERE id = ?",
                    arguments: StatementArguments(arguments)!
                )

                // Sync user-defined query rows to the requested set.
                let currentQueryTypeIDs = Set(try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT query.query_type_id
                        FROM query
                        JOIN query_type ON query_type.id = query.query_type_id
                        WHERE query.instance_id = ? AND query_type.type_id = ?
                        """,
                    arguments: [personID, personTypeID]
                ))
                for queryTypeID in queryTypeIDs.subtracting(currentQueryTypeIDs).sorted() {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO query (instance_id, query_type_id) VALUES (?, ?)",
                        arguments: [personID, queryTypeID]
                    )
                }
                for queryTypeID in currentQueryTypeIDs.subtracting(queryTypeIDs).sorted() {
                    try db.execute(
                        sql: "DELETE FROM query WHERE instance_id = ? AND query_type_id = ?",
                        arguments: [personID, queryTypeID]
                    )
                }
            } else {
                try db.execute(
                    sql: "INSERT INTO instance_id_type_id (type_id) VALUES (?)",
                    arguments: [personTypeID]
                )
                personID = db.lastInsertedRowID
                oldSex = "Male"

                let columnNames = ["id"] + fields.map { "\"field\($0.fieldIndex)\"" }
                let placeholders = Array(repeating: "?", count: columnNames.count).joined(separator: ", ")
                var arguments: [DatabaseValue] = [personID.databaseValue]
                arguments.append(contentsOf: fields.map { field in
                    Self.normalizedFieldValue(fieldValuesByFieldID[field.id] ?? "", kind: field.fieldType).databaseValue
                })
                try db.execute(
                    sql: """
                        INSERT INTO "type\(personTypeID)" (\(columnNames.joined(separator: ", ")))
                        VALUES (\(placeholders))
                        """,
                    arguments: StatementArguments(arguments)!
                )
                for queryTypeID in queryTypeIDs.sorted() {
                    try db.execute(
                        sql: "INSERT INTO query (instance_id, query_type_id) VALUES (?, ?)",
                        arguments: [personID, queryTypeID]
                    )
                }
            }

            let newSex = Self.normalizedFieldValue(fieldValuesByFieldID[sexField.id] ?? oldSex, kind: .sex)

            // 2. Load current relationship state.
            let currentSlots = try Self.fetchParentSlots(db: db, childID: personID)
            let currentPartnerships = try Self.fetchPartnershipsInvolving(db: db, personID: personID)
            var currentChildrenByPartnershipID: [Int64: [(rowID: Int64, ref: PersonRef)]] = [:]
            for row in currentPartnerships {
                currentChildrenByPartnershipID[row.id] = try Self.fetchGroupedChildRows(db: db, partnershipID: row.id)
            }
            let currentUngrouped = try Self.fetchDirectChildRows(db: db, parentID: personID)
            let currentHoldings = try Self.fetchPersonOfficeHoldings(db: db, instanceID: personID)

            // The partnership (if any) under which A itself is grouped: its two
            // sides are A's grouping-derived biological parents.
            let groupingPartnershipID = try Int64.fetchOne(
                db,
                sql: "SELECT partnership_id FROM person_partnership_child WHERE child_id = ?",
                arguments: [personID]
            )

            // 3. Structural validation (plain DatabaseError, not a contradiction).
            try Self.validateDraftStructure(
                db: db,
                personID: personID,
                personTypeID: personTypeID,
                relations: relations,
                currentPartnershipIDs: Set(currentPartnerships.map(\.id)),
                currentPersonOfficeIDs: Set(currentHoldings.map(\.personOfficeID))
            )

            // 4-5. Diff + conflict collection (read-only).
            var conflicts: [PersonSaveConflict] = []
            var changes: Set<PersonRelationChange> = []

            let draftSlots: [PersonParentRole: PersonRef?] = [
                .mother: relations.mother,
                .father: relations.father,
                .adoptiveMother: relations.adoptiveMother,
                .adoptiveFather: relations.adoptiveFather,
            ]

            // 4a. Own parent slots.
            for role in PersonParentRole.allCases {
                let current = currentSlots[role]
                let draft = draftSlots[role] ?? nil
                guard current != draft else { continue }

                let isBiological = (role == .mother || role == .father)
                if isBiological, let groupingPartnershipID,
                   let grouping = try Self.fetchPartnershipRow(db: db, id: groupingPartnershipID) {
                    // A's biological parents come from a grouping owned by the
                    // parents' partnership; block child-side edits.
                    let aName = try Self.refDescription(db: db, .instance(grouping.aID))
                    let bName = try Self.refDescription(
                        db: db,
                        grouping.bID.map(PersonRef.instance) ?? .bare(grouping.bBare ?? "")
                    )
                    conflicts.append(PersonSaveConflict(
                        instanceID: nil,
                        displayName: try Self.displayNameOrUnknown(db: db, instanceID: personID),
                        kind: .groupedParentEdit(parentAName: aName, parentBName: bName)
                    ))
                    continue
                }

                if case .instance(let parentID)? = draft {
                    let requiredSex = (role == .mother || role == .adoptiveMother) ? "Female" : "Male"
                    let parentSex = try Self.fetchPersonSex(db: db, personTypeID: personTypeID, instanceID: parentID)
                    if parentSex != requiredSex {
                        conflicts.append(PersonSaveConflict(
                            instanceID: parentID,
                            displayName: try Self.displayNameOrUnknown(db: db, instanceID: parentID),
                            kind: .sexRoleMismatch(role: role, actualSex: parentSex)
                        ))
                    }
                }

                try Self.addParentSlotChangeEffects(
                    db: db, into: &changes, childID: personID, role: role, old: current, new: draft
                )
            }

            // 4b. Partnerships: match by partnershipID.
            let draftByPartnershipID = Dictionary(
                uniqueKeysWithValues: relations.partners.compactMap { draft in
                    draft.partnershipID.map { ($0, draft) }
                }
            )
            let removedPartnerships = currentPartnerships.filter { draftByPartnershipID[$0.id] == nil }

            // Partner-identity replacements + grouped-children membership diffs.
            struct GroupedChildrenDiff {
                let partnershipRow: PartnershipRow?   // nil for new partnerships
                let draft: PersonPartnerDraft
                let added: [PersonRef]
                let removed: [PersonRef]
                let orderChanged: Bool
            }
            var groupedDiffs: [GroupedChildrenDiff] = []

            for draft in relations.partners {
                if let partnershipID = draft.partnershipID {
                    guard let row = currentPartnerships.first(where: { $0.id == partnershipID }) else { continue }
                    let currentPartner = row.partnerRef(relativeTo: personID)
                    let currentChildren = (currentChildrenByPartnershipID[partnershipID] ?? []).map(\.ref)
                    let draftChildren = draft.children.map(\.child)
                    let added = Self.multisetSubtract(draftChildren, currentChildren)
                    let removed = Self.multisetSubtract(currentChildren, draftChildren)
                    let orderChanged = currentChildren != draftChildren
                    groupedDiffs.append(GroupedChildrenDiff(
                        partnershipRow: row, draft: draft,
                        added: added, removed: removed, orderChanged: orderChanged
                    ))

                    if draft.partner != currentPartner, !currentChildren.isEmpty || !draftChildren.isEmpty {
                        // Replacing a partner who has (or is gaining) grouped
                        // children: the replacement must carry the vacated role.
                        if case .instance(let newPartnerID) = draft.partner {
                            let vacatedRoleSex = try Self.partnerRoleSex(
                                db: db, personTypeID: personTypeID,
                                mySex: newSex, partner: currentPartner
                            )
                            let newPartnerSex = try Self.fetchPersonSex(
                                db: db, personTypeID: personTypeID, instanceID: newPartnerID
                            )
                            if let vacatedRoleSex, newPartnerSex != vacatedRoleSex {
                                let role: PersonParentRole = vacatedRoleSex == "Female" ? .mother : .father
                                conflicts.append(PersonSaveConflict(
                                    instanceID: newPartnerID,
                                    displayName: try Self.displayNameOrUnknown(db: db, instanceID: newPartnerID),
                                    kind: .sexRoleMismatch(role: role, actualSex: newPartnerSex)
                                ))
                            }
                        }
                    }
                } else {
                    let draftChildren = draft.children.map(\.child)
                    groupedDiffs.append(GroupedChildrenDiff(
                        partnershipRow: nil, draft: draft,
                        added: draftChildren, removed: [], orderChanged: !draftChildren.isEmpty
                    ))
                }
            }

            // Same-sex + child-slot conflicts for every added grouped child.
            for diff in groupedDiffs where !diff.added.isEmpty {
                let partner = diff.draft.partner
                var partnerSex: String?
                if case .instance(let partnerID) = partner {
                    partnerSex = try Self.fetchPersonSex(db: db, personTypeID: personTypeID, instanceID: partnerID)
                }
                if let partnerSex, partnerSex == newSex {
                    conflicts.append(PersonSaveConflict(
                        instanceID: nil,
                        displayName: try Self.displayNameOrUnknown(db: db, instanceID: personID),
                        kind: .sameSexChildren(otherPartnerName: try Self.refDescription(db: db, partner))
                    ))
                    continue
                }
                let myRole: PersonParentRole = newSex == "Female" ? .mother : .father
                let partnerRole: PersonParentRole = myRole == .mother ? .father : .mother
                for childRef in diff.added {
                    guard case .instance(let childID) = childRef else { continue }
                    let childSlots = try Self.fetchParentSlots(db: db, childID: childID)
                    let implied: [(PersonParentRole, PersonRef)] = [
                        (myRole, .instance(personID)),
                        (partnerRole, partner),
                    ]
                    for (role, ref) in implied {
                        if let existing = childSlots[role], existing != ref {
                            conflicts.append(PersonSaveConflict(
                                instanceID: childID,
                                displayName: try Self.displayNameOrUnknown(db: db, instanceID: childID),
                                kind: .slotOccupied(
                                    slot: role,
                                    existingDescription: try Self.refDescription(db: db, existing),
                                    attemptedDescription: try Self.refDescription(db: db, ref)
                                )
                            ))
                        }
                    }
                }
            }

            // 4c. Ungrouped children diff + conflicts.
            let currentUngroupedRefs = currentUngrouped.map(\.ref)
            let draftUngroupedRefs = relations.ungroupedChildren.map(\.child)
            let ungroupedAdded = Self.multisetSubtract(draftUngroupedRefs, currentUngroupedRefs)
            let ungroupedRemoved = Self.multisetSubtract(currentUngroupedRefs, draftUngroupedRefs)
            let ungroupedOrderChanged = currentUngroupedRefs != draftUngroupedRefs

            let myBiologicalRole: PersonParentRole = newSex == "Female" ? .mother : .father
            for childRef in ungroupedAdded {
                guard case .instance(let childID) = childRef else { continue }
                let childSlots = try Self.fetchParentSlots(db: db, childID: childID)
                if let existing = childSlots[myBiologicalRole], existing != .instance(personID) {
                    conflicts.append(PersonSaveConflict(
                        instanceID: childID,
                        displayName: try Self.displayNameOrUnknown(db: db, instanceID: childID),
                        kind: .slotOccupied(
                            slot: myBiologicalRole,
                            existingDescription: try Self.refDescription(db: db, existing),
                            attemptedDescription: try Self.refDescription(db: db, .instance(personID))
                        )
                    ))
                }
            }

            // 4d. Sex change: flipping A's role on existing children.
            let sexFlipped = oldSex != newSex
            var flipRows: [(rowID: Int64, childID: Int64, role: PersonParentRole)] = []
            if sexFlipped {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, child_id, role FROM person_parent WHERE parent_id = ?",
                    arguments: [personID]
                )
                for row in rows {
                    guard let role = PersonParentRole(rawValue: row["role"]) else { continue }
                    flipRows.append((row["id"], row["child_id"], role))
                }

                for (_, childID, role) in flipRows {
                    let flipped = Self.flippedRole(role)
                    let childSlots = try Self.fetchParentSlots(db: db, childID: childID)
                    guard let occupant = childSlots[flipped] else { continue }
                    // {A, bare} biological pairs swap in place — no conflict.
                    let isBiologicalPair = (role == .mother || role == .father)
                        && occupant.bareName != nil
                    if isBiologicalPair { continue }
                    conflicts.append(PersonSaveConflict(
                        instanceID: childID,
                        displayName: try Self.displayNameOrUnknown(db: db, instanceID: childID),
                        kind: .sexChangeConflict(
                            occupiedSlot: flipped,
                            occupantDescription: try Self.refDescription(db: db, occupant)
                        )
                    ))
                }

                // A child-bearing partnership must stay opposite-sex.
                for row in currentPartnerships {
                    let hasChildren = !(currentChildrenByPartnershipID[row.id] ?? []).isEmpty
                    guard hasChildren else { continue }
                    let partner = row.partnerRef(relativeTo: personID)
                    if case .instance(let partnerID) = partner {
                        let partnerSex = try Self.fetchPersonSex(db: db, personTypeID: personTypeID, instanceID: partnerID)
                        if partnerSex == newSex {
                            conflicts.append(PersonSaveConflict(
                                instanceID: nil,
                                displayName: try Self.displayNameOrUnknown(db: db, instanceID: personID),
                                kind: .sameSexChildren(otherPartnerName: try Self.refDescription(db: db, partner))
                            ))
                        }
                    }
                }
            }

            if !conflicts.isEmpty {
                throw PersonSaveError(conflicts: conflicts)
            }

            // 6. Apply. Deletes first (frees slots), then updates/inserts, then
            //    sex-flip role moves, then order renumbering and enablement.

            // 6a. Removed partnerships: auto-ungroup their children (keep
            //     parentage, append to each instance side's ungrouped list),
            //     then delete the row (cascades grouping + children_with rows).
            for row in removedPartnerships {
                let children = currentChildrenByPartnershipID[row.id] ?? []
                for side in row.sideInstanceIDs {
                    for (_, childRef) in children {
                        try Self.appendDirectChild(db: db, parentID: side, child: childRef)
                    }
                    changes.insert(PersonRelationChange(instanceID: side, kind: .children))
                    // Both sides' partner lists lost this partnership.
                    changes.insert(PersonRelationChange(instanceID: side, kind: .partners))
                }
                for (_, childRef) in children {
                    if case .instance(let childID) = childRef {
                        changes.insert(PersonRelationChange(instanceID: childID, kind: .fullSiblings))
                    }
                }
                try db.execute(sql: "DELETE FROM person_partnership WHERE id = ?", arguments: [row.id])
            }

            // 6b. Own-slot changes (removals + replacements + fills).
            for role in PersonParentRole.allCases {
                let current = currentSlots[role]
                let draft = draftSlots[role] ?? nil
                guard current != draft else { continue }
                let isBiological = (role == .mother || role == .father)

                if let current {
                    try db.execute(
                        sql: "DELETE FROM person_parent WHERE child_id = ? AND role = ?",
                        arguments: [personID, role.rawValue]
                    )
                    if isBiological, case .instance(let oldParentID) = current {
                        try db.execute(
                            sql: "DELETE FROM person_direct_child WHERE parent_id = ? AND child_id = ?",
                            arguments: [oldParentID, personID]
                        )
                    }
                }
                if let draft {
                    try Self.insertParentRow(db: db, childID: personID, role: role, parent: draft)
                    if isBiological, case .instance(let newParentID) = draft {
                        try Self.appendDirectChild(db: db, parentID: newParentID, child: .instance(personID))
                    }
                }
            }

            // 6c. Partnership in-place updates + partner replacements.
            for draft in relations.partners {
                guard let partnershipID = draft.partnershipID,
                      let row = currentPartnerships.first(where: { $0.id == partnershipID })
                else { continue }
                let currentPartner = row.partnerRef(relativeTo: personID)

                if draft.partner != currentPartner {
                    try Self.replacePartner(
                        db: db,
                        personID: personID,
                        personTypeID: personTypeID,
                        mySex: newSex,
                        row: row,
                        oldPartner: currentPartner,
                        newPartner: draft.partner,
                        groupedChildren: (currentChildrenByPartnershipID[partnershipID] ?? []).map(\.ref),
                        changes: &changes
                    )
                }

                try db.execute(
                    sql: """
                        UPDATE person_partnership
                        SET is_married = ?, start_text = ?, end_text = ?
                        WHERE id = ?
                        """,
                    arguments: [draft.isMarried ? 1 : 0, draft.startText, draft.endText, partnershipID]
                )
            }

            // 6d. New partnerships.
            var partnershipIDByDraftIndex: [Int: Int64] = [:]
            for (index, draft) in relations.partners.enumerated() {
                if let existingID = draft.partnershipID {
                    partnershipIDByDraftIndex[index] = existingID
                    continue
                }
                let bID: Int64?
                let bBare: String?
                var bOrder: Int?
                switch draft.partner {
                case .instance(let partnerID):
                    bID = partnerID
                    bBare = nil
                    bOrder = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM person_partnership WHERE a_id = ? OR b_id = ?",
                        arguments: [partnerID, partnerID]
                    ) ?? 0
                case .bare(let name):
                    bID = nil
                    bBare = name
                    bOrder = nil
                }
                try db.execute(
                    sql: """
                        INSERT INTO person_partnership
                            (a_id, b_id, b_bare, is_married, start_text, end_text, a_order_index, b_order_index)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [personID, bID, bBare, draft.isMarried ? 1 : 0, draft.startText, draft.endText, index, bOrder]
                )
                partnershipIDByDraftIndex[index] = db.lastInsertedRowID

                // A new partnership adds to this person's partner list (and the
                // instance partner's, reciprocally).
                changes.insert(PersonRelationChange(instanceID: personID, kind: .partners))
                if case .instance(let partnerID) = draft.partner {
                    changes.insert(PersonRelationChange(instanceID: partnerID, kind: .partners))
                }
            }

            // 6e. Grouped-children reconciliation (per partner draft).
            for (index, draft) in relations.partners.enumerated() {
                guard let partnershipID = partnershipIDByDraftIndex[index] else { continue }
                guard let diff = groupedDiffs.first(where: {
                    $0.draft.partnershipID == draft.partnershipID && $0.draft.partner == draft.partner
                        && $0.draft.children == draft.children
                }) else { continue }
                guard !diff.added.isEmpty || !diff.removed.isEmpty || diff.orderChanged else { continue }

                let myRole: PersonParentRole = newSex == "Female" ? .mother : .father
                let partnerRole: PersonParentRole = myRole == .mother ? .father : .mother

                // Dematerialize removed instance children (they lose both parents).
                for childRef in diff.removed {
                    guard case .instance(let childID) = childRef else { continue }
                    let slots = try Self.fetchParentSlots(db: db, childID: childID)
                    try db.execute(
                        sql: "DELETE FROM person_parent WHERE child_id = ? AND role IN ('mother','father')",
                        arguments: [childID]
                    )
                    try Self.addParentSlotChangeEffects(
                        db: db, into: &changes, childID: childID, role: .mother, old: slots[.mother], new: nil
                    )
                    try Self.addParentSlotChangeEffects(
                        db: db, into: &changes, childID: childID, role: .father, old: slots[.father], new: nil
                    )
                }

                // Materialize added instance children + pull them out of both
                // parents' ungrouped lists.
                for childRef in diff.added {
                    guard case .instance(let childID) = childRef else { continue }
                    let slots = try Self.fetchParentSlots(db: db, childID: childID)
                    let implied: [(PersonParentRole, PersonRef)] = [
                        (myRole, .instance(personID)),
                        (partnerRole, draft.partner),
                    ]
                    for (role, ref) in implied where slots[role] != ref {
                        try db.execute(
                            sql: "DELETE FROM person_parent WHERE child_id = ? AND role = ?",
                            arguments: [childID, role.rawValue]
                        )
                        try Self.insertParentRow(db: db, childID: childID, role: role, parent: ref)
                        try Self.addParentSlotChangeEffects(
                            db: db, into: &changes, childID: childID, role: role, old: slots[role], new: ref
                        )
                    }
                    var parentIDs = [personID]
                    if case .instance(let partnerID) = draft.partner { parentIDs.append(partnerID) }
                    let idList = parentIDs.map(String.init).joined(separator: ", ")
                    try db.execute(
                        sql: "DELETE FROM person_direct_child WHERE child_id = ? AND parent_id IN (\(idList))",
                        arguments: [childID]
                    )
                }

                // Rewrite the grouping rows in draft order (no SRS anchors here).
                try db.execute(
                    sql: "DELETE FROM person_partnership_child WHERE partnership_id = ?",
                    arguments: [partnershipID]
                )
                for (childIndex, child) in draft.children.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO person_partnership_child (partnership_id, child_id, child_bare, order_index)
                            VALUES (?, ?, ?, ?)
                            """,
                        arguments: [partnershipID, child.child.instanceID, child.child.bareName, childIndex]
                    )
                }

                changes.insert(PersonRelationChange(instanceID: personID, kind: .children))
                changes.insert(PersonRelationChange(instanceID: personID, kind: .childrenWith(partnershipID: partnershipID)))
                if case .instance(let partnerID) = draft.partner {
                    changes.insert(PersonRelationChange(instanceID: partnerID, kind: .children))
                    changes.insert(PersonRelationChange(instanceID: partnerID, kind: .childrenWith(partnershipID: partnershipID)))
                }
                for childRef in diff.added + diff.removed {
                    if case .instance(let childID) = childRef {
                        changes.insert(PersonRelationChange(instanceID: childID, kind: .fullSiblings))
                    }
                }
            }

            // 6f. Ungrouped-children reconciliation.
            if !ungroupedAdded.isEmpty || !ungroupedRemoved.isEmpty || ungroupedOrderChanged {
                for childRef in ungroupedRemoved {
                    if case .instance(let childID) = childRef {
                        let slots = try Self.fetchParentSlots(db: db, childID: childID)
                        let role: PersonParentRole = slots.first(where: { $0.value == .instance(personID) && ($0.key == .mother || $0.key == .father) })?.key ?? myBiologicalRole
                        try db.execute(
                            sql: "DELETE FROM person_parent WHERE child_id = ? AND role = ? AND parent_id = ?",
                            arguments: [childID, role.rawValue, personID]
                        )
                        try Self.addParentSlotChangeEffects(
                            db: db, into: &changes, childID: childID, role: role, old: .instance(personID), new: nil
                        )
                    }
                }
                for childRef in ungroupedAdded {
                    if case .instance(let childID) = childRef {
                        let slots = try Self.fetchParentSlots(db: db, childID: childID)
                        if slots[myBiologicalRole] != .instance(personID) {
                            try Self.insertParentRow(db: db, childID: childID, role: myBiologicalRole, parent: .instance(personID))
                            try Self.addParentSlotChangeEffects(
                                db: db, into: &changes, childID: childID, role: myBiologicalRole,
                                old: slots[myBiologicalRole], new: .instance(personID)
                            )
                        }
                    }
                }

                // Rewrite A's ungrouped list in draft order.
                try db.execute(
                    sql: "DELETE FROM person_direct_child WHERE parent_id = ?",
                    arguments: [personID]
                )
                for (childIndex, child) in relations.ungroupedChildren.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO person_direct_child (parent_id, child_id, child_bare, order_index)
                            VALUES (?, ?, ?, ?)
                            """,
                        arguments: [personID, child.child.instanceID, child.child.bareName, childIndex]
                    )
                }
                changes.insert(PersonRelationChange(instanceID: personID, kind: .children))
            }

            // 6g. Sex-flip role moves on surviving rows.
            if sexFlipped {
                let survivingRows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, child_id, role FROM person_parent WHERE parent_id = ?",
                    arguments: [personID]
                )
                for row in survivingRows {
                    guard let role = PersonParentRole(rawValue: row["role"]) else { continue }
                    let rowID = row["id"] as Int64
                    let childID = row["child_id"] as Int64
                    let flipped = Self.flippedRole(role)
                    let childSlots = try Self.fetchParentSlots(db: db, childID: childID)
                    if let occupant = childSlots[flipped], let bare = occupant.bareName {
                        // {A, bare} pair: swap both slots.
                        try db.execute(
                            sql: "DELETE FROM person_parent WHERE child_id = ? AND role IN (?, ?)",
                            arguments: [childID, role.rawValue, flipped.rawValue]
                        )
                        try Self.insertParentRow(db: db, childID: childID, role: flipped, parent: .instance(personID))
                        try Self.insertParentRow(db: db, childID: childID, role: role, parent: .bare(bare))
                    } else {
                        try db.execute(
                            sql: "UPDATE person_parent SET role = ? WHERE id = ?",
                            arguments: [flipped.rawValue, rowID]
                        )
                    }
                    if role == .mother || role == .father {
                        changes.insert(PersonRelationChange(instanceID: childID, kind: .mother))
                        changes.insert(PersonRelationChange(instanceID: childID, kind: .father))
                        changes.insert(PersonRelationChange(instanceID: childID, kind: .parents))
                        changes.insert(PersonRelationChange(instanceID: childID, kind: .fullSiblings))
                    } else {
                        changes.insert(PersonRelationChange(instanceID: childID, kind: .adoptiveMother))
                        changes.insert(PersonRelationChange(instanceID: childID, kind: .adoptiveFather))
                    }
                }
            }

            // 6h. My-side partner order = draft order.
            for (index, _) in relations.partners.enumerated() {
                guard let partnershipID = partnershipIDByDraftIndex[index] else { continue }
                guard let row = try Self.fetchPartnershipRow(db: db, id: partnershipID) else { continue }
                if row.aID == personID {
                    try db.execute(
                        sql: "UPDATE person_partnership SET a_order_index = ? WHERE id = ?",
                        arguments: [index, partnershipID]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE person_partnership SET b_order_index = ? WHERE id = ?",
                        arguments: [index, partnershipID]
                    )
                }
            }
            if relations.partners.map(\.partnershipID) != currentPartnerships.map(\.id).map(Optional.init) {
                changes.insert(PersonRelationChange(instanceID: personID, kind: .children))
            }

            // 6i. Offices: holdings, succession edges, and their change-set
            // entries. Unlike the parent-slot fan-out (which over-approximates),
            // this set is exact: edge changes reset both endpoints' per-office
            // query but NOT peers' All Offices (that answer shows only the
            // person's own holdings, no succession content). Deletes first.
            let currentHoldingsByOfficeID = Dictionary(uniqueKeysWithValues: currentHoldings.map { ($0.officeID, $0) })
            let draftOfficeIDs = Set(relations.offices.map(\.officeID))

            // Removed holdings: capture edge peers first (their office answers
            // lose this person), then delete the per-office query row explicitly
            // (person_query FKs the office, not the holding) and the holding —
            // whose composite-FK cascade removes this person's edges for the
            // office in both directions.
            for holding in currentHoldings where !draftOfficeIDs.contains(holding.officeID) {
                let peers = try Self.fetchOfficeSuccessionPeers(db: db, instanceID: personID, officeID: holding.officeID)
                for peer in Set(peers.predecessors + peers.successors) {
                    changes.insert(PersonRelationChange(instanceID: peer, kind: .office(officeID: holding.officeID)))
                }
                try db.execute(
                    sql: "DELETE FROM person_query WHERE instance_id = ? AND kind = 'office' AND office_id = ?",
                    arguments: [personID, holding.officeID]
                )
                try db.execute(
                    sql: "DELETE FROM person_office WHERE instance_id = ? AND office_id = ?",
                    arguments: [personID, holding.officeID]
                )
                changes.insert(PersonRelationChange(instanceID: personID, kind: .allOffices))
            }

            // Kept holdings UPDATE in place; added holdings INSERT. order_index
            // always follows the draft order.
            for (index, draft) in relations.offices.enumerated() {
                if let current = currentHoldingsByOfficeID[draft.officeID] {
                    if current.whenBegan != draft.whenBegan
                        || current.whenEnded != draft.whenEnded
                        || current.note != draft.note {
                        changes.insert(PersonRelationChange(instanceID: personID, kind: .office(officeID: draft.officeID)))
                        changes.insert(PersonRelationChange(instanceID: personID, kind: .allOffices))
                    }
                    try db.execute(
                        sql: """
                            UPDATE person_office SET when_began = ?, when_ended = ?, note = ?, order_index = ?
                            WHERE instance_id = ? AND office_id = ?
                            """,
                        arguments: [draft.whenBegan, draft.whenEnded, draft.note, index, personID, draft.officeID]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO person_office (instance_id, office_id, when_began, when_ended, note, order_index)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [personID, draft.officeID, draft.whenBegan, draft.whenEnded, draft.note, index]
                    )
                    changes.insert(PersonRelationChange(instanceID: personID, kind: .allOffices))
                }
            }
            // Order-only changes still re-render the All Offices answer.
            if currentHoldings.map(\.officeID) != relations.offices.map(\.officeID) {
                changes.insert(PersonRelationChange(instanceID: personID, kind: .allOffices))
            }

            // Succession edges, per draft holding, predecessors and successors
            // symmetric. An added edge to a peer who doesn't yet hold the office
            // AUTO-ADDS the holding (empty fields, end of the peer's order) —
            // the composite FK requires it, and the linked person did hold the
            // office by definition.
            func ensurePeerHolding(_ peerID: Int64, officeID: Int64) throws {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO person_office (instance_id, office_id, order_index)
                        VALUES (?1, ?2, (SELECT COALESCE(MAX(order_index) + 1, 0) FROM person_office WHERE instance_id = ?1))
                        """,
                    arguments: [peerID, officeID]
                )
                if db.changesCount == 1 {
                    changes.insert(PersonRelationChange(instanceID: peerID, kind: .allOffices))
                }
            }

            for draft in relations.offices {
                let officeID = draft.officeID
                let currentPeers = try Self.fetchOfficeSuccessionPeers(db: db, instanceID: personID, officeID: officeID)

                // (isPredecessorSide: drafted peers precede this person.)
                for (drafted, current, isPredecessorSide) in [
                    (draft.predecessors, currentPeers.predecessors, true),
                    (draft.successors, currentPeers.successors, false),
                ] {
                    let currentSet = Set(current)
                    let draftedSet = Set(drafted)
                    for peer in drafted where !currentSet.contains(peer) {
                        try ensurePeerHolding(peer, officeID: officeID)
                        try db.execute(
                            sql: """
                                INSERT OR IGNORE INTO person_office_succession (office_id, predecessor_id, successor_id)
                                VALUES (?, ?, ?)
                                """,
                            arguments: isPredecessorSide
                                ? [officeID, peer, personID]
                                : [officeID, personID, peer]
                        )
                        changes.insert(PersonRelationChange(instanceID: personID, kind: .office(officeID: officeID)))
                        changes.insert(PersonRelationChange(instanceID: peer, kind: .office(officeID: officeID)))
                    }
                    for peer in current where !draftedSet.contains(peer) {
                        try db.execute(
                            sql: """
                                DELETE FROM person_office_succession
                                WHERE office_id = ? AND predecessor_id = ? AND successor_id = ?
                                """,
                            arguments: isPredecessorSide
                                ? [officeID, peer, personID]
                                : [officeID, personID, peer]
                        )
                        changes.insert(PersonRelationChange(instanceID: personID, kind: .office(officeID: officeID)))
                        changes.insert(PersonRelationChange(instanceID: peer, kind: .office(officeID: officeID)))
                    }
                }
            }

            // 6j. Built-in query enablement (rows = enabled).
            for kind in PersonQueryKind.standaloneKinds {
                if builtinEnabledKinds.contains(kind) {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO person_query (instance_id, kind) VALUES (?, ?)",
                        arguments: [personID, kind.rawValue]
                    )
                } else {
                    try db.execute(
                        sql: """
                            DELETE FROM person_query
                            WHERE instance_id = ? AND kind = ? AND partnership_id IS NULL AND office_id IS NULL
                            """,
                        arguments: [personID, kind.rawValue]
                    )
                }
            }
            for (index, draft) in relations.partners.enumerated() {
                guard let partnershipID = partnershipIDByDraftIndex[index] else { continue }
                if draft.isChildrenQueryEnabled {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO person_query (instance_id, kind, partnership_id)
                            VALUES (?, 'children_with', ?)
                            """,
                        arguments: [personID, partnershipID]
                    )
                } else {
                    try db.execute(
                        sql: """
                            DELETE FROM person_query
                            WHERE instance_id = ? AND kind = 'children_with' AND partnership_id = ?
                            """,
                        arguments: [personID, partnershipID]
                    )
                }
            }
            for draft in relations.offices {
                if draft.isQueryEnabled {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO person_query (instance_id, kind, office_id)
                            VALUES (?, 'office', ?)
                            """,
                        arguments: [personID, draft.officeID]
                    )
                } else {
                    try db.execute(
                        sql: "DELETE FROM person_query WHERE instance_id = ? AND kind = 'office' AND office_id = ?",
                        arguments: [personID, draft.officeID]
                    )
                }
            }

            // 7. Reset affected queries when the per-type option is on.
            let resetFlag = try String.fetchOne(
                db,
                sql: "SELECT value FROM globals WHERE name = ?",
                arguments: [PERSON_RESET_QUERIES_GLOBAL_KEY]
            ) == "1"
            let resetCount = resetFlag
                ? try Self.resetPersonQueriesForRelationshipChanges(db: db, changes: changes)
                : 0

            return PersonSaveResult(instanceID: personID, resetQueryCount: resetCount)
        }
    }

    // MARK: - Save helpers

    /// Draft-shape validation: throws plain DatabaseError (surfaced as a toast,
    /// not the blocking contradiction popup).
    private nonisolated static func validateDraftStructure(
        db: Database,
        personID: Int64,
        personTypeID: Int64,
        relations: PersonRelationsDraft,
        currentPartnershipIDs: Set<Int64>,
        currentPersonOfficeIDs: Set<Int64>
    ) throws {
        var instanceRefs: [Int64] = []
        var bareNames: [String] = []
        var childInstanceIDs: [Int64] = []

        func collect(_ ref: PersonRef?, isChild: Bool = false) {
            switch ref {
            case .instance(let id):
                instanceRefs.append(id)
                if isChild { childInstanceIDs.append(id) }
            case .bare(let name):
                bareNames.append(name)
            case nil:
                break
            }
        }

        collect(relations.mother)
        collect(relations.father)
        collect(relations.adoptiveMother)
        collect(relations.adoptiveFather)
        for partner in relations.partners {
            collect(partner.partner)
            for child in partner.children { collect(child.child, isChild: true) }
        }
        for child in relations.ungroupedChildren { collect(child.child, isChild: true) }

        for name in bareNames where name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DatabaseError(message: "A name-only entry cannot be blank.")
        }
        if instanceRefs.contains(personID) {
            throw DatabaseError(message: "A person cannot be their own relative.")
        }
        if childInstanceIDs.count != Set(childInstanceIDs).count {
            throw DatabaseError(message: "The same person cannot be listed as a child more than once.")
        }
        let parentSlotIDs = Set([relations.mother, relations.father, relations.adoptiveMother, relations.adoptiveFather]
            .compactMap { $0?.instanceID })
        if !parentSlotIDs.isDisjoint(with: Set(childInstanceIDs)) {
            throw DatabaseError(message: "A person cannot be both a parent and a child of the same person.")
        }
        for partner in relations.partners {
            if let partnerID = partner.partner.instanceID,
               partner.children.contains(where: { $0.child.instanceID == partnerID }) {
                throw DatabaseError(message: "A partner cannot also be a child of that partnership.")
            }
            if let partnershipID = partner.partnershipID, !currentPartnershipIDs.contains(partnershipID) {
                throw DatabaseError(message: "Unknown partnership for this person.")
            }
        }

        // Office shape checks. Self-links get their office-specific message
        // BEFORE the peers merge into instanceRefs (whose generic self-relative
        // check already ran above on relationship refs only).
        let draftOfficeIDs = relations.offices.map(\.officeID)
        if draftOfficeIDs.count != Set(draftOfficeIDs).count {
            throw DatabaseError(message: "The same office cannot be added to a person twice.")
        }
        for office in relations.offices {
            if office.predecessors.contains(personID) || office.successors.contains(personID) {
                throw DatabaseError(message: "A person cannot be their own predecessor or successor.")
            }
            if office.predecessors.count != Set(office.predecessors).count
                || office.successors.count != Set(office.successors).count {
                throw DatabaseError(message: "The same person cannot be listed as a predecessor or successor twice for one office.")
            }
            if let personOfficeID = office.personOfficeID, !currentPersonOfficeIDs.contains(personOfficeID) {
                throw DatabaseError(message: "Unknown office entry for this person.")
            }
            instanceRefs.append(contentsOf: office.predecessors)
            instanceRefs.append(contentsOf: office.successors)
        }
        if !draftOfficeIDs.isEmpty {
            let idList = Set(draftOfficeIDs).map(String.init).joined(separator: ", ")
            let foundOffices = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM office WHERE id IN (\(idList))",
                arguments: []
            ) ?? 0
            if foundOffices != Set(draftOfficeIDs).count {
                throw DatabaseError(message: "Every office entry must reference an existing office.")
            }
        }

        if !instanceRefs.isEmpty {
            let idList = Set(instanceRefs).map(String.init).joined(separator: ", ")
            let nonPersonCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM instance_id_type_id
                    WHERE instance_id IN (\(idList)) AND type_id != ?
                    """,
                arguments: [personTypeID]
            ) ?? 0
            let foundCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM instance_id_type_id WHERE instance_id IN (\(idList))",
                arguments: []
            ) ?? 0
            if nonPersonCount > 0 || foundCount != Set(instanceRefs).count {
                throw DatabaseError(message: "Every linked relative must be an existing Person instance.")
            }
        }
    }

    /// The sex of the role a partner occupies, for role-vacancy checks. nil for
    /// bare partners with no children context (role inferred at grouping time).
    private nonisolated static func partnerRoleSex(
        db: Database,
        personTypeID: Int64,
        mySex: String,
        partner: PersonRef
    ) throws -> String? {
        switch partner {
        case .instance(let id):
            return try fetchPersonSex(db: db, personTypeID: personTypeID, instanceID: id)
        case .bare:
            return mySex == "Female" ? "Male" : "Female"
        }
    }

    private nonisolated static func flippedRole(_ role: PersonParentRole) -> PersonParentRole {
        switch role {
        case .mother: return .father
        case .father: return .mother
        case .adoptiveMother: return .adoptiveFather
        case .adoptiveFather: return .adoptiveMother
        }
    }

    private nonisolated static func insertParentRow(
        db: Database,
        childID: Int64,
        role: PersonParentRole,
        parent: PersonRef
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO person_parent (child_id, role, parent_id, parent_bare)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [childID, role.rawValue, parent.instanceID, parent.bareName]
        )
    }

    /// Appends a child to a parent's ungrouped list (end of order). No-op when
    /// an identical instance row already exists (partial unique index).
    private nonisolated static func appendDirectChild(db: Database, parentID: Int64, child: PersonRef) throws {
        let nextOrder = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(order_index) + 1, 0) FROM person_direct_child WHERE parent_id = ?",
            arguments: [parentID]
        ) ?? 0
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO person_direct_child (parent_id, child_id, child_bare, order_index)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [parentID, child.instanceID, child.bareName, nextOrder]
        )
    }

    /// Swaps a partnership's partner ref in place (id + children_with SRS
    /// survive) and rewrites each grouped child's materialized other-parent slot.
    private nonisolated static func replacePartner(
        db: Database,
        personID: Int64,
        personTypeID: Int64,
        mySex: String,
        row: PartnershipRow,
        oldPartner: PersonRef,
        newPartner: PersonRef,
        groupedChildren: [PersonRef],
        changes: inout Set<PersonRelationChange>
    ) throws {
        // Rewrite the row so that `personID` stays on a side and the partner
        // ref changes. a_id must always be an instance, so when the new partner
        // is bare, `personID` takes the a side.
        switch newPartner {
        case .instance(let newID):
            let newOrder = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM person_partnership WHERE (a_id = ? OR b_id = ?) AND id != ?",
                arguments: [newID, newID, row.id]
            ) ?? 0
            if row.aID == personID {
                try db.execute(
                    sql: "UPDATE person_partnership SET b_id = ?, b_bare = NULL, b_order_index = ? WHERE id = ?",
                    arguments: [newID, newOrder, row.id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE person_partnership SET a_id = ?, a_order_index = ? WHERE id = ?",
                    arguments: [newID, newOrder, row.id]
                )
            }
        case .bare(let name):
            let myOrder = row.orderIndex(of: personID)
            try db.execute(
                sql: """
                    UPDATE person_partnership
                    SET a_id = ?, a_order_index = ?, b_id = NULL, b_order_index = NULL, b_bare = ?
                    WHERE id = ?
                    """,
                arguments: [personID, myOrder, name, row.id]
            )
        }

        // The departed instance partner loses its children_with row for this
        // partnership (the FK cascade only covers whole-partnership deletion).
        if case .instance(let oldID) = oldPartner {
            try db.execute(
                sql: """
                    DELETE FROM person_query
                    WHERE instance_id = ? AND kind = 'children_with' AND partnership_id = ?
                    """,
                arguments: [oldID, row.id]
            )
            changes.insert(PersonRelationChange(instanceID: oldID, kind: .children))
            changes.insert(PersonRelationChange(instanceID: oldID, kind: .partners))
        }
        if case .instance(let newID) = newPartner {
            changes.insert(PersonRelationChange(instanceID: newID, kind: .children))
            changes.insert(PersonRelationChange(instanceID: newID, kind: .childrenWith(partnershipID: row.id)))
            changes.insert(PersonRelationChange(instanceID: newID, kind: .partners))
        }
        changes.insert(PersonRelationChange(instanceID: personID, kind: .children))
        changes.insert(PersonRelationChange(instanceID: personID, kind: .childrenWith(partnershipID: row.id)))
        // This person's partner-list entry swapped identity.
        changes.insert(PersonRelationChange(instanceID: personID, kind: .partners))

        // Rewrite each grouped instance child's other-parent slot.
        let partnerRole: PersonParentRole = mySex == "Female" ? .father : .mother
        for childRef in groupedChildren {
            guard case .instance(let childID) = childRef else { continue }
            let slots = try Self.fetchParentSlots(db: db, childID: childID)
            let old = slots[partnerRole]
            try db.execute(
                sql: "DELETE FROM person_parent WHERE child_id = ? AND role = ?",
                arguments: [childID, partnerRole.rawValue]
            )
            try insertParentRow(db: db, childID: childID, role: partnerRole, parent: newPartner)
            try addParentSlotChangeEffects(
                db: db, into: &changes, childID: childID, role: partnerRole, old: old, new: newPartner
            )
        }
    }

    private nonisolated static func multisetSubtract(_ lhs: [PersonRef], _ rhs: [PersonRef]) -> [PersonRef] {
        var counts: [PersonRef: Int] = [:]
        for ref in rhs { counts[ref, default: 0] += 1 }
        var result: [PersonRef] = []
        for ref in lhs {
            if let count = counts[ref], count > 0 {
                counts[ref] = count - 1
            } else {
                result.append(ref)
            }
        }
        return result
    }

    /// Expands one parent-slot change on `childID` into the affected-query set
    /// (deliberate over-approximation: resetting a query that didn't strictly
    /// change is cheap; missing one is not).
    private nonisolated static func addParentSlotChangeEffects(
        db: Database,
        into changes: inout Set<PersonRelationChange>,
        childID: Int64,
        role: PersonParentRole,
        old: PersonRef?,
        new: PersonRef?
    ) throws {
        switch role {
        case .adoptiveMother:
            changes.insert(PersonRelationChange(instanceID: childID, kind: .adoptiveMother))
            return
        case .adoptiveFather:
            changes.insert(PersonRelationChange(instanceID: childID, kind: .adoptiveFather))
            return
        case .mother:
            changes.insert(PersonRelationChange(instanceID: childID, kind: .mother))
        case .father:
            changes.insert(PersonRelationChange(instanceID: childID, kind: .father))
        }
        changes.insert(PersonRelationChange(instanceID: childID, kind: .parents))
        changes.insert(PersonRelationChange(instanceID: childID, kind: .fullSiblings))

        for ref in [old, new] {
            switch ref {
            case .instance(let parentID)?:
                changes.insert(PersonRelationChange(instanceID: parentID, kind: .children))
                for partnership in try fetchPartnershipsInvolving(db: db, personID: parentID) {
                    changes.insert(PersonRelationChange(
                        instanceID: parentID, kind: .childrenWith(partnershipID: partnership.id)
                    ))
                }
                // Half-siblings through this parent may gain/lose a full sibling.
                let siblingIDs = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT child_id FROM person_parent
                        WHERE parent_id = ? AND role IN ('mother','father')
                        """,
                    arguments: [parentID]
                )
                for siblingID in siblingIDs {
                    changes.insert(PersonRelationChange(instanceID: siblingID, kind: .fullSiblings))
                }
            case .bare(let name)?:
                // Siblings matched through the same bare-name parent string.
                let siblingIDs = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT child_id FROM person_parent
                        WHERE parent_bare = ? AND role = ?
                        """,
                    arguments: [name, role.rawValue]
                )
                for siblingID in siblingIDs {
                    changes.insert(PersonRelationChange(instanceID: siblingID, kind: .fullSiblings))
                }
            case nil:
                break
            }
        }
    }

    // MARK: - Deletion (convert-to-bare)

    /// Number of DISTINCT other Person instances connected to this one through
    /// any relationship table or office succession link (for the
    /// delete-confirmation warning).
    func hasPersonConnections(instanceID: Int64) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (
                        SELECT b_id AS other FROM person_partnership WHERE a_id = ?1 AND b_id IS NOT NULL
                        UNION
                        SELECT a_id FROM person_partnership WHERE b_id = ?1
                        UNION
                        SELECT parent_id FROM person_parent WHERE child_id = ?1 AND parent_id IS NOT NULL
                        UNION
                        SELECT child_id FROM person_parent WHERE parent_id = ?1
                        UNION
                        SELECT child_id FROM person_direct_child WHERE parent_id = ?1 AND child_id IS NOT NULL
                        UNION
                        SELECT parent_id FROM person_direct_child WHERE child_id = ?1
                        UNION
                        SELECT ppc.child_id FROM person_partnership_child ppc
                            JOIN person_partnership pp ON pp.id = ppc.partnership_id
                            WHERE (pp.a_id = ?1 OR pp.b_id = ?1) AND ppc.child_id IS NOT NULL
                        UNION
                        SELECT successor_id FROM person_office_succession WHERE predecessor_id = ?1
                        UNION
                        SELECT predecessor_id FROM person_office_succession WHERE successor_id = ?1
                    )
                    """,
                arguments: [instanceID]
            ) ?? 0
        }
    }

    /// How many of the given instances are Persons linked to at least one
    /// other person (relationships or office succession) — drives the extra
    /// consequences line in delete confirmations. One set-based query, so
    /// bulk deletes (select-all) don't pay a per-instance round-trip.
    func connectedPersonCount(instanceIDs: [Int64]) throws -> Int {
        guard !instanceIDs.isEmpty else { return 0 }
        return try dbQueue.read { db in
            let personTypeID = try Self.fetchPersonTypeID(db: db)
            let idList = Set(instanceIDs).map(String.init).joined(separator: ", ")
            // The EXISTS arms mirror hasPersonConnections' UNION arms.
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM instance_id_type_id i
                    WHERE i.instance_id IN (\(idList)) AND i.type_id = ?
                      AND (
                        EXISTS (SELECT 1 FROM person_partnership pp
                                WHERE (pp.a_id = i.instance_id AND pp.b_id IS NOT NULL) OR pp.b_id = i.instance_id)
                        OR EXISTS (SELECT 1 FROM person_parent p
                                   WHERE (p.child_id = i.instance_id AND p.parent_id IS NOT NULL)
                                      OR p.parent_id = i.instance_id)
                        OR EXISTS (SELECT 1 FROM person_direct_child dc
                                   WHERE (dc.parent_id = i.instance_id AND dc.child_id IS NOT NULL)
                                      OR dc.child_id = i.instance_id)
                        OR EXISTS (SELECT 1 FROM person_partnership_child ppc
                                   JOIN person_partnership pp2 ON pp2.id = ppc.partnership_id
                                   WHERE (pp2.a_id = i.instance_id OR pp2.b_id = i.instance_id)
                                     AND ppc.child_id IS NOT NULL)
                        OR EXISTS (SELECT 1 FROM person_office_succession s
                                   WHERE s.predecessor_id = i.instance_id OR s.successor_id = i.instance_id)
                      )
                    """,
                arguments: [personTypeID]
            ) ?? 0
        }
    }

    /// Converts every reference to `instanceID` on OTHER people into a
    /// bare-name entry (display name, fallback "Unknown"), preserving family
    /// structure, groupings, and children_with SRS state. Returns the affected-
    /// query change set. Must run before the generic instance delete.
    ///
    /// Office succession links have no bare-name form: the peers' edges (and
    /// this person's holdings/queries) die by FK cascade when the instance row
    /// is deleted — only their change-set entries are gathered here.
    nonisolated static func deletePersonRelations(db: Database, instanceID: Int64) throws -> Set<PersonRelationChange> {
        let name = try displayNameOrUnknown(db: db, instanceID: instanceID)
        var changes: Set<PersonRelationChange> = []

        // Gather the affected-query set BEFORE mutating.
        // Office succession peers: their per-office answers lose this person.
        let successionRows = try Row.fetchAll(
            db,
            sql: """
                SELECT office_id, predecessor_id, successor_id
                FROM person_office_succession
                WHERE predecessor_id = ?1 OR successor_id = ?1
                """,
            arguments: [instanceID]
        )
        for row in successionRows {
            let predecessorID = row["predecessor_id"] as Int64
            let successorID = row["successor_id"] as Int64
            let peer = predecessorID == instanceID ? successorID : predecessorID
            changes.insert(PersonRelationChange(instanceID: peer, kind: .office(officeID: row["office_id"])))
        }

        let partnerships = try fetchPartnershipsInvolving(db: db, personID: instanceID)
        for row in partnerships {
            for side in row.sideInstanceIDs where side != instanceID {
                changes.insert(PersonRelationChange(instanceID: side, kind: .children))
                changes.insert(PersonRelationChange(instanceID: side, kind: .childrenWith(partnershipID: row.id)))
                // The partner's reference to the deleted person becomes a bare
                // name, so their Partners answer changes.
                changes.insert(PersonRelationChange(instanceID: side, kind: .partners))
            }
        }
        // Children of X (their parent slot converts to a bare name).
        let childRows = try Row.fetchAll(
            db,
            sql: "SELECT child_id, role FROM person_parent WHERE parent_id = ?",
            arguments: [instanceID]
        )
        for row in childRows {
            let childID = row["child_id"] as Int64
            let role = PersonParentRole(rawValue: row["role"]) ?? .mother
            switch role {
            case .mother: changes.insert(PersonRelationChange(instanceID: childID, kind: .mother))
            case .father: changes.insert(PersonRelationChange(instanceID: childID, kind: .father))
            case .adoptiveMother: changes.insert(PersonRelationChange(instanceID: childID, kind: .adoptiveMother))
            case .adoptiveFather: changes.insert(PersonRelationChange(instanceID: childID, kind: .adoptiveFather))
            }
            if role == .mother || role == .father {
                changes.insert(PersonRelationChange(instanceID: childID, kind: .parents))
                changes.insert(PersonRelationChange(instanceID: childID, kind: .fullSiblings))
            }
        }
        // Parents of X (X leaves their children answers as an instance link).
        let parentIDs = try Int64.fetchAll(
            db,
            sql: "SELECT parent_id FROM person_parent WHERE child_id = ? AND parent_id IS NOT NULL",
            arguments: [instanceID]
        )
        for parentID in parentIDs {
            changes.insert(PersonRelationChange(instanceID: parentID, kind: .children))
            for partnership in try fetchPartnershipsInvolving(db: db, personID: parentID) {
                changes.insert(PersonRelationChange(instanceID: parentID, kind: .childrenWith(partnershipID: partnership.id)))
            }
            let siblingIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT child_id FROM person_parent
                    WHERE parent_id = ? AND role IN ('mother','father') AND child_id != ?
                    """,
                arguments: [parentID, instanceID]
            )
            for siblingID in siblingIDs {
                changes.insert(PersonRelationChange(instanceID: siblingID, kind: .fullSiblings))
            }
        }

        // 1-3. Partnerships: keep the row when an instance side remains
        // (converting X's side to the bare name); delete when X's partner was
        // already bare (no instance side would remain).
        try db.execute(
            sql: """
                UPDATE person_partnership
                SET b_id = NULL, b_order_index = NULL, b_bare = ?
                WHERE b_id = ?
                """,
            arguments: [name, instanceID]
        )
        let aSideRows = try Row.fetchAll(
            db,
            sql: "SELECT id, b_id, b_order_index FROM person_partnership WHERE a_id = ?",
            arguments: [instanceID]
        )
        for row in aSideRows {
            if let bID = row["b_id"] as Int64? {
                let bOrder = row["b_order_index"] as Int64? ?? 0
                try db.execute(
                    sql: """
                        UPDATE person_partnership
                        SET a_id = ?, a_order_index = ?, b_id = NULL, b_order_index = NULL, b_bare = ?
                        WHERE id = ?
                        """,
                    arguments: [bID, bOrder, name, row["id"] as Int64]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM person_partnership WHERE id = ?",
                    arguments: [row["id"] as Int64]
                )
            }
        }

        // 4-6. Grouping, parent, and direct-child references.
        try db.execute(
            sql: "UPDATE person_partnership_child SET child_id = NULL, child_bare = ? WHERE child_id = ?",
            arguments: [name, instanceID]
        )
        try db.execute(
            sql: "UPDATE person_parent SET parent_id = NULL, parent_bare = ? WHERE parent_id = ?",
            arguments: [name, instanceID]
        )
        try db.execute(
            sql: "DELETE FROM person_parent WHERE child_id = ?",
            arguments: [instanceID]
        )
        try db.execute(
            sql: "DELETE FROM person_direct_child WHERE parent_id = ?",
            arguments: [instanceID]
        )
        try db.execute(
            sql: "UPDATE person_direct_child SET child_id = NULL, child_bare = ? WHERE child_id = ?",
            arguments: [name, instanceID]
        )
        // X's own person_query rows die via the instance_id_type_id FK cascade.

        return changes
    }

    // MARK: - Person picker search

    /// Search Person instances for the slot picker. Matches against the display
    /// field; empty query lists all. `excludingInstanceID` omits the instance
    /// being edited (no self references).
    func fetchPersonCandidates(matching query: String, excludingInstanceID: Int64?) throws -> [PersonCandidate] {
        try dbQueue.read { db in
            let personTypeID = try Self.fetchPersonTypeID(db: db)
            guard let displayFieldIndex = try Int.fetchOne(
                db,
                sql: """
                    SELECT field_index FROM field WHERE type_id = ?
                    ORDER BY is_primary DESC, field_display_index ASC, id
                    LIMIT 1
                    """,
                arguments: [personTypeID]
            ) else {
                return []
            }
            let sexIndex = try Self.personSexFieldIndex(db: db, personTypeID: personTypeID)

            let displayColumn = "\"field\(displayFieldIndex)\""
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

            var conditions: [String] = []
            var arguments: [DatabaseValue] = []
            if let excludingInstanceID {
                conditions.append("id != ?")
                arguments.append(excludingInstanceID.databaseValue)
            }
            if !trimmed.isEmpty {
                conditions.append("\(displayColumn) LIKE ? ESCAPE '\\'")
                let escaped = trimmed
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                arguments.append("%\(escaped)%".databaseValue)
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id,
                           COALESCE(\(displayColumn), '') AS displayValue,
                           COALESCE("field\(sexIndex)", 'Male') AS sex
                    FROM "type\(personTypeID)"
                    \(whereClause)
                    ORDER BY \(displayColumn) COLLATE NOCASE, id
                    LIMIT 100
                    """,
                arguments: StatementArguments(arguments)
            )
            return rows.map {
                PersonCandidate(id: $0["id"], displayValue: $0["displayValue"], sex: $0["sex"])
            }
        }
    }

    // MARK: - Reset-on-connection-change

    func fetchPersonResetQueriesOnConnectionChange() throws -> Bool {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM globals WHERE name = ?",
                arguments: [PERSON_RESET_QUERIES_GLOBAL_KEY]
            ) == "1"
        }
    }

    func setPersonResetQueriesOnConnectionChange(_ isOn: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO globals (name, value) VALUES (?, ?)",
                arguments: [PERSON_RESET_QUERIES_GLOBAL_KEY, isOn ? "1" : "0"]
            )
        }
    }

    /// Resets the SRS state of every ENABLED built-in query named by `changes`
    /// (never inserts rows). Already-reset rows are skipped so the returned
    /// count reflects genuinely-reset queries (green toast).
    @discardableResult
    nonisolated static func resetPersonQueriesForRelationshipChanges(
        db: Database,
        changes: Set<PersonRelationChange>
    ) throws -> Int {
        var total = 0
        for change in changes {
            let kind: PersonQueryKind
            var partnershipID: Int64?
            var officeID: Int64?
            switch change.kind {
            case .mother: kind = .mother
            case .father: kind = .father
            case .parents: kind = .parents
            case .adoptiveMother: kind = .adoptiveMother
            case .adoptiveFather: kind = .adoptiveFather
            case .partners: kind = .partners
            case .children: kind = .children
            case .fullSiblings: kind = .fullSiblings
            case .childrenWith(let id):
                kind = .childrenWith
                partnershipID = id
            case .office(let id):
                kind = .office
                officeID = id
            case .allOffices: kind = .allOffices
            }
            try db.execute(
                sql: """
                    UPDATE person_query
                    SET interval = 0, query_state = 0, last_answered_timestamp = NULL
                    WHERE instance_id = ? AND kind = ? AND partnership_id IS ? AND office_id IS ?
                        AND NOT (interval = 0 AND query_state = 0 AND last_answered_timestamp IS NULL)
                    """,
                arguments: [change.instanceID, kind.rawValue, partnershipID, officeID]
            )
            total += db.changesCount
        }
        return total
    }
}
