//
//  ManageOfficesWindowView.swift
//  Memor
//
//  Standalone window for managing the offices Person instances can hold
//  ("Edit Offices" on the Person type detail page): searchable list with
//  per-office holder counts, add/delete (confirmation spells out the cascade
//  when the office has holders), right-click rename, and a debounced
//  per-office Description editor. Refreshes live on memorDidChangeDatabase so
//  offices created from the instance editor's picker (or MCP) appear
//  immediately.
//

import AppKit
import Combine
import Foundation
import GRDB
import SwiftUI

@MainActor
final class ManageOfficesWindowState: ObservableObject {
    @Published var requestNonce = UUID()

    func requestOpen() {
        requestNonce = UUID()
    }
}

struct ManageOfficesWindowView: View {
    let appDatabase: AppDatabase
    @EnvironmentObject private var windowState: ManageOfficesWindowState
    @Environment(\.dismiss) private var dismiss

    @State private var offices: [OfficeSummary] = []
    @State private var searchText = ""
    @State private var selectedOfficeID: Int64?

    @State private var isAddPresented = false
    @State private var newOfficeName = ""
    @State private var addErrorMessage: String?
    @State private var renameTarget: OfficeSummary?
    @State private var renameText = ""
    @State private var renameErrorMessage: String?
    @State private var deleteTarget: OfficeSummary?
    @State private var isDeleteConfirmationPresented = false

    @State private var descriptionDraft = ""
    @State private var descriptionSaveTask: Task<Void, Never>?
    // The not-yet-written edit captured by the debounce, so a selection
    // change (or window close) can FLUSH it instead of discarding it.
    @State private var pendingDescriptionSave: (officeID: Int64, description: String)?

    @State private var errorMessage: String?

    private var filteredOffices: [OfficeSummary] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return offices }
        return offices.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var selectedOffice: OfficeSummary? {
        offices.first { $0.id == selectedOfficeID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar

            Divider()

            officeList

            if selectedOffice != nil {
                Divider()
                descriptionPanel
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .navigationTitle("Manage Offices")
        .onAppear { reload() }
        .onChange(of: windowState.requestNonce) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .memorDidChangeDatabase)) { _ in
            reload()
        }
        .onChange(of: selectedOfficeID) { _, _ in
            // Commit (never discard) the previous office's in-flight edit.
            flushPendingDescriptionSave()
            syncDescriptionDraftFromSelection()
        }
        .onChange(of: descriptionDraft) { _, _ in
            // Programmatic loads set the draft to the stored value, so this
            // schedules only for genuine edits (a flag can't gate onChange —
            // it runs after the transaction commits).
            guard let office = selectedOffice, descriptionDraft != office.description else { return }
            scheduleDescriptionSave()
        }
        .onDisappear { flushPendingDescriptionSave() }
        .onExitCommand { dismiss() }
        .background(
            // Reliable Escape even when nothing holds focus.
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
        .alert(
            "Delete office \u{201C}\(deleteTarget?.name ?? "")\u{201D}?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button("Delete", role: .destructive) {
                commitDelete()
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            let count = deleteTarget?.holderCount ?? 0
            Text("\(count) \(count == 1 ? "person currently holds" : "people currently hold") this office. Deleting it removes those holdings, their succession links, and any enabled office queries. This cannot be undone.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                newOfficeName = ""
                addErrorMessage = nil
                isAddPresented = true
            } label: {
                Label("Add office…", systemImage: "plus")
            }
            .popover(isPresented: $isAddPresented, arrowEdge: .bottom) {
                addOfficePopover
            }

            Button(role: .destructive) {
                beginDelete()
            } label: {
                Label("Delete office", systemImage: "trash")
            }
            .disabled(selectedOffice == nil)

            Spacer()

            TextField("Search offices", text: $searchText)
                .font(.system(.body, design: .monospaced))
                .solidFocusField()
                .frame(maxWidth: 240)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var addOfficePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Office")
                .font(.headline)

            TextField("Office Name", text: $newOfficeName)
                .solidFocusField()
                .frame(width: 240)
                .onSubmit { commitAdd() }

            if let addErrorMessage {
                Text(addErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isAddPresented = false }
                Button("Add") { commitAdd() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newOfficeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: List

    private var officeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredOffices.isEmpty {
                    Text(offices.isEmpty ? "No offices yet." : "No offices match.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(filteredOffices) { office in
                        officeRow(office)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func officeRow(_ office: OfficeSummary) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(office.name)
                    .lineLimit(1)
                DescriptionDisplay(office.description)
            }

            Spacer(minLength: 8)

            Text("\(office.holderCount)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Person instances holding this office")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(selectedOfficeID == office.id ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture {
            selectedOfficeID = office.id
        }
        .contextMenu {
            Button("Rename…") {
                beginRename(office)
            }
        }
        .popover(item: renamePopoverItem(for: office), arrowEdge: .bottom) { target in
            renameOfficePopover(target)
        }
    }

    /// Item-based presentation, but scoped to ONE row: the popover modifier is
    /// attached to every row, so a shared `$renameTarget` would present the
    /// popover from all of them at once. Each row sees the target only when
    /// it is that row's office.
    private func renamePopoverItem(for office: OfficeSummary) -> Binding<OfficeSummary?> {
        Binding(
            get: { renameTarget?.id == office.id ? renameTarget : nil },
            set: { newValue in
                if newValue == nil, renameTarget?.id == office.id {
                    renameTarget = nil
                }
            }
        )
    }

    private func renameOfficePopover(_ office: OfficeSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename Office")
                .font(.headline)

            TextField("Office Name", text: $renameText)
                .solidFocusField()
                .frame(width: 240)
                .onSubmit { commitRename() }

            if let renameErrorMessage {
                Text(renameErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                Button("Rename") { commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: Description

    private var descriptionPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description — \(selectedOffice?.name ?? "")")
                .font(.subheadline)
                .fontWeight(.medium)

            DescriptionEditor(text: $descriptionDraft)
                .frame(height: 96)
        }
        .padding(12)
    }

    private func syncDescriptionDraftFromSelection() {
        descriptionDraft = selectedOffice?.description ?? ""
    }

    private func scheduleDescriptionSave() {
        guard let officeID = selectedOfficeID else { return }
        pendingDescriptionSave = (officeID, descriptionDraft)
        descriptionSaveTask?.cancel()
        descriptionSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            flushPendingDescriptionSave()
        }
    }

    /// Writes the captured in-flight edit immediately (debounce expiry,
    /// selection change, window close). No reload (it would clobber typing)
    /// and no change notification (matches other description autosaves) —
    /// the in-memory row is patched in place instead.
    private func flushPendingDescriptionSave() {
        descriptionSaveTask?.cancel()
        descriptionSaveTask = nil
        guard let pending = pendingDescriptionSave else { return }
        pendingDescriptionSave = nil
        do {
            try appDatabase.setOfficeDescription(officeID: pending.officeID, description: pending.description)
            if let index = offices.firstIndex(where: { $0.id == pending.officeID }) {
                offices[index] = OfficeSummary(
                    id: offices[index].id,
                    name: offices[index].name,
                    description: pending.description,
                    holderCount: offices[index].holderCount
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save the description."
        }
    }

    // MARK: Actions

    private func commitAdd() {
        let trimmed = newOfficeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let officeID = try appDatabase.createOffice(name: trimmed)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            isAddPresented = false
            reload()
            selectedOfficeID = officeID
            syncDescriptionDraftFromSelection()
        } catch {
            addErrorMessage = (error as? DatabaseError)?.message ?? "Failed to add office."
        }
    }

    private func beginRename(_ office: OfficeSummary) {
        renameText = office.name
        renameErrorMessage = nil
        renameTarget = office
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try appDatabase.renameOffice(officeID: target.id, name: trimmed)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            renameTarget = nil
            reload()
            errorMessage = nil
        } catch {
            // Blank/duplicate-name messages come from validatedOfficeName;
            // keep the popover open so the user can correct the name.
            renameErrorMessage = (error as? DatabaseError)?.message ?? "Failed to rename office."
        }
    }

    private func beginDelete() {
        guard let selectedID = selectedOfficeID else { return }
        // Re-fetch the live holder count: the cached row can be stale (UI
        // instance-editor saves don't post memorDidChangeDatabase), and a
        // stale 0 would skip the cascade confirmation entirely.
        guard let office = try? appDatabase.fetchOffice(officeID: selectedID) else {
            reload()
            return
        }
        deleteTarget = office
        if office.holderCount == 0 {
            // No holders → nothing cascades that the user could care about.
            commitDelete()
        } else {
            isDeleteConfirmationPresented = true
        }
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        do {
            try appDatabase.deleteOffice(officeID: target.id)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            if selectedOfficeID == target.id {
                selectedOfficeID = nil
            }
            reload()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to delete office."
        }
    }

    private func reload() {
        // Don't clobber in-flight description typing: flush is debounced; the
        // draft re-syncs only when the selection id changes or disappears.
        do {
            offices = try appDatabase.fetchOffices()
            if let selectedOfficeID, !offices.contains(where: { $0.id == selectedOfficeID }) {
                self.selectedOfficeID = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load offices."
        }
    }
}
