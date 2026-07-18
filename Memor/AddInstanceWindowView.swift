//
//  AddInstanceWindowView.swift
//  Memor
//
//  Created by Codex on 4/4/26.
//

import AppKit
import Combine
import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AddInstanceWindowState: ObservableObject {
    /// In-progress (uncommitted) instances, one per tab. Lives at app level so tab
    /// contents survive window close/reopen; never persisted across app launches.
    @Published var drafts: [InstanceEditorDraft] = []
    @Published var selectedDraftID: UUID?
    @Published private(set) var latestAddedTypeID: Int64?
    @Published private(set) var latestAddNonce = UUID()
    // Bumped every time the window is asked to open, so the editor can reset its
    // field-area scroll position to the top (the view tree survives close/reopen).
    @Published private(set) var openNonce = UUID()
    var lastUsedTypeID: Int64?

    var selectedDraft: InstanceEditorDraft? {
        drafts.first { $0.id == selectedDraftID }
    }

    func ensureAtLeastOneTab() {
        if drafts.isEmpty {
            let draft = InstanceEditorDraft(initialTypeID: lastUsedTypeID)
            drafts.append(draft)
            selectedDraftID = draft.id
        } else if selectedDraft == nil {
            selectedDraftID = drafts.first?.id
        }
    }

    func newTab() {
        let draft = InstanceEditorDraft(initialTypeID: lastUsedTypeID)
        drafts.append(draft)
        selectedDraftID = draft.id
    }

    /// A plain open (no preselection) just shows the window with its existing tabs.
    /// A preselected-type open retargets the current tab if it is completely
    /// untouched, otherwise opens a new tab for that type.
    func requestOpen(preselectedTypeID: Int64? = nil) {
        openNonce = UUID()
        ensureAtLeastOneTab()
        guard let preselectedTypeID else { return }
        if let current = selectedDraft, current.isPristine {
            if current.selectedTypeID == nil {
                current.initialTypeID = preselectedTypeID
            } else if current.selectedTypeID != preselectedTypeID {
                current.selectedTypeID = preselectedTypeID
            }
        } else {
            let draft = InstanceEditorDraft(initialTypeID: preselectedTypeID)
            drafts.append(draft)
            selectedDraftID = draft.id
        }
    }

    func requestOpenForDuplication(sourceInstanceID: Int64) {
        openNonce = UUID()
        ensureAtLeastOneTab()
        if let current = selectedDraft, current.isPristine {
            current.pendingDuplicateSourceInstanceID = sourceInstanceID
        } else {
            let draft = InstanceEditorDraft(pendingDuplicateSourceInstanceID: sourceInstanceID)
            drafts.append(draft)
            selectedDraftID = draft.id
        }
    }

    /// Closes a tab, discarding its draft. The only tab is replaced with a blank
    /// tab of the most-recently-used type instead of closing the window.
    func closeTab(id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        if drafts.count == 1 {
            let replacement = InstanceEditorDraft(initialTypeID: lastUsedTypeID)
            drafts[index] = replacement
            selectedDraftID = replacement.id
            return
        }
        let wasSelected = selectedDraftID == id
        drafts.remove(at: index)
        if wasSelected {
            // Left neighbor; when the leftmost tab is closed, the right neighbor
            // has slid into its index.
            selectedDraftID = drafts[max(0, min(index - 1, drafts.count - 1))].id
        }
    }

    func notifyAdded(typeID: Int64) {
        latestAddedTypeID = typeID
        latestAddNonce = UUID()
    }
}

@MainActor
final class EditInstanceWindowState: ObservableObject {
    @Published private(set) var requestedInstanceID: Int64?
    @Published private(set) var requestedAutoEditPointID: Int64?
    @Published private(set) var requestNonce = UUID()
    @Published private(set) var latestSavedInstanceID: Int64?
    @Published private(set) var latestSaveNonce = UUID()

    func requestOpen(instanceID: Int64, autoEditPointID: Int64? = nil) {
        requestedInstanceID = instanceID
        requestedAutoEditPointID = autoEditPointID
        requestNonce = UUID()
    }

    func notifySaved(instanceID: Int64) {
        latestSavedInstanceID = instanceID
        latestSaveNonce = UUID()
    }
}

@MainActor
final class QueryPreviewWindowState: ObservableObject {
    @Published private(set) var requestedInstanceID: Int64?
    // Non-nil only for draft previews from the Add Instance window, where the
    // previewed "instance" has no row in the database yet — the query is built
    // from the type + query type instead.
    @Published private(set) var requestedTypeID: Int64?
    @Published private(set) var requestedQueryTypeID: Int64?
    @Published private(set) var requestedFieldValuesByName: [String: String]?
    // Built-in Person query previews (kind + the kind's discriminator:
    // partnership for childrenWith, office for office).
    @Published private(set) var requestedPersonKind: PersonQueryKind?
    @Published private(set) var requestedPersonPartnershipID: Int64?
    @Published private(set) var requestedPersonOfficeID: Int64?
    // Non-nil only for office-based built-in query previews from the Add
    // Instance window, where the person has no row yet: the drafted holdings
    // (and, for .office, the index of the previewed one) ride the request.
    @Published private(set) var requestedPersonOfficeDrafts: [PersonOfficeDraft]?
    @Published private(set) var requestedPersonOfficeDraftIndex: Int?
    // Non-nil only for previews requested by the instance editor: the draft's
    // currently-checked collections, so {{#CollectionClasses}}/{{#CollectionIDs}}
    // reflect unsaved checkbox state instead of the persisted membership.
    @Published private(set) var requestedCollectionIDs: Set<Int64>?
    @Published private(set) var requestNonce = UUID()

    func requestOpen(
        instanceID: Int64,
        queryTypeID: Int64,
        fieldValuesByName: [String: String]? = nil,
        collectionIDs: Set<Int64>? = nil
    ) {
        requestedInstanceID = instanceID
        requestedTypeID = nil
        requestedQueryTypeID = queryTypeID
        requestedFieldValuesByName = fieldValuesByName
        requestedPersonKind = nil
        requestedPersonPartnershipID = nil
        requestedPersonOfficeID = nil
        requestedPersonOfficeDrafts = nil
        requestedPersonOfficeDraftIndex = nil
        requestedCollectionIDs = collectionIDs
        requestNonce = UUID()
    }

    func requestOpenFirstQuery(instanceID: Int64) {
        requestedInstanceID = instanceID
        requestedTypeID = nil
        requestedQueryTypeID = nil
        requestedFieldValuesByName = nil
        requestedPersonKind = nil
        requestedPersonPartnershipID = nil
        requestedPersonOfficeID = nil
        requestedPersonOfficeDrafts = nil
        requestedPersonOfficeDraftIndex = nil
        requestedCollectionIDs = nil
        requestNonce = UUID()
    }

    /// Preview one of a Person instance's built-in queries.
    func requestOpenPersonQuery(
        instanceID: Int64,
        kind: PersonQueryKind,
        partnershipID: Int64?,
        officeID: Int64? = nil,
        collectionIDs: Set<Int64>? = nil
    ) {
        requestedInstanceID = instanceID
        requestedTypeID = nil
        requestedQueryTypeID = nil
        requestedFieldValuesByName = nil
        requestedPersonKind = kind
        requestedPersonPartnershipID = partnershipID
        requestedPersonOfficeID = officeID
        requestedPersonOfficeDrafts = nil
        requestedPersonOfficeDraftIndex = nil
        requestedCollectionIDs = collectionIDs
        requestNonce = UUID()
    }

    /// Preview a query for an unsaved instance being composed in the Add Instance
    /// window. The query is built from `typeID` + `queryTypeID` (no instance row),
    /// with the editor's current field values supplied as overrides.
    func requestOpenDraft(
        typeID: Int64,
        queryTypeID: Int64,
        fieldValuesByName: [String: String],
        collectionIDs: Set<Int64>? = nil
    ) {
        requestedInstanceID = nil
        requestedTypeID = typeID
        requestedQueryTypeID = queryTypeID
        requestedFieldValuesByName = fieldValuesByName
        requestedPersonKind = nil
        requestedPersonPartnershipID = nil
        requestedPersonOfficeID = nil
        requestedPersonOfficeDrafts = nil
        requestedPersonOfficeDraftIndex = nil
        requestedCollectionIDs = collectionIDs
        requestNonce = UUID()
    }

    /// Preview an office-based built-in query (.office / .allOffices) for an
    /// unsaved person being composed in the Add Instance window: holdings and
    /// field values come from the editor's draft, not the database, so
    /// uncommitted edits render. `officeIndex` picks the previewed holding for
    /// .office and is nil for .allOffices.
    func requestOpenPersonOfficeDraft(
        kind: PersonQueryKind,
        offices: [PersonOfficeDraft],
        officeIndex: Int?,
        fieldValuesByName: [String: String],
        collectionIDs: Set<Int64>? = nil
    ) {
        requestedInstanceID = nil
        requestedTypeID = nil
        requestedQueryTypeID = nil
        requestedFieldValuesByName = fieldValuesByName
        requestedPersonKind = kind
        requestedPersonPartnershipID = nil
        requestedPersonOfficeID = nil
        requestedPersonOfficeDrafts = offices
        requestedPersonOfficeDraftIndex = officeIndex
        requestedCollectionIDs = collectionIDs
        requestNonce = UUID()
    }
}

struct AddInstanceWindowView: View {
    @EnvironmentObject private var windowState: AddInstanceWindowState
    @Environment(\.dismiss) private var dismiss

    let appDatabase: AppDatabase

    var body: some View {
        VStack(spacing: 0) {
            AddInstanceTabBar(
                windowState: windowState,
                onSelect: selectTab,
                onClose: requestCloseTab,
                onNewTab: { windowState.newTab() }
            )

            Divider()

            if let draft = windowState.selectedDraft {
                InstanceEditorWindowView(
                    appDatabase: appDatabase,
                    mode: .add,
                    draft: draft,
                    requestedInstanceID: nil,
                    requestNonce: draft.id,
                    openNonce: windowState.openNonce,
                    dismiss: dismiss,
                    onEditSaved: nil,
                    onAddSaved: { typeID in
                        windowState.notifyAdded(typeID: typeID)
                    },
                    onTypeChanged: { typeID in
                        windowState.lastUsedTypeID = typeID
                    }
                )
                // Load-bearing: rebuilds the editor (incl. @StateObject controllers
                // and text views) from the newly selected draft on tab switches.
                .id(draft.id)
            }
        }
        .onAppear {
            windowState.ensureAtLeastOneTab()
        }
        .background {
            AddInstanceTabKeyHandler(
                onSelectTabIndex: { index in
                    guard windowState.drafts.indices.contains(index) else { return }
                    selectTab(windowState.drafts[index].id)
                },
                onCloseCurrentTab: {
                    guard let id = windowState.selectedDraftID else { return }
                    requestCloseTab(id)
                }
            )
        }
    }

    private func selectTab(_ id: UUID) {
        guard windowState.selectedDraftID != id else { return }
        windowState.selectedDraftID = id
        // Most-recently-used type tracks tab activation, not just type changes.
        if let typeID = windowState.selectedDraft?.selectedTypeID {
            windowState.lastUsedTypeID = typeID
        }
    }

    /// X button / ⌘W: switch to the tab first, then confirm the discard unless
    /// the tab has nothing the user could lose.
    private func requestCloseTab(_ id: UUID) {
        guard let draft = windowState.drafts.first(where: { $0.id == id }) else { return }
        selectTab(id)
        guard draft.isDirty, let window = NSApp.keyWindow else {
            windowState.closeTab(id: id)
            return
        }
        presentDiscardInstanceConfirmation(on: window) {
            windowState.closeTab(id: id)
        }
    }
}

/// The shared "Are you sure you want to discard this instance?" alert.
/// "No, keep editing" leaves everything untouched.
func presentDiscardInstanceConfirmation(on window: NSWindow, onDiscard: @escaping () -> Void) {
    if window.attachedSheet != nil { return }
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Are you sure you want to discard this instance?"
    alert.informativeText = "The data associated with this instance may be lost."
    alert.addButton(withTitle: "Yes, discard instance")
    let keepButton = alert.addButton(withTitle: "No, keep editing")
    keepButton.keyEquivalent = "\u{1b}"
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        onDiscard()
    }
}

struct EditInstanceWindowView: View {
    @EnvironmentObject private var windowState: EditInstanceWindowState
    @Environment(\.dismiss) private var dismiss

    let appDatabase: AppDatabase

    @StateObject private var draft = InstanceEditorDraft()

    var body: some View {
        InstanceEditorWindowView(
            appDatabase: appDatabase,
            mode: .edit,
            draft: draft,
            requestedInstanceID: windowState.requestedInstanceID,
            requestedAutoEditPointID: windowState.requestedAutoEditPointID,
            requestNonce: windowState.requestNonce,
            dismiss: dismiss,
            onEditSaved: { instanceID in
                windowState.notifySaved(instanceID: instanceID)
            },
            onAddSaved: nil,
            onTypeChanged: nil
        )
    }
}
