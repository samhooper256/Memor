//
//  PersonOfficesEditor.swift
//  Memor
//
//  The Person instance editor's Offices panel: ordered office cards (office
//  chip, Began/Ended/Note fields, predecessor/successor entries) plus the
//  office picker popover, which suggests existing offices by name and can
//  create a new one inline. Every card references an existing office row.
//  Predecessors/successors are Person instances (reciprocal by construction on
//  save) or bare names (free text with no reciprocity), like the relationship
//  slots. The Began/Ended/Note fields are the same InstanceTextView the main
//  field editors use (HTML highlighting, ⌘K hyperlinks), registered with the
//  editor's shared focus controller under synthetic NEGATIVE field ids.
//

import AppKit
import GRDB
import SwiftUI

/// Which of an office card's three inline text fields a synthetic field id
/// addresses, in the card's Tab order.
private enum OfficeFieldSlot: CaseIterable, Hashable {
    case began, ended, note
}

/// Hands out stable synthetic field ids for the office cards' inline text
/// views. InstanceTextView registers with the editor's shared
/// AddInstanceFieldFocusController keyed by Int64, so the office fields need
/// ids that can never collide with real field rows — real ids are positive,
/// these are allocated negative. Keyed by (draft entry UUID, slot): stable for
/// an entry's lifetime, unique across every editor window in the session.
private enum OfficeFieldIDAllocator {
    private struct Key: Hashable {
        let entryID: UUID
        let slot: OfficeFieldSlot
    }

    private static var idsByKey: [Key: Int64] = [:]
    private static var nextID: Int64 = -1

    static func fieldID(entryID: UUID, slot: OfficeFieldSlot) -> Int64 {
        let key = Key(entryID: entryID, slot: slot)
        if let existing = idsByKey[key] { return existing }
        let allocated = nextID
        nextID -= 1
        idsByKey[key] = allocated
        return allocated
    }
}

struct PersonOfficesEditor: View {
    let appDatabase: AppDatabase
    @ObservedObject var draft: InstanceEditorDraft
    let focusController: AddInstanceFieldFocusController
    let onSubmit: () -> Void
    let onRequestHyperlink: ((InstanceTextView.CommandAwareTextView) -> Void)?

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
                        let entry = PersonOfficeDraftEntry(
                            holdingID: nil,
                            officeID: officeID,
                            officeName: officeName
                        )
                        draft.personOffices.append(entry)
                        // Deferred a tick: the card's Began field doesn't exist
                        // until SwiftUI commits the append, and the closing
                        // picker popover is still giving up key focus.
                        DispatchQueue.main.async {
                            focusController.focusField(
                                OfficeFieldIDAllocator.fieldID(entryID: entry.id, slot: .began)
                            )
                        }
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
                officeFieldView(entryID: entry.id, slot: .began, keyPath: \.whenBeganText)
                    .frame(maxWidth: 140)
                Text("Ended:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                officeFieldView(entryID: entry.id, slot: .ended, keyPath: \.whenEndedText)
                    .frame(maxWidth: 140)
            }

            HStack(spacing: 8) {
                Text("Note:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                officeFieldView(entryID: entry.id, slot: .note, keyPath: \.noteText)
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

    // MARK: Began/Ended/Note fields

    private func officeFieldView(
        entryID: UUID,
        slot: OfficeFieldSlot,
        keyPath: WritableKeyPath<PersonOfficeDraftEntry, String>
    ) -> some View {
        let fieldID = OfficeFieldIDAllocator.fieldID(entryID: entryID, slot: slot)
        return OfficeInlineTextField(
            text: officeText(entryID: entryID, keyPath: keyPath),
            focusController: focusController,
            fieldID: fieldID,
            onSubmit: onSubmit,
            onRequestHyperlink: onRequestHyperlink,
            onMoveToNextField: { focusOfficeField(after: fieldID) },
            onMoveToPreviousField: { focusOfficeField(before: fieldID) }
        )
    }

    /// ID-keyed (not positional) text bindings: InstanceTextView's coordinator
    /// captures its binding once at creation, so a ForEach element binding
    /// would keep writing through its ORIGINAL index after cards reorder or
    /// delete. Looking the entry up by id on every access makes stale
    /// coordinators harmless.
    private func officeText(
        entryID: UUID,
        keyPath: WritableKeyPath<PersonOfficeDraftEntry, String>
    ) -> Binding<String> {
        Binding(
            get: {
                draft.personOffices.first(where: { $0.id == entryID })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                guard let index = draft.personOffices.firstIndex(where: { $0.id == entryID }) else { return }
                draft.personOffices[index][keyPath: keyPath] = newValue
            }
        )
    }

    private var orderedOfficeFieldIDs: [Int64] {
        draft.personOffices.flatMap { entry in
            OfficeFieldSlot.allCases.map { OfficeFieldIDAllocator.fieldID(entryID: entry.id, slot: $0) }
        }
    }

    /// Tab order: Began → Ended → Note within a card, then the next card; past
    /// either end of the panel, focus moves to the collection search field
    /// (like the main field editors' Tab cycle).
    private func focusOfficeField(after fieldID: Int64) {
        let ids = orderedOfficeFieldIDs
        guard let currentIndex = ids.firstIndex(of: fieldID) else { return }
        let nextIndex = ids.index(after: currentIndex)
        if nextIndex < ids.endIndex {
            focusController.focusField(ids[nextIndex])
        } else {
            focusController.focusCollectionSearch()
        }
    }

    private func focusOfficeField(before fieldID: Int64) {
        let ids = orderedOfficeFieldIDs
        guard let currentIndex = ids.firstIndex(of: fieldID), currentIndex > ids.startIndex else {
            focusController.focusCollectionSearch()
            return
        }
        focusController.focusField(ids[ids.index(before: currentIndex)])
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

// MARK: - Inline office text field

/// One office-card text field (Began/Ended/Note) backed by the SAME
/// InstanceTextView the main field editors use — HTML tag/entity highlighting,
/// the ⌘K hyperlink popup, entity auto-replacement, https link pasting, ⌘B/⌘I
/// wrapping via the shared focus controller — in the compact solid-focus
/// chrome the card had before. Grows with its content like the main editors,
/// from a one-line floor.
private struct OfficeInlineTextField: View {
    /// One line of the monospaced editor font + the text view's 4pt insets.
    private static let minimumHeight: CGFloat = 24

    @Binding var text: String
    let focusController: AddInstanceFieldFocusController
    let fieldID: Int64
    let onSubmit: () -> Void
    let onRequestHyperlink: ((InstanceTextView.CommandAwareTextView) -> Void)?
    let onMoveToNextField: () -> Void
    let onMoveToPreviousField: () -> Void

    @State private var editorHeight: CGFloat = minimumHeight
    // @FocusState can't observe an NSTextView, so the chrome's focus stroke is
    // driven by the text view's own first-responder callback.
    @State private var isFocused = false

    var body: some View {
        InstanceTextView(
            text: $text,
            focusController: focusController,
            fieldID: fieldID,
            onSubmit: onSubmit,
            onRequestHyperlink: onRequestHyperlink,
            onContentHeightChange: { contentHeight in
                editorHeight = max(Self.minimumHeight, contentHeight)
            },
            onMoveToNextField: onMoveToNextField,
            onMoveToPreviousField: onMoveToPreviousField,
            dedupesTrailingLineBreak: true,
            onFocusChange: { isFocused = $0 }
        )
        .frame(maxWidth: .infinity, minHeight: editorHeight, maxHeight: editorHeight)
        .solidFocusFieldChrome(isFocused: isFocused)
    }
}

// MARK: - Office picker

private struct OfficeAddButton: View {
    let appDatabase: AppDatabase
    let alreadySelectedOfficeIDs: Set<Int64>
    let onSelectOffice: (_ officeID: Int64, _ officeName: String) -> Void

    // Item-based presentation, NOT isPresented + `if let` content: gating the
    // whole popover body on separately-written optional @State can evaluate
    // against a nil snapshot and present an EmptyView popover (a tiny empty
    // circle). Keying presentation on the state itself makes that
    // unrepresentable. Dismissal = nil-ing this (outside clicks do it via the
    // binding).
    @State private var pickerState: PickerPanelState?

    var body: some View {
        Button("Add Office") {
            // A fresh state per open: blank search, offices re-fetched.
            pickerState = makePickerState()
        }
        .controlSize(.small)
        .popover(item: $pickerState, arrowEdge: .bottom) { state in
            PickerListView(state: state)
                .padding(12)
                .frame(width: 300)
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
                pickerState = nil
            },
            onClose: { pickerState = nil }
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
                    pickerState = nil
                } catch {
                    // errorMessage only — the popover must stay open on a
                    // failed create so the red error line shows.
                    state?.errorMessage = (error as? DatabaseError)?.message ?? "Failed to create office."
                }
            }
        }
        return state
    }
}
