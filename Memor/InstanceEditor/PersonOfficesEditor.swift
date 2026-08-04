//
//  PersonOfficesEditor.swift
//  Memor
//
//  The Person instance editor's Offices panel: ordered office cards (office
//  chip, Began/Ended/Note fields, predecessor/successor entries) plus the
//  office picker popover, which suggests existing offices by name and can
//  create a new one inline. Every card references an existing office row, and
//  a card is one STINT — adding an office the person already holds makes a
//  second card with its own dates/note/succession entries (Grover Cleveland).
//  Predecessors/successors are peer STINTS (reciprocal by construction on
//  save; picking a multi-term peer runs a term chooser) or bare names (free
//  text with no reciprocity), like the relationship slots.
//  The Began/Ended/Note fields are the same InstanceTextView the main
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
                    onSelectOffice: { officeID, officeName in
                        var entry = PersonOfficeDraftEntry(
                            holdingID: nil,
                            officeID: officeID,
                            officeName: officeName
                        )
                        // The per-office query is shared across stints, so a
                        // second card of an already-held office must carry the
                        // office's current enablement/interval — every card of
                        // one office stays in lockstep (the save ORs the
                        // flags; a default-false card would let deleting the
                        // original card silently disable the query and drop
                        // its SRS).
                        if let sibling = draft.personOffices.first(where: { $0.officeID == officeID }) {
                            entry.isOfficeQueryEnabled = sibling.isOfficeQueryEnabled
                            entry.officeQueryInterval = sibling.officeQueryInterval
                        }
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

            ForEach(draft.personOffices) { entry in
                officeCard(entry)
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

    /// ID-keyed (not positional) whole-entry binding, like the partner cards'
    /// partnerBinding(id:): the Began/Ended/Note fields were already immune
    /// via officeText(entryID:keyPath:), but the succession rows' derived
    /// bindings rode a positional ForEach element binding — same latent
    /// out-of-bounds hazard once the array shrinks. Get falls back to a
    /// placeholder, set no-ops once the entry is gone.
    private func officeBinding(id: UUID) -> Binding<PersonOfficeDraftEntry> {
        Binding(
            get: {
                draft.personOffices.first(where: { $0.id == id })
                    ?? PersonOfficeDraftEntry(holdingID: nil, officeID: 0, officeName: "")
            },
            set: { newValue in
                guard let index = draft.personOffices.firstIndex(where: { $0.id == id }) else { return }
                draft.personOffices[index] = newValue
            }
        )
    }

    private func officeCard(_ entry: PersonOfficeDraftEntry) -> some View {
        let office = officeBinding(id: entry.id)
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

            successionRow(title: "Predecessors", entry: entry, refs: office.predecessors)
            successionRow(title: "Successors", entry: entry, refs: office.successors)
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

    private func successionRow(
        title: String,
        entry: PersonOfficeDraftEntry,
        refs: Binding<[PersonSuccessionPeer]>
    ) -> some View {
        // One flow: the title, Add button, and chips share the first line and
        // only wrap when the card runs out of width.
        FlowLayout(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            PersonAddButton(
                appDatabase: appDatabase,
                excludingInstanceID: draft.loadedInstanceID,
                // Only unresolved-.instance peers are grayed out (they hold no
                // stint of the office, so a second entry could never differ).
                // A stint-bound peer stays pickable — a multi-term peer may
                // legitimately appear once per term; appendSuccessionPeer
                // filters out the terms already linked on this side.
                alreadySelected: Set(refs.wrappedValue.compactMap { peer in
                    if case .instance(let id) = peer { return id }
                    return nil
                }),
                onSelectInstance: { candidate in
                    draft.personDisplayNamesByID[candidate.id] = candidate.preferredName
                    draft.personSexesByID[candidate.id] = candidate.sex
                    appendSuccessionPeer(candidate: candidate, entry: entry, refs: refs)
                },
                onSelectBareName: { name in
                    // Exact duplicates per side are rejected by the save (they
                    // would collide in the DB), so don't let one into the draft;
                    // ForEach ids also stay unique this way.
                    let ref = PersonSuccessionPeer.bare(name)
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

    /// Resolves WHICH stint of the picked peer the edge binds to. Terms
    /// already linked on this side are excluded (the same peer may appear
    /// once per term): none held → an unresolved entry the save AUTO-ADDS a
    /// holding for; every term linked → an informational alert; exactly one
    /// term left → bind it; several → a blocking term chooser. Alerts are
    /// deferred a tick so the picker popover finishes closing first.
    private func appendSuccessionPeer(
        candidate: PersonCandidate,
        entry: PersonOfficeDraftEntry,
        refs: Binding<[PersonSuccessionPeer]>
    ) {
        let stints = (try? appDatabase.fetchOfficeStints(instanceID: candidate.id, officeID: entry.officeID)) ?? []
        guard !stints.isEmpty else {
            refs.wrappedValue.append(.instance(candidate.id))
            return
        }
        // A multi-term peer's chips need term suffixes to stay tellable
        // apart, whichever branch appends below.
        if stints.count > 1 {
            for (index, stint) in stints.enumerated() {
                draft.personStintLabelsByHoldingID[stint.personOfficeID] = AppDatabase.officeStintLabel(stint, index: index)
            }
        }
        let linkedHoldingIDs = Set(refs.wrappedValue.compactMap(\.holdingID))
        // (index, stint) pairs keep the ORIGINAL term numbering for labels.
        let available = stints.enumerated().filter { !linkedHoldingIDs.contains($0.element.personOfficeID) }
        let officeName = formatFieldDisplayValue(entry.officeName)

        if available.isEmpty {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Already linked"
                alert.informativeText = "Every term of \(candidate.preferredName) in \(officeName) is already listed on this side."
                alert.runModal()
            }
        } else if available.count == 1 {
            refs.wrappedValue.append(.holding(
                holdingID: available[0].element.personOfficeID,
                instanceID: candidate.id
            ))
        } else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Which term?"
                alert.informativeText = "\(candidate.preferredName) holds \(officeName) \(stints.count) times. Choose the term this succession link refers to."
                for (index, stint) in available {
                    alert.addButton(withTitle: AppDatabase.officeStintLabel(stint, index: index))
                }
                alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                let chosenOffset = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard available.indices.contains(chosenOffset) else { return }
                refs.wrappedValue.append(.holding(
                    holdingID: available[chosenOffset].element.personOfficeID,
                    instanceID: candidate.id
                ))
            }
        }
    }

    private func refLabel(_ ref: PersonSuccessionPeer) -> String {
        func personLabel(_ personID: Int64) -> String {
            let name = (draft.personDisplayNamesByID[personID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "#\(personID)" : name
        }
        switch ref {
        case .holding(let holdingID, let personID):
            // The term suffix appears only for peers holding the office more
            // than once (the label map is populated exactly for those).
            if let stintLabel = draft.personStintLabelsByHoldingID[holdingID] {
                return "\(personLabel(personID)) (\(stintLabel))"
            }
            return personLabel(personID)
        case .instance(let personID):
            return personLabel(personID)
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
                // Every office stays selectable — picking one the person
                // already holds adds another stint (a second card).
                let candidates = (try? appDatabase.fetchOfficeCandidates(matching: query)) ?? []
                return candidates.map { candidate in
                    PickerPanelItem(id: candidate.id, title: candidate.name)
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
