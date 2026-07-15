//
//  PersonOfficesEditor.swift
//  Memor
//
//  The Person instance editor's Offices panel: ordered office cards (office
//  chip, WhenBegan/WhenEnded/Note text fields, predecessor/successor links to
//  other Person instances) plus the office picker popover, which suggests
//  existing offices by name and can create a new one inline. Every card
//  references an existing office row; predecessor/successor links are
//  instance-only (no bare names) and reciprocal by construction on save.
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

            successionRow(title: "Predecessors", ids: office.predecessorIDs)
            successionRow(title: "Successors", ids: office.successorIDs)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private func successionRow(title: String, ids: Binding<[Int64]>) -> some View {
        // One flow: the title, Add button, and chips share the first line and
        // only wrap when the card runs out of width.
        FlowLayout(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            PersonAddButton(
                appDatabase: appDatabase,
                excludingInstanceID: draft.loadedInstanceID,
                alreadySelected: Set(ids.wrappedValue),
                allowsBareNames: false,
                onSelectInstance: { candidate in
                    draft.personDisplayNamesByID[candidate.id] = candidate.displayValue
                    draft.personSexesByID[candidate.id] = candidate.sex
                    ids.wrappedValue.append(candidate.id)
                },
                onSelectBareName: { _ in }
            )
            ForEach(ids.wrappedValue, id: \.self) { personID in
                PersonChip(
                    label: personLabel(personID),
                    isBareName: false,
                    onRemove: { ids.wrappedValue.removeAll { $0 == personID } }
                )
            }
        }
    }

    private func personLabel(_ personID: Int64) -> String {
        let name = (draft.personDisplayNamesByID[personID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "#\(personID)" : name
    }
}

// MARK: - Office picker

private struct OfficeAddButton: View {
    let appDatabase: AppDatabase
    let alreadySelectedOfficeIDs: Set<Int64>
    let onSelectOffice: (_ officeID: Int64, _ officeName: String) -> Void

    @State private var isPickerPresented = false

    var body: some View {
        Button("Add Office") {
            isPickerPresented = true
        }
        .controlSize(.small)
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            OfficePickerPopover(
                appDatabase: appDatabase,
                alreadySelectedOfficeIDs: alreadySelectedOfficeIDs,
                onSelectOffice: { officeID, officeName in
                    onSelectOffice(officeID, officeName)
                    isPickerPresented = false
                }
            )
        }
    }
}

private struct OfficePickerPopover: View {
    let appDatabase: AppDatabase
    let alreadySelectedOfficeIDs: Set<Int64>
    let onSelectOffice: (_ officeID: Int64, _ officeName: String) -> Void

    @State private var searchText = ""
    @State private var results: [OfficeCandidate] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search offices…", text: $searchText)
                .solidFocusField()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if results.isEmpty {
                        Text("No matching offices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(results) { candidate in
                            Button {
                                onSelectOffice(candidate.id, candidate.name)
                            } label: {
                                Text(candidate.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(alreadySelectedOfficeIDs.contains(candidate.id))
                            .opacity(alreadySelectedOfficeIDs.contains(candidate.id) ? 0.4 : 1)
                        }
                    }

                    // Unlike bare names, office names must not duplicate — the
                    // create row hides when an exact (case-insensitive) match exists.
                    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty,
                       !results.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                        Divider()
                            .padding(.vertical, 4)
                        Button {
                            createOffice(named: trimmed)
                        } label: {
                            Label("Create office \u{201C}\(trimmed)\u{201D}", systemImage: "plus.circle")
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 240)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { performSearch() }
        .onChange(of: searchText) { _, _ in performSearch() }
    }

    private func performSearch() {
        results = (try? appDatabase.fetchOfficeCandidates(matching: searchText)) ?? []
    }

    /// Creates the office row immediately (a draft entry needs a concrete
    /// office id, and other windows should see the new office live). If the
    /// draft is later discarded, a 0-holder office remains — visible and
    /// deletable in the Manage Offices window.
    private func createOffice(named name: String) {
        do {
            let officeID = try appDatabase.createOffice(name: name)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            onSelectOffice(officeID, name)
        } catch {
            errorMessage = (error as? DatabaseError)?.message ?? "Failed to create office."
        }
    }
}
