//
//  InstanceEditorDraft.swift
//  Memor
//
//  Per-tab model for an in-progress (uncommitted) instance in the Add Instance window.
//  Holds all editing state that must survive window close/reopen; owned by
//  AddInstanceWindowState (add mode, one per tab) or by EditInstanceWindowView
//  (edit mode, throwaway). Property names intentionally match the editor's former
//  @State names so the view reads naturally as `draft.fieldValues` etc.
//

import AppKit
import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI

/// One child entry in the Person editor (partner card or ungrouped list).
/// `id` is draft-local identity for SwiftUI; `rowID` is the persisted row.
struct PersonChildEntry: Identifiable, Hashable {
    let id = UUID()
    var rowID: Int64?
    var child: PersonRef
}

/// One partner card in the Person editor. `partnershipID` is the stable
/// person_partnership row id (nil until first save).
struct PersonPartnerDraftEntry: Identifiable, Hashable {
    let id = UUID()
    var partnershipID: Int64?
    var partner: PersonRef
    var isMarried = false
    var startText = ""
    var endText = ""
    var children: [PersonChildEntry] = []
    var isChildrenQueryEnabled = false
    /// Edit-mode SRS display for the "Children with" query (nil = never seen).
    var childrenQueryInterval: Int64?
}

/// One office card in the Person editor. `holdingID` is the persisted
/// person_office row id (nil until first save); `officeID` always references
/// an existing office row — offices are created in the DB before entering a
/// draft. Predecessors/successors are Person instance ids only (no bare names).
struct PersonOfficeDraftEntry: Identifiable, Hashable {
    let id = UUID()
    var holdingID: Int64?
    var officeID: Int64
    var officeName: String
    var whenBeganText = ""
    var whenEndedText = ""
    var noteText = ""
    var predecessorIDs: [Int64] = []
    var successorIDs: [Int64] = []
    var isOfficeQueryEnabled = false
    /// Edit-mode SRS display for the per-office query (nil = never seen).
    var officeQueryInterval: Int64?
}

final class InstanceEditorDraft: ObservableObject, Identifiable {
    let id = UUID()

    // MARK: Load requests (consumed by the editor's load path)

    /// Type to select on first load, resolved against the fetched type list.
    @Published var initialTypeID: Int64?
    /// When set, the editor loads this instance's values as a duplicate, then clears it.
    @Published var pendingDuplicateSourceInstanceID: Int64?

    // MARK: Type metadata mirrored from the editor so the draft can compute
    // isDirty/tabTitle without access to the window-level `types` list.

    @Published var selectedTypeIsPointMap = false
    @Published var selectedTypeIsBoundaryMap = false
    @Published var selectedTypeIsPerson = false
    @Published var selectedTypeName: String?

    // MARK: Core editing state

    @Published var selectedTypeID: Int64?
    @Published var loadedTypeID: Int64?
    @Published var loadedInstanceID: Int64?
    @Published var fields: [TypeField] = []
    @Published var queryTypes: [QueryType] = []
    @Published var selectedQueryTypeIDs: Set<Int64> = []
    @Published var queryIntervalsByQueryTypeID: [Int64: Int64] = [:]
    @Published var fieldValues: [Int64: String] = [:]
    @Published var selectedCollectionIDs: Set<Int64> = []
    @Published var stickyFieldIDs: Set<Int64> = []
    @Published var maxIntervalText: String = ""

    // MARK: Person relationship state

    @Published var personMother: PersonRef?
    @Published var personFather: PersonRef?
    @Published var personAdoptiveMother: PersonRef?
    @Published var personAdoptiveFather: PersonRef?
    @Published var personPartners: [PersonPartnerDraftEntry] = []
    @Published var personUngroupedChildren: [PersonChildEntry] = []
    @Published var personOffices: [PersonOfficeDraftEntry] = []
    /// Enabled standalone built-in query kinds (childrenWith enablement lives
    /// on each partner entry; per-office enablement on each office entry).
    @Published var personEnabledQueryKinds: Set<PersonQueryKind> = []
    /// Edit-mode SRS display for the standalone kinds (nil interval = never seen).
    @Published var personQueryIntervalsByKind: [PersonQueryKind: Int64] = [:]
    /// Display names + sexes for every instance referenced by the slots (chips,
    /// same-sex child blocking). Grows as the picker adds people.
    @Published var personDisplayNamesByID: [Int64: String] = [:]
    @Published var personSexesByID: [Int64: String] = [:]

    /// The draft's current Sex value ("Male" unless explicitly set to "Female").
    var personSexValue: String {
        guard let sexField = fields.first(where: { $0.fieldType == .sex }) else { return "Male" }
        return fieldValues[sexField.id] == "Female" ? "Female" : "Male"
    }

    var hasAnyPersonRelationshipData: Bool {
        personMother != nil || personFather != nil
            || personAdoptiveMother != nil || personAdoptiveFather != nil
            || !personPartners.isEmpty || !personUngroupedChildren.isEmpty
            || !personOffices.isEmpty
    }

    func resetPersonState() {
        personMother = nil
        personFather = nil
        personAdoptiveMother = nil
        personAdoptiveFather = nil
        personPartners = []
        personUngroupedChildren = []
        personOffices = []
        personEnabledQueryKinds = []
        personQueryIntervalsByKind = [:]
        personDisplayNamesByID = [:]
        personSexesByID = [:]
    }

    /// The relations payload for savePersonInstance.
    func buildPersonRelationsDraft() -> PersonRelationsDraft {
        PersonRelationsDraft(
            mother: personMother,
            father: personFather,
            adoptiveMother: personAdoptiveMother,
            adoptiveFather: personAdoptiveFather,
            partners: personPartners.map { entry in
                PersonPartnerDraft(
                    partnershipID: entry.partnershipID,
                    partner: entry.partner,
                    isMarried: entry.isMarried,
                    startText: entry.startText,
                    endText: entry.endText,
                    children: entry.children.map { PersonChildDraft(rowID: $0.rowID, child: $0.child) },
                    isChildrenQueryEnabled: entry.isChildrenQueryEnabled
                )
            },
            ungroupedChildren: personUngroupedChildren.map {
                PersonChildDraft(rowID: $0.rowID, child: $0.child)
            },
            offices: personOffices.map { entry in
                PersonOfficeDraft(
                    personOfficeID: entry.holdingID,
                    officeID: entry.officeID,
                    whenBegan: entry.whenBeganText,
                    whenEnded: entry.whenEndedText,
                    note: entry.noteText,
                    predecessors: entry.predecessorIDs,
                    successors: entry.successorIDs,
                    isQueryEnabled: entry.isOfficeQueryEnabled
                )
            }
        )
    }

    // MARK: PointMap state

    @Published var pointMapTitle: String = ""
    @Published var pointMapDescription: String = ""
    @Published var pointMapCameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
        )
    )
    @Published var pointMapCurrentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
    )
    @Published var pointMapExistingPoints: [PointMapPoint] = []
    @Published var pointMapNewPoints: [PointMapPointDraftEntry] = []
    @Published var pointMapSortMode: PointMapSortMode = .creation
    @Published var pointMapExplicitLat: String = ""
    @Published var pointMapExplicitLng: String = ""
    @Published var pointMapExplicitZoom: String = ""
    @Published var pointMapShowAllPointsInQuestion: Bool = true
    @Published var pointMapPointSize: PointMapPointSize = .medium
    @Published var pointMapApplyCurrentViewport: Bool = false
    @Published var pointMapLoadedDefaultCenterLat: Double?
    @Published var pointMapLoadedDefaultCenterLng: Double?
    @Published var pointMapLoadedDefaultZoom: Double?
    @Published var pointMapBoundaryGeometries: [BoundaryGeometry] = []
    let boundaryPickerState = BoundaryPickerState()

    // MARK: BoundaryMap state

    @Published var boundaryMapTitle: String = ""
    @Published var boundaryMapDescription: String = ""
    @Published var boundaryMapCameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
        )
    )
    @Published var boundaryMapCurrentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
    )
    @Published var boundaryMapExistingAttachments: [BoundaryMapAttachedBoundary] = []
    @Published var boundaryMapNewAttachments: [BoundaryMapAttachmentDraft] = []
    @Published var boundaryMapDeletedExistingIDs: Set<Int64> = []
    @Published var boundaryMapSortMode: BoundaryMapSortMode = .creation
    @Published var boundaryMapExplicitLat: String = ""
    @Published var boundaryMapExplicitLng: String = ""
    @Published var boundaryMapExplicitZoom: String = ""
    @Published var boundaryMapShowAllBoundariesInQuestion: Bool = true
    @Published var boundaryMapApplyCurrentViewport: Bool = false
    @Published var boundaryMapLoadedDefaultCenterLat: Double?
    @Published var boundaryMapLoadedDefaultCenterLng: Double?
    @Published var boundaryMapLoadedDefaultZoom: Double?
    @Published var boundaryMapGeometries: [BoundaryGeometry] = []
    let boundaryMapPickerState = BoundaryPickerState()

    private var cancellables: Set<AnyCancellable> = []

    init(initialTypeID: Int64? = nil, pendingDuplicateSourceInstanceID: Int64? = nil) {
        self.initialTypeID = initialTypeID
        self.pendingDuplicateSourceInstanceID = pendingDuplicateSourceInstanceID
        // The editor body and the tab bar observe only the draft, so picker-state
        // mutations must surface through the draft's objectWillChange.
        boundaryPickerState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        boundaryMapPickerState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Whether closing this draft would lose data the user typed. Port of the
    /// editor's former `shouldConfirmDiscard()` (add-mode dirtiness).
    var isDirty: Bool {
        if selectedTypeIsPointMap {
            return !pointMapNewPoints.isEmpty
        }
        if selectedTypeIsBoundaryMap {
            return !boundaryMapNewAttachments.isEmpty
        }
        if selectedTypeIsPerson, hasAnyPersonRelationshipData {
            return true
        }
        return fields.contains { field in
            guard !stickyFieldIDs.contains(field.id) else { return false }
            // Sex always carries a value ("Male" by default); it never makes a
            // draft dirty on its own.
            guard field.fieldType != .sex else { return false }
            let value = fieldValues[field.id] ?? ""
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether this draft is completely untouched and can be retargeted by an
    /// external open request (preselected type / duplication). Stricter than
    /// `!isDirty`; sticky leftovers are deliberately ignored — a tab holding only
    /// sticky values is reusable, matching post-add behavior.
    var isPristine: Bool {
        guard !isDirty else { return false }
        return selectedCollectionIDs.isEmpty
            && !hasAnyPersonRelationshipData
            && maxIntervalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pointMapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pointMapDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && boundaryPickerState.selectedIDs.isEmpty
            && boundaryMapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && boundaryMapDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && boundaryMapPickerState.selectedIDs.isEmpty
    }

    /// Tab label: the first display field's content (raw HTML, shown as-is),
    /// condensed to one line and capped at 64 characters; "New TypeName" while empty.
    var tabTitle: String {
        let raw: String
        if selectedTypeIsPointMap {
            raw = pointMapTitle
        } else if selectedTypeIsBoundaryMap {
            raw = boundaryMapTitle
        } else if let firstField = fields.first {
            raw = fieldValues[firstField.id] ?? ""
        } else {
            raw = ""
        }
        let condensed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if condensed.isEmpty {
            guard let selectedTypeName else { return "New Instance" }
            return "New \(selectedTypeName)"
        }
        return String(condensed.prefix(64))
    }
}
