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
    @Published var showAdvanced: Bool = false

    // MARK: Node-type link state

    @Published var linkFields: [LinkField] = []
    @Published var linkTargetsByLinkFieldID: [Int64: [Int64]] = [:]
    @Published var nodeSummariesByID: [Int64: String] = [:]

    // MARK: PointMap state

    @Published var pointMapTitle: String = ""
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
    @Published var pointMapShowAdvanced: Bool = false
    @Published var pointMapExplicitLat: String = ""
    @Published var pointMapExplicitLng: String = ""
    @Published var pointMapExplicitZoom: String = ""
    @Published var pointMapShowAllPointsInQuestion: Bool = true
    @Published var pointMapApplyCurrentViewport: Bool = false
    @Published var pointMapLoadedDefaultCenterLat: Double?
    @Published var pointMapLoadedDefaultCenterLng: Double?
    @Published var pointMapLoadedDefaultZoom: Double?
    @Published var pointMapBoundaryGeometries: [BoundaryGeometry] = []
    let boundaryPickerState = BoundaryPickerState()

    // MARK: BoundaryMap state

    @Published var boundaryMapTitle: String = ""
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
    @Published var boundaryMapShowAdvanced: Bool = false
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
        return fields.contains { field in
            guard !stickyFieldIDs.contains(field.id) else { return false }
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
            && linkTargetsByLinkFieldID.values.allSatisfy(\.isEmpty)
            && maxIntervalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pointMapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && boundaryPickerState.selectedIDs.isEmpty
            && boundaryMapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && boundaryMapPickerState.selectedIDs.isEmpty
    }

    /// Tab label: the first display field's content (raw HTML, shown as-is),
    /// condensed to one line and capped at 64 characters; "(no FieldName)" when empty.
    var tabTitle: String {
        let raw: String
        let fallbackName: String
        if selectedTypeIsPointMap {
            raw = pointMapTitle
            fallbackName = "Title"
        } else if selectedTypeIsBoundaryMap {
            raw = boundaryMapTitle
            fallbackName = "Title"
        } else if let firstField = fields.first {
            raw = fieldValues[firstField.id] ?? ""
            fallbackName = firstField.name
        } else {
            return "New Instance"
        }
        let condensed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return condensed.isEmpty ? "(no \(fallbackName))" : String(condensed.prefix(64))
    }
}
