//
//  ChangeTypeWindowView.swift
//  Memor
//
//  "Change Type" window: converts one or more same-typed instances to a destination
//  type with a user-defined field mapping, query-type selection (each checked query
//  type optionally copying SRS data from a source query type via "Copy Data From"),
//  and collection handling — preserving each instance's ID. Supports Object->Object
//  and Object->Person conversions (never away from Person or the map types).
//

import AppKit
import Combine
import SwiftUI

final class ChangeTypeWindowState: ObservableObject {
    @Published private(set) var requestNonce = UUID()
    @Published private(set) var instanceIDs: [Int64] = []
    @Published private(set) var sourceTypeID: Int64?

    // Bumped after a successful conversion so the originating Search window can refresh.
    @Published private(set) var conversionNonce = UUID()

    func requestOpen(instanceIDs: [Int64], sourceTypeID: Int64) {
        self.instanceIDs = instanceIDs
        self.sourceTypeID = sourceTypeID
        requestNonce = UUID()
    }

    func notifyConversion() {
        conversionNonce = UUID()
    }
}

private enum CollectionHandling {
    case keep
    case remove
}

/// Identifies a hoverable row on the destination column.
private enum DestRow: Hashable {
    case field(Int64)
    case queryType(Int64)
}

/// Gives a destination-column row a slight background highlight while hovered.
private struct DestRowHoverHighlight: ViewModifier {
    let row: DestRow
    @Binding var hovered: DestRow?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovered == row ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    hovered = row
                } else if hovered == row {
                    hovered = nil
                }
            }
    }
}

struct ChangeTypeWindowView: View {
    let appDatabase: AppDatabase

    @EnvironmentObject private var windowState: ChangeTypeWindowState
    @Environment(\.dismiss) private var dismiss

    // Loaded source data.
    @State private var sourceType: FlashcardType?
    @State private var sourceFields: [TypeField] = []
    @State private var sourceQueryTypes: [QueryType] = []
    @State private var queryTypeEnableCounts: [Int64: Int] = [:]

    // Destination candidates + selection.
    @State private var destCandidates: [FlashcardType] = []
    @State private var selectedDestTypeID: Int64?
    @State private var destType: FlashcardType?
    @State private var destFields: [TypeField] = []
    @State private var destQueryTypes: [QueryType] = []

    // User choices.
    @State private var fieldMapping: [Int64: Int64?] = [:]   // destFieldID -> sourceFieldID?
    @State private var enabledDestQueryTypeIDs: Set<Int64> = []
    @State private var queryDataMapping: [Int64: Int64?] = [:]   // destQueryTypeID -> sourceQueryTypeID? ("(None)" = nil)
    @State private var collectionHandling: CollectionHandling = .keep

    @State private var hoveredDestRow: DestRow?

    @State private var errorMessage: String?

    private var instanceCount: Int { windowState.instanceIDs.count }

    var body: some View {
        VStack(spacing: 0) {
            Text("Converting \(instanceCount) instance\(instanceCount == 1 ? "" : "(s)").")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        sourceColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        destinationColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if destType?.isPerson == true {
                        Text("Converted instances will have no relationships. Built-in relationship queries start disabled and can be enabled per person in the instance editor.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    Picker("", selection: $collectionHandling) {
                        Text("Keep instances in the same collections after conversion.")
                            .tag(CollectionHandling.keep)
                        Text("Remove instances from their collections after conversion.")
                            .tag(CollectionHandling.remove)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                .padding(16)
            }

            Divider()

            bottomBar
        }
        .frame(minWidth: 660, minHeight: 480)
        .task(id: windowState.requestNonce) {
            loadSourceData()
        }
        .onChange(of: selectedDestTypeID) { _, _ in
            loadDestinationData()
        }
        .onExitCommand {
            dismiss()
        }
        .alert(
            "Could not change type",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Source column (read-only)

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source Type")
                .font(.headline)

            Text(sourceType?.name ?? "")
                .font(.title3)

            VStack(alignment: .leading, spacing: 6) {
                Text("Fields")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if sourceFields.isEmpty {
                    Text("(no fields)")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(sourceFields) { field in
                        Text(field.name)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Query Types")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if sourceQueryTypes.isEmpty {
                    Text("(no query types)")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(sourceQueryTypes) { queryType in
                        HStack(spacing: 6) {
                            Image(systemName: sourceCheckboxSymbol(for: queryType))
                                .foregroundStyle(.secondary)
                            Text(queryType.name)
                        }
                    }
                }
            }
        }
    }

    /// Tri-state checkbox glyph: all input instances have it, some, or none.
    private func sourceCheckboxSymbol(for queryType: QueryType) -> String {
        let count = queryTypeEnableCounts[queryType.id] ?? 0
        if count == 0 {
            return "square"
        } else if count >= instanceCount {
            return "checkmark.square.fill"
        } else {
            return "minus.square"
        }
    }

    // MARK: - Destination column (editable)

    private var destinationColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Destination Type")
                .font(.headline)

            Picker("", selection: $selectedDestTypeID) {
                Text("Select a type…").tag(Int64?.none)
                ForEach(destCandidates) { candidate in
                    Text(candidate.name).tag(Optional(candidate.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280, alignment: .leading)

            if destType != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fields")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if destFields.isEmpty {
                        Text("(no fields)")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(destFields) { field in
                            HStack(spacing: 8) {
                                Text(field.name)
                                Spacer(minLength: 8)
                                if field.fieldType == .sex {
                                    Text("Male (default)")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 180, alignment: .leading)
                                        .help("Sex can't be mapped during conversion; converted people start as Male.")
                                } else {
                                    Picker("", selection: mappingBinding(for: field.id)) {
                                        Text("(none)").tag(Int64?.none)
                                        ForEach(sourceFields) { sourceField in
                                            Text(sourceField.name).tag(Optional(sourceField.id))
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 180)
                                }
                            }
                            .modifier(DestRowHoverHighlight(row: .field(field.id), hovered: $hoveredDestRow))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if destQueryTypes.isEmpty {
                        Text("Query Types")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("(no query types)")
                            .foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 8) {
                            Text("Query Types")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            // Trailing-only padding: the 180pt frame lines up over the
                            // picker column (inset 6 by DestRowHoverHighlight) while the
                            // caption stays at x=0 with its sibling captions.
                            Text("Copy Data From")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 180, alignment: .leading)
                                .padding(.trailing, 6)
                        }
                        ForEach(destQueryTypes) { queryType in
                            HStack(spacing: 8) {
                                Toggle(queryType.name, isOn: destQueryTypeBinding(for: queryType.id))
                                    .toggleStyle(.checkbox)
                                Spacer(minLength: 8)
                                Picker("", selection: queryDataBinding(for: queryType.id)) {
                                    Text("(None)").tag(Int64?.none)
                                    ForEach(sourceQueryTypes) { sourceQueryType in
                                        Text(sourceQueryType.name).tag(Optional(sourceQueryType.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 180)
                                .disabled(!enabledDestQueryTypeIDs.contains(queryType.id))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(DestRowHoverHighlight(row: .queryType(queryType.id), hovered: $hoveredDestRow))
                        }
                    }
                }
            }
        }
    }

    private func mappingBinding(for destFieldID: Int64) -> Binding<Int64?> {
        Binding(
            get: { fieldMapping[destFieldID] ?? nil },
            set: { fieldMapping[destFieldID] = $0 }
        )
    }

    private func queryDataBinding(for destQueryTypeID: Int64) -> Binding<Int64?> {
        Binding(
            get: { queryDataMapping[destQueryTypeID] ?? nil },
            set: { queryDataMapping[destQueryTypeID] = $0 }
        )
    }

    private func destQueryTypeBinding(for queryTypeID: Int64) -> Binding<Bool> {
        Binding(
            get: { enabledDestQueryTypeIDs.contains(queryTypeID) },
            set: { isOn in
                if isOn {
                    enabledDestQueryTypeIDs.insert(queryTypeID)
                } else {
                    enabledDestQueryTypeIDs.remove(queryTypeID)
                }
            }
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                dismiss()
            }
            Spacer()
            Button("Change Type") {
                performConversion()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedDestTypeID == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Data loading

    private func loadSourceData() {
        guard let sourceTypeID = windowState.sourceTypeID else { return }
        do {
            let type = try appDatabase.fetchType(typeID: sourceTypeID)
            sourceType = type
            sourceFields = try appDatabase.fetchFieldsForDisplay(forTypeID: sourceTypeID)
            sourceQueryTypes = try appDatabase.fetchQueryTypes(forTypeID: sourceTypeID)
            queryTypeEnableCounts = try appDatabase.fetchQueryTypeEnableCounts(instanceIDs: windowState.instanceIDs)

            let allTypes = try appDatabase.fetchTypes()
            destCandidates = allTypes
                .filter { candidate in
                    candidate.id != sourceTypeID
                        && (!candidate.isBuiltin || candidate.isPerson)
                        && candidate.name != POINTMAP_TYPE_NAME
                        && candidate.name != BOUNDARYMAP_TYPE_NAME
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Reset destination selection on (re)open.
            selectedDestTypeID = nil
            destType = nil
            destFields = []
            destQueryTypes = []
            fieldMapping = [:]
            enabledDestQueryTypeIDs = []
            queryDataMapping = [:]
            collectionHandling = .keep
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadDestinationData() {
        guard let destTypeID = selectedDestTypeID else {
            destType = nil
            destFields = []
            destQueryTypes = []
            fieldMapping = [:]
            enabledDestQueryTypeIDs = []
            queryDataMapping = [:]
            return
        }
        do {
            destType = destCandidates.first { $0.id == destTypeID }
            destFields = try appDatabase.fetchFieldsForDisplay(forTypeID: destTypeID)
            destQueryTypes = try appDatabase.fetchQueryTypes(forTypeID: destTypeID)
            enabledDestQueryTypeIDs = []
            queryDataMapping = [:]
            fieldMapping = autoPopulatedMapping()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Auto-populate destination field pickers:
    /// 1. Exact-name match maps a destination field to the source field of the same name.
    /// 2. Remaining source fields (in source order) fill the still-blank destination
    ///    pickers (in destination order). Leftover destination pickers stay "(none)".
    private func autoPopulatedMapping() -> [Int64: Int64?] {
        var mapping: [Int64: Int64?] = [:]
        var assignedSourceIDs: Set<Int64> = []

        // Sex is never a mapping target (converted people start as Male).
        let mappableDestFields = destFields.filter { $0.fieldType != .sex }

        for destField in mappableDestFields {
            mapping[destField.id] = nil
            if let match = sourceFields.first(where: { $0.name == destField.name && !assignedSourceIDs.contains($0.id) }) {
                mapping[destField.id] = match.id
                assignedSourceIDs.insert(match.id)
            }
        }

        let leftoverSources = sourceFields.filter { !assignedSourceIDs.contains($0.id) }
        let blankDestFields = mappableDestFields.filter { (mapping[$0.id] ?? nil) == nil }
        for (blank, source) in zip(blankDestFields, leftoverSources) {
            mapping[blank.id] = source.id
        }

        return mapping
    }

    // MARK: - Conversion

    private func performConversion() {
        guard let destTypeID = selectedDestTypeID,
              let source = sourceType,
              let destination = destType else {
            return
        }
        let count = windowState.instanceIDs.count
        let sourceName = source.name
        let destName = destination.name

        // Only checked query types with a non-"(None)" selector copy SRS data.
        let queryDataSources = queryDataMapping
            .compactMapValues { $0 }
            .filter { enabledDestQueryTypeIDs.contains($0.key) }

        do {
            try appDatabase.changeInstanceType(
                instanceIDs: windowState.instanceIDs,
                sourceTypeID: source.id,
                destTypeID: destTypeID,
                fieldMapping: fieldMapping,
                enabledDestQueryTypeIDs: enabledDestQueryTypeIDs,
                queryDataSources: queryDataSources,
                removeFromCollections: collectionHandling == .remove
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        windowState.notifyConversion()
        NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)
        dismiss()
        presentSuccessAlert(count: count, sourceName: sourceName, destName: destName)
    }

    private func presentSuccessAlert(count: Int, sourceName: String, destName: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Type change successful"
        alert.informativeText = "\(count) instance\(count == 1 ? "" : "s") changed from \(sourceName) to \(destName)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
