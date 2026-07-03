//
//  PersonModels.swift
//  Memor
//
//  Plain-data types for the built-in Person type: relationship slots (drafts),
//  built-in relationship queries, the save routine's change set, and the
//  structured contradiction errors surfaced by the blocking save popup.
//

import Foundation

/// The globals-table key for the Person type's "Reset affected queries when
/// connections change" option ('1' = on; anything else / absent = off).
nonisolated let PERSON_RESET_QUERIES_GLOBAL_KEY = "person_reset_queries_on_connection_change"

/// An entry in a Person relationship slot: another Person instance, or a bare
/// name (free text for someone the user didn't make an instance for). Bare
/// names anchor to the one instance side of a relationship and carry no
/// reciprocity or consistency obligations.
nonisolated enum PersonRef: Hashable {
    case instance(Int64)
    case bare(String)

    var instanceID: Int64? {
        if case .instance(let id) = self { return id }
        return nil
    }

    var bareName: String? {
        if case .bare(let name) = self { return name }
        return nil
    }
}

/// The four 0-or-1 parent slots on a Person. Raw values match the
/// person_parent.role column.
nonisolated enum PersonParentRole: String, Hashable, CaseIterable {
    case mother
    case father
    case adoptiveMother = "adoptive_mother"
    case adoptiveFather = "adoptive_father"

    var displayName: String {
        switch self {
        case .mother: return "Mother"
        case .father: return "Father"
        case .adoptiveMother: return "Adoptive Mother"
        case .adoptiveFather: return "Adoptive Father"
        }
    }
}

/// One child entry in a partner card or the ungrouped Children list.
/// `rowID` is the person_partnership_child / person_direct_child row id
/// (nil = newly added in the editor).
nonisolated struct PersonChildDraft: Hashable {
    var rowID: Int64?
    var child: PersonRef
}

/// One partner entry in a Person's Partners slot. `partnershipID` is the
/// stable person_partnership row id (nil = newly added); existing rows are
/// UPDATEd in place on save so their `children_with` SRS state survives edits.
nonisolated struct PersonPartnerDraft: Hashable {
    var partnershipID: Int64?
    var partner: PersonRef
    var isMarried: Bool = false
    var startText: String = ""
    var endText: String = ""
    var children: [PersonChildDraft] = []
    /// Whether this person's "Children with {partner}" built-in query is enabled.
    var isChildrenQueryEnabled: Bool = false
}

/// The full slot state of one Person, as edited (and as fetched).
nonisolated struct PersonRelationsDraft: Hashable {
    var mother: PersonRef?
    var father: PersonRef?
    var adoptiveMother: PersonRef?
    var adoptiveFather: PersonRef?
    var partners: [PersonPartnerDraft] = []
    var ungroupedChildren: [PersonChildDraft] = []
}

/// The built-in, non-deleteable relationship query kinds on a Person instance.
/// Raw values match the person_query.kind column. `childrenWith` rows
/// additionally carry a partnership id (one query per partner entry).
nonisolated enum PersonQueryKind: String, Codable, Hashable, CaseIterable {
    case mother
    case father
    case parents
    case adoptiveMother = "adoptive_mother"
    case adoptiveFather = "adoptive_father"
    case partners
    case children
    case childrenWith = "children_with"
    case fullSiblings = "full_siblings"

    var displayName: String {
        switch self {
        case .mother: return "Mother"
        case .father: return "Father"
        case .parents: return "Parents"
        case .adoptiveMother: return "Adoptive Mother"
        case .adoptiveFather: return "Adoptive Father"
        case .partners: return "Partners"
        case .children: return "Children"
        case .childrenWith: return "Children with"
        case .fullSiblings: return "Full Siblings"
        }
    }

    /// The partnership-independent kinds, in display order. `childrenWith`
    /// rows are enumerated separately, one per partner entry.
    static let standaloneKinds: [PersonQueryKind] = [
        .mother, .father, .parents, .adoptiveMother, .adoptiveFather, .partners, .children, .fullSiblings
    ]
}

/// One built-in query's enablement + SRS state for an instance (enabled rows
/// plus disabled placeholders with nil SRS fields).
nonisolated struct PersonBuiltinQueryInfo: Hashable {
    let kind: PersonQueryKind
    let partnershipID: Int64?
    let displayName: String
    let enabled: Bool
    let interval: Int64?
    let queryState: QueryState?
    let lastAnsweredTimestamp: Int64?
}

/// Everything the Person instance editor needs to load one instance.
nonisolated struct PersonEditorData {
    let instanceID: Int64
    let typeID: Int64
    let fieldValuesByFieldID: [Int64: String]
    let enabledQueryTypeIDs: Set<Int64>
    let maxInterval: Int64?
    let relations: PersonRelationsDraft
    /// Display values for every instance referenced by the relations (chips).
    let displayNamesByInstanceID: [Int64: String]
    /// "Male"/"Female" for every referenced instance (same-sex child blocking).
    let sexesByInstanceID: [Int64: String]
    /// Enablement + SRS for the standalone built-in kinds (childrenWith state
    /// is carried on each PersonPartnerDraft).
    let builtinQueries: [PersonBuiltinQueryInfo]
}

// MARK: - Contradictions

/// Why a save was blocked, per affected instance.
nonisolated enum PersonConflictKind: Hashable {
    /// Another instance's 0-or-1 slot is occupied by a different value.
    case slotOccupied(slot: PersonParentRole, existingDescription: String, attemptedDescription: String)
    /// An instance was placed in a sexed role its Sex contradicts.
    case sexRoleMismatch(role: PersonParentRole, actualSex: String)
    /// Children cannot be added to (or persist under) a same-sex partnership.
    case sameSexChildren(otherPartnerName: String)
    /// A grouped parent slot can only be edited from the partnership owner.
    case groupedParentEdit(parentAName: String, parentBName: String)
    /// A sex change would flip this person's role on a child whose opposite
    /// slot is already occupied.
    case sexChangeConflict(occupiedSlot: PersonParentRole, occupantDescription: String)

    var description: String {
        switch self {
        case .slotOccupied(let slot, let existing, let attempted):
            return "\(slot.displayName) is already \(existing) (attempted: \(attempted))"
        case .sexRoleMismatch(let role, let actualSex):
            return "cannot be \(role.displayName) — their Sex is \(actualSex)"
        case .sameSexChildren(let otherPartnerName):
            return "same-sex partners (with \(otherPartnerName)) cannot have shared children"
        case .groupedParentEdit(let parentAName, let parentBName):
            return "this parent comes from the partnership of \(parentAName) and \(parentBName); edit it there"
        case .sexChangeConflict(let occupiedSlot, let occupant):
            return "changing Sex would make them the \(occupiedSlot.displayName.lowercased()), but that slot is already \(occupant)"
        }
    }
}

nonisolated struct PersonSaveConflict: Hashable {
    /// The affected instance (nil when the conflict is about the edited person).
    let instanceID: Int64?
    let displayName: String
    let kind: PersonConflictKind
}

/// Thrown by savePersonInstance when the edit contradicts other instances'
/// data. Nothing is written. The editor presents one bullet per conflict in a
/// blocking alert.
nonisolated struct PersonSaveError: Error {
    let conflicts: [PersonSaveConflict]
}

// MARK: - Change set (consumed by reset-on-connection-change)

/// One relationship fact whose rendered answer may have changed on `instanceID`.
nonisolated enum PersonRelationKind: Hashable {
    case mother
    case father
    case parents
    case adoptiveMother
    case adoptiveFather
    case partners
    case children
    case childrenWith(partnershipID: Int64)
    case fullSiblings
}

nonisolated struct PersonRelationChange: Hashable {
    let instanceID: Int64
    let kind: PersonRelationKind
}

nonisolated struct PersonSaveResult {
    let instanceID: Int64
    /// Enabled queries reset because the per-type reset option was on (0 when off).
    let resetQueryCount: Int
}
