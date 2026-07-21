//
//  PersonOfficesEditor.swift
//  Memor
//
//  The Person instance editor's Offices panel: ordered office cards (office
//  chip, WhenBegan/WhenEnded/Note text fields, predecessor/successor entries)
//  plus the office picker popover, which suggests existing offices by name and
//  can create a new one inline. Every card references an existing office row.
//  Predecessors/successors are Person instances (reciprocal by construction on
//  save) or bare names (free text with no reciprocity), like the relationship
//  slots.
//

import AppKit
import GRDB
import SwiftUI

struct PersonOfficesEditor: View {
    let appDatabase: AppDatabase
    @ObservedObject var draft: InstanceEditorDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Offices")
                .font(.headline)

            officesBox
        }
    }

    private var officesBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Held Offices")
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                OfficeAddButton(
                    appDatabase: appDatabase,
                    alreadySelectedOfficeIDs: Set(draft.personOffices.map(\.officeID)),
                    onSelectOffice: { officeID, officeName in
                        draft.personOffices.append(PersonOfficeDraftEntry(
                            holdingID: nil,
                            officeID: officeID,
                            officeName: officeName
                        ))
                    }
                )
            }

            if draft.personOffices.isEmpty {
                Text("No offices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach($draft.personOffices) { $office in
                officeCard($office)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    // MARK: Office card

    private func officeCard(_ office: Binding<PersonOfficeDraftEntry>) -> some View {
        let entry = office.wrappedValue
        let index = draft.personOffices.firstIndex(where: { $0.id == entry.id }) ?? 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PersonReorderButtons(
                    canMoveUp: index > 0,
                    canMoveDown: index < draft.personOffices.count - 1,
                    onMoveUp: { draft.personOffices.swapAt(index, index - 1) },
                    onMoveDown: { draft.personOffices.swapAt(index, index + 1) }
                )

                HStack(spacing: 4) {
                    Image(systemName: "building.columns")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(formatFieldDisplayValue(entry.officeName))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())

                Spacer(minLength: 0)

                Button {
                    draft.personOffices.removeAll { $0.id == entry.id }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this office from this person")
            }

            HStack(spacing: 8) {
                Text("Began:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: office.whenBeganText)
                    .solidFocusField()
                    .frame(maxWidth: 140)
                Text("Ended:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: office.whenEndedText)
                    .solidFocusField()
                    .frame(maxWidth: 140)
            }

            HStack(spacing: 8) {
                Text("Note:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: office.noteText)
                    .solidFocusField()
            }

            successionRow(title: "Predecessors", refs: office.predecessors)
            successionRow(title: "Successors", refs: office.successors)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private func successionRow(title: String, refs: Binding<[PersonRef]>) -> some View {
        // One flow: the title, Add button, and chips share the first line and
        // only wrap when the card runs out of width.
        FlowLayout(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            PersonAddButton(
                appDatabase: appDatabase,
                excludingInstanceID: draft.loadedInstanceID,
                alreadySelected: Set(refs.wrappedValue.compactMap(\.instanceID)),
                onSelectInstance: { candidate in
                    draft.personDisplayNamesByID[candidate.id] = candidate.displayValue
                    draft.personSexesByID[candidate.id] = candidate.sex
                    refs.wrappedValue.append(.instance(candidate.id))
                },
                onSelectBareName: { name in
                    // Exact duplicates per side are rejected by the save (they
                    // would collide in the DB), so don't let one into the draft;
                    // ForEach ids also stay unique this way.
                    let ref = PersonRef.bare(name)
                    if !refs.wrappedValue.contains(ref) {
                        refs.wrappedValue.append(ref)
                    }
                }
            )
            ForEach(refs.wrappedValue, id: \.self) { ref in
                PersonChip(
                    label: refLabel(ref),
                    isBareName: ref.bareName != nil,
                    onRemove: { refs.wrappedValue.removeAll { $0 == ref } }
                )
            }
        }
    }

    private func refLabel(_ ref: PersonRef) -> String {
        switch ref {
        case .instance(let personID):
            let name = (draft.personDisplayNamesByID[personID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "#\(personID)" : name
        case .bare(let name):
            return name
        }
    }
}

// MARK: - Office picker

private struct OfficeAddButton: View {
    let appDatabase: AppDatabase
    let alreadySelectedOfficeIDs: Set<Int64>
    let onSelectOffice: (_ officeID: Int64, _ officeName: String) -> Void

    @State private var isPickerPresented = false
    @State private var pickerState: PickerPanelState?

    var body: some View {
        Button("Add Office") {
            // A fresh state per open: blank search, offices re-fetched.
            pickerState = makePickerState()
            isPickerPresented = true
        }
        .controlSize(.small)
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            if let pickerState {
                PickerListView(state: pickerState)
                    .padding(12)
                    .frame(width: 300)
            }
        }
    }

    private func makePickerState() -> PickerPanelState {
        let state = PickerPanelState(
            title: "",
            placeholder: "Search offices…",
            emptyText: "No matching offices.",
            // A live provider, not a fixed list: fetchOfficeCandidates LIMITs
            // its results, so each keystroke re-queries the DB and the cap
            // applies to the matches rather than to the whole office list.
            itemsProvider: { query in
                let candidates = (try? appDatabase.fetchOfficeCandidates(matching: query)) ?? []
                return candidates.map { candidate in
                    PickerPanelItem(
                        id: candidate.id,
                        title: candidate.name,
                        isSelectable: !alreadySelectedOfficeIDs.contains(candidate.id)
                    )
                }
            },
            onSelect: { item in
                onSelectOffice(item.id, item.title)
                isPickerPresented = false
            },
            onClose: { isPickerPresented = false }
        )
        // Unlike bare names, office names must not duplicate — the create row
        // hides when an exact (case-insensitive) match exists.
        state.accessoryRowProvider = { [weak state] trimmed in
            guard !trimmed.isEmpty,
                  let state,
                  !state.filteredItems.contains(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { return nil }
            return PickerPanelAccessoryRow(title: "Create office \u{201C}\(trimmed)\u{201D}") { [weak state] in
                // Creates the office row immediately (a draft entry needs a
                // concrete office id, and other windows should see the new
                // office live). If the draft is later discarded, a 0-holder
                // office remains — visible and deletable in Manage Offices.
                do {
                    let officeID = try appDatabase.createOffice(name: trimmed)
                    NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
                    onSelectOffice(officeID, trimmed)
                    isPickerPresented = false
                } catch {
                    state?.errorMessage = (error as? DatabaseError)?.message ?? "Failed to create office."
                }
            }
        }
        return state
    }
}
