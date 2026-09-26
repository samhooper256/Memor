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

/// Everything in an instance editor's draft that affects how its queries
/// render, captured when a preview is requested. Editor previews render ONLY
/// from this (plus type-level data: query type HTML, CSS, office names, other
/// people's names) — never from the edited instance's saved row — so the
/// Query Preview shows the instance exactly as it will be once saved, in Add
/// and Edit mode alike. A new draft input that affects rendering belongs here.
struct InstanceDraftPreviewSnapshot {
    /// The draft's selected type (may differ from the saved type in Edit mode).
    let typeID: Int64
    /// The edited instance's row in Edit mode; nil for an Add-mode draft.
    let instanceID: Int64?
    /// Field values, normalized exactly as saving would store them.
    let fieldValuesByName: [String: String]
    /// The draft's checked collections.
    let collectionIDs: Set<Int64>
    /// The drafted relationships and office stints; nil unless the type is Person.
    let personRelations: PersonRelationsDraft?

    var renderOverrides: QueryRenderOverrides {
        QueryRenderOverrides(collectionIDs: collectionIDs, personOffices: personRelations?.offices)
    }
}

/// Which of the draft's queries an editor preview shows.
enum InstanceDraftPreviewTarget {
    case queryType(Int64)
    /// A built-in Person query. `partnerIndex` addresses the drafted partners
    /// for .childrenWith; `officeIndex` picks the previewed OFFICE for
    /// .office (via any of its stint entries — every stint renders).
    case personBuiltin(kind: PersonQueryKind, partnerIndex: Int?, officeIndex: Int?)
}

enum QueryPreviewRequest {
    /// Saved state (Search, Study, link navigation). A nil query type shows
    /// the instance's first query.
    case saved(instanceID: Int64, queryTypeID: Int64?)
    /// The instance editor's current draft.
    case draft(InstanceDraftPreviewSnapshot, InstanceDraftPreviewTarget)
}

@MainActor
final class QueryPreviewWindowState: ObservableObject {
    @Published private(set) var request: QueryPreviewRequest?
    @Published private(set) var requestNonce = UUID()

    func requestOpen(instanceID: Int64, queryTypeID: Int64) {
        open(.saved(instanceID: instanceID, queryTypeID: queryTypeID))
    }

    func requestOpenFirstQuery(instanceID: Int64) {
        open(.saved(instanceID: instanceID, queryTypeID: nil))
    }

    /// Preview one of the instance editor's queries from its CURRENT draft.
    func requestOpenDraft(_ snapshot: InstanceDraftPreviewSnapshot, target: InstanceDraftPreviewTarget) {
        open(.draft(snapshot, target))
    }

    private func open(_ request: QueryPreviewRequest) {
        self.request = request
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
