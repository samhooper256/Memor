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
    @Published private(set) var requestedTypeID: Int64?
    @Published private(set) var requestedDuplicateSourceInstanceID: Int64?
    @Published private(set) var requestNonce = UUID()
    @Published private(set) var latestAddedTypeID: Int64?
    @Published private(set) var latestAddNonce = UUID()
    var lastUsedTypeID: Int64?

    func requestOpen(preselectedTypeID: Int64? = nil) {
        requestedTypeID = preselectedTypeID ?? lastUsedTypeID
        requestedDuplicateSourceInstanceID = nil
        requestNonce = UUID()
    }

    func requestOpenForDuplication(sourceInstanceID: Int64) {
        requestedTypeID = nil
        requestedDuplicateSourceInstanceID = sourceInstanceID
        requestNonce = UUID()
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
    @Published private(set) var requestedLinkTargetIDsByLinkFieldID: [Int64: [Int64]]?
    @Published private(set) var requestNonce = UUID()

    func requestOpen(
        instanceID: Int64,
        queryTypeID: Int64,
        fieldValuesByName: [String: String]? = nil
    ) {
        requestedInstanceID = instanceID
        requestedTypeID = nil
        requestedQueryTypeID = queryTypeID
        requestedFieldValuesByName = fieldValuesByName
        requestedLinkTargetIDsByLinkFieldID = nil
        requestNonce = UUID()
    }

    func requestOpenFirstQuery(instanceID: Int64) {
        requestedInstanceID = instanceID
        requestedTypeID = nil
        requestedQueryTypeID = nil
        requestedFieldValuesByName = nil
        requestedLinkTargetIDsByLinkFieldID = nil
        requestNonce = UUID()
    }

    /// Preview a query for an unsaved instance being composed in the Add Instance
    /// window. The query is built from `typeID` + `queryTypeID` (no instance row),
    /// with the editor's current field values and link targets supplied as overrides.
    func requestOpenDraft(
        typeID: Int64,
        queryTypeID: Int64,
        fieldValuesByName: [String: String],
        linkTargetIDsByLinkFieldID: [Int64: [Int64]]
    ) {
        requestedInstanceID = nil
        requestedTypeID = typeID
        requestedQueryTypeID = queryTypeID
        requestedFieldValuesByName = fieldValuesByName
        requestedLinkTargetIDsByLinkFieldID = linkTargetIDsByLinkFieldID
        requestNonce = UUID()
    }
}

struct AddInstanceWindowView: View {
    @EnvironmentObject private var windowState: AddInstanceWindowState
    @Environment(\.dismiss) private var dismiss

    let appDatabase: AppDatabase

    var body: some View {
        InstanceEditorWindowView(
            appDatabase: appDatabase,
            mode: .add,
            requestedTypeID: windowState.requestedTypeID,
            requestedInstanceID: nil,
            requestedDuplicateSourceInstanceID: windowState.requestedDuplicateSourceInstanceID,
            requestNonce: windowState.requestNonce,
            dismiss: dismiss,
            onEditSaved: nil,
            onAddSaved: { typeID in
                windowState.notifyAdded(typeID: typeID)
            },
            onTypeChanged: { typeID in
                windowState.lastUsedTypeID = typeID
            }
        )
    }
}

struct EditInstanceWindowView: View {
    @EnvironmentObject private var windowState: EditInstanceWindowState
    @Environment(\.dismiss) private var dismiss

    let appDatabase: AppDatabase

    var body: some View {
        InstanceEditorWindowView(
            appDatabase: appDatabase,
            mode: .edit,
            requestedTypeID: nil,
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
