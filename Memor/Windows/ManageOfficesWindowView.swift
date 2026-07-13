//
//  ManageOfficesWindowView.swift
//  Memor
//
//  Standalone window for managing the offices Person instances can hold
//  ("Edit Offices" on the Person type detail page): searchable list with
//  per-office holder counts, add/delete (confirmation spells out the cascade
//  when the office has holders), and a debounced per-office Description
//  editor. Refreshes live on memorDidChangeDatabase so offices created from
//  the instance editor's picker (or MCP) appear immediately.
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
    @State private var deleteTarget: OfficeSummary?
    @State private var isDeleteConfirmationPresented = false

    @State private var descriptionDraft = ""
    @State private var descriptionSaveTask: Task<Void, Never>?
    // True while descriptionDraft is being set programmatically (selection
    // change / reload), so the onChange save doesn't fire for non-edits.
    @State private var isSyncingDescription = false

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
            syncDescriptionDraftFromSelection()
        }
        .onChange(of: descriptionDraft) { _, _ in
            guard !isSyncingDescription else { return }
            scheduleDescriptionSave()
        }
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
        descriptionSaveTask?.cancel()
        isSyncingDescription = true
        descriptionDraft = selectedOffice?.description ?? ""
        isSyncingDescription = false
    }

    private func scheduleDescriptionSave() {
        guard let officeID = selectedOfficeID else { return }
        let description = descriptionDraft
        descriptionSaveTask?.cancel()
        descriptionSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do {
                try appDatabase.setOfficeDescription(officeID: officeID, description: description)
                // Update the row copy in place; no reload (it would clobber typing)
                // and no change notification (matches other description autosaves).
                if let index = offices.firstIndex(where: { $0.id == officeID }) {
                    offices[index] = OfficeSummary(
                        id: offices[index].id,
                        name: offices[index].name,
                        description: description,
                        holderCount: offices[index].holderCount
                    )
                }
                errorMessage = nil
            } catch {
                errorMessage = "Failed to save the description."
            }
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

    private func beginDelete() {
        guard let office = selectedOffice else { return }
        if office.holderCount == 0 {
            // No holders → nothing cascades that the user could care about.
            deleteTarget = office
            commitDelete()
        } else {
            deleteTarget = office
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
