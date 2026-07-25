//
//  InstanceEditorWindowView.swift
//  Memor
//
//  Core editor body shared by the Add Instance and Edit Instance windows.
//

import AppKit
import Combine
import CoreLocation
import GRDB
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
    @ObservedObject var draft: InstanceEditorDraft
    let requestedInstanceID: Int64?
    var requestedAutoEditPointID: Int64? = nil
    let requestNonce: UUID
    // Add mode only: bumped each time the Add Instance window is opened, so the
    // field area scrolls back to the top (the editor view survives window reopen).
    var openNonce: UUID? = nil
    let dismiss: DismissAction
    let onEditSaved: ((Int64) -> Void)?
    let onAddSaved: ((Int64) -> Void)?
    let onTypeChanged: ((Int64) -> Void)?

    @State private var types: [FlashcardType] = []
    @State private var isInitialLoadComplete = false
    // Set when the user picks a type via the ⌘T picker, so loadFields can focus
    // the first field editor for Object types once the new fields have rendered.
    @State private var shouldFocusFirstFieldAfterTypePick = false
    @State private var toast: ToastMessage?
    @State private var toastTask: Task<Void, Never>?
    @State private var allCollectionItems: [CollectionChecklistItem] = []
    @State private var collectionSearchQuery = ""
    @State private var collectionsScrollNonce = UUID()
    @State private var addScrollNonce = UUID()   // bumped after an add to reset field scroll
    @State private var highlightedCollectionID: Int64?   // C; nil = none
    @StateObject private var focusController = AddInstanceFieldFocusController()
    @StateObject private var hyperlinkSearchController = HyperlinkSearchController()
    @StateObject private var typePickerController = TypePickerController()
    @StateObject private var tableSizePickerController = TableSizePickerController()
    @StateObject private var advancedSettingsController = AdvancedSettingsController()

    // Deletion confirmations for the map query lists
    @State private var pendingPointMapDeletion: Set<PointMapEntryRef> = []
    @State private var isPointMapDeletionConfirmationPresented = false
    @State private var pendingBoundaryMapDeletion: Set<BoundaryMapEntryRef> = []
    @State private var isBoundaryMapDeletionConfirmationPresented = false

    // Confirmation for deleting the whole instance being edited (edit mode only).
    @State private var isInstanceDeletionConfirmationPresented = false
    @State private var instanceDeletionMessage = ""

    // Transient map presentation state (per-mounted-editor; per-instance map data lives on the draft)
    @State private var pointMapHoveredEntryID: String?
    @State private var pointMapMapSelection: String?
    @State private var pointMapListSelection: Set<PointMapEntryRef> = []
    @State private var boundaryMapListSelection: Set<BoundaryMapEntryRef> = []
    @StateObject private var pointMapPointController = AddPointPopupController()
    @StateObject private var movePointsPickerController = PickerPanelController()
    @State private var isBoundaryPickerPresented = false
    @State private var isIDCopyButtonHovered = false
    @State private var isBoundaryMapPickerPresented = false

    private var selectedType: FlashcardType? {
        guard draft.selectedTypeID != nil else { return nil }
        return types.first(where: { $0.id == draft.selectedTypeID })
    }

    private var isPointMapSelected: Bool {
        guard let selectedType else { return false }
        return selectedType.isBuiltin && selectedType.name == POINTMAP_TYPE_NAME
    }

    private var isBoundaryMapSelected: Bool {
        guard let selectedType else { return false }
        return selectedType.isBuiltin && selectedType.name == BOUNDARYMAP_TYPE_NAME
    }

    private var isPersonSelected: Bool {
        selectedType?.isPerson ?? false
    }

    /// A plain Object type: a real type that is not a built-in Map or Person.
    private var isObjectTypeSelected: Bool {
        selectedType != nil && !isPointMapSelected && !isBoundaryMapSelected && !isPersonSelected
    }

    /// Mirrors the selected type's map-kind and name onto the draft so it can
    /// compute isDirty/tabTitle without access to the window-level `types` list.
    private func syncDraftTypeFlags() {
        draft.selectedTypeIsPointMap = isPointMapSelected
        draft.selectedTypeIsBoundaryMap = isBoundaryMapSelected
        draft.selectedTypeIsPerson = isPersonSelected
        draft.selectedTypeName = selectedType?.name
    }

    private var canSubmit: Bool {
        guard draft.selectedTypeID != nil else { return false }
        if isPointMapSelected {
            return !draft.pointMapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isBoundaryMapSelected {
            return !draft.boundaryMapTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasFieldValue = draft.fields.contains { field in
            guard field.fieldType != .sex else { return false }
            let value = draft.fieldValues[field.id] ?? ""
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// Escape closes a showing map add-popup (boundaries picker or Add Point panel)
    /// in preference to the whole window; only a bare Escape dismisses the editor.
    private func handleEscape() {
        // A person/office picker popover is open (relationship slots,
        // predecessors/successors, Add Office): close it, not the window.
        if PickerPopoverEscapeRegistry.shared.closeTopmost() {
            return
        }
        if isBoundaryPickerPresented {
            isBoundaryPickerPresented = false
            return
        }
        if isBoundaryMapPickerPresented {
            isBoundaryMapPickerPresented = false
            return
        }
        if pointMapPointController.isPresented {
            pointMapPointController.close()
            return
        }
        if movePointsPickerController.isPresented {
            movePointsPickerController.close()
            return
        }
        dismiss()
    }

    private var keyCommandHandler: some View {
        WindowKeyCommandHandler(
            onEscape: { handleEscape() },
            onCommandReturn: submitInstance,
            onCommandS: handleCommandS,
            onCommandB: { wrapFocusedSelection(openTag: "<b>", closeTag: "</b>") },
            onCommandI: { wrapFocusedSelection(openTag: "<i>", closeTag: "</i>") },
            onCommandO: insertImageIntoCurrentField,
            onCommandJ: { wrapFocusedSelection(openTag: "<e>", closeTag: "</e>") },
            onCommandL: copyInstanceLinkToClipboard,
            onCommandT: mode == .add ? { presentTypePicker() } : nil,
            onFocusCollectionSearch: {
                collectionsScrollNonce = UUID()
                focusController.focusCollectionSearch(placingCaretAtEnd: true)
            },
            shortcutSettings: shortcutSettings
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            typePicker
                .padding(.bottom, 12)

            editorPanels
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if mode == .edit, draft.loadedInstanceID != nil {
                    Button("Delete", role: .destructive) {
                        // Computed once here, not in the alert body — the Person
                        // consequences line runs a DB query.
                        instanceDeletionMessage = computedInstanceDeletionMessage
                        isInstanceDeletionConfirmationPresented = true
                    }
                    .tint(.red)
                }

                if draft.selectedTypeID != nil {
                    Button("Advanced Settings") {
                        presentAdvancedSettings()
                    }
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
                Text(instanceDeletionMessage)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(minWidth: 760, minHeight: 420)
        .background { keyCommandHandler }
        .task {
            await loadInitialData()
        }
        .onChange(of: draft.selectedTypeID) { _, newValue in
            guard mode == .add else { return }
            if let newValue {
                onTypeChanged?(newValue)
            }
            syncDraftTypeFlags()
            Task {
                await loadFields(for: newValue)
            }
        }
        .onChange(of: draft.pendingDuplicateSourceInstanceID) { _, newValue in
            // An external duplication request retargeted this already-mounted tab.
            guard mode == .add, let newValue else { return }
            draft.pendingDuplicateSourceInstanceID = nil
            Task {
                await loadInstanceForDuplication(sourceInstanceID: newValue)
                syncDraftTypeFlags()
            }
        }
        .onChange(of: requestNonce) { _, _ in
            // Edit mode only: a new instance was requested into this window. Add
            // mode passes the stable draft ID, so this never fires there.
            guard mode == .edit else { return }
            Task<Void, Never> {
                await loadInitialData()
            }
        }
        .onExitCommand {
            // A showing map add-popup swallows Escape first; otherwise closes
            // silently — in add mode all tab drafts live on AddInstanceWindowState
            // and are restored when the window reopens.
            handleEscape()
        }
        .onDisappear {
            // Floating panels outlive the editor subtree (tab switch or window
            // close) unless closed explicitly.
            pointMapPointController.close()
            movePointsPickerController.close()
            hyperlinkSearchController.close()
            typePickerController.close()
            tableSizePickerController.close()
            advancedSettingsController.close()
        }
        .background {
            EditorPreviewShortcutHandler(
                shortcutSettings: shortcutSettings,
                onPreviewTopQuery: previewTopmostCheckedQueryType
            )
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
        if draft.selectedTypeID != nil, let type = types.first(where: { $0.id == draft.selectedTypeID }) {
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

                if mode == .edit, let loadedInstanceID = draft.loadedInstanceID {
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
                HStack(spacing: 8) {
                    Button {
                        insertImageIntoCurrentField()
                    } label: {
                        ShortcutLabel(title: "Insert Image", action: .editorInsertImage)
                    }
                    .controlSize(.small)

                    Button {
                        presentTablePicker()
                    } label: {
                        Text("Insert Table")
                    }
                    .controlSize(.small)
                }
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
                .frame(width: 320)
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
                TextField("", text: $draft.pointMapTitle)
                    .solidFocusField()
            }

            HStack(spacing: 6) {
                Text("Description:")
                    .font(.subheadline)
                TextField("", text: $draft.pointMapDescription)
                    .solidFocusField()
            }

            HStack(alignment: .center, spacing: 8) {
                Text("Boundaries:")
                    .font(.subheadline)
                SelectedBoundariesStrip(
                    boundaries: draft.boundaryPickerState.selectedBoundaries,
                    onRemove: { id in
                        draft.boundaryPickerState.selectedIDs.remove(id)
                        refreshBoundaryGeometries()
                    },
                    onSetColor: { id, color in
                        applyBoundaryColorChange(boundaryID: id, color: color)
                    },
                    onAddTapped: { isBoundaryPickerPresented = true },
                    addButtonLabel: "Add"
                )
                .popover(isPresented: $isBoundaryPickerPresented, arrowEdge: .bottom) {
                    BoundaryPickerPopoverView(
                        state: draft.boundaryPickerState,
                        appDatabase: appDatabase,
                        onManage: {
                            isBoundaryPickerPresented = false
                            openWindow(id: "manage-boundaries")
                        }
                    )
                }
                .onChange(of: draft.boundaryPickerState.selectedIDs) { _, _ in
                    refreshBoundaryGeometries()
                }
            }

            MapReader { proxy in
                ZStack {
                    Map(position: $draft.pointMapCameraPosition, selection: $pointMapMapSelection) {
                        ForEach(pointMapDisplayPoints, id: \.id) { entry in
                            Annotation("", coordinate: CLLocationCoordinate2D(latitude: entry.latitude, longitude: entry.longitude)) {
                                MapPointMarker(
                                    name: entry.name,
                                    size: draft.pointMapPointSize.normalDiameter,
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
                        ForEach(draft.pointMapBoundaryGeometries) { geo in
                            ForEach(Array(geo.geometry.rings.enumerated()), id: \.offset) { _, polygonRings in
                                if let outer = polygonRings.first, outer.count >= 3 {
                                    MapPolygon(coordinates: outer.map(\.clLocation))
                                        .foregroundStyle(.clear)
                                        .stroke(geo.color.swiftUIColor, lineWidth: 1.5)
                                }
                            }
                        }
                    }
                    // .onEnd, not .continuous: per-frame writes to @Published draft
                    // properties re-render the whole editor on every pan/zoom frame,
                    // and no consumer of the region needs frame-rate updates.
                    .onMapCameraChange(frequency: .onEnd) { context in
                        draft.pointMapCurrentRegion = context.region
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

            Toggle(isOn: $draft.pointMapShowAllPointsInQuestion) {
                Text("Show all points in the question side of each query")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)

            if mode == .edit {
                Toggle(isOn: $draft.pointMapApplyCurrentViewport) {
                    Text("Set each query's default map location and zoom to current")
                        .font(.subheadline)
                }
                .toggleStyle(.checkbox)
            }
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
                            // Resetting writes SRS state directly to the saved points,
                            // so it's only meaningful once the instance exists (Edit mode).
                            if mode == .edit {
                                Menu("Reset Queries") {
                                    Button("Forward") { resetPointMapEntriesDueDates(refs, isReverse: false) }
                                    Button("Reverse") { resetPointMapEntriesDueDates(refs, isReverse: true) }
                                }
                                // Moving also writes directly to the DB (the points are
                                // re-parented immediately, keeping their queries' SRS state).
                                Button("Move to a different PointMap…") {
                                    presentMovePointsPicker(refs)
                                }
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
                Picker("", selection: $draft.pointMapSortMode) {
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
        entries.reserveCapacity(draft.pointMapExistingPoints.count + draft.pointMapNewPoints.count)
        for point in draft.pointMapExistingPoints {
            entries.append(PointMapDisplayEntry(
                ref: .existing(point.id),
                name: point.name,
                latitude: point.latitude,
                longitude: point.longitude,
                forwardEnabled: point.forwardEnabled,
                reverseEnabled: point.reverseEnabled
            ))
        }
        for entry in draft.pointMapNewPoints {
            entries.append(PointMapDisplayEntry(
                ref: .new(entry.localID),
                name: entry.name,
                latitude: entry.latitude,
                longitude: entry.longitude,
                forwardEnabled: entry.forwardEnabled,
                reverseEnabled: entry.reverseEnabled
            ))
        }
        switch draft.pointMapSortMode {
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
        let region = draft.pointMapCurrentRegion
        draft.pointMapExplicitLat = String(format: "%.6f", region.center.latitude)
        draft.pointMapExplicitLng = String(format: "%.6f", region.center.longitude)
        let latDelta = max(region.span.latitudeDelta, 0.0001)
        let zoom = log2(360.0 / latDelta)
        draft.pointMapExplicitZoom = String(format: "%.2f", zoom)
    }

    private func applyExplicitPointMapViewport() {
        guard let lat = Double(draft.pointMapExplicitLat.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lng = Double(draft.pointMapExplicitLng.trimmingCharacters(in: .whitespacesAndNewlines)),
              let zoom = Double(draft.pointMapExplicitZoom.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showToast(message: "Invalid viewport values.", style: .error)
            return
        }
        let clampedZoom = max(0.0, min(20.0, zoom))
        let delta = max(0.0001, 360.0 / pow(2.0, clampedZoom))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
        )
        draft.pointMapCurrentRegion = region
        draft.pointMapCameraPosition = .region(region)
        // Explicit entry directly updates the map's stored default viewport (what gets
        // saved when "set to current" is unchecked). It must NOT tick the checkbox —
        // that's a separate, user-controlled choice to instead capture the live viewport.
        draft.pointMapLoadedDefaultCenterLat = lat
        draft.pointMapLoadedDefaultCenterLng = lng
        draft.pointMapLoadedDefaultZoom = clampedZoom
    }

    private func resetPointMapState() {
        draft.pointMapTitle = ""
        draft.pointMapDescription = ""
        draft.pointMapExistingPoints = []
        draft.pointMapNewPoints = []
        draft.pointMapSortMode = .creation
        draft.pointMapShowAllPointsInQuestion = true
        draft.pointMapPointSize = .medium
        draft.pointMapApplyCurrentViewport = false
        draft.pointMapLoadedDefaultCenterLat = nil
        draft.pointMapLoadedDefaultCenterLng = nil
        draft.pointMapLoadedDefaultZoom = nil
        let defaultRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
        )
        draft.pointMapCurrentRegion = defaultRegion
        draft.pointMapCameraPosition = .region(defaultRegion)
        pointMapSyncExplicitFieldsFromRegion()
        draft.boundaryPickerState.selectedIDs = []
        draft.boundaryPickerState.reload(appDatabase: appDatabase)
        draft.pointMapBoundaryGeometries = []
    }

    private func loadPointMapInto(instance: PointMapInstanceWithPoints) {
        draft.pointMapTitle = instance.instance.title
        draft.pointMapDescription = instance.instance.description
        draft.pointMapExistingPoints = instance.points
        draft.pointMapNewPoints = []
        draft.pointMapSortMode = .creation
        draft.pointMapShowAllPointsInQuestion = instance.instance.showAllPointsInQuestion
        draft.pointMapPointSize = instance.instance.pointSize
        draft.pointMapApplyCurrentViewport = false
        draft.pointMapLoadedDefaultCenterLat = instance.instance.defaultCenterLat
        draft.pointMapLoadedDefaultCenterLng = instance.instance.defaultCenterLng
        draft.pointMapLoadedDefaultZoom = instance.instance.defaultZoom
        let delta = max(0.0001, 360.0 / pow(2.0, max(0.0, min(20.0, instance.instance.defaultZoom))))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: instance.instance.defaultCenterLat, longitude: instance.instance.defaultCenterLng),
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
        )
        draft.pointMapCurrentRegion = region
        draft.pointMapCameraPosition = .region(region)
        pointMapSyncExplicitFieldsFromRegion()
        draft.boundaryPickerState.selectedIDs = Set(instance.boundaryIDs)
        draft.boundaryPickerState.reload(appDatabase: appDatabase)
        refreshBoundaryGeometries()
    }

    private func refreshBoundaryGeometries() {
        guard let instanceID = draft.loadedInstanceID else {
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
        let ids = draft.boundaryPickerState.selectedIDs
        guard !ids.isEmpty else {
            draft.pointMapBoundaryGeometries = []
            return
        }
        // Reuse the parsing path: fetch each boundary individually. For small
        // selections this is cheap; for large selections we accept the cost.
        var geometries: [BoundaryGeometry] = []
        geometries.reserveCapacity(ids.count)
        for option in draft.boundaryPickerState.options where ids.contains(option.id) {
            if let geo = try? appDatabase.fetchBoundaryGeometry(boundaryID: option.id) {
                geometries.append(BoundaryGeometry(
                    id: option.id,
                    name: option.boundary.name,
                    geometry: geo,
                    color: option.boundary.color
                ))
            }
        }
        draft.pointMapBoundaryGeometries = geometries
    }

    // Writes the boundary's border color to the DB immediately (a boundary's
    // color is a property of the boundary itself, shared across every instance
    // it appears on — not part of this editor's draft), then refreshes both
    // map editors' color sources.
    private func applyBoundaryColorChange(boundaryID: Int64, color: BoundaryColor) {
        do {
            try appDatabase.setBoundaryColor(boundaryID: boundaryID, color: color)
        } catch {
            showToast(message: "Failed to change boundary color.", style: .error)
            return
        }
        draft.boundaryPickerState.reload(appDatabase: appDatabase)
        draft.boundaryMapPickerState.reload(appDatabase: appDatabase)
        refreshBoundaryGeometries()
        refreshBoundaryMapGeometries()
        NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
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
                var actions: [MapMenuAction] = [
                    MapMenuAction(title: "Edit") { presentEditPointPopup(for: ref) }
                ]
                // Resetting writes SRS state directly to the saved point, so it's only
                // meaningful once the instance exists (Edit mode), matching the points
                // list's "Reset Queries" submenu.
                if mode == .edit {
                    actions.append(MapMenuAction(title: "Reset all queries") {
                        resetAllPointMapEntryQueries(ref)
                    })
                }
                actions.append(MapMenuAction(title: "Delete") { removePointMapEntry(ref) })
                return actions
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
        ) { name, lat, lng, forward, reverse, hint in
            let entry = PointMapPointDraftEntry(
                localID: UUID(),
                name: name,
                latitude: lat,
                longitude: lng,
                forwardEnabled: forward,
                reverseEnabled: reverse,
                hint: hint
            )
            draft.pointMapNewPoints.append(entry)
        }
    }

    private func presentEditPointPopup(for ref: PointMapEntryRef) {
        let window = NSApp.keyWindow
        switch ref {
        case .existing(let id):
            guard let point = draft.pointMapExistingPoints.first(where: { $0.id == id }) else { return }
            pointMapPointController.present(
                from: window,
                initialName: point.name,
                initialHint: point.hint,
                initialLatitude: String(point.latitude),
                initialLongitude: String(point.longitude),
                initialForwardEnabled: point.forwardEnabled,
                initialReverseEnabled: point.reverseEnabled,
                forwardInterval: point.forwardInterval,
                reverseInterval: point.reverseInterval,
                isEdit: true,
                onResetForward: {
                    try? appDatabase.resetPointMapPointDueDate(pointID: id, isReverse: false)
                    if let idx = draft.pointMapExistingPoints.firstIndex(where: { $0.id == id }) {
                        draft.pointMapExistingPoints[idx].forwardInterval = 0
                    }
                },
                onResetReverse: {
                    try? appDatabase.resetPointMapPointDueDate(pointID: id, isReverse: true)
                    if let idx = draft.pointMapExistingPoints.firstIndex(where: { $0.id == id }) {
                        draft.pointMapExistingPoints[idx].reverseInterval = 0
                    }
                }
            ) { name, lat, lng, forward, reverse, hint in
                guard let idx = draft.pointMapExistingPoints.firstIndex(where: { $0.id == id }) else { return }
                let existing = draft.pointMapExistingPoints[idx]
                draft.pointMapExistingPoints[idx] = PointMapPoint(
                    id: existing.id,
                    instanceID: existing.instanceID,
                    name: name,
                    latitude: lat,
                    longitude: lng,
                    forwardEnabled: forward,
                    reverseEnabled: reverse,
                    forwardInterval: existing.forwardInterval,
                    reverseInterval: existing.reverseInterval,
                    hint: hint
                )
            }
        case .new(let localID):
            guard let entry = draft.pointMapNewPoints.first(where: { $0.localID == localID }) else { return }
            pointMapPointController.present(
                from: window,
                initialName: entry.name,
                initialHint: entry.hint,
                initialLatitude: String(entry.latitude),
                initialLongitude: String(entry.longitude),
                initialForwardEnabled: entry.forwardEnabled,
                initialReverseEnabled: entry.reverseEnabled,
                isEdit: true
            ) { name, lat, lng, forward, reverse, hint in
                guard let idx = draft.pointMapNewPoints.firstIndex(where: { $0.localID == localID }) else { return }
                draft.pointMapNewPoints[idx] = PointMapPointDraftEntry(
                    localID: localID,
                    name: name,
                    latitude: lat,
                    longitude: lng,
                    forwardEnabled: forward,
                    reverseEnabled: reverse,
                    hint: hint
                )
            }
        }
    }

    private func removePointMapEntry(_ ref: PointMapEntryRef) {
        switch ref {
        case .existing(let id):
            draft.pointMapExistingPoints.removeAll { $0.id == id }
        case .new(let localID):
            draft.pointMapNewPoints.removeAll { $0.localID == localID }
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
            guard let point = draft.pointMapExistingPoints.first(where: { $0.id == id }) else { return (true, false) }
            return (point.forwardEnabled, point.reverseEnabled)
        case .new(let localID):
            guard let draft = draft.pointMapNewPoints.first(where: { $0.localID == localID }) else { return (true, false) }
            return (draft.forwardEnabled, draft.reverseEnabled)
        }
    }

    private func setPointMapEntryFlags(for ref: PointMapEntryRef, forward: Bool?, reverse: Bool?) {
        switch ref {
        case .existing(let id):
            guard let index = draft.pointMapExistingPoints.firstIndex(where: { $0.id == id }) else { return }
            if let forward { draft.pointMapExistingPoints[index].forwardEnabled = forward }
            if let reverse { draft.pointMapExistingPoints[index].reverseEnabled = reverse }
        case .new(let localID):
            guard let index = draft.pointMapNewPoints.firstIndex(where: { $0.localID == localID }) else { return }
            if let forward { draft.pointMapNewPoints[index].forwardEnabled = forward }
            if let reverse { draft.pointMapNewPoints[index].reverseEnabled = reverse }
        }
    }

    // Bulk enable/disable a query direction across all selected points (used by the
    // points list's "Enable Queries" / "Disable Queries" context-menu submenus).
    private func setPointMapEntriesEnabled(_ refs: Set<PointMapEntryRef>, forward: Bool?, reverse: Bool?) {
        for ref in refs {
            setPointMapEntryFlags(for: ref, forward: forward, reverse: reverse)
        }
    }

    // Reset the due dates for one query direction across all selected saved points
    // (Edit mode only — new points have no persisted queries yet). Writes straight to
    // the DB and reports how many queries were actually reset via a green toast.
    @MainActor
    // Resets both directions' SRS state for a single point (the map right-click
    // "Reset all queries" item).
    private func resetAllPointMapEntryQueries(_ ref: PointMapEntryRef) {
        guard case .existing(let pointID) = ref else { return }
        do {
            let forward = try appDatabase.resetPointMapPointDueDates(pointIDs: [pointID], isReverse: false)
            let reverse = try appDatabase.resetPointMapPointDueDates(pointIDs: [pointID], isReverse: true)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            showToast(message: "Reset due dates for \(forward + reverse) queries", style: .success)
        } catch {
            showToast(message: "Failed to reset due dates.", style: .error)
        }
    }

    private func resetPointMapEntriesDueDates(_ refs: Set<PointMapEntryRef>, isReverse: Bool) {
        let pointIDs = refs.compactMap { ref -> Int64? in
            if case .existing(let id) = ref { return id }
            return nil
        }
        guard !pointIDs.isEmpty else { return }
        do {
            let count = try appDatabase.resetPointMapPointDueDates(pointIDs: pointIDs, isReverse: isReverse)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            showToast(message: "Reset due dates for \(count) queries", style: .success)
        } catch {
            showToast(message: "Failed to reset due dates.", style: .error)
        }
    }

    // Opens the "Move to a different PointMap…" picker for the selected points
    // (Edit mode only). Snapshots the drafted point data up front so the move
    // writes what the sidebar shows, unsaved edits included.
    private func presentMovePointsPicker(_ refs: Set<PointMapEntryRef>) {
        guard mode == .edit, !refs.isEmpty else { return }
        let existingPoints = draft.pointMapExistingPoints.filter { refs.contains(.existing($0.id)) }
        let newEntries = draft.pointMapNewPoints.filter { refs.contains(.new($0.localID)) }
        guard !existingPoints.isEmpty || !newEntries.isEmpty else { return }
        let maps = (try? appDatabase.fetchPointMapInstanceList()) ?? []
        let pointCount = existingPoints.count + newEntries.count
        movePointsPickerController.present(
            from: NSApp.keyWindow,
            title: pointCount == 1 ? "Move 1 Point to…" : "Move \(pointCount) Points to…",
            placeholder: "Search PointMaps…",
            emptyText: "No matching PointMaps.",
            items: maps.map { map in
                PickerPanelItem(
                    id: map.id,
                    title: map.title.isEmpty ? "(untitled)" : map.title,
                    detail: map.id == draft.loadedInstanceID ? "(current)" : nil,
                    isSelectable: map.id != draft.loadedInstanceID
                )
            }
        ) { target in
            movePointMapEntries(existingPoints: existingPoints, newEntries: newEntries, to: target)
        }
    }

    // Moves the points to the chosen PointMap immediately (no save needed):
    // saved points are re-parented in the DB — their enabled queries keep their
    // SRS state — and unsaved draft points are inserted into the target. The
    // moved points then leave this editor's draft so a later save of the source
    // instance doesn't touch them.
    private func movePointMapEntries(
        existingPoints: [PointMapPoint],
        newEntries: [PointMapPointDraftEntry],
        to target: PickerPanelItem
    ) {
        let newDrafts = newEntries.map { entry in
            AppDatabase.PointMapPointDraft(
                name: entry.name,
                latitude: entry.latitude,
                longitude: entry.longitude,
                forwardEnabled: entry.forwardEnabled,
                reverseEnabled: entry.reverseEnabled,
                hint: entry.hint
            )
        }
        do {
            try appDatabase.movePointMapPoints(
                existingPoints: existingPoints,
                newPoints: newDrafts,
                toInstanceID: target.id
            )
            let existingIDs = Set(existingPoints.map(\.id))
            let newLocalIDs = Set(newEntries.map(\.localID))
            draft.pointMapExistingPoints.removeAll { existingIDs.contains($0.id) }
            draft.pointMapNewPoints.removeAll { newLocalIDs.contains($0.localID) }
            pointMapListSelection.subtract(
                existingIDs.map(PointMapEntryRef.existing) + newLocalIDs.map(PointMapEntryRef.new)
            )
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            let count = existingPoints.count + newEntries.count
            let noun = count == 1 ? "point" : "points"
            showToast(message: "Moved \(count) \(noun) to \u{201C}\(target.title)\u{201D}.", style: .success)
        } catch {
            showToast(message: "Failed to move points.", style: .error)
        }
    }

    // MARK: - BoundaryMap editor

    private var boundaryMapEditor: some View {
        HStack(alignment: .top, spacing: 12) {
            boundaryMapMapPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            boundaryMapListPane
                .frame(width: 320)
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
                TextField("", text: $draft.boundaryMapTitle)
                    .solidFocusField()
            }

            HStack(spacing: 6) {
                Text("Description:")
                    .font(.subheadline)
                TextField("", text: $draft.boundaryMapDescription)
                    .solidFocusField()
            }

            MapReader { proxy in
                ZStack {
                    Map(position: $draft.boundaryMapCameraPosition) {
                        ForEach(boundaryMapDisplayEntries, id: \.id) { entry in
                            if let geo = boundaryMapGeometriesByBoundaryID[entry.boundaryID] {
                                ForEach(Array(geo.geometry.rings.enumerated()), id: \.offset) { _, polygonRings in
                                    if let outer = polygonRings.first, outer.count >= 3 {
                                        MapPolygon(coordinates: outer.map(\.clLocation))
                                            .foregroundStyle(.clear)
                                            .stroke(geo.color.swiftUIColor, lineWidth: 1.5)
                                    }
                                }
                            }
                        }
                    }
                    // .onEnd, not .continuous: per-frame writes to @Published draft
                    // properties re-render the whole editor on every pan/zoom frame,
                    // and no consumer of the region needs frame-rate updates.
                    .onMapCameraChange(frequency: .onEnd) { context in
                        draft.boundaryMapCurrentRegion = context.region
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

            Toggle(isOn: $draft.boundaryMapShowAllBoundariesInQuestion) {
                Text("Show all boundaries on the question side of each query")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)

            if mode == .edit {
                Toggle(isOn: $draft.boundaryMapApplyCurrentViewport) {
                    Text("Set each query's default map location and zoom to current")
                        .font(.subheadline)
                }
                .toggleStyle(.checkbox)
            }
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
                    state: draft.boundaryMapPickerState,
                    appDatabase: appDatabase,
                    onManage: {
                        isBoundaryMapPickerPresented = false
                        openWindow(id: "manage-boundaries")
                    }
                )
            }
            .onChange(of: draft.boundaryMapPickerState.selectedIDs) { oldValue, newValue in
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
                                color: boundaryMapColorsByBoundaryID[entry.boundaryID] ?? .red,
                                onSetColor: { color in
                                    applyBoundaryColorChange(boundaryID: entry.boundaryID, color: color)
                                },
                                forwardEnabled: boundaryMapForwardBinding(for: entry.ref),
                                reverseEnabled: boundaryMapReverseBinding(for: entry.ref)
                            )
                            .tag(entry.ref)
                        }
                    }
                    .listStyle(.inset)
                    .contextMenu(forSelectionType: BoundaryMapEntryRef.self) { refs in
                        if !refs.isEmpty {
                            Menu("Enable Queries") {
                                Button("Forward") { setBoundaryMapEntriesEnabled(refs, forward: true, reverse: nil) }
                                Button("Reverse") { setBoundaryMapEntriesEnabled(refs, forward: nil, reverse: true) }
                            }
                            Menu("Disable Queries") {
                                Button("Forward") { setBoundaryMapEntriesEnabled(refs, forward: false, reverse: nil) }
                                Button("Reverse") { setBoundaryMapEntriesEnabled(refs, forward: nil, reverse: false) }
                            }
                            // Resetting writes SRS state directly to the saved
                            // attachments, so it's only meaningful once the
                            // instance exists (Edit mode) — like PointMap.
                            if mode == .edit {
                                Menu("Reset Queries") {
                                    Button("Forward") { resetBoundaryMapEntriesDueDates(refs, isReverse: false) }
                                    Button("Reverse") { resetBoundaryMapEntriesDueDates(refs, isReverse: true) }
                                }
                            }
                            Menu("Change Color") {
                                Button("Red") { setBoundaryMapEntriesColor(refs, color: .red) }
                                Button("Blue") { setBoundaryMapEntriesColor(refs, color: .blue) }
                            }
                            Divider()
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
                // Two radio-group pickers sharing one binding, so "Color" sits
                // beside "Creation order" instead of on a third row (a single
                // radioGroup picker can only lay out one column or one row).
                Picker("", selection: $draft.boundaryMapSortMode) {
                    ForEach([BoundaryMapSortMode.creation, .color], id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                Picker("", selection: $draft.boundaryMapSortMode) {
                    Text(BoundaryMapSortMode.alphabetical.displayName).tag(BoundaryMapSortMode.alphabetical)
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
        for attached in draft.boundaryMapExistingAttachments where !draft.boundaryMapDeletedExistingIDs.contains(attached.id) {
            entries.append(BoundaryMapDisplayEntry(
                ref: .existing(attached.id),
                boundaryID: attached.boundaryID,
                name: attached.name,
                forwardEnabled: attached.forwardEnabled,
                reverseEnabled: attached.reverseEnabled
            ))
        }
        for draft in draft.boundaryMapNewAttachments {
            entries.append(BoundaryMapDisplayEntry(
                ref: .new(draft.localID),
                boundaryID: draft.boundaryID,
                name: draft.name,
                forwardEnabled: draft.forwardEnabled,
                reverseEnabled: draft.reverseEnabled
            ))
        }
        switch draft.boundaryMapSortMode {
        case .creation:
            return entries
        case .alphabetical:
            return entries.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .color:
            // Red boundaries first, then blue, each group alphabetical.
            let colors = boundaryMapColorsByBoundaryID
            return entries.sorted { lhs, rhs in
                let lhsColor = colors[lhs.boundaryID] ?? .red
                let rhsColor = colors[rhs.boundaryID] ?? .red
                if lhsColor != rhsColor { return lhsColor == .red }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private var boundaryMapGeometriesByBoundaryID: [Int64: BoundaryGeometry] {
        var map: [Int64: BoundaryGeometry] = [:]
        for geo in draft.boundaryMapGeometries {
            map[geo.id] = geo
        }
        return map
    }

    // Colors come from the picker's option list (always reloaded on editor
    // load/reset), not the attachment drafts — a boundary's color is shared
    // app-wide, not per-instance state.
    private var boundaryMapColorsByBoundaryID: [Int64: BoundaryColor] {
        var map: [Int64: BoundaryColor] = [:]
        for option in draft.boundaryMapPickerState.options {
            map[option.id] = option.boundary.color
        }
        return map
    }

    private func setBoundaryMapEntriesColor(_ refs: Set<BoundaryMapEntryRef>, color: BoundaryColor) {
        let boundaryIDs = Set(
            boundaryMapDisplayEntries
                .filter { refs.contains($0.ref) }
                .map(\.boundaryID)
        )
        for boundaryID in boundaryIDs {
            applyBoundaryColorChange(boundaryID: boundaryID, color: color)
        }
    }

    private func boundaryMapSyncExplicitFieldsFromRegion() {
        let region = draft.boundaryMapCurrentRegion
        draft.boundaryMapExplicitLat = String(format: "%.6f", region.center.latitude)
        draft.boundaryMapExplicitLng = String(format: "%.6f", region.center.longitude)
        let latDelta = max(region.span.latitudeDelta, 0.0001)
        let zoom = log2(360.0 / latDelta)
        draft.boundaryMapExplicitZoom = String(format: "%.2f", zoom)
    }

    private func applyExplicitBoundaryMapViewport() {
        guard let lat = Double(draft.boundaryMapExplicitLat.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lng = Double(draft.boundaryMapExplicitLng.trimmingCharacters(in: .whitespacesAndNewlines)),
              let zoom = Double(draft.boundaryMapExplicitZoom.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showToast(message: "Invalid viewport values.", style: .error)
            return
        }
        let clampedZoom = max(0.0, min(20.0, zoom))
        let delta = max(0.0001, 360.0 / pow(2.0, clampedZoom))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
        )
        draft.boundaryMapCurrentRegion = region
        draft.boundaryMapCameraPosition = .region(region)
        // Explicit entry is a deliberate intent to set the default viewport, so commit it
        // on save (the editor checkbox ticks on to reflect this).
        draft.boundaryMapApplyCurrentViewport = true
    }

    private func resetBoundaryMapState() {
        draft.boundaryMapTitle = ""
        draft.boundaryMapDescription = ""
        draft.boundaryMapExistingAttachments = []
        draft.boundaryMapNewAttachments = []
        draft.boundaryMapDeletedExistingIDs = []
        draft.boundaryMapSortMode = .creation
        draft.boundaryMapShowAllBoundariesInQuestion = true
        draft.boundaryMapApplyCurrentViewport = false
        draft.boundaryMapLoadedDefaultCenterLat = nil
        draft.boundaryMapLoadedDefaultCenterLng = nil
        draft.boundaryMapLoadedDefaultZoom = nil
        let defaultRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90)
        )
        draft.boundaryMapCurrentRegion = defaultRegion
        draft.boundaryMapCameraPosition = .region(defaultRegion)
        boundaryMapSyncExplicitFieldsFromRegion()
        draft.boundaryMapPickerState.selectedIDs = []
        draft.boundaryMapPickerState.reload(appDatabase: appDatabase)
        draft.boundaryMapGeometries = []
    }

    private func loadBoundaryMapInto(instance: BoundaryMapInstanceWithBoundaries) {
        draft.boundaryMapTitle = instance.instance.title
        draft.boundaryMapDescription = instance.instance.description
        draft.boundaryMapExistingAttachments = instance.attachments
        draft.boundaryMapNewAttachments = []
        draft.boundaryMapDeletedExistingIDs = []
        draft.boundaryMapSortMode = .creation
        draft.boundaryMapShowAllBoundariesInQuestion = instance.instance.showAllBoundariesInQuestion
        draft.boundaryMapApplyCurrentViewport = false
        draft.boundaryMapLoadedDefaultCenterLat = instance.instance.defaultCenterLat
        draft.boundaryMapLoadedDefaultCenterLng = instance.instance.defaultCenterLng
        draft.boundaryMapLoadedDefaultZoom = instance.instance.defaultZoom
        let delta = max(0.0001, 360.0 / pow(2.0, max(0.0, min(20.0, instance.instance.defaultZoom))))
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: instance.instance.defaultCenterLat, longitude: instance.instance.defaultCenterLng),
            span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
        )
        draft.boundaryMapCurrentRegion = region
        draft.boundaryMapCameraPosition = .region(region)
        boundaryMapSyncExplicitFieldsFromRegion()
        draft.boundaryMapPickerState.selectedIDs = Set(instance.attachments.map(\.boundaryID))
        draft.boundaryMapPickerState.reload(appDatabase: appDatabase)
        refreshBoundaryMapGeometries()
    }

    private func reconcileBoundaryMapPickerSelection(old: Set<Int64>, new: Set<Int64>) {
        let added = new.subtracting(old)
        let removed = old.subtracting(new)

        // Existing-attachment boundary IDs (excluding any already staged for deletion)
        let existingIDs: [Int64: Int64] = draft.boundaryMapExistingAttachments.reduce(into: [:]) { acc, attached in
            acc[attached.boundaryID] = attached.id
        }

        for boundaryID in removed {
            if let attachmentID = existingIDs[boundaryID] {
                draft.boundaryMapDeletedExistingIDs.insert(attachmentID)
            } else {
                draft.boundaryMapNewAttachments.removeAll { $0.boundaryID == boundaryID }
            }
        }

        for boundaryID in added {
            if let attachmentID = existingIDs[boundaryID] {
                // User re-toggled an existing attachment back on — un-stage its deletion.
                draft.boundaryMapDeletedExistingIDs.remove(attachmentID)
            } else {
                guard !draft.boundaryMapNewAttachments.contains(where: { $0.boundaryID == boundaryID }) else { continue }
                let name = draft.boundaryMapPickerState.options.first(where: { $0.id == boundaryID })?.boundary.name ?? ""
                draft.boundaryMapNewAttachments.append(BoundaryMapAttachmentDraft(
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
            draft.boundaryMapGeometries = []
            return
        }
        var geometries: [BoundaryGeometry] = []
        geometries.reserveCapacity(displayedBoundaryIDs.count)
        for option in draft.boundaryMapPickerState.options where displayedBoundaryIDs.contains(option.id) {
            if let geo = try? appDatabase.fetchBoundaryGeometry(boundaryID: option.id) {
                geometries.append(BoundaryGeometry(
                    id: option.id,
                    name: option.boundary.name,
                    geometry: geo,
                    color: option.boundary.color
                ))
            }
        }
        draft.boundaryMapGeometries = geometries
    }

    private func boundaryMapContextMenuActions(at localPoint: CGPoint, proxy: MapProxy) -> [MapMenuAction] {
        guard let coord = proxy.convert(localPoint, from: .local) else { return [] }
        for entry in boundaryMapDisplayEntries.reversed() {
            guard let geometry = boundaryMapGeometriesByBoundaryID[entry.boundaryID] else { continue }
            if boundaryContains(coordinate: coord, geometry: geometry.geometry) {
                let ref = entry.ref
                return [MapMenuAction(title: "Delete") { removeBoundaryMapEntry(ref) }]
            }
        }
        return []
    }

    private func removeBoundaryMapEntry(_ ref: BoundaryMapEntryRef) {
        switch ref {
        case .existing(let id):
            guard let attached = draft.boundaryMapExistingAttachments.first(where: { $0.id == id }) else { return }
            draft.boundaryMapDeletedExistingIDs.insert(id)
            draft.boundaryMapPickerState.selectedIDs.remove(attached.boundaryID)
        case .new(let localID):
            guard let attachmentDraft = draft.boundaryMapNewAttachments.first(where: { $0.localID == localID }) else { return }
            draft.boundaryMapNewAttachments.removeAll { $0.localID == localID }
            draft.boundaryMapPickerState.selectedIDs.remove(attachmentDraft.boundaryID)
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
            guard let attached = draft.boundaryMapExistingAttachments.first(where: { $0.id == id }) else { return (true, false) }
            return (attached.forwardEnabled, attached.reverseEnabled)
        case .new(let localID):
            guard let draft = draft.boundaryMapNewAttachments.first(where: { $0.localID == localID }) else { return (true, false) }
            return (draft.forwardEnabled, draft.reverseEnabled)
        }
    }

    private func setBoundaryMapEntriesEnabled(_ refs: Set<BoundaryMapEntryRef>, forward: Bool?, reverse: Bool?) {
        for ref in refs {
            setBoundaryMapEntryFlags(for: ref, forward: forward, reverse: reverse)
        }
    }

    // Reset the due dates for one query direction across all selected saved
    // attachments (Edit mode only — new attachments have no persisted queries
    // yet). Writes straight to the DB and reports how many queries were
    // actually reset via a green toast, mirroring the PointMap list.
    private func resetBoundaryMapEntriesDueDates(_ refs: Set<BoundaryMapEntryRef>, isReverse: Bool) {
        let attachmentIDs = refs.compactMap { ref -> Int64? in
            if case .existing(let id) = ref { return id }
            return nil
        }
        guard !attachmentIDs.isEmpty else { return }
        do {
            let count = try appDatabase.resetBoundaryMapAttachmentDueDates(attachmentIDs: attachmentIDs, isReverse: isReverse)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            showToast(message: "Reset due dates for \(count) queries", style: .success)
        } catch {
            showToast(message: "Failed to reset due dates.", style: .error)
        }
    }

    private func setBoundaryMapEntryFlags(for ref: BoundaryMapEntryRef, forward: Bool?, reverse: Bool?) {
        switch ref {
        case .existing(let id):
            guard let index = draft.boundaryMapExistingAttachments.firstIndex(where: { $0.id == id }) else { return }
            if let forward { draft.boundaryMapExistingAttachments[index].forwardEnabled = forward }
            if let reverse { draft.boundaryMapExistingAttachments[index].reverseEnabled = reverse }
        case .new(let localID):
            guard let index = draft.boundaryMapNewAttachments.firstIndex(where: { $0.localID == localID }) else { return }
            if let forward { draft.boundaryMapNewAttachments[index].forwardEnabled = forward }
            if let reverse { draft.boundaryMapNewAttachments[index].reverseEnabled = reverse }
        }
    }

    private var fieldsSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear
                        .frame(height: 0)
                        .id("fieldsSectionTop")

                    if draft.selectedTypeID == nil {
                        // Render nothing while the initial load is still resolving a
                        // type, so the empty-state text doesn't flash on new tabs.
                        if isInitialLoadComplete {
                            Text("No types are available.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if draft.fields.isEmpty, draft.loadedTypeID != draft.selectedTypeID {
                        // Fields for the newly selected type are still loading.
                    } else if draft.fields.isEmpty {
                        Text("This type has no fields.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        fieldEditors
                    }

                    if isPersonSelected {
                        PersonSlotsEditor(appDatabase: appDatabase, draft: draft)
                        PersonOfficesEditor(
                            appDatabase: appDatabase,
                            draft: draft,
                            focusController: focusController,
                            onSubmit: submitInstance,
                            onRequestHyperlink: { textView in
                                hyperlinkSearchController.present(
                                    appDatabase: appDatabase,
                                    from: textView
                                )
                            }
                        )
                    }

                    if draft.selectedTypeID != nil {
                        collectionChecklistSection
                            .id("collectionsSection")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: collectionsScrollNonce) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("collectionsSection", anchor: .bottom)
                }
            }
            .onChange(of: requestNonce) { _, _ in
                guard mode == .edit else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo("fieldsSectionTop", anchor: .top)
                }
            }
            .onChange(of: openNonce) { _, _ in
                // Add mode: the window was (re)opened — reset the scroll to the top.
                DispatchQueue.main.async {
                    proxy.scrollTo("fieldsSectionTop", anchor: .top)
                }
            }
            .onChange(of: addScrollNonce) { _, _ in
                // Add mode: an instance was just added — reset the scroll to the top.
                DispatchQueue.main.async {
                    proxy.scrollTo("fieldsSectionTop", anchor: .top)
                }
            }
            .onChange(of: draft.pendingDuplicateSourceInstanceID) { _, newValue in
                guard mode == .add, newValue != nil else { return }
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
                    if draft.selectedTypeID == nil {
                        Text("No types are available.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if draft.queryTypes.isEmpty && !isPersonSelected {
                        Text("This type has no query types.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        if !draft.queryTypes.isEmpty {
                            queryTypeCheckboxList
                        }
                        if isPersonSelected {
                            PersonQueryChecklist(
                                draft: draft,
                                mode: mode,
                                onPreview: { kind, partnerEntryID, officeEntryID in
                                    openPersonQueryPreview(kind: kind, partnerEntryID: partnerEntryID, officeEntryID: officeEntryID)
                                },
                                onResetDueDate: { kind, partnerEntryID, officeEntryID in
                                    resetPersonQueryDueDate(kind: kind, partnerEntryID: partnerEntryID, officeEntryID: officeEntryID)
                                }
                            )
                        }
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
            SwiftUI.ForEach(draft.fields) { field in
                if field.fieldType == .sex {
                    InstanceSexFieldEditor(
                        fieldName: field.name,
                        value: binding(for: field.id)
                    )
                } else if field.fieldType == .boolean {
                    InstanceBooleanFieldEditor(
                        fieldName: field.name,
                        value: binding(for: field.id),
                        isSticky: draft.stickyFieldIDs.contains(field.id),
                        showStickyToggle: mode == .add,
                        onToggleSticky: {
                            if let selectedTypeID = draft.selectedTypeID {
                                toggleSticky(typeID: selectedTypeID, fieldID: field.id)
                            }
                        }
                    )
                } else {
                    InstanceFieldEditor(
                        fieldName: field.name,
                        text: binding(for: field.id),
                        focusController: focusController,
                        fieldID: field.id,
                        isSticky: draft.stickyFieldIDs.contains(field.id),
                        showStickyToggle: mode == .add,
                        isCollapsed: draft.collapsedFieldIDs.contains(field.id),
                        onToggleSticky: {
                            if let selectedTypeID = draft.selectedTypeID {
                                toggleSticky(typeID: selectedTypeID, fieldID: field.id)
                            }
                        },
                        onToggleCollapsed: {
                            if let selectedTypeID = draft.selectedTypeID {
                                toggleCollapsed(typeID: selectedTypeID, fieldID: field.id)
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
                        },
                        dedupesTrailingLineBreak: true
                    )
                }
            }
        }
    }

    private var queryTypeCheckboxList: some View {
        let displayedQueryTypes = draft.queryTypes.sorted { lhs, rhs in
            lhs.id < rhs.id
        }

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(displayedQueryTypes) { queryType in
                HStack(spacing: 12) {
                    Toggle(
                        queryType.name,
                        isOn: Binding(
                            get: { draft.selectedQueryTypeIDs.contains(queryType.id) },
                            set: { isSelected in
                                if isSelected {
                                    draft.selectedQueryTypeIDs.insert(queryType.id)
                                    if mode == .edit {
                                        draft.queryIntervalsByQueryTypeID[queryType.id] = 0
                                    }
                                } else {
                                    draft.selectedQueryTypeIDs.remove(queryType.id)
                                    draft.queryIntervalsByQueryTypeID.removeValue(forKey: queryType.id)
                                }
                                if mode == .add, let typeID = draft.selectedTypeID {
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

                    Button {
                        openPreview(queryTypeID: queryType.id)
                    } label: {
                        Image(systemName: "eye")
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                    .help("Preview")

                    if mode == .edit, let loadedInstanceID = draft.loadedInstanceID {
                        if let interval = draft.queryIntervalsByQueryTypeID[queryType.id] {
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
        let matching: [CollectionChecklistItem]
        if trimmedQuery.isEmpty {
            matching = allCollectionItems
        } else {
            matching = allCollectionItems.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }
        // Pinned collections sort to the top, even when a search is active. The search still
        // filters everything (a pinned collection that doesn't match is hidden); among the
        // matches, pinned ones come first. Stable partition preserves order within each group.
        let pinned = matching.filter(\.isPinned)
        let unpinned = matching.filter { !$0.isPinned }
        return pinned + unpinned
    }

    // Moves the highlighted collection ("C") up/down the visible list, wrapping around
    // from the top to the bottom and vice versa.
    private func moveHighlight(by delta: Int) {
        let items = filteredCollectionItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == highlightedCollectionID } ?? 0
        let next = ((current + delta) % items.count + items.count) % items.count
        highlightedCollectionID = items[next].id
    }

    // Toggles whether the highlighted collection is selected, without changing focus.
    private func toggleHighlightedCollection() {
        guard let id = highlightedCollectionID else { return }
        if draft.selectedCollectionIDs.contains(id) {
            draft.selectedCollectionIDs.remove(id)
        } else {
            draft.selectedCollectionIDs.insert(id)
        }
    }

    private var collectionChecklistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Collections")
                    .font(.headline)

                if !draft.selectedCollectionIDs.isEmpty {
                    Text("(\(draft.selectedCollectionIDs.count) selected)")
                        .font(.headline)
                        .foregroundStyle(.blue)
                }
            }

            CollectionSearchTextField(
                text: $collectionSearchQuery,
                focusController: focusController,
                onTab: { focusNextField(after: nil) },
                onBackTab: { focusPreviousField(before: nil) },
                onMoveUp: { moveHighlight(by: -1) },
                onMoveDown: { moveHighlight(by: 1) },
                onToggleHighlighted: { toggleHighlightedCollection() },
                onFocusGained: { highlightedCollectionID = filteredCollectionItems.first?.id },
                onFocusLost: { highlightedCollectionID = nil }
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredCollectionItems) { item in
                                CollectionChecklistRow(
                                    item: item,
                                    isChecked: draft.selectedCollectionIDs.contains(item.id),
                                    isHighlighted: item.id == highlightedCollectionID,
                                    onToggleCheck: { isChecked in
                                        if isChecked {
                                            draft.selectedCollectionIDs.insert(item.id)
                                        } else {
                                            draft.selectedCollectionIDs.remove(item.id)
                                        }
                                    },
                                    onTogglePin: {
                                        togglePin(for: item)
                                    }
                                )
                                .id(item.id)
                            }
                        }
                        .background(ScrollBubbleBlocker())
                    }
                    .frame(maxHeight: 260)
                    .onChange(of: highlightedCollectionID) { _, newValue in
                        guard let newValue else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .onChange(of: collectionSearchQuery) { _, _ in
            if let c = highlightedCollectionID,
               !filteredCollectionItems.contains(where: { $0.id == c }) {
                highlightedCollectionID = filteredCollectionItems.first?.id
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

    private func presentAdvancedSettings() {
        let kind: AdvancedSettingsKind = isPointMapSelected
            ? .pointMap
            : (isBoundaryMapSelected ? .boundaryMap : .standard)
        advancedSettingsController.present(
            from: NSApp.keyWindow,
            draft: draft,
            kind: kind,
            onApplyPointMapViewport: applyExplicitPointMapViewport,
            onApplyBoundaryMapViewport: applyExplicitBoundaryMapViewport
        )
    }

    private func togglePin(for item: CollectionChecklistItem) {
        guard let selectedTypeID = draft.selectedTypeID else { return }
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
        guard let selectedTypeID = draft.selectedTypeID else {
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
        defer { isInitialLoadComplete = true }
        do {
            types = try appDatabase.fetchTypesOrderedByID()
            if mode == .edit, let requestedInstanceID {
                await loadInstance(instanceID: requestedInstanceID)
            } else if mode == .add, let pendingDuplicateSourceInstanceID = draft.pendingDuplicateSourceInstanceID {
                draft.pendingDuplicateSourceInstanceID = nil
                await loadInstanceForDuplication(sourceInstanceID: pendingDuplicateSourceInstanceID)
            } else if mode == .add, let typeID = draft.selectedTypeID,
                      types.contains(where: { $0.id == typeID }) {
                // Restored tab: value-preserving reload of the type's metadata
                // (fields/queryTypes/sticky), keeping the draft's contents.
                await loadFields(for: typeID)
            } else {
                await applyRequestedTypeSelection()
            }
            syncDraftTypeFlags()
        } catch {
            showToast(message: "Failed to load types.", style: .error)
            types = []
            draft.selectedTypeID = nil
            draft.loadedTypeID = nil
            draft.loadedInstanceID = nil
            draft.fields = []
            draft.queryTypes = []
            draft.selectedQueryTypeIDs = []
            draft.fieldValues = [:]
        }
    }

    @MainActor
    private func loadInstanceForDuplication(sourceInstanceID: Int64) async {
        do {
            let editorData = try appDatabase.fetchInstanceEditorData(instanceID: sourceInstanceID)
            draft.fields = try appDatabase.fetchFieldsForDisplay(forTypeID: editorData.typeID)
            draft.queryTypes = try appDatabase.fetchQueryTypes(forTypeID: editorData.typeID)
            draft.stickyFieldIDs = try appDatabase.fetchStickyFieldIDs(forTypeID: editorData.typeID)
            draft.collapsedFieldIDs = try appDatabase.fetchCollapsedFieldIDs(forTypeID: editorData.typeID)
            draft.selectedQueryTypeIDs = editorData.enabledQueryTypeIDs
            draft.fieldValues = Dictionary(
                uniqueKeysWithValues: draft.fields.map { field in
                    (field.id, editorData.fieldValuesByFieldID[field.id] ?? "")
                }
            )
            draft.selectedCollectionIDs = try appDatabase.fetchCollectionIDs(forInstanceID: sourceInstanceID)
            draft.queryIntervalsByQueryTypeID = [:]
            collectionSearchQuery = ""
            draft.maxIntervalText = ""
            draft.loadedTypeID = editorData.typeID
            draft.loadedInstanceID = nil
            draft.selectedTypeID = editorData.typeID
            loadCollectionItems()
            focusController.reset(with: navigableFieldIDs)
            focusController.focusField(navigableFieldIDs.first)
        } catch {
            print("Failed to load instance for duplication: \(error)")
            await applyRequestedTypeSelection()
            showToast(message: "Failed to load instance to duplicate.", style: .error)
        }
    }

    @MainActor
    private func applyRequestedTypeSelection() async {
        guard !types.isEmpty else {
            draft.selectedTypeID = nil
            draft.loadedTypeID = nil
            draft.loadedInstanceID = nil
            draft.fields = []
            draft.queryTypes = []
            draft.selectedQueryTypeIDs = []
            draft.fieldValues = [:]
            return
        }

        let resolvedTypeID = if let initialTypeID = draft.initialTypeID,
                                types.contains(where: { $0.id == initialTypeID }) {
            initialTypeID
        } else {
            types[0].id
        }

        if draft.selectedTypeID != resolvedTypeID {
            draft.selectedTypeID = resolvedTypeID
        } else {
            await loadFields(for: resolvedTypeID)
        }
    }

    @MainActor
    private func loadFields(for typeID: Int64?) async {
        guard let typeID else {
            draft.fields = []
            draft.loadedTypeID = nil
            draft.loadedInstanceID = nil
            draft.queryTypes = []
            draft.selectedQueryTypeIDs = []
            draft.fieldValues = [:]
            allCollectionItems = []
            draft.selectedCollectionIDs = []
            collectionSearchQuery = ""
            draft.stickyFieldIDs = []
            draft.collapsedFieldIDs = []
            draft.maxIntervalText = ""
            return
        }

        do {
            let didChangeType = draft.loadedTypeID != typeID
            if didChangeType {
                // Same as loadInstance: resign any focused partner/office card
                // field before resetPersonState() below empties the arrays
                // behind it (see endEditing() — belt-and-braces now that card
                // fields use id-keyed bindings).
                focusController.endEditing()
            }
            draft.fields = try appDatabase.fetchFieldsForDisplay(forTypeID: typeID)
            draft.queryTypes = try appDatabase.fetchQueryTypes(forTypeID: typeID)
            draft.stickyFieldIDs = try appDatabase.fetchStickyFieldIDs(forTypeID: typeID)
            draft.collapsedFieldIDs = try appDatabase.fetchCollapsedFieldIDs(forTypeID: typeID)
            if didChangeType {
                draft.resetPersonState()
                let availableQueryTypeIDs = draft.queryTypes.map(\.id)
                draft.selectedQueryTypeIDs = (try? appDatabase.resolveTypeQueryDefaultSelection(
                    forTypeID: typeID,
                    availableQueryTypeIDs: availableQueryTypeIDs
                )) ?? Set(availableQueryTypeIDs)
                draft.selectedCollectionIDs = []
                collectionSearchQuery = ""
                draft.maxIntervalText = ""
                if let selectedType = types.first(where: { $0.id == typeID }),
                   selectedType.isBuiltin, selectedType.name == POINTMAP_TYPE_NAME {
                    resetPointMapState()
                }
                if let selectedType = types.first(where: { $0.id == typeID }),
                   selectedType.isBuiltin, selectedType.name == BOUNDARYMAP_TYPE_NAME {
                    resetBoundaryMapState()
                }
            } else {
                draft.selectedQueryTypeIDs = draft.selectedQueryTypeIDs.intersection(Set(draft.queryTypes.map(\.id)))
            }
            draft.fieldValues = Dictionary(
                uniqueKeysWithValues: draft.fields.map { field in
                    (field.id, draft.fieldValues[field.id] ?? "")
                }
            )
            draft.loadedTypeID = typeID
            draft.loadedInstanceID = nil
            focusController.reset(with: navigableFieldIDs)
            focusController.focusField(navigableFieldIDs.first)
            loadCollectionItems()

            // When the type was just chosen via the ⌘T picker, re-issue focus for
            // Object types after this render cycle. The picker panel's close causes
            // the editor window to restore its previous first responder, which would
            // otherwise win the race against the focus requested just above.
            if shouldFocusFirstFieldAfterTypePick {
                shouldFocusFirstFieldAfterTypePick = false
                if isObjectTypeSelected, let firstFieldID = navigableFieldIDs.first {
                    DispatchQueue.main.async {
                        focusController.focusField(firstFieldID)
                    }
                }
            }
        } catch {
            shouldFocusFirstFieldAfterTypePick = false
            draft.fields = []
            draft.loadedTypeID = nil
            draft.loadedInstanceID = nil
            draft.queryTypes = []
            draft.selectedQueryTypeIDs = []
            draft.fieldValues = [:]
            allCollectionItems = []
            draft.selectedCollectionIDs = []
            draft.stickyFieldIDs = []
            draft.collapsedFieldIDs = []
            focusController.reset(with: [])
            focusController.focusField(nil)
            showToast(message: "Failed to load fields.", style: .error)
        }
    }

    @MainActor
    private func loadInstance(instanceID: Int64) async {
        // Resign the focused control before the draft is repointed at another
        // instance and the partner/office arrays are wholesale replaced (see
        // endEditing() — belt-and-braces now that card fields use id-keyed
        // bindings).
        focusController.endEditing()
        do {
            if let pointMap = try appDatabase.fetchPointMapInstance(instanceID: instanceID),
               let pointMapTypeID = types.first(where: { $0.isBuiltin && $0.name == POINTMAP_TYPE_NAME })?.id {
                draft.fields = []
                draft.queryTypes = []
                draft.selectedTypeID = pointMapTypeID
                draft.loadedTypeID = pointMapTypeID
                draft.loadedInstanceID = instanceID
                draft.selectedQueryTypeIDs = []
                draft.fieldValues = [:]
                draft.selectedCollectionIDs = try appDatabase.fetchCollectionIDs(forInstanceID: instanceID)
                draft.stickyFieldIDs = []
                draft.collapsedFieldIDs = []
                collectionSearchQuery = ""
                draft.maxIntervalText = ""
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
                draft.fields = []
                draft.queryTypes = []
                draft.selectedTypeID = boundaryMapTypeID
                draft.loadedTypeID = boundaryMapTypeID
                draft.loadedInstanceID = instanceID
                draft.selectedQueryTypeIDs = []
                draft.fieldValues = [:]
                draft.selectedCollectionIDs = try appDatabase.fetchCollectionIDs(forInstanceID: instanceID)
                draft.stickyFieldIDs = []
                draft.collapsedFieldIDs = []
                collectionSearchQuery = ""
                draft.maxIntervalText = ""
                loadCollectionItems()
                focusController.reset(with: [])
                focusController.focusField(nil)
                loadBoundaryMapInto(instance: boundaryMap)
                return
            }

            let editorData = try appDatabase.fetchInstanceEditorData(instanceID: instanceID)
            draft.fields = try appDatabase.fetchFieldsForDisplay(forTypeID: editorData.typeID)
            draft.queryTypes = try appDatabase.fetchQueryTypes(forTypeID: editorData.typeID)
            if types.first(where: { $0.id == editorData.typeID })?.isPerson == true {
                applyPersonEditorData(try appDatabase.fetchPersonEditorData(instanceID: instanceID))
            } else {
                draft.resetPersonState()
            }
            draft.selectedTypeID = editorData.typeID
            draft.loadedTypeID = editorData.typeID
            draft.loadedInstanceID = instanceID
            draft.selectedQueryTypeIDs = editorData.enabledQueryTypeIDs
            draft.fieldValues = Dictionary(
                uniqueKeysWithValues: draft.fields.map { field in
                    (field.id, editorData.fieldValuesByFieldID[field.id] ?? "")
                }
            )
            draft.selectedCollectionIDs = try appDatabase.fetchCollectionIDs(forInstanceID: instanceID)
            draft.stickyFieldIDs = try appDatabase.fetchStickyFieldIDs(forTypeID: editorData.typeID)
            draft.collapsedFieldIDs = try appDatabase.fetchCollapsedFieldIDs(forTypeID: editorData.typeID)
            draft.queryIntervalsByQueryTypeID = try appDatabase.fetchQueryIntervals(forInstanceID: instanceID)
            collectionSearchQuery = ""
            draft.maxIntervalText = editorData.maxInterval.map(String.init) ?? ""
            loadCollectionItems()
            focusController.reset(with: navigableFieldIDs)
            focusController.focusField(navigableFieldIDs.first)
        } catch {
            print("Failed to load instance editor data: \(error)")
            draft.fields = []
            draft.loadedTypeID = nil
            draft.loadedInstanceID = nil
            draft.queryTypes = []
            draft.selectedQueryTypeIDs = []
            draft.fieldValues = [:]
            allCollectionItems = []
            draft.selectedCollectionIDs = []
            draft.stickyFieldIDs = []
            draft.collapsedFieldIDs = []
            draft.queryIntervalsByQueryTypeID = [:]
            focusController.reset(with: [])
            focusController.focusField(nil)
            showToast(message: "Failed to load instance.", style: .error)
        }
    }

    @MainActor
    private func submitCurrentInstance() async {
        guard let selectedTypeID = draft.selectedTypeID else { return }

        if isPointMapSelected {
            await submitPointMapInstance(typeID: selectedTypeID)
            return
        }

        if isBoundaryMapSelected {
            await submitBoundaryMapInstance(typeID: selectedTypeID)
            return
        }

        if isPersonSelected {
            await submitPersonInstance(typeID: selectedTypeID)
            return
        }

        let parsedMaxInterval: Int64? = Int64(draft.maxIntervalText)

        do {
            switch mode {
            case .add:
                let instanceID = try appDatabase.makeInstance(
                    forTypeID: selectedTypeID,
                    fieldValuesByFieldID: draft.fieldValues,
                    queryTypeIDs: draft.selectedQueryTypeIDs
                )
                if !draft.selectedCollectionIDs.isEmpty {
                    try appDatabase.setInstanceCollections(
                        instanceID: instanceID,
                        collectionIDs: draft.selectedCollectionIDs
                    )
                }
                if parsedMaxInterval != nil {
                    try appDatabase.setMaxInterval(
                        forInstanceID: instanceID,
                        maxInterval: parsedMaxInterval
                    )
                }
                onAddSaved?(selectedTypeID)
                draft.fieldValues = Dictionary(
                    uniqueKeysWithValues: draft.fields.map { field in
                        let preserved = draft.stickyFieldIDs.contains(field.id) ? draft.fieldValues[field.id] ?? "" : ""
                        return (field.id, preserved)
                    }
                )
                // navigableFieldIDs, not draft.fields: focusing a collapsed
                // (unmounted) first field would desync activeFieldID and arm a
                // pending focus that fires on a later expand.
                focusController.focusField(navigableFieldIDs.first)
                addScrollNonce = UUID()
                showToast(message: "Instance added successfully.", style: .success)
            case .edit:
                guard let loadedInstanceID = draft.loadedInstanceID else { return }
                try appDatabase.updateInstance(
                    instanceID: loadedInstanceID,
                    fieldValuesByFieldID: draft.fieldValues,
                    queryTypeIDs: draft.selectedQueryTypeIDs
                )
                try appDatabase.setInstanceCollections(
                    instanceID: loadedInstanceID,
                    collectionIDs: draft.selectedCollectionIDs
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
        let title = draft.pointMapTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = draft.pointMapDescription
        let region = draft.pointMapCurrentRegion
        let latDelta = max(region.span.latitudeDelta, 0.0001)
        let zoom = log2(360.0 / latDelta)
        let drafts = draft.pointMapNewPoints.map { entry in
            AppDatabase.PointMapPointDraft(
                name: entry.name,
                latitude: entry.latitude,
                longitude: entry.longitude,
                forwardEnabled: entry.forwardEnabled,
                reverseEnabled: entry.reverseEnabled,
                hint: entry.hint
            )
        }

        let boundaryIDs = Array(draft.boundaryPickerState.selectedIDs)
        do {
            switch mode {
            case .add:
                let instanceID = try appDatabase.makePointMapInstance(
                    title: title,
                    description: description,
                    defaultCenterLat: region.center.latitude,
                    defaultCenterLng: region.center.longitude,
                    defaultZoom: zoom,
                    showAllPointsInQuestion: draft.pointMapShowAllPointsInQuestion,
                    pointSize: draft.pointMapPointSize,
                    points: drafts,
                    boundaryIDs: boundaryIDs
                )
                if !draft.selectedCollectionIDs.isEmpty {
                    try appDatabase.setInstanceCollections(
                        instanceID: instanceID,
                        collectionIDs: draft.selectedCollectionIDs
                    )
                }
                onAddSaved?(typeID)
                resetPointMapState()
                showToast(message: "PointMap added successfully.", style: .success)
            case .edit:
                guard let loadedInstanceID = draft.loadedInstanceID else { return }
                let saveLat: Double
                let saveLng: Double
                let saveZoom: Double
                if draft.pointMapApplyCurrentViewport {
                    saveLat = region.center.latitude
                    saveLng = region.center.longitude
                    saveZoom = zoom
                } else {
                    saveLat = draft.pointMapLoadedDefaultCenterLat ?? region.center.latitude
                    saveLng = draft.pointMapLoadedDefaultCenterLng ?? region.center.longitude
                    saveZoom = draft.pointMapLoadedDefaultZoom ?? zoom
                }
                try appDatabase.updatePointMapInstance(
                    instanceID: loadedInstanceID,
                    title: title,
                    description: description,
                    defaultCenterLat: saveLat,
                    defaultCenterLng: saveLng,
                    defaultZoom: saveZoom,
                    showAllPointsInQuestion: draft.pointMapShowAllPointsInQuestion,
                    pointSize: draft.pointMapPointSize,
                    existingPoints: draft.pointMapExistingPoints,
                    newPoints: drafts,
                    boundaryIDs: boundaryIDs
                )
                try appDatabase.setInstanceCollections(
                    instanceID: loadedInstanceID,
                    collectionIDs: draft.selectedCollectionIDs
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
        let title = draft.boundaryMapTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = draft.boundaryMapDescription
        let region = draft.boundaryMapCurrentRegion
        let latDelta = max(region.span.latitudeDelta, 0.0001)
        let zoom = log2(360.0 / latDelta)
        let newBoundaries = draft.boundaryMapNewAttachments.map { draft in
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
                    description: description,
                    defaultCenterLat: region.center.latitude,
                    defaultCenterLng: region.center.longitude,
                    defaultZoom: zoom,
                    showAllBoundariesInQuestion: draft.boundaryMapShowAllBoundariesInQuestion,
                    boundaries: newBoundaries
                )
                if !draft.selectedCollectionIDs.isEmpty {
                    try appDatabase.setInstanceCollections(
                        instanceID: instanceID,
                        collectionIDs: draft.selectedCollectionIDs
                    )
                }
                onAddSaved?(typeID)
                resetBoundaryMapState()
                showToast(message: "BoundaryMap added successfully.", style: .success)
            case .edit:
                guard let loadedInstanceID = draft.loadedInstanceID else { return }
                let saveLat: Double
                let saveLng: Double
                let saveZoom: Double
                if draft.boundaryMapApplyCurrentViewport {
                    saveLat = region.center.latitude
                    saveLng = region.center.longitude
                    saveZoom = zoom
                } else {
                    saveLat = draft.boundaryMapLoadedDefaultCenterLat ?? region.center.latitude
                    saveLng = draft.boundaryMapLoadedDefaultCenterLng ?? region.center.longitude
                    saveZoom = draft.boundaryMapLoadedDefaultZoom ?? zoom
                }
                let keptExistingAttachments = draft.boundaryMapExistingAttachments
                    .filter { !draft.boundaryMapDeletedExistingIDs.contains($0.id) }
                try appDatabase.updateBoundaryMapInstance(
                    instanceID: loadedInstanceID,
                    title: title,
                    description: description,
                    defaultCenterLat: saveLat,
                    defaultCenterLng: saveLng,
                    defaultZoom: saveZoom,
                    showAllBoundariesInQuestion: draft.boundaryMapShowAllBoundariesInQuestion,
                    existingAttachments: keptExistingAttachments,
                    newBoundaries: newBoundaries
                )
                try appDatabase.setInstanceCollections(
                    instanceID: loadedInstanceID,
                    collectionIDs: draft.selectedCollectionIDs
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
            get: { draft.fieldValues[fieldID, default: ""] },
            set: { draft.fieldValues[fieldID] = $0 }
        )
    }

    private func submitInstance() {
        guard canSubmit else { return }

        Task {
            await submitCurrentInstance()
        }
    }

    private func handleCommandS() {
        if mode == .edit {
            submitInstance()
            return
        }
        guard let selectedTypeID = draft.selectedTypeID,
              let fieldID = focusController.activeFieldID ?? focusController.lastFocusedFieldID,
              // The Person office cards' text views register synthetic
              // (negative) field ids; sticky is a real-field concept and
              // toggling it here would write a bogus sticky row.
              draft.fields.contains(where: { $0.id == fieldID }) else { return }
        toggleSticky(typeID: selectedTypeID, fieldID: fieldID)
    }

    private func copyInstanceIDToClipboard(_ instanceID: Int64) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(instanceID), forType: .string)
    }

    private func copyInstanceLinkToClipboard() {
        guard let loadedInstanceID = draft.loadedInstanceID else { return }
        let link = #"<a href="id:\#(loadedInstanceID)"></a>"#
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        showToast(message: "Link copied", style: .success)
    }

    private func liveFieldValuesByName() -> [String: String] {
        Dictionary(uniqueKeysWithValues: draft.fields.map { field in
            (field.name, draft.fieldValues[field.id] ?? "")
        })
    }

    /// Opens the Query Preview window for one query type, using the editor's live
    /// field values so the preview reflects what's currently typed. In Edit mode
    /// the preview is keyed on the persisted instance; in Add mode it's a draft
    /// preview built from the type alone.
    private func openPreview(queryTypeID: Int64) {
        switch mode {
        case .edit:
            guard let loadedInstanceID = draft.loadedInstanceID else { return }
            queryPreviewWindowState.requestOpen(
                instanceID: loadedInstanceID,
                queryTypeID: queryTypeID,
                fieldValuesByName: liveFieldValuesByName(),
                collectionIDs: draft.selectedCollectionIDs
            )
        case .add:
            guard let selectedTypeID = draft.selectedTypeID else { return }
            queryPreviewWindowState.requestOpenDraft(
                typeID: selectedTypeID,
                queryTypeID: queryTypeID,
                fieldValuesByName: liveFieldValuesByName(),
                collectionIDs: draft.selectedCollectionIDs
            )
        }
        openWindow(id: "query-preview")
    }

    private func previewTopmostCheckedQueryType() {
        let displayedQueryTypes = draft.queryTypes.sorted { $0.id < $1.id }
        guard let topmost = displayedQueryTypes.first(where: { draft.selectedQueryTypeIDs.contains($0.id) }) else {
            return
        }
        openPreview(queryTypeID: topmost.id)
    }

    private func wrapFocusedSelection(openTag: String, closeTag: String) {
        _ = focusController.wrapFocusedSelection(openTag: openTag, closeTag: closeTag)
    }

    private func presentTypePicker() {
        guard mode == .add, !types.isEmpty else { return }
        let currentWindow = NSApp.keyWindow
        typePickerController.present(
            types: types,
            currentTypeID: draft.selectedTypeID,
            from: currentWindow
        ) { [self] typeID in
            shouldFocusFirstFieldAfterTypePick = true
            draft.selectedTypeID = typeID
        }
    }

    @MainActor
    private func insertImageIntoCurrentField() {
        guard draft.selectedTypeID != nil else {
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

    @MainActor
    private func presentTablePicker() {
        tableSizePickerController.present(
            initialRows: TableInsertSizeStore.shared.lastRows,
            initialCols: TableInsertSizeStore.shared.lastCols,
            from: NSApp.keyWindow
        ) { [self] rows, cols in
            insertTableIntoCurrentField(rows: rows, cols: cols)
        }
    }

    @MainActor
    private func insertTableIntoCurrentField(rows: Int, cols: Int) {
        let rowsHTML = (1...rows).map { r in
            "<tr>" + (1...cols).map { c in "<td>CELL\(r)_\(c)</td>" }.joined() + "</tr>"
        }.joined(separator: "\n")
        let tableHTML = "<table>\n" + rowsHTML + "\n</table>"

        guard focusController.insertAtEndOfFocusedLine(tableHTML, selecting: "CELL1_1") else {
            showToast(message: "Select a field before inserting a table.", style: .error)
            return
        }

        TableInsertSizeStore.shared.lastRows = rows
        TableInsertSizeStore.shared.lastCols = cols
    }

    private func toggleSticky(typeID: Int64, fieldID: Int64) {
        let newSticky = !draft.stickyFieldIDs.contains(fieldID)
        do {
            try appDatabase.setStickyField(typeID: typeID, fieldID: fieldID, isSticky: newSticky)
            if newSticky {
                draft.stickyFieldIDs.insert(fieldID)
            } else {
                draft.stickyFieldIDs.remove(fieldID)
            }
        } catch {
            showToast(message: "Failed to update sticky field.", style: .error)
        }
    }

    private func toggleCollapsed(typeID: Int64, fieldID: Int64) {
        let newCollapsed = !draft.collapsedFieldIDs.contains(fieldID)
        do {
            try appDatabase.setCollapsedField(typeID: typeID, fieldID: fieldID, isCollapsed: newCollapsed)
            if newCollapsed {
                let hadFocus = focusController.activeFieldID == fieldID
                draft.collapsedFieldIDs.insert(fieldID)
                // Collapsing the focused field unmounts its text view, which
                // would strand first responder on the window and take Tab out
                // of the field cycle — hand focus to the next expanded field
                // (falling through to the collection search, like Tab does)
                // BEFORE the render pass removes the view.
                if hadFocus {
                    let ids = navigableFieldIDs
                    let followingID = draft.fields
                        .drop(while: { $0.id != fieldID })
                        .dropFirst()
                        .first(where: { ids.contains($0.id) })?
                        .id
                    if let followingID {
                        focusController.focusField(followingID)
                    } else {
                        focusController.focusCollectionSearch()
                    }
                }
            } else {
                draft.collapsedFieldIDs.remove(fieldID)
            }
        } catch {
            showToast(message: "Failed to update collapsed field.", style: .error)
        }
    }

    // Tab navigation only visits text fields — boolean fields are checkboxes, not
    // NSTextViews, so they aren't part of the focus chain. Collapsed fields have
    // no mounted text view, so they're skipped too.
    private var navigableFieldIDs: [Int64] {
        draft.fields
            .filter { $0.fieldType == .text && !draft.collapsedFieldIDs.contains($0.id) }
            .map(\.id)
    }

    private func focusNextField(after fieldID: Int64?) {
        let ids = navigableFieldIDs
        guard !ids.isEmpty else { return }

        guard let fieldID, let currentIndex = ids.firstIndex(of: fieldID) else {
            focusController.focusField(ids.first)
            return
        }

        let nextIndex = ids.index(after: currentIndex)
        if nextIndex < ids.endIndex {
            focusController.focusField(ids[nextIndex])
        } else {
            focusController.focusCollectionSearch()
        }
    }

    private func focusPreviousField(before fieldID: Int64?) {
        let ids = navigableFieldIDs
        guard !ids.isEmpty else { return }

        guard let fieldID, let currentIndex = ids.firstIndex(of: fieldID) else {
            focusController.focusField(ids.last)
            return
        }

        if currentIndex > ids.startIndex {
            focusController.focusField(ids[ids.index(before: currentIndex)])
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
            draft.queryIntervalsByQueryTypeID[queryTypeID] = 0
        } catch {
            print("Failed to reset query due date: \(error)")
            showToast(message: "Failed to reset query due date.", style: .error)
        }
    }

    /// Delete-confirmation body; for a connected Person it also spells out the
    /// relationship/succession consequences.
    private var computedInstanceDeletionMessage: String {
        var message = "This action is irreversible."
        if isPersonSelected, let instanceID = draft.loadedInstanceID,
           let connections = try? appDatabase.hasPersonConnections(instanceID: instanceID),
           connections > 0 {
            message += " This person is linked to \(connections) other \(connections == 1 ? "person" : "people"): relationship and office succession references become plain names."
        }
        return message
    }

    @MainActor
    private func deleteCurrentInstance() {
        guard let loadedInstanceID = draft.loadedInstanceID else { return }
        do {
            try appDatabase.deleteInstance(instanceID: loadedInstanceID)
            NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
            // Close the entire Edit Instance window. Deferred to the next runloop tick so
            // the confirmation alert finishes tearing down first — dismissing the window
            // while its alert is still the active modal would otherwise be dropped.
            DispatchQueue.main.async {
                dismiss()
            }
        } catch {
            showToast(message: "Failed to delete instance.", style: .error)
        }
    }

    /// Maps the draft's per-partner rows to the saved partnership ids so
    /// preview/reset can target "Children with" queries. nil for unsaved cards.
    private func personPartnershipID(forEntryID entryID: UUID?) -> Int64? {
        guard let entryID else { return nil }
        return draft.personPartners.first(where: { $0.id == entryID })?.partnershipID
    }

    /// The persisted office id for an office checklist row, or nil when the
    /// card was added this session and hasn't been saved yet (no holding row,
    /// so no per-office query exists to preview/reset).
    private func personSavedOfficeID(forEntryID officeEntryID: UUID?) -> Int64? {
        guard let officeEntryID,
              let entry = draft.personOffices.first(where: { $0.id == officeEntryID }),
              entry.holdingID != nil else { return nil }
        return entry.officeID
    }

    /// Preview a built-in Person query from the editor's CURRENT draft (both
    /// modes), so unsaved relationship/office/field edits render — including
    /// queries of not-yet-saved partners and offices.
    private func openPersonQueryPreview(kind: PersonQueryKind, partnerEntryID: UUID?, officeEntryID: UUID?) {
        // buildPersonRelationsDraft maps personPartners/personOffices in
        // order, so an entry's index addresses the same item in the payload.
        var partnerIndex: Int?
        if kind == .childrenWith {
            guard let index = draft.personPartners.firstIndex(where: { $0.id == partnerEntryID }) else { return }
            partnerIndex = index
        }
        var officeIndex: Int?
        if kind == .office {
            guard let index = draft.personOffices.firstIndex(where: { $0.id == officeEntryID }) else { return }
            officeIndex = index
        }
        queryPreviewWindowState.requestOpenPersonDraft(
            kind: kind,
            relations: draft.buildPersonRelationsDraft(),
            partnerIndex: partnerIndex,
            officeIndex: officeIndex,
            selfInstanceID: mode == .edit ? draft.loadedInstanceID : nil,
            fieldValuesByName: liveFieldValuesByName(),
            collectionIDs: draft.selectedCollectionIDs
        )
        openWindow(id: "query-preview")
    }

    @MainActor
    private func resetPersonQueryDueDate(kind: PersonQueryKind, partnerEntryID: UUID?, officeEntryID: UUID?) {
        guard let loadedInstanceID = draft.loadedInstanceID else { return }
        if kind == .childrenWith, personPartnershipID(forEntryID: partnerEntryID) == nil { return }
        if kind == .office, personSavedOfficeID(forEntryID: officeEntryID) == nil { return }
        do {
            try appDatabase.resetQueryDueDates(targets: [QueryTarget(
                instanceID: loadedInstanceID,
                queryTypeID: 0,
                isReverse: false,
                kind: .person,
                personKind: kind,
                personPartnershipID: personPartnershipID(forEntryID: partnerEntryID),
                personOfficeID: personSavedOfficeID(forEntryID: officeEntryID)
            )])
            if let officeEntryID,
               let index = draft.personOffices.firstIndex(where: { $0.id == officeEntryID }) {
                draft.personOffices[index].officeQueryInterval = 0
            } else if let partnerEntryID,
               let index = draft.personPartners.firstIndex(where: { $0.id == partnerEntryID }) {
                draft.personPartners[index].childrenQueryInterval = 0
            } else {
                draft.personQueryIntervalsByKind[kind] = 0
            }
        } catch {
            showToast(message: "Failed to reset query due date.", style: .error)
        }
    }

    @MainActor
    private func applyPersonEditorData(_ data: PersonEditorData) {
        draft.personMother = data.relations.mother
        draft.personFather = data.relations.father
        draft.personAdoptiveMother = data.relations.adoptiveMother
        draft.personAdoptiveFather = data.relations.adoptiveFather
        draft.personPartners = data.relations.partners.map { partner in
            var entry = PersonPartnerDraftEntry(
                partnershipID: partner.partnershipID,
                partner: partner.partner,
                isMarried: partner.isMarried,
                startText: partner.startText,
                endText: partner.endText,
                children: partner.children.map { PersonChildEntry(rowID: $0.rowID, child: $0.child) },
                isChildrenQueryEnabled: partner.isChildrenQueryEnabled
            )
            if partner.isChildrenQueryEnabled, let partnershipID = partner.partnershipID,
               let info = try? appDatabase.fetchPersonBuiltinQueryInfos(instanceID: data.instanceID)
                   .first(where: { $0.kind == .childrenWith && $0.partnershipID == partnershipID }) {
                entry.childrenQueryInterval = info.interval
            }
            return entry
        }
        draft.personUngroupedChildren = data.relations.ungroupedChildren.map {
            PersonChildEntry(rowID: $0.rowID, child: $0.child)
        }
        draft.personOffices = data.relations.offices.map { office in
            var entry = PersonOfficeDraftEntry(
                holdingID: office.personOfficeID,
                officeID: office.officeID,
                officeName: data.officeNamesByID[office.officeID] ?? "#\(office.officeID)",
                whenBeganText: office.whenBegan,
                whenEndedText: office.whenEnded,
                noteText: office.note,
                predecessors: office.predecessors,
                successors: office.successors,
                isOfficeQueryEnabled: office.isQueryEnabled
            )
            if office.isQueryEnabled,
               let info = data.builtinQueries.first(where: { $0.kind == .office && $0.officeID == office.officeID }) {
                entry.officeQueryInterval = info.interval
            }
            return entry
        }
        // Per-office rows must NOT leak into the standalone kind set — it is
        // passed to savePersonInstance(builtinEnabledKinds:), where a stray
        // .office member would be meaningless (office enablement rides the
        // offices payload). .allOffices IS standalone and stays.
        draft.personEnabledQueryKinds = Set(
            data.builtinQueries.filter { $0.enabled && $0.kind != .office }.map(\.kind)
        )
        draft.personQueryIntervalsByKind = Dictionary(
            uniqueKeysWithValues: data.builtinQueries.compactMap { info in
                guard info.enabled, info.partnershipID == nil, info.kind != .office else { return nil }
                return (info.kind, info.interval ?? 0)
            }
        )
        draft.personDisplayNamesByID = data.displayNamesByInstanceID
        draft.personSexesByID = data.sexesByInstanceID
        draft.personTimePeriodsByID = data.timePeriodsByInstanceID
    }

    @MainActor
    private func submitPersonInstance(typeID: Int64) async {
        let parsedMaxInterval: Int64? = Int64(draft.maxIntervalText)

        do {
            let result = try appDatabase.savePersonInstance(
                instanceID: mode == .edit ? draft.loadedInstanceID : nil,
                fieldValuesByFieldID: draft.fieldValues,
                queryTypeIDs: draft.selectedQueryTypeIDs,
                relations: draft.buildPersonRelationsDraft(),
                builtinEnabledKinds: draft.personEnabledQueryKinds
            )
            if !draft.selectedCollectionIDs.isEmpty || mode == .edit {
                try appDatabase.setInstanceCollections(
                    instanceID: result.instanceID,
                    collectionIDs: draft.selectedCollectionIDs
                )
            }
            if parsedMaxInterval != nil || mode == .edit {
                try appDatabase.setMaxInterval(
                    forInstanceID: result.instanceID,
                    maxInterval: parsedMaxInterval
                )
            }

            let resetSuffix = result.resetQueryCount > 0
                ? " \(result.resetQueryCount) \(result.resetQueryCount == 1 ? "query" : "queries") reset."
                : ""

            switch mode {
            case .add:
                onAddSaved?(typeID)
                // Resign a focused partner/office card field before
                // resetPersonState() empties the arrays behind it (see
                // endEditing() — belt-and-braces now that card fields use
                // id-keyed bindings).
                focusController.endEditing()
                draft.fieldValues = Dictionary(
                    uniqueKeysWithValues: draft.fields.map { field in
                        let preserved = draft.stickyFieldIDs.contains(field.id) ? draft.fieldValues[field.id] ?? "" : ""
                        return (field.id, preserved)
                    }
                )
                draft.resetPersonState()
                // navigableFieldIDs, not draft.fields: with the Name field
                // collapsed, focusing it would leave NOTHING focused after the
                // endEditing() above (the collapsed field mounts no text view).
                focusController.focusField(navigableFieldIDs.first)
                addScrollNonce = UUID()
                showToast(message: "Person added successfully.\(resetSuffix)", style: .success)
            case .edit:
                onEditSaved?(result.instanceID)
                if result.resetQueryCount > 0 {
                    // Leave the toast on screen long enough to read the count.
                    showToast(message: "Changes saved.\(resetSuffix)", style: .success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        dismiss()
                    }
                } else {
                    dismiss()
                }
            }
        } catch let error as PersonSaveError {
            presentPersonConflictAlert(error)
        } catch {
            let message = (error as? DatabaseError)?.message ?? "Failed to save."
            showToast(message: message, style: .error)
        }
    }

    /// The BLOCKING contradiction popup: one bullet per affected instance/field.
    @MainActor
    private func presentPersonConflictAlert(_ error: PersonSaveError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot save — contradictory relationships"
        let bullets = error.conflicts.map { conflict in
            let idSuffix = conflict.instanceID.map { " (ID \($0))" } ?? ""
            return "• \(conflict.displayName)\(idSuffix): \(conflict.kind.description)"
        }.joined(separator: "\n")
        alert.informativeText = "Saving would contradict existing relationship data:\n\n\(bullets)\n\nNo changes were saved."
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
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
