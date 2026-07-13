//
//  PersonQueryChecklist.swift
//  Memor
//
//  The built-in queries in the Person instance editor's query panel: one
//  checkbox row per standalone relationship kind plus one "Children with
//  {partner}" row per partner card, then an Offices section with one row per
//  office card plus the "All Offices" row. A warning triangle appears when an
//  enabled query's answer would currently be empty (every kind except Full
//  Siblings and the per-office queries, whose answers always name the person)
//  — the query stays enable-able regardless.
//

import SwiftUI

struct PersonQueryChecklist: View {
    @ObservedObject var draft: InstanceEditorDraft
    let mode: InstanceEditorMode
    let onPreview: (PersonQueryKind, _ partnerEntryID: UUID?, _ officeEntryID: UUID?) -> Void
    let onResetDueDate: (PersonQueryKind, _ partnerEntryID: UUID?, _ officeEntryID: UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Relationships")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(relationshipRows, id: \.rowID) { row in
                checklistRow(row)
            }

            Divider()
            Text("Offices")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(officeRows, id: \.rowID) { row in
                checklistRow(row)
            }
        }
    }

    // MARK: Rows

    private struct ChecklistRow {
        let rowID: String
        let kind: PersonQueryKind
        let partnerEntryID: UUID?
        let officeEntryID: UUID?
        let title: String
        let showsEmptyWarning: Bool
        let isEnabled: Bool
        let interval: Int64?
    }

    private var relationshipRows: [ChecklistRow] {
        var rows: [ChecklistRow] = []
        // Office kinds render in their own section below (the filter is
        // belt-and-braces for .office, which is never standalone).
        let relationshipKinds = PersonQueryKind.standaloneKinds.filter { $0 != .allOffices && $0 != .office }
        let childrenWithIndex = relationshipKinds.firstIndex(of: .fullSiblings) ?? 0
        for (index, kind) in relationshipKinds.enumerated() {
            if index == childrenWithIndex {
                // Per-partner rows sit between Children and Full Siblings.
                for partner in draft.personPartners {
                    rows.append(ChecklistRow(
                        rowID: "children_with:\(partner.id)",
                        kind: .childrenWith,
                        partnerEntryID: partner.id,
                        officeEntryID: nil,
                        title: "Children with \(partnerLabel(partner))",
                        showsEmptyWarning: partner.isChildrenQueryEnabled && partner.children.isEmpty,
                        isEnabled: partner.isChildrenQueryEnabled,
                        interval: partner.childrenQueryInterval
                    ))
                }
            }
            let enabled = draft.personEnabledQueryKinds.contains(kind)
            rows.append(ChecklistRow(
                rowID: kind.rawValue,
                kind: kind,
                partnerEntryID: nil,
                officeEntryID: nil,
                title: kind.displayName,
                showsEmptyWarning: enabled && answerWouldBeEmpty(kind),
                isEnabled: enabled,
                interval: draft.personQueryIntervalsByKind[kind]
            ))
        }
        return rows
    }

    private var officeRows: [ChecklistRow] {
        var rows: [ChecklistRow] = draft.personOffices.map { office in
            ChecklistRow(
                rowID: "office:\(office.id)",
                kind: .office,
                partnerEntryID: nil,
                officeEntryID: office.id,
                title: office.officeName,
                showsEmptyWarning: false,
                isEnabled: office.isOfficeQueryEnabled,
                interval: office.officeQueryInterval
            )
        }
        let allOfficesEnabled = draft.personEnabledQueryKinds.contains(.allOffices)
        rows.append(ChecklistRow(
            rowID: PersonQueryKind.allOffices.rawValue,
            kind: .allOffices,
            partnerEntryID: nil,
            officeEntryID: nil,
            title: PersonQueryKind.allOffices.displayName,
            showsEmptyWarning: allOfficesEnabled && answerWouldBeEmpty(.allOffices),
            isEnabled: allOfficesEnabled,
            interval: draft.personQueryIntervalsByKind[.allOffices]
        ))
        return rows
    }

    private func partnerLabel(_ partner: PersonPartnerDraftEntry) -> String {
        switch partner.partner {
        case .instance(let id):
            let name = (draft.personDisplayNamesByID[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "#\(id)" : name
        case .bare(let name):
            return name
        }
    }

    /// Whether an enabled query's answer would currently be just "N/A" — a
    /// warning, never a block (Full Siblings is exempt by spec; a per-office
    /// answer always contains the person's own name).
    private func answerWouldBeEmpty(_ kind: PersonQueryKind) -> Bool {
        switch kind {
        case .mother: return draft.personMother == nil
        case .father: return draft.personFather == nil
        case .adoptiveMother: return draft.personAdoptiveMother == nil
        case .adoptiveFather: return draft.personAdoptiveFather == nil
        case .parents: return draft.personMother == nil && draft.personFather == nil
        case .partners: return draft.personPartners.isEmpty
        case .children:
            return draft.personUngroupedChildren.isEmpty
                && draft.personPartners.allSatisfy { $0.children.isEmpty }
        case .allOffices:
            return draft.personOffices.isEmpty
        case .childrenWith, .fullSiblings, .office:
            return false
        }
    }

    @ViewBuilder
    private func checklistRow(_ row: ChecklistRow) -> some View {
        HStack(spacing: 12) {
            Toggle(
                row.title,
                isOn: Binding(
                    get: { row.isEnabled },
                    set: { isOn in setEnabled(isOn, row: row) }
                )
            )
            .toggleStyle(.checkbox)

            if row.showsEmptyWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                    .help("Enabled, but this query currently has an empty answer.")
            }

            if mode == .edit {
                Button {
                    onPreview(row.kind, row.partnerEntryID, row.officeEntryID)
                } label: {
                    Image(systemName: "eye")
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Preview")
            }

            if mode == .edit, row.isEnabled {
                if let interval = row.interval, interval != 0 {
                    Text(formatStudyInterval(interval))
                        .font(.subheadline)
                        .foregroundStyle(interval < 86_400 ? Color.red : Color.green)

                    Button {
                        onResetDueDate(row.kind, row.partnerEntryID, row.officeEntryID)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                    .help("Reset Due Date")
                } else {
                    Text("New")
                        .font(.subheadline)
                        .foregroundStyle(Color.blue)
                }
            }
        }
    }

    private func setEnabled(_ isOn: Bool, row: ChecklistRow) {
        if let officeEntryID = row.officeEntryID {
            guard let index = draft.personOffices.firstIndex(where: { $0.id == officeEntryID }) else { return }
            draft.personOffices[index].isOfficeQueryEnabled = isOn
            if !isOn {
                draft.personOffices[index].officeQueryInterval = nil
            } else if mode == .edit {
                draft.personOffices[index].officeQueryInterval = 0
            }
        } else if let partnerEntryID = row.partnerEntryID {
            guard let index = draft.personPartners.firstIndex(where: { $0.id == partnerEntryID }) else { return }
            draft.personPartners[index].isChildrenQueryEnabled = isOn
            if !isOn {
                draft.personPartners[index].childrenQueryInterval = nil
            } else if mode == .edit {
                draft.personPartners[index].childrenQueryInterval = 0
            }
        } else {
            if isOn {
                draft.personEnabledQueryKinds.insert(row.kind)
                if mode == .edit {
                    draft.personQueryIntervalsByKind[row.kind] = 0
                }
            } else {
                draft.personEnabledQueryKinds.remove(row.kind)
                draft.personQueryIntervalsByKind.removeValue(forKey: row.kind)
            }
        }
    }
}
