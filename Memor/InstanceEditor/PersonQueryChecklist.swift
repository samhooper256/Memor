//
//  PersonQueryChecklist.swift
//  Memor
//
//  The built-in relationship queries in the Person instance editor's query
//  panel: one checkbox row per standalone kind plus one "Children with
//  {partner}" row per partner card. A warning triangle appears when an
//  enabled query's answer would currently be empty (every kind except Full
//  Siblings) — the query stays enable-able regardless.
//

import SwiftUI

struct PersonQueryChecklist: View {
    @ObservedObject var draft: InstanceEditorDraft
    let mode: InstanceEditorMode
    let onPreview: (PersonQueryKind, _ partnerEntryID: UUID?) -> Void
    let onResetDueDate: (PersonQueryKind, _ partnerEntryID: UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Relationships")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(orderedRows, id: \.rowID) { row in
                checklistRow(row)
            }
        }
    }

    // MARK: Rows

    private struct ChecklistRow {
        let rowID: String
        let kind: PersonQueryKind
        let partnerEntryID: UUID?
        let title: String
        let showsEmptyWarning: Bool
        let isEnabled: Bool
        let interval: Int64?
    }

    private var orderedRows: [ChecklistRow] {
        var rows: [ChecklistRow] = []
        let childrenWithIndex = PersonQueryKind.standaloneKinds.firstIndex(of: .fullSiblings) ?? 0
        for (index, kind) in PersonQueryKind.standaloneKinds.enumerated() {
            if index == childrenWithIndex {
                // Per-partner rows sit between Children and Full Siblings.
                for partner in draft.personPartners {
                    rows.append(ChecklistRow(
                        rowID: "children_with:\(partner.id)",
                        kind: .childrenWith,
                        partnerEntryID: partner.id,
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
                title: kind.displayName,
                showsEmptyWarning: enabled && answerWouldBeEmpty(kind),
                isEnabled: enabled,
                interval: draft.personQueryIntervalsByKind[kind]
            ))
        }
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
    /// warning, never a block (Full Siblings is exempt by spec).
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
        case .childrenWith, .fullSiblings:
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
                    onPreview(row.kind, row.partnerEntryID)
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
                        onResetDueDate(row.kind, row.partnerEntryID)
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
        if let partnerEntryID = row.partnerEntryID {
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
