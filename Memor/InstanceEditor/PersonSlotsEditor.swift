//
//  PersonSlotsEditor.swift
//  Memor
//
//  The Person instance editor's relationship panel: the four single-entry
//  parent slots, the ordered partner cards (married checkbox, start/end texts,
//  per-partner children), and the Children box that mirrors ALL children
//  (grouped ones live in their partner card's array, so removals sync both
//  directions automatically). Every slot accepts another Person instance or a
//  bare name (free text for someone without an instance).
//

import AppKit
import SwiftUI

struct PersonSlotsEditor: View {
    let appDatabase: AppDatabase
    @ObservedObject var draft: InstanceEditorDraft

    private var excludingInstanceID: Int64? { draft.loadedInstanceID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relationships")
                .font(.headline)

            parentsBox
            partnersBox
            childrenBox
        }
    }

    // MARK: Shared helpers

    private func chipLabel(for ref: PersonRef) -> String {
        switch ref {
        case .instance(let id):
            let name = (draft.personDisplayNamesByID[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "#\(id)" : name
        case .bare(let name):
            return name
        }
    }

    private func rememberCandidate(_ candidate: PersonCandidate) {
        draft.personDisplayNamesByID[candidate.id] = candidate.displayValue
        draft.personSexesByID[candidate.id] = candidate.sex
    }

    /// Instance ids already used anywhere in the slots (pickers grey them out).
    private var usedInstanceIDs: Set<Int64> {
        var ids: Set<Int64> = []
        for ref in [draft.personMother, draft.personFather, draft.personAdoptiveMother, draft.personAdoptiveFather] {
            if let id = ref?.instanceID { ids.insert(id) }
        }
        for partner in draft.personPartners {
            if let id = partner.partner.instanceID { ids.insert(id) }
            for child in partner.children {
                if let id = child.child.instanceID { ids.insert(id) }
            }
        }
        for child in draft.personUngroupedChildren {
            if let id = child.child.instanceID { ids.insert(id) }
        }
        return ids
    }

    private func slotBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }
    }

    // MARK: Parents

    private var parentsBox: some View {
        slotBox {
            Text("Parents")
                .fontWeight(.medium)
            singleSlotRow(label: "Mother", ref: $draft.personMother)
            singleSlotRow(label: "Father", ref: $draft.personFather)
            singleSlotRow(label: "Adoptive Mother", ref: $draft.personAdoptiveMother)
            singleSlotRow(label: "Adoptive Father", ref: $draft.personAdoptiveFather)
        }
    }

    private func singleSlotRow(label: String, ref: Binding<PersonRef?>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .frame(width: 110, alignment: .leading)

            if let value = ref.wrappedValue {
                PersonChip(
                    label: chipLabel(for: value),
                    isBareName: value.bareName != nil,
                    onRemove: { ref.wrappedValue = nil }
                )
            } else {
                PersonAddButton(
                    appDatabase: appDatabase,
                    excludingInstanceID: excludingInstanceID,
                    alreadySelected: usedInstanceIDs,
                    onSelectInstance: { candidate in
                        rememberCandidate(candidate)
                        ref.wrappedValue = .instance(candidate.id)
                    },
                    onSelectBareName: { name in
                        ref.wrappedValue = .bare(name)
                    }
                )
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: Partners

    private var partnersBox: some View {
        slotBox {
            HStack(spacing: 8) {
                Text("Partners")
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                PersonAddButton(
                    title: "Add Partner",
                    appDatabase: appDatabase,
                    excludingInstanceID: excludingInstanceID,
                    alreadySelected: usedInstanceIDs,
                    onSelectInstance: { candidate in
                        rememberCandidate(candidate)
                        draft.personPartners.append(
                            PersonPartnerDraftEntry(partnershipID: nil, partner: .instance(candidate.id))
                        )
                    },
                    onSelectBareName: { name in
                        draft.personPartners.append(
                            PersonPartnerDraftEntry(partnershipID: nil, partner: .bare(name))
                        )
                    }
                )
            }

            if draft.personPartners.isEmpty {
                Text("No partners.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($draft.personPartners) { $partner in
                    partnerCard($partner)
                }
            }
        }
    }

    private func partnerCard(_ partner: Binding<PersonPartnerDraftEntry>) -> some View {
        let entry = partner.wrappedValue
        let index = draft.personPartners.firstIndex(where: { $0.id == entry.id }) ?? 0
        let partnerSex = entry.partner.instanceID.flatMap { draft.personSexesByID[$0] }
        // Children can't be added under a same-sex couple; bare-name partners
        // (sex unknown) allow them (the role is inferred as the opposite side).
        let isSameSex = partnerSex != nil && partnerSex == draft.personSexValue

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PersonReorderButtons(
                    canMoveUp: index > 0,
                    canMoveDown: index < draft.personPartners.count - 1,
                    onMoveUp: { draft.personPartners.swapAt(index, index - 1) },
                    onMoveDown: { draft.personPartners.swapAt(index, index + 1) }
                )

                PersonChip(
                    label: chipLabel(for: entry.partner),
                    isBareName: entry.partner.bareName != nil,
                    onRemove: nil
                )

                Spacer(minLength: 0)

                Button {
                    // The partner's children fall back to the ungrouped list on
                    // save (auto-ungroup); mirror that in the draft so the
                    // Children box doesn't silently lose them.
                    draft.personUngroupedChildren.append(
                        contentsOf: entry.children.map { PersonChildEntry(rowID: nil, child: $0.child) }
                    )
                    draft.personPartners.removeAll { $0.id == entry.id }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this partner (their children move to the ungrouped list)")
            }

            Toggle("Married", isOn: partner.isMarried)
                .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Text(entry.isMarried ? "Marriage Start:" : "Relationship Start:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: partner.startText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                Text(entry.isMarried ? "Marriage End:" : "Relationship End:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: partner.endText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
            }

            HStack(spacing: 6) {
                Text("Children")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isSameSex {
                    Text("Same-sex partners can't have shared children.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    PersonAddButton(
                        appDatabase: appDatabase,
                        excludingInstanceID: excludingInstanceID,
                        alreadySelected: usedInstanceIDs,
                        onSelectInstance: { candidate in
                            rememberCandidate(candidate)
                            partner.wrappedValue.children.append(
                                PersonChildEntry(rowID: nil, child: .instance(candidate.id))
                            )
                        },
                        onSelectBareName: { name in
                            partner.wrappedValue.children.append(
                                PersonChildEntry(rowID: nil, child: .bare(name))
                            )
                        }
                    )
                }
            }

            if !entry.children.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(entry.children) { child in
                        PersonChip(
                            label: chipLabel(for: child.child),
                            isBareName: child.child.bareName != nil,
                            onRemove: {
                                partner.wrappedValue.children.removeAll { $0.id == child.id }
                            }
                        )
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    // MARK: Children (all of them)

    private var childrenBox: some View {
        slotBox {
            HStack(spacing: 8) {
                Text("Children")
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                PersonAddButton(
                    appDatabase: appDatabase,
                    excludingInstanceID: excludingInstanceID,
                    alreadySelected: usedInstanceIDs,
                    onSelectInstance: { candidate in
                        rememberCandidate(candidate)
                        draft.personUngroupedChildren.append(
                            PersonChildEntry(rowID: nil, child: .instance(candidate.id))
                        )
                    },
                    onSelectBareName: { name in
                        draft.personUngroupedChildren.append(
                            PersonChildEntry(rowID: nil, child: .bare(name))
                        )
                    }
                )
            }

            let hasGrouped = draft.personPartners.contains { !$0.children.isEmpty }
            if !hasGrouped && draft.personUngroupedChildren.isEmpty {
                Text("No children.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Grouped children are live mirrors of each partner card's array,
            // so removing one here removes it there too (and vice versa).
            ForEach($draft.personPartners) { $partner in
                if !partner.children.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("with \(chipLabel(for: partner.partner))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(partner.children) { child in
                                PersonChip(
                                    label: chipLabel(for: child.child),
                                    isBareName: child.child.bareName != nil,
                                    onRemove: {
                                        $partner.wrappedValue.children.removeAll { $0.id == child.id }
                                    }
                                )
                            }
                        }
                    }
                }
            }

            if !draft.personUngroupedChildren.isEmpty {
                if hasGrouped {
                    Text("Ungrouped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(draft.personUngroupedChildren) { child in
                    let index = draft.personUngroupedChildren.firstIndex(where: { $0.id == child.id }) ?? 0
                    HStack(spacing: 8) {
                        PersonReorderButtons(
                            canMoveUp: index > 0,
                            canMoveDown: index < draft.personUngroupedChildren.count - 1,
                            onMoveUp: { draft.personUngroupedChildren.swapAt(index, index - 1) },
                            onMoveDown: { draft.personUngroupedChildren.swapAt(index, index + 1) }
                        )
                        PersonChip(
                            label: chipLabel(for: child.child),
                            isBareName: child.child.bareName != nil,
                            onRemove: {
                                draft.personUngroupedChildren.removeAll { $0.id == child.id }
                            }
                        )
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

// MARK: - Chip

struct PersonChip: View {
    let label: String
    let isBareName: Bool
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if isBareName {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Text(formatFieldDisplayValue(label))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isBareName ? Color.orange.opacity(0.15) : Color.accentColor.opacity(0.15))
        .clipShape(Capsule())
        .help(isBareName ? "Name only — not linked to a Person instance" : "")
    }
}

// MARK: - Reorder buttons

private struct PersonReorderButtons: View {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onMoveUp) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)
            .opacity(canMoveUp ? 0.7 : 0.2)

            Button(action: onMoveDown) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(!canMoveDown)
            .opacity(canMoveDown ? 0.7 : 0.2)
        }
    }
}

// MARK: - Add button + picker popover

private struct PersonAddButton: View {
    var title: String = "Add"
    let appDatabase: AppDatabase
    let excludingInstanceID: Int64?
    let alreadySelected: Set<Int64>
    let onSelectInstance: (PersonCandidate) -> Void
    let onSelectBareName: (String) -> Void

    @State private var isPickerPresented = false

    var body: some View {
        Button(title) {
            isPickerPresented = true
        }
        .controlSize(.small)
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            PersonPickerPopover(
                appDatabase: appDatabase,
                excludingInstanceID: excludingInstanceID,
                alreadySelected: alreadySelected,
                onSelectInstance: { candidate in
                    onSelectInstance(candidate)
                    isPickerPresented = false
                },
                onSelectBareName: { name in
                    onSelectBareName(name)
                    isPickerPresented = false
                }
            )
        }
    }
}

private struct PersonPickerPopover: View {
    let appDatabase: AppDatabase
    let excludingInstanceID: Int64?
    let alreadySelected: Set<Int64>
    let onSelectInstance: (PersonCandidate) -> Void
    let onSelectBareName: (String) -> Void

    @State private var searchText = ""
    @State private var results: [PersonCandidate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search people…", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if results.isEmpty {
                        Text("No matching people.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(results) { candidate in
                            Button {
                                onSelectInstance(candidate)
                            } label: {
                                Text(formatFieldDisplayValue(candidate.displayValue))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(alreadySelected.contains(candidate.id))
                            .opacity(alreadySelected.contains(candidate.id) ? 0.4 : 1)
                        }
                    }

                    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                        // A bare name may legitimately coincide with an existing
                        // instance's name, so this row shows whenever text is typed.
                        Button {
                            onSelectBareName(trimmed)
                        } label: {
                            Label("Add as name: “\(trimmed)”", systemImage: "plus.circle")
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
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { performSearch() }
        .onChange(of: searchText) { _, _ in performSearch() }
    }

    private func performSearch() {
        results = (try? appDatabase.fetchPersonCandidates(
            matching: searchText,
            excludingInstanceID: excludingInstanceID
        )) ?? []
    }
}
