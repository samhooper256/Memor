//
//  InstanceEditorWindowView.swift
//  Memor
//
//  Core editor body shared by the Add Instance and Edit Instance windows.
//

import AppKit
import Combine
import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

enum InstanceEditorMode {
    case add
    case edit
}

struct InstanceEditorWindowView: View {
    @Environment(\.openWindow) private var openWindow

    @EnvironmentObject private var queryPreviewWindowState: QueryPreviewWindowState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings

    let appDatabase: AppDatabase
    let mode: InstanceEditorMode
    let requestedTypeID: Int64?
    let requestedInstanceID: Int64?
    var requestedDuplicateSourceInstanceID: Int64? = nil
    var requestedAutoEditPointID: Int64? = nil
    let requestNonce: UUID
    let dismiss: DismissAction
    let onEditSaved: ((Int64) -> Void)?
    let onAddSaved: ((Int64) -> Void)?
    let onTypeChanged: ((Int64) -> Void)?

    @State private var types: [FlashcardType] = []
    @State private var selectedTypeID: Int64?
    @State private var loadedTypeID: Int64?
    @State private var loadedInstanceID: Int64?
    @State private var fields: [TypeField] = []
    @State private var queryTypes: [QueryType] = []
    @State private var selectedQueryTypeIDs: Set<Int64> = []
    @State private var queryIntervalsByQueryTypeID: [Int64: Int64] = [:]
    @State private var fieldValues: [Int64: String] = [:]
    @State private var toast: ToastMessage?
    @State private var toastTask: Task<Void, Never>?
    @State private var allCollectionItems: [CollectionChecklistItem] = []
    @State private var selectedCollectionIDs: Set<Int64> = []
    @State private var collectionSearchQuery = ""
    @State private var stickyFieldIDs: Set<Int64> = []
    @State private var maxIntervalText: String = ""
    @State private var showAdvanced: Bool = false
    @StateObject private var focusController = AddInstanceFieldFocusController()
    @StateObject private var hyperlinkSearchController = HyperlinkSearchController()
    @StateObject private var typePickerController = TypePickerController()

    // Node-type-specific state
    @State private var linkFields: [LinkField] = []
    @State private var linkTargetsByLinkFieldID: [Int64: [Int64]] = [:]
    @State private var nodeSummariesByID: [Int64: String] = [:]

    // Deletion confirmations for the map query lists
    @State private var pendingPointMapDeletion: Set<PointMapEntryRef> = []
    @State private var isPointMapDeletionConfirmationPresented = false
    @State private var pendingBoundaryMapDeletion: Set<BoundaryMapEntryRef> = []
    @State private var isBoundaryMapDeletionConfirmationPresented = false

    // Confirmation for deleting the whole instance being edited (edit mode only).
    @State private var isInstanceDeletionConfirmationPresented = false

    // PointMap-specific state
    @State private var pointMapTitle: String = ""
    @State private var pointMapCameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
        )
    )
    @State private var pointMapCurrentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
    )
    @State private var pointMapExistingPoints: [PointMapPoint] = []
    @State private var pointMapNewPoints: [PointMapPointDraftEntry] = []
    @State private var pointMapHoveredEntryID: String?
    @State private var pointMapMapSelection: String?
    @State private var pointMapListSelection: Set<PointMapEntryRef> = []
    @State private var boundaryMapListSelection: Set<BoundaryMapEntryRef> = []
    @State private var pointMapSortMode: PointMapSortMode = .creation
    @State private var pointMapShowAdvanced: Bool = false
    @State private var pointMapExplicitLat: String = ""
    @State private var pointMapExplicitLng: String = ""
    @State private var pointMapExplicitZoom: String = ""
    @State private var pointMapShowAllPointsInQuestion: Bool = true
    @State private var pointMapApplyCurrentViewport: Bool = false
    @State private var pointMapLoadedDefaultCenterLat: Double?
    @State private var pointMapLoadedDefaultCenterLng: Double?
    @State private var pointMapLoadedDefaultZoom: Double?
    @StateObject private var pointMapPointController = AddPointPopupController()
    @State private var closeInterceptor = InstanceEditorCloseInterceptor()
    @StateObject private var boundaryPickerState = BoundaryPickerState()
    @State private var isBoundaryPickerPresented = false
    @State private var pointMapBoundaryGeometries: [BoundaryGeometry] = []
    @State private var isIDCopyButtonHovered = false

    // BoundaryMap-specific state
    @State private var boundaryMapTitle: String = ""
    @State private var boundaryMapCameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
        )
    )
    @State private var boundaryMapCurrentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
    )
    @State private var boundaryMapExistingAttachments: [BoundaryMapAttachedBoundary] = []
    @State private var boundaryMapNewAttachments: [BoundaryMapAttachmentDraft] = []
    @State private var boundaryMapDeletedExistingIDs: Set<Int64> = []
    @State private var boundaryMapSortMode: BoundaryMapSortMode = .creation
    @State private var boundaryMapShowAdvanced: Bool = false
    @State private var boundaryMapExplicitLat: String = ""
    @State private var boundaryMapExplicitLng: String = ""
    @State private var boundaryMapExplicitZoom: String = ""
    @State private var boundaryMapShowAllBoundariesInQuestion: Bool = true
    @State private var boundaryMapApplyCurrentViewport: Bool = false
    @State private var boundaryMapLoadedDefaultCenterLat: Double?
    @State private var boundaryMapLoadedDefaultCenterLng: Double?
    @State private var boundaryMapLoadedDefaultZoom: Double?
    @StateObject private var boundaryMapPickerState = BoundaryPickerState()
    @State private var isBoundaryMapPickerPresented = false
    @State private var boundaryMapGeometries: [BoundaryGeometry] = []

    private var selectedType: FlashcardType? {
        guard let selectedTypeID else { return nil }
        return types.first(where: { $0.id == selectedTypeID })
    }

    private var isPointMapSelected: Bool {
        guard let selectedType else { return false }
        return selectedType.isBuiltin && selectedType.name == POINTMAP_TYPE_NAME
    }

    private var isBoundaryMapSelected: Bool {
        guard let selectedType else { return false }
        return selectedType.isBuiltin && selectedType.name == BOUNDARYMAP_TYPE_NAME
    }

    private var isNodeTypeSelected: Bool {
        selectedType?.isNode ?? false
    }

    private var linkCountsAreValid: Bool {
        for linkField in linkFields {
            let count = linkTargetsByLinkFieldID[linkField.id]?.count ?? 0
            if count < linkField.minCount { return false }
            if let maxCount = linkField.maxCount, count > maxCount { return false }
        }
        return true
    }

    private var canSubmit: Bool {
        guard selectedTypeID != nil else { return false }
        if isPointMapSelected {
            return !pointMapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isBoundaryMapSelected {
            return !boundaryMapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasFieldValue = fieldValues.values.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isNodeTypeSelected {
            return hasFieldValue && linkCountsAreValid
        }
        return hasFieldValue
    }

    private var submitButtonTitle: String {
        switch mode {
        case .add:
            return "Add"
        case .edit:
            return "Save Changes"
        }
    }

    private var keyCommandHandler: some View {
        WindowKeyCommandHandler(
            onEscape: { attemptDismiss() },
            onCommandReturn: submitInstance,
            onCommandS: handleCommandS,
            onCommandB: { wrapFocusedSelection(openTag: "<b>", closeTag: "</b>") },
            onCommandI: { wrapFocusedSelection(openTag: "<i>", closeTag: "</i>") },
            onCommandO: insertImageIntoCurrentField,
            onCommandJ: { wrapFocusedSelection(openTag: "<e>", closeTag: "</e>") },
            onCommandL: copyInstanceLinkToClipboard,
            onCommandT: mode == .add ? { presentTypePicker() } : nil,
            shortcutSettings: shortcutSettings
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            typePicker
                .padding(.bottom, 12)

            editorPanels
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !isPointMapSelected && !isBoundaryMapSelected && selectedTypeID != nil {
                advancedSection
                    .padding(.top, 12)
            }

            HStack {
                if mode == .edit, loadedInstanceID != nil {
                    Button("Delete", role: .destructive) {
                        isInstanceDeletionConfirmationPresented = true
                    }
                    .tint(.red)
                }

                Spacer()

                Button(submitButtonTitle) {
                    submitInstance()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
            .padding(.top, 6)
            .alert(
                "Are you sure you want to delete this instance?",
                isPresented: $isInstanceDeletionConfirmationPresented
            ) {
                Button("Delete", role: .destructive) {
                    deleteCurrentInstance()
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action is irreversible.")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(minWidth: 760, minHeight: 420)
        .background { keyCommandHandler }
        .task {
            await loadInitialData()
        }
        .onChange(of: selectedTypeID) { _, newValue in
            guard mode == .add else { return }
            if let newValue {
                onTypeChanged?(newValue)
            }
            Task {
                await loadFields(for: newValue)
            }
        }
        .onChange(of: requestNonce) { _, _ in
            Task<Void, Never> {
                await loadInitialData()
            }
        }
        .onExitCommand {
            attemptDismiss()
        }
        .background {
            InstanceEditorCloseGuard(
                interceptor: closeInterceptor,
                shouldConfirm: { shouldConfirmDiscard() },
                presentConfirmation: { window in
                    presentDiscardConfirmation(on: window)
                }
            )
        }
        .background {
            if mode == .edit {
                EditorPreviewShortcutHandler(
                    shortcutSettings: shortcutSettings,
                    onPreviewTopQuery: previewTopmostCheckedQueryType
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if let toast {
                ToastView(toast: toast)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    private var selectedTypeName: String {
        if let selectedTypeID, let type = types.first(where: { $0.id == selectedTypeID }) {
            return type.name
        }
        return "No Type Selected"
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Type: \(selectedTypeName)")

                    if mode == .add {
                        Button("Change Type (⌘T)") {
                            presentTypePicker()
                        }
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if mode == .edit, let loadedInstanceID {
                    HStack(spacing: 8) {
                        Text("ID: \(loadedInstanceID)")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)

                        Button {
                            copyInstanceIDToClipboard(loadedInstanceID)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isIDCopyButtonHovered ? Color.secondary.opacity(0.18) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Copy ID")
                        .onHover { hovering in
                            isIDCopyButtonHovered = hovering
                        }
                    }
                }
            }

            if !isPointMapSelected && !isBoundaryMapSelected {
                Button {
                    insertImageIntoCurrentField()
                } label: {
                    ShortcutLabel(title: "Insert Image", action: .editorInsertImage)
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var editorPanels: some View {
        if isPointMapSelected {
            pointMapEditor
        } else if isBoundaryMapSelected {
            boundaryMapEditor
        } else {
            HStack(alignment: .top, spacing: 12) {
                fieldsSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                queryTypesPanel
                    .frame(width: 260)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var pointMapEditor: some View {
        HStack(alignment: .top, spacing: 12) {
            pointMapMapPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            pointMapListPane
                .frame(width: 260)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .background {
            PointMapShortcutKeyHandler(
                shortcutSettings: shortcutSettings,
                onAddQuery: { presentAddPointPopup() }
            )
        }
    }

    private var pointMapMapPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Name:")
                    .font(.subheadline)
                TextField("", text: $pointMapTitle)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .center, spacing: 8) {
                Text("Boundaries:")
                    .font(.subheadline)
                SelectedBoundariesStrip(
                    boundaries: boundaryPickerState.selectedBoundaries,
                    onRemove: { id in
                        boundaryPickerState.selectedIDs.remove(id)
                        refreshBoundaryGeometries()
                    },
                    onAddTapped: { isBoundaryPickerPresented = true },
                    addButtonLabel: "Add"
                )
                .popover(isPresented: $isBoundaryPickerPresented, arrowEdge: .bottom) {
                    BoundaryPickerPopoverView(
                        state: boundaryPickerState,
                        appDatabase: appDatabase,
                        onManage: {
                            isBoundaryPickerPresented = false
                            openWindow(id: "manage-boundaries")
                        }
                    )
                }
                .onChange(of: boundaryPickerState.selectedIDs) { _, _ in
                    refreshBoundaryGeometries()
                }
            }

            MapReader { proxy in
                ZStack {
                    Map(position: $pointMapCameraPosition, selection: $pointMapMapSelection) {
                        ForEach(pointMapDisplayPoints, id: \.id) { entry in
                            Annotation("", coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude)) {
                                MapPointMarker(
                                    name: entry.name,
                                    size: 12,
                                    isHighlighted: false,
                                    showTooltipOnHover: true
                                ) { hovering in
                                    if hovering {
                                        pointMapHoveredEntryID = entry.id
                                        pointMapMapSelection = entry.id
                                    } else if pointMapHoveredEntryID == entry.id {
                                        pointMapHoveredEntryID = nil
                                        pointMapMapSelection = nil
                                    }
                                }
                            }
                            .tag(entry.id)
                        }
                        ForEach(pointMapBoundaryGeometries) { geo in
                            ForEach(Array(geo.geometry.rings.enumerated()), id: \.offset) { _, polygonRings in
                                if let outer = polygonRings.first, outer.count >= 3 {
                                    MapPolygon(coordinates: outer.map(\.clLocation))
                                        .foregroundStyle(.clear)
                                        .stroke(Color.red, lineWidth: 1.5)
                                }
                            }
                        }
                    }
                    .onMapCameraChange(frequency: .continuous) { context in
                        pointMapCurrentRegion = context.region
                        pointMapSyncExplicitFieldsFromRegion()
                    }

                    MapRightClickContextMenu { localPoint in
                        mapContextMenuActions(at: localPoint, proxy: proxy)
                    }

                    MapDoubleClickCatcher { localPoint in
                        pointMapDoubleClickEdit(at: localPoint, proxy: proxy)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }

            Toggle(isOn: $pointMapShowAllPointsInQuestion) {
                Text("Show all points in the question side of each query")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)

            if mode == .edit {
                Toggle(isOn: $pointMapApplyCurrentViewport) {
                    Text("Set each query's default map location and zoom to current")
                        .font(.subheadline)
                }
                .toggleStyle(.checkbox)
            }

            DisclosureGroup("Advanced", isExpanded: $pointMapShowAdvanced) {
                HStack(spacing: 6) {
                    Text("Lat:")
                    TextField("", text: $pointMapExplicitLat)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 90)
                        .onSubmit(applyExplicitPointMapViewport)
                    Text("Lng:")
                    TextField("", text: $pointMapExplicitLng)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 90)
                        .onSubmit(applyExplicitPointMapViewport)
                    Text("Zoom:")
                    TextField("", text: $pointMapExplicitZoom)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 60)
                        .onSubmit(applyExplicitPointMapViewport)
                    Button("Apply") {
                        applyExplicitPointMapViewport()
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .font(.subheadline)
        }
    }

    private var pointMapListPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                presentAddPointPopup()
            } label: {
                ShortcutLabel(title: "Add Point", action: .editorPointMapAddQuery)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Divider()

            Group {
                if pointMapDisplayEntries.isEmpty {
                    Text("No points yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(selection: $pointMapListSelection) {
                        ForEach(pointMapDisplayEntries, id: \.id) { entry in
                            PointMapEntryRow(
                                name: entry.name,
                                forwardEnabled: pointMapForwardBinding(for: entry.ref),
                                reverseEnabled: pointMapReverseBinding(for: entry.ref)
                            )
                            .tag(entry.ref)
                        }
                    }
                    .listStyle(.inset)
                    .contextMenu(forSelectionType: PointMapEntryRef.self) { refs in
                        if !refs.isEmpty {
                            Menu("Enable Queries") {
                                Button("Forward") { setPointMapEntriesEnabled(refs, forward: true, reverse: nil) }
                                Button("Reverse") { setPointMapEntriesEnabled(refs, forward: nil, reverse: true) }
                            }
                            Menu("Disable Queries") {
                                Button("Forward") { setPointMapEntriesEnabled(refs, forward: false, reverse: nil) }
                                Button("Reverse") { setPointMapEntriesEnabled(refs, forward: nil, reverse: false) }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                requestDeletePointMapEntries(refs)
                            }
                        }
                    } primaryAction: { refs in
                        if refs.count == 1, let ref = refs.first {
                            presentEditPointPopup(for: ref)
                        }
                    }
                    .onDeleteCommand {
                        requestDeletePointMapEntries(pointMapListSelection)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }
            .alert(
                pointMapDeletionTitle,
                isPresented: $isPointMapDeletionConfirmationPresented
            ) {
                Button("Delete", role: .destructive) {
                    let refs = pendingPointMapDeletion
                    pendingPointMapDeletion = []
                    deletePointMapEntries(refs)
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {
                    pendingPointMapDeletion = []
                }
            } message: {
                Text("This action is irreversible.")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sort:")
                    .font(.subheadline)
                Picker("", selection: $pointMapSortMode) {
                    ForEach(PointMapSortMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
    }

    private struct PointMapDisplayEntry {
        let ref: PointMapEntryRef
        let name: String
        let latitude: Double
        let longitude: Double
        let forwardEnabled: Bool
        let reverseEnabled: Bool
        var id: String { ref.id }
    }

    private var pointMapDisplayEntries: [PointMapDisplayEntry] {
        var entries: [PointMapDisplayEntry] = []
        entries.reserveCapacity(pointMapExistingPoints.count + pointMapNewPoints.count)
        for point in pointMapExistingPoints {
            entries.append(PointMapDisplayEntry(
                ref: .existing(point.id),
                name: point.name,
                latitude: point.latitude,
                longitude: point.longitude,
                forwardEnabled: point.forwardEnabled,
                reverseEnabled: point.reverseEnabled
            ))
        }
        for entry in pointMapNewPoints {
            entries.append(PointMapDisplayEntry(
                ref: .new(entry.localID),
                name: entry.name,
                latitude: entry.latitude,
                longitude: entry.longitude,
                forwardEnabled: entry.forwardEnabled,
                reverseEnabled: entry.reverseEnabled
            ))
        }
        switch pointMapSortMode {
        case .creation:
            return entries
        case .alphabetical:
            return entries.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private var pointMapDisplayPoints: [PointMapDisplayEntry] {
        pointMapDisplayEntries
    }

    private func pointMapSyncExplicitFieldsFromRegion() {
        let region = pointMapCurrentRegion
        pointMapExplicitLat = String(format: "%.6f", region.center.latitude)
        pointMapExplicitLng = String(format: "%.6f", region.center.longitude)
        let latDelta = max(region.span.latitudeDelta, 0.0001)
        let zoom = log2(360.0 / latDelta)
        pointMapExplicitZoom = String(format: "%.2f", zoom)
    }

    private func applyExplicitPointMapViewport() {
        guard let lat = Double(pointMapExplicitLat.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lng = Double(pointMapExplicitLng.trimmingCharacters(in: .whitespacesAndNewlines)),
              let zoom = Double(pointMapExplicitZoom.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showToast(message: "Invalid viewport values.", style: .error)
            return
        }
        let clampedZoom = max(0.0, min(20.0, zoom))
        let delta = max(0.0001, 360.0 / pow(2.0, clampedZoom))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
        )
        pointMapCurrentRegion = region
        pointMapCameraPosition = .region(region)
    }

    private func resetPointMapState() {
        pointMapTitle = ""
        pointMapExistingPoints = []
        pointMapNewPoints = []
        pointMapSortMode = .creation
        pointMapShowAdvanced = false
        pointMapShowAllPointsInQuestion = true
        pointMapApplyCurrentViewport = false
        pointMapLoadedDefaultCenterLat = nil
        pointMapLoadedDefaultCenterLng = nil
        pointMapLoadedDefaultZoom = nil
        let defaultRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
        )
        pointMapCurrentRegion = defaultRegion
        pointMapCameraPosition = .region(defaultRegion)
        pointMapSyncExplicitFieldsFromRegion()
        boundaryPickerState.selectedIDs = []
        boundaryPickerState.reload(appDatabase: appDatabase)
        pointMapBoundaryGeometries = []
    }

    private func loadPointMapInto(instance: PointMapInstanceWithPoints) {
        pointMapTitle = instance.instance.title
        pointMapExistingPoints = instance.points
        pointMapNewPoints = []
        pointMapSortMode = .creation
        pointMapShowAdvanced = false
        pointMapShowAllPointsInQuestion = instance.instance.showAllPointsInQuestion
        pointMapApplyCurrentViewport = false
        pointMapLoadedDefaultCenterLat = instance.instance.defaultCenterLat
        pointMapLoadedDefaultCenterLng = instance.instance.defaultCenterLng
        pointMapLoadedDefaultZoom = instance.instance.defaultZoom
        let delta = max(0.0001, 360.0 / pow(2.0, max(0.0, min(20.0, instance.instance.defaultZoom))))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: instance.instance.defaultCenterLat, longitude: instance.instance.defaultCenterLng),
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
        )
        pointMapCurrentRegion = region
        pointMapCameraPosition = .region(region)
        pointMapSyncExplicitFieldsFromRegion()
        boundaryPickerState.selectedIDs = Set(instance.boundaryIDs)
        boundaryPickerState.reload(appDatabase: appDatabase)
        refreshBoundaryGeometries()
    }

    private func refreshBoundaryGeometries() {
        guard let instanceID = loadedInstanceID else {
            // In Add mode we haven't persisted yet; load geometries ad-hoc.
            loadBoundaryGeometriesForSelected()
            return
        }
        // If selection matches what's in DB, we can just re-fetch by instance.
        // Otherwise fall back to selected-ids loading.
        loadBoundaryGeometriesForSelected()
        _ = instanceID
    }

    private func loadBoundaryGeometriesForSelected() {
        let ids = boundaryPickerState.selectedIDs
        guard !ids.isEmpty else {
            pointMapBoundaryGeometries = []
            return
        }
        // Reuse the parsing path: fetch each boundary individually. For small
        // selections this is cheap; for large selections we accept the cost.
        var geometries: [BoundaryGeometry] = []
        geometries.reserveCapacity(ids.count)
        for option in boundaryPickerState.options where ids.contains(option.id) {
            if let geo = try? appDatabase.fetchBoundaryGeometry(boundaryID: option.id) {
                geometries.append(BoundaryGeometry(
                    id: option.id,
                    name: option.boundary.name,
                    geometry: geo
                ))
            }
        }
        pointMapBoundaryGeometries = geometries
    }

    private func mapContextMenuActions(at localPoint: CGPoint, proxy: MapProxy) -> [MapMenuAction] {
        let hitRadius: CGFloat = 12
        for entry in pointMapDisplayPoints {
            let entryCoord = CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude)
            guard let entryLocal = proxy.convert(entryCoord, to: .local) else { continue }
            let dx = entryLocal.x - localPoint.x
            let dy = entryLocal.y - localPoint.y
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                let ref = entry.ref
                return [
                    MapMenuAction(title: "Edit") { presentEditPointPopup(for: ref) },
                    MapMenuAction(title: "Delete") { removePointMapEntry(ref) }
                ]
            }
        }
        guard let coord = proxy.convert(localPoint, from: .local) else { return [] }
        return [
            MapMenuAction(title: "Add point here") {
                presentAddPointPopup(
                    initialLatitude: String(coord.latitude),
                    initialLongitude: String(coord.longitude)
                )
            },
            MapMenuAction(title: "Copy coordinates") {
                let text = "\(coord.latitude),\(coord.longitude)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        ]
    }

    // Hit-tests a left double-click against the points and opens the edit popup
    // for the one under the cursor. Returns true when a point was hit (so the
    // catcher can swallow the event and prevent the map's double-click zoom).
    private func pointMapDoubleClickEdit(at localPoint: CGPoint, proxy: MapProxy) -> Bool {
        let hitRadius: CGFloat = 12
        for entry in pointMapDisplayPoints {
            let entryCoord = CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude)
            guard let entryLocal = proxy.convert(entryCoord, to: .local) else { continue }
            let dx = entryLocal.x - localPoint.x
            let dy = entryLocal.y - localPoint.y
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                presentEditPointPopup(for: entry.ref)
                return true
            }
        }
        return false
    }

    private func presentAddPointPopup(initialLatitude: String = "", initialLongitude: String = "") {
        let window = NSApp.keyWindow
        pointMapPointController.present(
            from: window,
            initialLatitude: initialLatitude,
            initialLongitude: initialLongitude,
            initialForwardEnabled: true,
            initialReverseEnabled: false,
            isEdit: false
        ) { name, lat, lng, forward, reverse in
            let entry = PointMapPointDraftEntry(
                localID: UUID(),
                name: name,
                latitude: lat,
                longitude: lng,
                forwardEnabled: forward,
                reverseEnabled: reverse
            )
            pointMapNewPoints.append(entry)
        }
    }

    private func presentEditPointPopup(for ref: PointMapEntryRef) {
        let window = NSApp.keyWindow
        switch ref {
        case .existing(let id):
            guard let point = pointMapExistingPoints.first(where: { $0.id == id }) else { return }
            pointMapPointController.present(
                from: window,
                initialName: point.name,
                initialLatitude: String(point.latitude),
                initialLongitude: String(point.longitude),
                initialForwardEnabled: point.forwardEnabled,
                initialReverseEnabled: point.reverseEnabled,
                forwardInterval: point.forwardInterval,
                reverseInterval: point.reverseInterval,
                isEdit: true,
                onResetForward: {
                    try? appDatabase.resetPointMapPointDueDate(pointID: id, isReverse: false)
                    if let idx = pointMapExistingPoints.firstIndex(where: { $0.id == id }) {
                        pointMapExistingPoints[idx].forwardInterval = 0
                    }
                },
                onResetReverse: {
                    try? appDatabase.resetPointMapPointDueDate(pointID: id, isReverse: true)
                    if let idx = pointMapExistingPoints.firstIndex(where: { $0.id == id }) {
                        pointMapExistingPoints[idx].reverseInterval = 0
                    }
                }
            ) { name, lat, lng, forward, reverse in
                guard let idx = pointMapExistingPoints.firstIndex(where: { $0.id == id }) else { return }
                let existing = pointMapExistingPoints[idx]
                pointMapExistingPoints[idx] = PointMapPoint(
                    id: existing.id,
                    instanceID: existing.instanceID,
                    name: name,
                    latitude: lat,
                    longitude: lng,
                    forwardEnabled: forward,
                    reverseEnabled: reverse,
                    forwardInterval: existing.forwardInterval,
                    reverseInterval: existing.reverseInterval
                )
            }
        case .new(let localID):
            guard let entry = pointMapNewPoints.first(where: { $0.localID == localID }) else { return }
            pointMapPointController.present(
                from: window,
                initialName: entry.name,
                initialLatitude: String(entry.latitude),
                initialLongitude: String(entry.longitude),
                initialForwardEnabled: entry.forwardEnabled,
                initialReverseEnabled: entry.reverseEnabled,
                isEdit: true
            ) { name, lat, lng, forward, reverse in
                guard let idx = pointMapNewPoints.firstIndex(where: { $0.localID == localID }) else { return }
                pointMapNewPoints[idx] = PointMapPointDraftEntry(
                    localID: localID,
                    name: name,
                    latitude: lat,
                    longitude: lng,
                    forwardEnabled: forward,
                    reverseEnabled: reverse
                )
            }
        }
    }

    private func removePointMapEntry(_ ref: PointMapEntryRef) {
        switch ref {
        case .existing(let id):
            pointMapExistingPoints.removeAll { $0.id == id }
        case .new(let localID):
            pointMapNewPoints.removeAll { $0.localID == localID }
        }
    }

    private func deletePointMapEntries(_ refs: Set<PointMapEntryRef>) {
        for ref in refs {
            removePointMapEntry(ref)
        }
        pointMapListSelection.subtract(refs)
    }

    private func requestDeletePointMapEntries(_ refs: Set<PointMapEntryRef>) {
        guard !refs.isEmpty else { return }
        pendingPointMapDeletion = refs
        isPointMapDeletionConfirmationPresented = true
    }

    private var pointMapDeletionTitle: String {
        let count = pendingPointMapDeletion.count
        return count == 1
            ? "Are you sure you want to delete this point?"
            : "Are you sure you want to delete these \(count) points?"
    }

    // Two-way bindings from a row's checkboxes into the backing point arrays.
    private func pointMapForwardBinding(for ref: PointMapEntryRef) -> Binding<Bool> {
        Binding(
            get: { pointMapEntryFlags(for: ref).forward },
            set: { setPointMapEntryFlags(for: ref, forward: $0, reverse: nil) }
        )
    }

    private func pointMapReverseBinding(for ref: PointMapEntryRef) -> Binding<Bool> {
        Binding(
            get: { pointMapEntryFlags(for: ref).reverse },
            set: { setPointMapEntryFlags(for: ref, forward: nil, reverse: $0) }
        )
    }

    private func pointMapEntryFlags(for ref: PointMapEntryRef) -> (forward: Bool, reverse: Bool) {
        switch ref {
        case .existing(let id):
            guard let point = pointMapExistingPoints.first(where: { $0.id == id }) else { return (true, false) }
            return (point.forwardEnabled, point.reverseEnabled)
        case .new(let localID):
            guard let draft = pointMapNewPoints.first(where: { $0.localID == localID }) else { return (true, false) }
            return (draft.forwardEnabled, draft.reverseEnabled)
        }
    }

    private func setPointMapEntryFlags(for ref: PointMapEntryRef, forward: Bool?, reverse: Bool?) {
        switch ref {
        case .existing(let id):
            guard let index = pointMapExistingPoints.firstIndex(where: { $0.id == id }) else { return }
            if let forward { pointMapExistingPoints[index].forwardEnabled = forward }
            if let reverse { pointMapExistingPoints[index].reverseEnabled = reverse }
        case .new(let localID):
            guard let index = pointMapNewPoints.firstIndex(where: { $0.localID == localID }) else { return }
            if let forward { pointMapNewPoints[index].forwardEnabled = forward }
            if let reverse { pointMapNewPoints[index].reverseEnabled = reverse }
        }
    }

    // Bulk enable/disable a query direction across all selected points (used by the
    // points list's "Enable Queries" / "Disable Queries" context-menu submenus).
    private func setPointMapEntriesEnabled(_ refs: Set<PointMapEntryRef>, forward: Bool?, reverse: Bool?) {
        for ref in refs {
            setPointMapEntryFlags(for: ref, forward: forward, reverse: reverse)
        }
    }

    // MARK: - BoundaryMap editor

    private var boundaryMapEditor: some View {
        HStack(alignment: .top, spacing: 12) {
            boundaryMapMapPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            boundaryMapListPane
                .frame(width: 260)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .background {
            PointMapShortcutKeyHandler(
                shortcutSettings: shortcutSettings,
                onAddQuery: { isBoundaryMapPickerPresented = true }
            )
        }
    }

    private var boundaryMapMapPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Name:")
                    .font(.subheadline)
                TextField("", text: $boundaryMapTitle)
                    .textFieldStyle(.roundedBorder)
            }

            MapReader { proxy in
                ZStack {
                    Map(position: $boundaryMapCameraPosition) {
                        ForEach(boundaryMapDisplayEntries, id: \.id) { entry in
                            if let geo = boundaryMapGeometriesByBoundaryID[entry.boundaryID] {
                                ForEach(Array(geo.rings.enumerated()), id: \.offset) { _, polygonRings in
                                    if let outer = polygonRings.first, outer.count >= 3 {
                                        MapPolygon(coordinates: outer.map(\.clLocation))
                                            .foregroundStyle(.clear)
                                            .stroke(Color.red, lineWidth: 1.5)
                                    }
                                }
                            }
                        }
                    }
                    .onMapCameraChange(frequency: .continuous) { context in
                        boundaryMapCurrentRegion = context.region
                        boundaryMapSyncExplicitFieldsFromRegion()
                    }

                    MapRightClickContextMenu { localPoint in
                        boundaryMapContextMenuActions(at: localPoint, proxy: proxy)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }

            Toggle(isOn: $boundaryMapShowAllBoundariesInQuestion) {
                Text("Show all boundaries on the question side of each query")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)

            if mode == .edit {
                Toggle(isOn: $boundaryMapApplyCurrentViewport) {
                    Text("Set each query's default map location and zoom to current")
                        .font(.subheadline)
                }
                .toggleStyle(.checkbox)
            }

            DisclosureGroup("Advanced", isExpanded: $boundaryMapShowAdvanced) {
                HStack(spacing: 6) {
                    Text("Lat:")
                    TextField("", text: $boundaryMapExplicitLat)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 90)
                        .onSubmit(applyExplicitBoundaryMapViewport)
                    Text("Lng:")
                    TextField("", text: $boundaryMapExplicitLng)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 90)
                        .onSubmit(applyExplicitBoundaryMapViewport)
                    Text("Zoom:")
                    TextField("", text: $boundaryMapExplicitZoom)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 60)
                        .onSubmit(applyExplicitBoundaryMapViewport)
                    Button("Apply") {
                        applyExplicitBoundaryMapViewport()
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .font(.subheadline)
        }
    }

    private var boundaryMapListPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isBoundaryMapPickerPresented = true
            } label: {
                ShortcutLabel(title: "Add Boundary", action: .editorPointMapAddQuery)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .popover(isPresented: $isBoundaryMapPickerPresented, arrowEdge: .bottom) {
                BoundaryPickerPopoverView(
                    state: boundaryMapPickerState,
                    appDatabase: appDatabase,
                    onManage: {
                        isBoundaryMapPickerPresented = false
                        openWindow(id: "manage-boundaries")
                    }
                )
            }
            .onChange(of: boundaryMapPickerState.selectedIDs) { oldValue, newValue in
                reconcileBoundaryMapPickerSelection(old: oldValue, new: newValue)
            }

            Divider()

            Group {
                if boundaryMapDisplayEntries.isEmpty {
                    Text("No boundaries yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(selection: $boundaryMapListSelection) {
                        ForEach(boundaryMapDisplayEntries, id: \.id) { entry in
                            BoundaryMapEntryRow(
                                name: entry.name,
                                forwardEnabled: boundaryMapForwardBinding(for: entry.ref),
                                reverseEnabled: boundaryMapReverseBinding(for: entry.ref)
                            )
                            .tag(entry.ref)
                        }
                    }
                    .listStyle(.inset)
                    .contextMenu(forSelectionType: BoundaryMapEntryRef.self) { refs in
                        if !refs.isEmpty {
                            Button("Delete", role: .destructive) {
                                requestDeleteBoundaryMapEntries(refs)
                            }
                        }
                    }
                    .onDeleteCommand {
                        requestDeleteBoundaryMapEntries(boundaryMapListSelection)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }
            .alert(
                boundaryMapDeletionTitle,
                isPresented: $isBoundaryMapDeletionConfirmationPresented
            ) {
                Button("Delete", role: .destructive) {
                    let refs = pendingBoundaryMapDeletion
                    pendingBoundaryMapDeletion = []
                    deleteBoundaryMapEntries(refs)
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {
                    pendingBoundaryMapDeletion = []
                }
            } message: {
                Text("This action is irreversible.")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sort:")
                    .font(.subheadline)
                Picker("", selection: $boundaryMapSortMode) {
                    ForEach(BoundaryMapSortMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
    }

    private struct BoundaryMapDisplayEntry {
        let ref: BoundaryMapEntryRef
        let boundaryID: Int64
        let name: String
        let forwardEnabled: Bool
        let reverseEnabled: Bool
        var id: String { ref.id }
    }

    private var boundaryMapDisplayEntries: [BoundaryMapDisplayEntry] {
        var entries: [BoundaryMapDisplayEntry] = []
        for attached in boundaryMapExistingAttachments where !boundaryMapDeletedExistingIDs.contains(attached.id) {
            entries.append(BoundaryMapDisplayEntry(
                ref: .existing(attached.id),
                boundaryID: attached.boundaryID,
                name: attached.name,
                forwardEnabled: attached.forwardEnabled,
                reverseEnabled: attached.reverseEnabled
            ))
        }
        for draft in boundaryMapNewAttachments {
            entries.append(BoundaryMapDisplayEntry(
                ref: .new(draft.localID),
                boundaryID: draft.boundaryID,
                name: draft.name,
                forwardEnabled: draft.forwardEnabled,
                reverseEnabled: draft.reverseEnabled
            ))
        }
        switch boundaryMapSortMode {
        case .creation:
            return entries
        case .alphabetical:
            return entries.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private var boundaryMapGeometriesByBoundaryID: [Int64: ParsedMultiPolygon] {
        var map: [Int64: ParsedMultiPolygon] = [:]
        for geo in boundaryMapGeometries {
            map[geo.id] = geo.geometry
        }
        return map
    }

    private func boundaryMapSyncExplicitFieldsFromRegion() {
        let region = boundaryMapCurrentRegion
        boundaryMapExplicitLat = String(format: "%.6f", region.center.latitude)
        boundaryMapExplicitLng = String(format: "%.6f", region.center.longitude)
        let latDelta = max(region.span.latitudeDelta, 0.0001)
        let zoom = log2(360.0 / latDelta)
        boundaryMapExplicitZoom = String(format: "%.2f", zoom)
    }

    private func applyExplicitBoundaryMapViewport() {
        guard let lat = Double(boundaryMapExplicitLat.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lng = Double(boundaryMapExplicitLng.trimmingCharacters(in: .whitespacesAndNewlines)),
              let zoom = Double(boundaryMapExplicitZoom.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showToast(message: "Invalid viewport values.", style: .error)
            return
        }
        let clampedZoom = max(0.0, min(20.0, zoom))
        let delta = max(0.0001, 360.0 / pow(2.0, clampedZoom))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
        )
        boundaryMapCurrentRegion = region
        boundaryMapCameraPosition = .region(region)
    }

    private func resetBoundaryMapState() {
        boundaryMapTitle = ""
        boundaryMapExistingAttachments = []
        boundaryMapNewAttachments = []
        boundaryMapDeletedExistingIDs = []
        boundaryMapSortMode = .creation
        boundaryMapShowAdvanced = false
        boundaryMapShowAllBoundariesInQuestion = true
        boundaryMapApplyCurrentViewport = false
        boundaryMapLoadedDefaultCenterLat = nil
        boundaryMapLoadedDefaultCenterLng = nil
        boundaryMapLoadedDefaultZoom = nil
        let defaultRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
        )
        boundaryMapCurrentRegion = defaultRegion
        boundaryMapCameraPosition = .region(defaultRegion)
        boundaryMapSyncExplicitFieldsFromRegion()
        boundaryMapPickerState.selectedIDs = []
        boundaryMapPickerState.reload(appDatabase: appDatabase)
        boundaryMapGeometries = []
    }

    private func loadBoundaryMapInto(instance: BoundaryMapInstanceWithBoundaries) {
        boundaryMapTitle = instance.instance.title
        boundaryMapExistingAttachments = instance.attachments
        boundaryMapNewAttachments = []
        boundaryMapDeletedExistingIDs = []
        boundaryMapSortMode = .creation
        boundaryMapShowAdvanced = false
        boundaryMapShowAllBoundariesInQuestion = instance.instance.showAllBoundariesInQuestion
        boundaryMapApplyCurrentViewport = false
        boundaryMapLoadedDefaultCenterLat = instance.instance.defaultCenterLat
        boundaryMapLoadedDefaultCenterLng = instance.instance.defaultCenterLng
        boundaryMapLoadedDefaultZoom = instance.instance.defaultZoom
        let delta = max(0.0001, 360.0 / pow(2.0, max(0.0, min(20.0, instance.instance.defaultZoom))))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: instance.instance.defaultCenterLat, longitude: instance.instance.defaultCenterLng),
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
        )
        boundaryMapCurrentRegion = region
        boundaryMapCameraPosition = .region(region)
        boundaryMapSyncExplicitFieldsFromRegion()
        boundaryMapPickerState.selectedIDs = Set(instance.attachments.map(\.boundaryID))
        boundaryMapPickerState.reload(appDatabase: appDatabase)
        refreshBoundaryMapGeometries()
    }

    private func reconcileBoundaryMapPickerSelection(old: Set<Int64>, new: Set<Int64>) {
        let added = new.subtracting(old)
        let removed = old.subtracting(new)

        // Existing-attachment boundary IDs (excluding any already staged for deletion)
        let existingIDs: [Int64: Int64] = boundaryMapExistingAttachments.reduce(into: [:]) { acc, attached in
            acc[attached.boundaryID] = attached.id
        }

        for boundaryID in removed {
            if let attachmentID = existingIDs[boundaryID] {
                boundaryMapDeletedExistingIDs.insert(attachmentID)
            } else {
                boundaryMapNewAttachments.removeAll { $0.boundaryID == boundaryID }
            }
        }

        for boundaryID in added {
            if let attachmentID = existingIDs[boundaryID] {
                // User re-toggled an existing attachment back on — un-stage its deletion.
                boundaryMapDeletedExistingIDs.remove(attachmentID)
            } else {
                guard !boundaryMapNewAttachments.contains(where: { $0.boundaryID == boundaryID }) else { continue }
                let name = boundaryMapPickerState.options.first(where: { $0.id == boundaryID })?.boundary.name ?? ""
                boundaryMapNewAttachments.append(BoundaryMapAttachmentDraft(
                    localID: UUID(),
                    boundaryID: boundaryID,
                    name: name
                ))
            }
        }

        refreshBoundaryMapGeometries()
    }

    private func refreshBoundaryMapGeometries() {
        let displayedBoundaryIDs = Set(boundaryMapDisplayEntries.map(\.boundaryID))
        guard !displayedBoundaryIDs.isEmpty else {
            boundaryMapGeometries = []
            return
        }
        var geometries: [BoundaryGeometry] = []
        geometries.reserveCapacity(displayedBoundaryIDs.count)
        for option in boundaryMapPickerState.options where displayedBoundaryIDs.contains(option.id) {
            if let geo = try? appDatabase.fetchBoundaryGeometry(boundaryID: option.id) {
                geometries.append(BoundaryGeometry(
                    id: option.id,
                    name: option.boundary.name,
                    geometry: geo
                ))
            }
        }
        boundaryMapGeometries = geometries
    }

    private func boundaryMapContextMenuActions(at localPoint: CGPoint, proxy: MapProxy) -> [MapMenuAction] {
        guard let coord = proxy.convert(localPoint, from: .local) else { return [] }
        for entry in boundaryMapDisplayEntries.reversed() {
            guard let geometry = boundaryMapGeometriesByBoundaryID[entry.boundaryID] else { continue }
            if boundaryContains(coordinate: coord, geometry: geometry) {
                let ref = entry.ref
                return [MapMenuAction(title: "Delete") { removeBoundaryMapEntry(ref) }]
            }
        }
        return []
    }

    private func removeBoundaryMapEntry(_ ref: BoundaryMapEntryRef) {
        switch ref {
        case .existing(let id):
            guard let attached = boundaryMapExistingAttachments.first(where: { $0.id == id }) else { return }
            boundaryMapDeletedExistingIDs.insert(id)
            boundaryMapPickerState.selectedIDs.remove(attached.boundaryID)
        case .new(let localID):
            guard let draft = boundaryMapNewAttachments.first(where: { $0.localID == localID }) else { return }
            boundaryMapNewAttachments.removeAll { $0.localID == localID }
            boundaryMapPickerState.selectedIDs.remove(draft.boundaryID)
        }
        refreshBoundaryMapGeometries()
    }

    private func deleteBoundaryMapEntries(_ refs: Set<BoundaryMapEntryRef>) {
        for ref in refs {
            removeBoundaryMapEntry(ref)
        }
        boundaryMapListSelection.subtract(refs)
    }

    private func requestDeleteBoundaryMapEntries(_ refs: Set<BoundaryMapEntryRef>) {
        guard !refs.isEmpty else { return }
        pendingBoundaryMapDeletion = refs
        isBoundaryMapDeletionConfirmationPresented = true
    }

    private var boundaryMapDeletionTitle: String {
        let count = pendingBoundaryMapDeletion.count
        return count == 1
            ? "Are you sure you want to delete this boundary?"
            : "Are you sure you want to delete these \(count) boundaries?"
    }

    // Two-way bindings from a row's checkboxes into the backing attachment arrays.
    private func boundaryMapForwardBinding(for ref: BoundaryMapEntryRef) -> Binding<Bool> {
        Binding(
            get: { boundaryMapEntryFlags(for: ref).forward },
            set: { setBoundaryMapEntryFlags(for: ref, forward: $0, reverse: nil) }
        )
    }

    private func boundaryMapReverseBinding(for ref: BoundaryMapEntryRef) -> Binding<Bool> {
        Binding(
            get: { boundaryMapEntryFlags(for: ref).reverse },
            set: { setBoundaryMapEntryFlags(for: ref, forward: nil, reverse: $0) }
        )
    }

    private func boundaryMapEntryFlags(for ref: BoundaryMapEntryRef) -> (forward: Bool, reverse: Bool) {
        switch ref {
        case .existing(let id):
            guard let attached = boundaryMapExistingAttachments.first(where: { $0.id == id }) else { return (true, false) }
            return (attached.forwardEnabled, attached.reverseEnabled)
        case .new(let localID):
            guard let draft = boundaryMapNewAttachments.first(where: { $0.localID == localID }) else { return (true, false) }
            return (draft.forwardEnabled, draft.reverseEnabled)
        }
    }

    private func setBoundaryMapEntryFlags(for ref: BoundaryMapEntryRef, forward: Bool?, reverse: Bool?) {
        switch ref {
        case .existing(let id):
            guard let index = boundaryMapExistingAttachments.firstIndex(where: { $0.id == id }) else { return }
            if let forward { boundaryMapExistingAttachments[index].forwardEnabled = forward }
            if let reverse { boundaryMapExistingAttachments[index].reverseEnabled = reverse }
        case .new(let localID):
            guard let index = boundaryMapNewAttachments.firstIndex(where: { $0.localID == localID }) else { return }
            if let forward { boundaryMapNewAttachments[index].forwardEnabled = forward }
            if let reverse { boundaryMapNewAttachments[index].reverseEnabled = reverse }
        }
    }

    private var fieldsSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear
                        .frame(height: 0)
                        .id("fieldsSectionTop")

                    if selectedTypeID == nil {
                        Text("No types are available.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if fields.isEmpty {
                        Text("This type has no fields.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        fieldEditors
                    }

                    if isNodeTypeSelected {
                        NodeLinkFieldEditor(
                            appDatabase: appDatabase,
                            typeID: selectedTypeID ?? 0,
                            excludingInstanceID: loadedInstanceID,
                            linkFields: linkFields,
                            linkTargetsByLinkFieldID: $linkTargetsByLinkFieldID,
                            nodeSummariesByID: $nodeSummariesByID
                        )
                    }

                    if selectedTypeID != nil {
                        collectionChecklistSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: requestNonce) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("fieldsSectionTop", anchor: .top)
                }
            }
        }
    }

    private var queryTypesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Query Types")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if selectedTypeID == nil {
                        Text("No types are available.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if queryTypes.isEmpty {
                        Text("This type has no query types.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        queryTypeCheckboxList
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private var fieldEditors: some View {
        VStack(alignment: .leading, spacing: 12) {
            SwiftUI.ForEach(fields) { field in
                InstanceFieldEditor(
                    fieldName: field.name,
                    text: binding(for: field.id),
                    focusController: focusController,
                    fieldID: field.id,
                    isSticky: stickyFieldIDs.contains(field.id),
                    showStickyToggle: mode == .add,
                    onToggleSticky: {
                        if let selectedTypeID {
                            toggleSticky(typeID: selectedTypeID, fieldID: field.id)
                        }
                    },
                    onSubmit: submitInstance,
                    onRequestHyperlink: { textView in
                        hyperlinkSearchController.present(
                            appDatabase: appDatabase,
                            from: textView
                        )
                    },
                    onMoveToNextField: {
                        focusNextField(after: field.id)
                    },
                    onMoveToPreviousField: {
                        focusPreviousField(before: field.id)
                    }
                )
            }
        }
    }

    private var queryTypeCheckboxList: some View {
        let displayedQueryTypes = queryTypes.sorted { lhs, rhs in
            lhs.id < rhs.id
        }

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(displayedQueryTypes) { queryType in
                HStack(spacing: 12) {
                    Toggle(
                        queryType.name,
                        isOn: Binding(
                            get: { selectedQueryTypeIDs.contains(queryType.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedQueryTypeIDs.insert(queryType.id)
                                    if mode == .edit {
                                        queryIntervalsByQueryTypeID[queryType.id] = 0
                                    }
                                } else {
                                    selectedQueryTypeIDs.remove(queryType.id)
                                    queryIntervalsByQueryTypeID.removeValue(forKey: queryType.id)
                                }
                                if mode == .add, let typeID = selectedTypeID {
                                    try? appDatabase.setTypeQueryDefault(
                                        typeID: typeID,
                                        queryTypeID: queryType.id,
                                        isEnabled: isSelected
                                    )
                                }
                            }
                        )
                    )
                    .toggleStyle(.checkbox)

                    if mode == .edit, let loadedInstanceID {
                        Button {
                            queryPreviewWindowState.requestOpen(
                                instanceID: loadedInstanceID,
                                queryTypeID: queryType.id,
                                fieldValuesByName: liveFieldValuesByName()
                            )
                            openWindow(id: "query-preview")
                        } label: {
                            Image(systemName: "eye")
                                .foregroundStyle(.gray)
                        }
                        .buttonStyle(.plain)
                        .help("Preview")

                        if let interval = queryIntervalsByQueryTypeID[queryType.id] {
                            if interval == 0 {
                                Text("New")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.blue)
                            } else {
                                Text(formatStudyInterval(interval))
                                    .font(.subheadline)
                                    .foregroundStyle(interval < 86_400 ? Color.red : Color.green)

                                Button {
                                    resetQueryDueDate(instanceID: loadedInstanceID, queryTypeID: queryType.id)
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .foregroundStyle(.gray)
                                }
                                .buttonStyle(.plain)
                                .help("Reset Due Date")
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredCollectionItems: [CollectionChecklistItem] {
        let trimmedQuery = collectionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [CollectionChecklistItem]
        if trimmedQuery.isEmpty {
            let pinned = allCollectionItems.filter(\.isPinned)
            let unpinned = allCollectionItems.filter { !$0.isPinned }
            filtered = pinned + unpinned
        } else {
            filtered = allCollectionItems.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }
        return filtered
    }

    private var collectionChecklistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Collections")
                    .font(.headline)

                if !selectedCollectionIDs.isEmpty {
                    Text("(\(selectedCollectionIDs.count) selected)")
                        .font(.headline)
                        .foregroundStyle(.blue)
                }
            }

            CollectionSearchTextField(
                text: $collectionSearchQuery,
                focusController: focusController,
                onTab: { focusNextField(after: nil) },
                onBackTab: { focusPreviousField(before: nil) }
            )
            .frame(height: 22)

            if allCollectionItems.isEmpty {
                Text("No collections.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else if filteredCollectionItems.isEmpty {
                Text("No matching collections.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredCollectionItems) { item in
                            CollectionChecklistRow(
                                item: item,
                                isChecked: selectedCollectionIDs.contains(item.id),
                                onToggleCheck: { isChecked in
                                    if isChecked {
                                        selectedCollectionIDs.insert(item.id)
                                    } else {
                                        selectedCollectionIDs.remove(item.id)
                                    }
                                },
                                onTogglePin: {
                                    togglePin(for: item)
                                }
                            )
                        }
                    }
                    .background(ScrollBubbleBlocker())
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            HStack(spacing: 8) {
                Text("Max Interval:")
                    .font(.subheadline)

                TextField("", text: $maxIntervalText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onChange(of: maxIntervalText) { _, newValue in
                        let digitsOnly = newValue.filter(\.isNumber)
                        if digitsOnly != newValue {
                            maxIntervalText = digitsOnly
                        }
                    }

                Text("Leave blank for no max interval.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.top, 4)
        }
        .font(.subheadline)
    }

    private func togglePin(for item: CollectionChecklistItem) {
        guard let selectedTypeID else { return }
        let newPinned = !item.isPinned
        do {
            try appDatabase.setPinnedCollection(typeID: selectedTypeID, collectionID: item.id, isPinned: newPinned)
            if let index = allCollectionItems.firstIndex(where: { $0.id == item.id }) {
                allCollectionItems[index] = CollectionChecklistItem(
                    id: item.id,
                    name: item.name,
                    isPinned: newPinned
                )
            }
        } catch {
            showToast(message: "Failed to update pin.", style: .error)
        }
    }

    @MainActor
    private func loadCollectionItems() {
        guard let selectedTypeID else {
            allCollectionItems = []
            return
        }
        do {
            allCollectionItems = try appDatabase.fetchCollectionChecklistItems(forTypeID: selectedTypeID)
        } catch {
            allCollectionItems = []
        }
    }

    @MainActor
    private func loadInitialData() async {
        do {
            types = try appDatabase.fetchTypesOrderedByID()
            if mode == .edit, let requestedInstanceID {
                await loadInstance(instanceID: requestedInstanceID)
            } else if mode == .add, let requestedDuplicateSourceInstanceID {
                await loadInstanceForDuplication(sourceInstanceID: requestedDuplicateSourceInstanceID)
            } else {
                await applyRequestedTypeSelection()
            }
        } catch {
            showToast(message: "Failed to load types.", style: .error)
            types = []
            selectedTypeID = nil
            loadedTypeID = nil
            loadedInstanceID = nil
            fields = []
            queryTypes = []
            selectedQueryTypeIDs = []
            fieldValues = [:]
        }
    }

    @MainActor
    private func loadInstanceForDuplication(sourceInstanceID: Int64) async {
        do {
            let editorData = try appDatabase.fetchInstanceEditorData(instanceID: sourceInstanceID)
            fields = try appDatabase.fetchFieldsForDisplay(forTypeID: editorData.typeID)
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: editorData.typeID)
            stickyFieldIDs = try appDatabase.fetchStickyFieldIDs(forTypeID: editorData.typeID)
            selectedQueryTypeIDs = editorData.enabledQueryTypeIDs
            fieldValues = Dictionary(
                uniqueKeysWithValues: fields.map { field in
                    (field.id, editorData.fieldValuesByFieldID[field.id] ?? "")
                }
            )
            selectedCollectionIDs = try appDatabase.fetchCollectionIDs(forInstanceID: sourceInstanceID)
            queryIntervalsByQueryTypeID = [:]
            collectionSearchQuery = ""
            maxIntervalText = ""
            loadedTypeID = editorData.typeID
            loadedInstanceID = nil
            selectedTypeID = editorData.typeID
            loadCollectionItems()
            focusController.reset(with: fields.map(\.id))
            focusController.focusField(fields.first?.id)
        } catch {
            print("Failed to load instance for duplication: \(error)")
            await applyRequestedTypeSelection()
            showToast(message: "Failed to load instance to duplicate.", style: .error)
        }
    }

    @MainActor
    private func applyRequestedTypeSelection() async {
        guard !types.isEmpty else {
            selectedTypeID = nil
            loadedTypeID = nil
            loadedInstanceID = nil
            fields = []
            queryTypes = []
            selectedQueryTypeIDs = []
            fieldValues = [:]
            return
        }

        let resolvedTypeID = if let requestedTypeID,
                                types.contains(where: { $0.id == requestedTypeID }) {
            requestedTypeID
        } else {
            types[0].id
        }

        if selectedTypeID != resolvedTypeID {
            selectedTypeID = resolvedTypeID
        } else {
            await loadFields(for: resolvedTypeID)
        }
    }

    @MainActor
    private func loadFields(for typeID: Int64?) async {
        guard let typeID else {
            fields = []
            loadedTypeID = nil
            loadedInstanceID = nil
            queryTypes = []
            selectedQueryTypeIDs = []
            fieldValues = [:]
            allCollectionItems = []
            selectedCollectionIDs = []
            collectionSearchQuery = ""
            stickyFieldIDs = []
            maxIntervalText = ""
            return
        }

        do {
            let didChangeType = loadedTypeID != typeID
            fields = try appDatabase.fetchFieldsForDisplay(forTypeID: typeID)
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: typeID)
            stickyFieldIDs = try appDatabase.fetchStickyFieldIDs(forTypeID: typeID)
            if let selectedType = types.first(where: { $0.id == typeID }), selectedType.isNode {
                linkFields = try appDatabase.fetchLinkFields(forTypeID: typeID)
            } else {
                linkFields = []
            }
            if didChangeType {
                linkTargetsByLinkFieldID = [:]
                nodeSummariesByID = [:]
                let availableQueryTypeIDs = queryTypes.map(\.id)
                selectedQueryTypeIDs = (try? appDatabase.resolveTypeQueryDefaultSelection(
                    forTypeID: typeID,
                    availableQueryTypeIDs: availableQueryTypeIDs
                )) ?? Set(availableQueryTypeIDs)
                selectedCollectionIDs = []
                collectionSearchQuery = ""
                maxIntervalText = ""
                if let selectedType = types.first(where: { $0.id == typeID }),
                   selectedType.isBuiltin, selectedType.name == POINTMAP_TYPE_NAME {
                    resetPointMapState()
                }
                if let selectedType = types.first(where: { $0.id == typeID }),
                   selectedType.isBuiltin, selectedType.name == BOUNDARYMAP_TYPE_NAME {
                    resetBoundaryMapState()
                }
            } else {
                selectedQueryTypeIDs = selectedQueryTypeIDs.intersection(Set(queryTypes.map(\.id)))
            }
            fieldValues = Dictionary(
                uniqueKeysWithValues: fields.map { field in
                    (field.id, fieldValues[field.id] ?? "")
                }
            )
            loadedTypeID = typeID
            loadedInstanceID = nil
            focusController.reset(with: fields.map(\.id))
            focusController.focusField(fields.first?.id)
            loadCollectionItems()
        } catch {
            fields = []
            loadedTypeID = nil
            loadedInstanceID = nil
            queryTypes = []
            selectedQueryTypeIDs = []
            fieldValues = [:]
            allCollectionItems = []
            selectedCollectionIDs = []
            stickyFieldIDs = []
            focusController.reset(with: [])
            focusController.focusField(nil)
            showToast(message: "Failed to load fields.", style: .error)
        }
    }

    @MainActor
    private func loadInstance(instanceID: Int64) async {
        do {
            if let pointMap = try appDatabase.fetchPointMapInstance(instanceID: instanceID),
               let pointMapTypeID = types.first(where: { $0.isBuiltin && $0.name == POINTMAP_TYPE_NAME })?.id {
                fields = []
                queryTypes = []
                selectedTypeID = pointMapTypeID
                loadedTypeID = pointMapTypeID
                loadedInstanceID = instanceID
                selectedQueryTypeIDs = []
                fieldValues = [:]
                linkFields = []
                linkTargetsByLinkFieldID = [:]
                nodeSummariesByID = [:]
                selectedCollectionIDs = try appDatabase.fetchCollectionIDs(forInstanceID: instanceID)
                stickyFieldIDs = []
                collectionSearchQuery = ""
                maxIntervalText = ""
                loadCollectionItems()
                focusController.reset(with: [])
                focusController.focusField(nil)
                loadPointMapInto(instance: pointMap)
                if let autoEditPointID = requestedAutoEditPointID,
                   pointMap.points.contains(where: { $0.id == autoEditPointID }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        presentEditPointPopup(for: .existing(autoEditPointID))
                    }
                }
                return
            }

            if let boundaryMap = try appDatabase.fetchBoundaryMapInstance(instanceID: instanceID),
               let boundaryMapTypeID = types.first(where: { $0.isBuiltin && $0.name == BOUNDARYMAP_TYPE_NAME })?.id {
                fields = []
                queryTypes = []
                selectedTypeID = boundaryMapTypeID
                loadedTypeID = boundaryMapTypeID
                loadedInstanceID = instanceID
                selectedQueryTypeIDs = []
                fieldValues = [:]
                linkFields = []
                linkTargetsByLinkFieldID = [:]
                nodeSummariesByID = [:]
                selectedCollectionIDs = try appDatabase.fetchCollectionIDs(forInstanceID: instanceID)
                stickyFieldIDs = []
                collectionSearchQuery = ""
                maxIntervalText = ""
                loadCollectionItems()
                focusController.reset(with: [])
                focusController.focusField(nil)
                loadBoundaryMapInto(instance: boundaryMap)
                return
            }

            let editorData = try appDatabase.fetchInstanceEditorData(instanceID: instanceID)
            fields = try appDatabase.fetchFieldsForDisplay(forTypeID: editorData.typeID)
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: editorData.typeID)
            if types.first(where: { $0.id == editorData.typeID })?.isNode == true {
                linkFields = try appDatabase.fetchLinkFields(forTypeID: editorData.typeID)
                linkTargetsByLinkFieldID = editorData.linkTargetsByLinkFieldID
                nodeSummariesByID = editorData.linkedNodeSummaries
            } else {
                linkFields = []
                linkTargetsByLinkFieldID = [:]
                nodeSummariesByID = [:]
            }
            selectedTypeID = editorData.typeID
            loadedTypeID = editorData.typeID
            loadedInstanceID = instanceID
            selectedQueryTypeIDs = editorData.enabledQueryTypeIDs
            fieldValues = Dictionary(
                uniqueKeysWithValues: fields.map { field in
                    (field.id, editorData.fieldValuesByFieldID[field.id] ?? "")
                }
            )
            selectedCollectionIDs = try appDatabase.fetchCollectionIDs(forInstanceID: instanceID)
            stickyFieldIDs = try appDatabase.fetchStickyFieldIDs(forTypeID: editorData.typeID)
            queryIntervalsByQueryTypeID = try appDatabase.fetchQueryIntervals(forInstanceID: instanceID)
            collectionSearchQuery = ""
            maxIntervalText = editorData.maxInterval.map(String.init) ?? ""
            loadCollectionItems()
            focusController.reset(with: fields.map(\.id))
            focusController.focusField(fields.first?.id)
        } catch {
            print("Failed to load instance editor data: \(error)")
            fields = []
            loadedTypeID = nil
            loadedInstanceID = nil
            queryTypes = []
            selectedQueryTypeIDs = []
            fieldValues = [:]
            allCollectionItems = []
            selectedCollectionIDs = []
            stickyFieldIDs = []
            queryIntervalsByQueryTypeID = [:]
            focusController.reset(with: [])
            focusController.focusField(nil)
            showToast(message: "Failed to load instance.", style: .error)
        }
    }

    @MainActor
    private func submitCurrentInstance() async {
        guard let selectedTypeID else { return }

        if isPointMapSelected {
            await submitPointMapInstance(typeID: selectedTypeID)
            return
        }

        if isBoundaryMapSelected {
            await submitBoundaryMapInstance(typeID: selectedTypeID)
            return
        }

        let parsedMaxInterval: Int64? = Int64(maxIntervalText)

        do {
            switch mode {
            case .add:
                let instanceID = try appDatabase.makeInstance(
                    forTypeID: selectedTypeID,
                    fieldValuesByFieldID: fieldValues,
                    queryTypeIDs: selectedQueryTypeIDs,
                    linksByLinkFieldID: isNodeTypeSelected ? linkTargetsByLinkFieldID : [:]
                )
                if !selectedCollectionIDs.isEmpty {
                    try appDatabase.setInstanceCollections(
                        instanceID: instanceID,
                        collectionIDs: selectedCollectionIDs
                    )
                }
                if parsedMaxInterval != nil {
                    try appDatabase.setMaxInterval(
                        forInstanceID: instanceID,
                        maxInterval: parsedMaxInterval
                    )
                }
                onAddSaved?(selectedTypeID)
                fieldValues = Dictionary(
                    uniqueKeysWithValues: fields.map { field in
                        let preserved = stickyFieldIDs.contains(field.id) ? fieldValues[field.id] ?? "" : ""
                        return (field.id, preserved)
                    }
                )
                // Links are not sticky; clear them for the next add.
                linkTargetsByLinkFieldID = [:]
                focusController.focusField(fields.first?.id)
                showToast(message: "Instance added successfully.", style: .success)
            case .edit:
                guard let loadedInstanceID else { return }
                try appDatabase.updateInstance(
                    instanceID: loadedInstanceID,
                    fieldValuesByFieldID: fieldValues,
                    queryTypeIDs: selectedQueryTypeIDs,
                    linksByLinkFieldID: isNodeTypeSelected ? linkTargetsByLinkFieldID : [:]
                )
                try appDatabase.setInstanceCollections(
                    instanceID: loadedInstanceID,
                    collectionIDs: selectedCollectionIDs
                )
                try appDatabase.setMaxInterval(
                    forInstanceID: loadedInstanceID,
                    maxInterval: parsedMaxInterval
                )
                onEditSaved?(loadedInstanceID)
                dismiss()
            }
        } catch {
            switch mode {
            case .add:
                showToast(message: "Failed to add instance.", style: .error)
            case .edit:
                showToast(message: "Failed to save changes.", style: .error)
            }
        }
    }

    @MainActor
    private func submitPointMapInstance(typeID: Int64) async {
        let title = pointMapTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = pointMapCurrentRegion
        let latDelta = max(region.span.latitudeDelta, 0.0001)
        let zoom = log2(360.0 / latDelta)
        let drafts = pointMapNewPoints.map { entry in
            AppDatabase.PointMapPointDraft(
                name: entry.name,
                latitude: entry.latitude,
                longitude: entry.longitude,
                forwardEnabled: entry.forwardEnabled,
                reverseEnabled: entry.reverseEnabled
            )
        }

        let boundaryIDs = Array(boundaryPickerState.selectedIDs)
        do {
            switch mode {
            case .add:
                let instanceID = try appDatabase.makePointMapInstance(
                    title: title,
                    defaultCenterLat: region.center.latitude,
                    defaultCenterLng: region.center.longitude,
                    defaultZoom: zoom,
                    showAllPointsInQuestion: pointMapShowAllPointsInQuestion,
                    points: drafts,
                    boundaryIDs: boundaryIDs
                )
                if !selectedCollectionIDs.isEmpty {
                    try appDatabase.setInstanceCollections(
                        instanceID: instanceID,
                        collectionIDs: selectedCollectionIDs
                    )
                }
                onAddSaved?(typeID)
                resetPointMapState()
                showToast(message: "PointMap added successfully.", style: .success)
            case .edit:
                guard let loadedInstanceID else { return }
                let saveLat: Double
                let saveLng: Double
                let saveZoom: Double
                if pointMapApplyCurrentViewport {
                    saveLat = region.center.latitude
                    saveLng = region.center.longitude
                    saveZoom = zoom
                } else {
                    saveLat = pointMapLoadedDefaultCenterLat ?? region.center.latitude
                    saveLng = pointMapLoadedDefaultCenterLng ?? region.center.longitude
                    saveZoom = pointMapLoadedDefaultZoom ?? zoom
                }
                try appDatabase.updatePointMapInstance(
                    instanceID: loadedInstanceID,
                    title: title,
                    defaultCenterLat: saveLat,
                    defaultCenterLng: saveLng,
                    defaultZoom: saveZoom,
                    showAllPointsInQuestion: pointMapShowAllPointsInQuestion,
                    existingPoints: pointMapExistingPoints,
                    newPoints: drafts,
                    boundaryIDs: boundaryIDs
                )
                try appDatabase.setInstanceCollections(
                    instanceID: loadedInstanceID,
                    collectionIDs: selectedCollectionIDs
                )
                onEditSaved?(loadedInstanceID)
                dismiss()
            }
        } catch {
            switch mode {
            case .add:
                showToast(message: "Failed to add PointMap.", style: .error)
            case .edit:
                showToast(message: "Failed to save changes.", style: .error)
            }
        }
    }

    @MainActor
    private func submitBoundaryMapInstance(typeID: Int64) async {
        let title = boundaryMapTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = boundaryMapCurrentRegion
        let latDelta = max(region.span.latitudeDelta, 0.0001)
        let zoom = log2(360.0 / latDelta)
        let newBoundaries = boundaryMapNewAttachments.map { draft in
            AppDatabase.BoundaryMapBoundaryDraft(
                boundaryID: draft.boundaryID,
                forwardEnabled: draft.forwardEnabled,
                reverseEnabled: draft.reverseEnabled
            )
        }

        do {
            switch mode {
            case .add:
                let instanceID = try appDatabase.makeBoundaryMapInstance(
                    title: title,
                    defaultCenterLat: region.center.latitude,
                    defaultCenterLng: region.center.longitude,
                    defaultZoom: zoom,
                    showAllBoundariesInQuestion: boundaryMapShowAllBoundariesInQuestion,
                    boundaries: newBoundaries
                )
                if !selectedCollectionIDs.isEmpty {
                    try appDatabase.setInstanceCollections(
                        instanceID: instanceID,
                        collectionIDs: selectedCollectionIDs
                    )
                }
                onAddSaved?(typeID)
                resetBoundaryMapState()
                showToast(message: "BoundaryMap added successfully.", style: .success)
            case .edit:
                guard let loadedInstanceID else { return }
                let saveLat: Double
                let saveLng: Double
                let saveZoom: Double
                if boundaryMapApplyCurrentViewport {
                    saveLat = region.center.latitude
                    saveLng = region.center.longitude
                    saveZoom = zoom
                } else {
                    saveLat = boundaryMapLoadedDefaultCenterLat ?? region.center.latitude
                    saveLng = boundaryMapLoadedDefaultCenterLng ?? region.center.longitude
                    saveZoom = boundaryMapLoadedDefaultZoom ?? zoom
                }
                let keptExistingAttachments = boundaryMapExistingAttachments
                    .filter { !boundaryMapDeletedExistingIDs.contains($0.id) }
                try appDatabase.updateBoundaryMapInstance(
                    instanceID: loadedInstanceID,
                    title: title,
                    defaultCenterLat: saveLat,
                    defaultCenterLng: saveLng,
                    defaultZoom: saveZoom,
                    showAllBoundariesInQuestion: boundaryMapShowAllBoundariesInQuestion,
                    existingAttachments: keptExistingAttachments,
                    newBoundaries: newBoundaries
                )
                try appDatabase.setInstanceCollections(
                    instanceID: loadedInstanceID,
                    collectionIDs: selectedCollectionIDs
                )
                onEditSaved?(loadedInstanceID)
                dismiss()
            }
        } catch {
            switch mode {
            case .add:
                showToast(message: "Failed to add BoundaryMap.", style: .error)
            case .edit:
                showToast(message: "Failed to save changes.", style: .error)
            }
        }
    }

    private func binding(for fieldID: Int64) -> Binding<String> {
        Binding(
            get: { fieldValues[fieldID, default: ""] },
            set: { fieldValues[fieldID] = $0 }
        )
    }

    private func submitInstance() {
        guard canSubmit else { return }

        Task {
            await submitCurrentInstance()
        }
    }

    private func shouldConfirmDiscard() -> Bool {
        guard mode == .add else { return false }
        if isPointMapSelected {
            return !pointMapNewPoints.isEmpty
        }
        if isBoundaryMapSelected {
            return !boundaryMapNewAttachments.isEmpty
        }
        return fields.contains { field in
            guard !stickyFieldIDs.contains(field.id) else { return false }
            let value = fieldValues[field.id] ?? ""
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func attemptDismiss() {
        guard shouldConfirmDiscard() else {
            closeInterceptor.bypassNextClose = true
            dismiss()
            return
        }
        if let window = NSApp.keyWindow {
            presentDiscardConfirmation(on: window)
        } else {
            closeInterceptor.bypassNextClose = true
            dismiss()
        }
    }

    private func presentDiscardConfirmation(on window: NSWindow) {
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
            closeInterceptor.bypassNextClose = true
            window.close()
        }
    }

    private func handleCommandS() {
        if mode == .edit {
            submitInstance()
            return
        }
        guard let selectedTypeID,
              let fieldID = focusController.activeFieldID ?? focusController.lastFocusedFieldID else { return }
        toggleSticky(typeID: selectedTypeID, fieldID: fieldID)
    }

    private func copyInstanceIDToClipboard(_ instanceID: Int64) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(instanceID), forType: .string)
    }

    private func copyInstanceLinkToClipboard() {
        guard let loadedInstanceID else { return }
        let link = #"<a href="id:\#(loadedInstanceID)"></a>"#
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        showToast(message: "Link copied", style: .success)
    }

    private func liveFieldValuesByName() -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { field in
            (field.name, fieldValues[field.id] ?? "")
        })
    }

    private func previewTopmostCheckedQueryType() {
        guard mode == .edit, let loadedInstanceID else { return }
        let displayedQueryTypes = queryTypes.sorted { $0.id < $1.id }
        guard let topmost = displayedQueryTypes.first(where: { selectedQueryTypeIDs.contains($0.id) }) else {
            return
        }
        queryPreviewWindowState.requestOpen(
            instanceID: loadedInstanceID,
            queryTypeID: topmost.id,
            fieldValuesByName: liveFieldValuesByName()
        )
        openWindow(id: "query-preview")
    }

    private func wrapFocusedSelection(openTag: String, closeTag: String) {
        _ = focusController.wrapFocusedSelection(openTag: openTag, closeTag: closeTag)
    }

    private func presentTypePicker() {
        guard mode == .add, !types.isEmpty else { return }
        let currentWindow = NSApp.keyWindow
        typePickerController.present(
            types: types,
            currentTypeID: selectedTypeID,
            from: currentWindow
        ) { [self] typeID in
            selectedTypeID = typeID
        }
    }

    @MainActor
    private func insertImageIntoCurrentField() {
        guard selectedTypeID != nil else {
            showToast(message: "Select a type before inserting an image.", style: .error)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Image"
        panel.message = "Select an image to insert."
        panel.prompt = "Insert Image (\(shortcutSettings.binding(for: .editorInsertImage).displayString))"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let imageURL = panel.url else { return }

        do {
            try appDatabase.grantImageFileAccess(fileURL: imageURL)
        } catch {
            print("Failed to store image access: \(error)")
            showToast(message: "Failed to access the selected image.", style: .error)
            return
        }

        let imageTag = #"<img src="\#(imageURL.absoluteString)">"#
        guard focusController.insertTextAtFocusedField(imageTag) else {
            showToast(message: "Select a field before inserting an image.", style: .error)
            return
        }
    }

    private func toggleSticky(typeID: Int64, fieldID: Int64) {
        let newSticky = !stickyFieldIDs.contains(fieldID)
        do {
            try appDatabase.setStickyField(typeID: typeID, fieldID: fieldID, isSticky: newSticky)
            if newSticky {
                stickyFieldIDs.insert(fieldID)
            } else {
                stickyFieldIDs.remove(fieldID)
            }
        } catch {
            showToast(message: "Failed to update sticky field.", style: .error)
        }
    }

    private func focusNextField(after fieldID: Int64?) {
        guard !fields.isEmpty else { return }

        if fieldID == nil {
            focusController.focusField(fields.first?.id)
            return
        }

        guard let currentIndex = fields.firstIndex(where: { $0.id == fieldID }) else {
            focusController.focusField(fields.first?.id)
            return
        }

        let nextIndex = fields.index(after: currentIndex)
        if nextIndex < fields.endIndex {
            focusController.focusField(fields[nextIndex].id)
        } else {
            focusController.focusCollectionSearch()
        }
    }

    private func focusPreviousField(before fieldID: Int64?) {
        guard !fields.isEmpty else { return }

        if fieldID == nil {
            focusController.focusField(fields.last?.id)
            return
        }

        guard let currentIndex = fields.firstIndex(where: { $0.id == fieldID }) else {
            focusController.focusField(fields.last?.id)
            return
        }

        if currentIndex > fields.startIndex {
            focusController.focusField(fields[fields.index(before: currentIndex)].id)
        } else {
            focusController.focusCollectionSearch()
        }
    }

    @MainActor
    private func resetQueryDueDate(instanceID: Int64, queryTypeID: Int64) {
        do {
            try appDatabase.resetQueryDueDates(
                instanceIDAndQueryTypeIDPairs: [(instanceID: instanceID, queryTypeID: queryTypeID)]
            )
            queryIntervalsByQueryTypeID[queryTypeID] = 0
        } catch {
            print("Failed to reset query due date: \(error)")
            showToast(message: "Failed to reset query due date.", style: .error)
        }
    }

    @MainActor
    private func deleteCurrentInstance() {
        guard let loadedInstanceID else { return }
        do {
            try appDatabase.deleteInstance(instanceID: loadedInstanceID)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            dismiss()
        } catch {
            showToast(message: "Failed to delete instance.", style: .error)
        }
    }

    @MainActor
    private func showToast(message: String, style: ToastStyle) {
        toastTask?.cancel()
        toast = ToastMessage(message: message, style: style)

        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

private struct EditorPreviewShortcutHandler: NSViewRepresentable {
    let shortcutSettings: ShortcutSettings
    let onPreviewTopQuery: () -> Void

    func makeNSView(context: Context) -> KeyHandlingView {
        let view = KeyHandlingView()
        view.shortcutSettings = shortcutSettings
        view.onPreviewTopQuery = onPreviewTopQuery
        return view
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        nsView.shortcutSettings = shortcutSettings
        nsView.onPreviewTopQuery = onPreviewTopQuery
    }

    final class KeyHandlingView: NSView {
        var shortcutSettings: ShortcutSettings?
        var onPreviewTopQuery: (() -> Void)?

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.window === self.window,
                      let settings = self.shortcutSettings else {
                    return event
                }

                if settings.binding(for: .editorPreviewTopQueryType).matches(event) {
                    self.onPreviewTopQuery?()
                    return nil
                }

                return event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

private struct PointMapShortcutKeyHandler: NSViewRepresentable {
    let shortcutSettings: ShortcutSettings
    let onAddQuery: () -> Void

    func makeNSView(context: Context) -> KeyHandlingView {
        let view = KeyHandlingView()
        view.shortcutSettings = shortcutSettings
        view.onAddQuery = onAddQuery
        return view
    }

    func updateNSView(_ nsView: KeyHandlingView, context: Context) {
        nsView.shortcutSettings = shortcutSettings
        nsView.onAddQuery = onAddQuery
    }

    final class KeyHandlingView: NSView {
        var shortcutSettings: ShortcutSettings?
        var onAddQuery: (() -> Void)?

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.window === self.window,
                      let settings = self.shortcutSettings else {
                    return event
                }

                if event.window?.firstResponder is NSText {
                    return event
                }

                if settings.binding(for: .editorPointMapAddQuery).matches(event) {
                    self.onAddQuery?()
                    return nil
                }

                return event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
