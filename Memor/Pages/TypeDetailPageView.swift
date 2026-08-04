//
//  TypeDetailPageView.swift
//  Memor
//
//  Detail pane for a single type: fields section, query-type editors, preview, and CSS editor.
//

import AppKit
import GRDB
import SwiftUI

struct TypeDetailPageView: View {
    let type: FlashcardType
    let appDatabase: AppDatabase
    let shouldAutoPresentRenamePopover: Bool
    let onAutoRenamePopoverPresented: () -> Void
    let onBack: () -> Void

    @EnvironmentObject private var manageOfficesWindowState: ManageOfficesWindowState
    @Environment(\.openWindow) private var openWindow

    @FocusState private var isAddFieldNameFocused: Bool
    @FocusState private var isRenameTypeNameFocused: Bool
    @FocusState private var isRenameQueryTypeNameFocused: Bool
    @State private var activeEditor: FocusedEditor? = .html
    @State private var fields: [TypeField] = []
    @State private var queryTypes: [QueryType] = []
    @State private var selectedQueryTypeID: Int64?
    @State private var selectedQueryHTML = ""
    @State private var selectedTypeCSS = ""
    @State private var selectedHTMLContentMode: HTMLContentMode = .query
    @State private var pendingHTMLSaveQueryTypeID: Int64?
    @State private var pendingHTMLSaveMode: HTMLContentMode = .query
    @State private var pendingHTMLSaveText: String = ""
    @State private var hasPendingHTMLSave: Bool = false
    @State private var htmlSaveTask: Task<Void, Never>?
    @State private var hasPendingCSSSave: Bool = false
    @State private var cssSaveTask: Task<Void, Never>?
    @State private var isSyncingEditorState: Bool = false
    @State private var editorSplitRatio: CGFloat = 0.5
    @State private var errorMessage: String?
    @State private var previewHTML = ""
    @State private var previewErrorMessage: String?
    @State private var isIDCopyButtonHovered = false
    // The preview hosts a WKWebView, whose synchronous creation (~hundreds of ms
    // the first time) would otherwise block the navigation into this page. Mount
    // it one runloop after the page's first paint so the transition feels instant.
    @State private var isPreviewMounted = false
    @State private var isAddFieldPopoverPresented = false
    @State private var newFieldName = ""
    @State private var newFieldType: FieldKind = .text
    @State private var fieldPendingDeletion: TypeField?
    @State private var fieldPendingRename: TypeField?
    @State private var renamedFieldName = ""
    @State private var displayedTypeName = ""
    @State private var description: String = ""
    @State private var descriptionSaveTask: Task<Void, Never>?
    @State private var isRenameTypePopoverPresented = false
    @State private var renamedTypeName = ""
    @State private var isRenameQueryTypePopoverPresented = false
    @State private var renamedQueryTypeName = ""
    @State private var isAddQueryTypePopoverPresented = false
    @State private var newQueryTypeName = ""
    @State private var isDuplicateQueryTypePopoverPresented = false
    @State private var duplicateQueryTypeName = ""
    @State private var queryTypePendingDeletion: QueryType?
    @State private var hasAutoPresentedRenamePopover = false

    // Person only
    @State private var personResetOnConnectionChange = false
    @State private var isPersonResetInfoPopoverPresented = false
    @State private var isPersonOfficesElementInfoPopoverPresented = false
    @State private var isInstanceIDInfoPopoverPresented = false
    /// Live copy of the customizable built-in-query "details" HTML (Person only).
    @State private var personBuiltinQueryHTML = ""
    /// Live copy of the per-office question template HTML (Person only).
    @State private var personOfficeQueryHTML = ""

    /// Sentinel `selectedQueryTypeID`s for the synthetic, non-deleteable
    /// "Built-in Relationship Queries" / "Built-in Office Queries" entries
    /// (Person only). Real query-type ids are positive.
    private static let builtinQueriesSelectionID: Int64 = -1
    private static let builtinOfficeQueriesSelectionID: Int64 = -2

    private var selectedQueryType: QueryType? {
        guard let selectedQueryTypeID else { return nil }
        return queryTypes.first(where: { $0.id == selectedQueryTypeID })
    }

    /// Whether the synthetic "Built-in Relationship Queries" entry is selected.
    private var isBuiltinQueriesSelected: Bool {
        type.isPerson && selectedQueryTypeID == Self.builtinQueriesSelectionID
    }

    /// Whether the synthetic "Built-in Office Queries" entry is selected.
    private var isBuiltinOfficeQueriesSelected: Bool {
        type.isPerson && selectedQueryTypeID == Self.builtinOfficeQueriesSelectionID
    }

    /// Either synthetic built-in entry (both are Question-only, non-renameable).
    private var isAnyBuiltinSelected: Bool {
        isBuiltinQueriesSelected || isBuiltinOfficeQueriesSelected
    }

    /// The query-types toolbar + editor show whenever there's something to edit:
    /// any user query type, or (on Person) always, thanks to "Built-in Queries".
    private var showsQueryTypesSection: Bool {
        type.isPerson || !displayedQueryTypes.isEmpty
    }

    private var displayedQueryTypes: [QueryType] {
        queryTypes.sorted { lhs, rhs in
            lhs.id < rhs.id
        }
    }

    var body: some View {
        if type.isBuiltin && !type.isPerson {
            builtinTypeBody
        } else {
            // Person is built-in but partially editable: user fields and query
            // types are fully editable, the protected fields and the type name
            // are locked, and Person-specific sections appear below the fields.
            editableTypeBody
        }
    }

    // Trailing "ID: N" + copy button shared by both header variants, matching
    // the Collections detail header.
    @ViewBuilder
    private var typeIDBadge: some View {
        Spacer(minLength: 0)

        Text("ID: \(type.id)")
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)

        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(String(type.id), forType: .string)
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

    private var builtinTypeBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: onBack) {
                    Label(AppTab.types.title, systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                HStack(spacing: 12) {
                    Text(type.name)
                        .font(.largeTitle)
                        .fontWeight(.semibold)

                    typeIDBadge
                }
                .frame(maxWidth: .infinity)

                Text("Built-in type — not editable")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var editableTypeBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: onBack) {
                    Label(AppTab.types.title, systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                HStack(spacing: 12) {
                    Text(displayedTypeName.isEmpty ? type.name : displayedTypeName)
                        .font(.largeTitle)
                        .fontWeight(.semibold)

                    if type.isPerson {
                        Text("(built-in)")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        Button {
                            manageOfficesWindowState.requestOpen()
                            openWindow(id: "manage-offices")
                        } label: {
                            Label("Edit Offices", systemImage: "building.columns")
                        }
                        .buttonStyle(.bordered)
                    }

                    if !type.isPerson {
                    Button {
                        renamedTypeName = displayedTypeName.isEmpty ? type.name : displayedTypeName
                        activeEditor = nil
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        isRenameTypePopoverPresented = true
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isRenameTypePopoverPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Edit Type Name")
                                .font(.headline)

                            TextField("Type Name", text: $renamedTypeName)
                                .solidFocusField()
                                .focused($isRenameTypeNameFocused)
                                .onSubmit {
                                    Task {
                                        await renameType()
                                    }
                                }

                            HStack {
                                Spacer()

                                Button("Cancel") {
                                    isRenameTypePopoverPresented = false
                                }

                                Button("Save") {
                                    Task {
                                        await renameType()
                                    }
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(renamedTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(16)
                        .frame(width: 280)
                        .onAppear {
                            DispatchQueue.main.async {
                                isRenameTypeNameFocused = true
                            }
                        }
                    }
                    }

                    typeIDBadge
                }
                .frame(maxWidth: .infinity)

                DescriptionEditor(text: $description)
                    .onChange(of: description) { _, newValue in
                        descriptionSaveTask?.cancel()
                        descriptionSaveTask = Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard !Task.isCancelled else { return }
                            try? appDatabase.updateTypeDescription(typeID: type.id, description: newValue)
                        }
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else {
                    Text("Fields")
                        .font(.title3)
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 6) {
                    FieldsSectionView(
                        fields: fields,
                        onEditField: { field in
                            renamedFieldName = field.name
                            fieldPendingRename = field
                        },
                        onDeleteField: { field in
                            fieldPendingDeletion = field
                        },
                        onReorder: { orderedIDs in
                            Task { await reorderFields(orderedIDs: orderedIDs) }
                        }
                    )

                    RenameFieldPopoverAnchor(
                        fieldPendingRename: $fieldPendingRename,
                        renamedFieldName: $renamedFieldName,
                        isFieldNameFocused: $isAddFieldNameFocused,
                        onSubmit: { field in
                            Task {
                                await renameField(field)
                            }
                        },
                        onCancel: {
                            fieldPendingRename = nil
                        }
                    )

                    Button("Add Field") {
                        newFieldName = ""
                        isAddFieldPopoverPresented = true
                    }
                    .popover(isPresented: $isAddFieldPopoverPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Add Field")
                                .font(.headline)

                            TextField("Field Name", text: $newFieldName)
                                .solidFocusField()
                                .focused($isAddFieldNameFocused)
                                .onSubmit {
                                    Task {
                                        await addField()
                                    }
                                }

                            Text("You can rename this later.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Picker("Field Type", selection: $newFieldType) {
                                Text("Text").tag(FieldKind.text)
                                Text("Boolean").tag(FieldKind.boolean)
                            }
                            .pickerStyle(.radioGroup)

                            Text("Field type can't be changed later.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Spacer()

                                Button("Cancel") {
                                    isAddFieldPopoverPresented = false
                                }

                                Button("Add") {
                                    Task {
                                        await addField()
                                    }
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(newFieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(16)
                        .frame(width: 280)
                        .onAppear {
                            isAddFieldNameFocused = true
                        }
                    }
                    }

                    if type.isPerson {
                        personBuiltinQueriesSection
                        personOfficeQueriesSection
                    }

                    Text("Query Types")
                        .font(.title3)
                        .fontWeight(.semibold)

                    queryTypesToolbar

                    queryEditorAndPreview
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onExitCommand(perform: onBack)
        .task {
            await loadTypeDetails()
            // First paint (page chrome + editors) is done; now bring in the
            // WebView-backed preview without having blocked the navigation.
            isPreviewMounted = true
        }
        .task(id: shouldAutoPresentRenamePopover) {
            guard shouldAutoPresentRenamePopover, !hasAutoPresentedRenamePopover else { return }
            hasAutoPresentedRenamePopover = true
            renamedTypeName = displayedTypeName.isEmpty ? type.name : displayedTypeName
            onAutoRenamePopoverPresented()
            activeEditor = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
            isRenameTypePopoverPresented = true
        }
        .onChange(of: selectedQueryTypeID) { _, newValue in
            flushPendingHTMLSave()
            syncSelectedQueryTypeEditorState(selectedQueryTypeID: newValue)
        }
        .onChange(of: selectedHTMLContentMode) { _, _ in
            flushPendingHTMLSave()
            syncSelectedQueryTypeEditorState(selectedQueryTypeID: selectedQueryTypeID)
        }
        .onChange(of: selectedQueryHTML) { _, _ in
            refreshPreviewCanvas()
            guard !isSyncingEditorState else { return }
            scheduleHTMLAutoSave()
        }
        .onChange(of: selectedTypeCSS) { _, _ in
            refreshPreviewCanvas()
            guard !isSyncingEditorState else { return }
            scheduleCSSAutoSave()
        }
        .onDisappear {
            flushPendingHTMLSave()
            flushPendingCSSSave()
        }
        .modifier(TypeDetailAlertsModifier(
            fieldPendingDeletion: $fieldPendingDeletion,
            queryTypePendingDeletion: $queryTypePendingDeletion,
            onDeleteField: { field in Task { await deleteField(field) } },
            onDeleteQueryType: { queryType in Task { await deleteQueryType(queryType) } }
        ))
        .onChange(of: isRenameQueryTypePopoverPresented) { _, isPresented in
            guard isPresented else { return }
            activeEditor = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: isRenameTypePopoverPresented) { _, isPresented in
            guard isPresented else { return }
            activeEditor = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: isAddQueryTypePopoverPresented) { _, isPresented in
            guard isPresented else { return }
            activeEditor = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: isDuplicateQueryTypePopoverPresented) { _, isPresented in
            guard isPresented else { return }
            activeEditor = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private var personBuiltinQueriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Built-in Relationship Queries")
                .font(.title3)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(personBuiltinQueryRows.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                        Text(row.1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if index < personBuiltinQueryRows.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }

            Text("Enabled per person in the instance editor. Answers are computed from the person's relationships and rendered with this type's CSS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Toggle(
                    "Reset affected queries when connections change",
                    isOn: Binding(
                        get: { personResetOnConnectionChange },
                        set: { isOn in
                            personResetOnConnectionChange = isOn
                            try? appDatabase.setPersonResetQueriesOnConnectionChange(isOn)
                        }
                    )
                )
                .toggleStyle(.checkbox)

                Button {
                    isPersonResetInfoPopoverPresented = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $isPersonResetInfoPopoverPresented, arrowEdge: .bottom) {
                    Text("Whenever a Person's relationship to another Person instance changes, every enabled built-in query that asks about that relationship — on this person or anyone the change propagates to — is reset to new. A green toast reports how many queries were reset after each save.")
                        .font(.callout)
                        .frame(width: 320, alignment: .leading)
                        .padding(12)
                }
                .help("What does this do?")
            }
        }
    }

    private var personBuiltinQueryRows: [(String, String)] {
        [
            ("Mother", "Who is this person's mother?"),
            ("Father", "Who is this person's father?"),
            ("Parents", "Who are this person's parents?"),
            ("Adoptive Mother", "Who is this person's adoptive mother?"),
            ("Adoptive Father", "Who is this person's adoptive father?"),
            ("Children", "Who are this person's children, grouped by partner?"),
            ("Children with {partner}", "One query per listed partner."),
            ("Full Siblings", "Who shares both parents with this person?"),
        ]
    }

    private var personOfficeQueriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Built-in Office Queries")
                .font(.title3)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(personOfficeQueryRows.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                        Text(row.1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if index < personOfficeQueryRows.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }

            Text("Offices are managed via Edit Offices and assigned per person in the instance editor. The question HTML (under Query Types) supports the {{@Office}}, {{@WhenBegan}}, {{@WhenEnded}}, and {{@Note}} tokens; answers are computed from the person's holdings and succession links.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var personOfficeQueryRows: [(String, String)] {
        [
            ("Office: {office}", "One query per office the person holds, however many separate terms; the answer shows one predecessors/person/successors row per term."),
            ("All Offices", "Which offices has this person held?"),
        ]
    }

    private var queryTypesToolbar: some View {
        HStack(spacing: 12) {
                        // The nil check keeps the Picker unmounted for the first frames of a
                        // Person page, before loadTypeDetails() sets the selection — a Picker
                        // whose optional selection is nil (no matching tag) logs a SwiftUI
                        // "Invalid Configuration" fault. Post-load, nil implies the section
                        // is hidden anyway (deletion falls back to the built-in sentinel).
                        if showsQueryTypesSection, selectedQueryTypeID != nil {
                            Picker("Edit Query Type:", selection: $selectedQueryTypeID) {
                                if type.isPerson {
                                    Text("Built-in Relationship Queries")
                                        .tag(Optional(Self.builtinQueriesSelectionID))
                                    Text("Built-in Office Queries")
                                        .tag(Optional(Self.builtinOfficeQueriesSelectionID))
                                }
                                ForEach(displayedQueryTypes) { queryType in
                                    Text(queryType.name)
                                        .tag(Optional(queryType.id))
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        if !displayedQueryTypes.isEmpty {
                            Button("Rename") {
                                guard let selectedQueryType else { return }
                                renamedQueryTypeName = selectedQueryType.name
                                activeEditor = nil
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                isRenameQueryTypePopoverPresented = true
                            }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.secondary)
                            .disabled(selectedQueryType == nil)
                            .popover(isPresented: $isRenameQueryTypePopoverPresented, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Rename Query Type")
                                        .font(.headline)
                                    
                                    TextField("Query Type Name", text: $renamedQueryTypeName)
                                        .solidFocusField()
                                        .focused($isRenameQueryTypeNameFocused)
                                        .onSubmit {
                                            Task {
                                                await renameSelectedQueryType()
                                            }
                                        }
                                    
                                    HStack {
                                        Spacer()
                                        
                                        Button("Cancel") {
                                            isRenameQueryTypePopoverPresented = false
                                        }
                                        
                                        Button("Save") {
                                            Task {
                                                await renameSelectedQueryType()
                                            }
                                        }
                                        .keyboardShortcut(.defaultAction)
                                        .disabled(renamedQueryTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                                .padding(16)
                                .frame(width: 280)
                                .onAppear {
                                    DispatchQueue.main.async {
                                        isRenameQueryTypeNameFocused = true
                                    }
                                }
                            }
                        }

                        Button("Add Query Type") {
                            newQueryTypeName = ""
                            activeEditor = nil
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            isAddQueryTypePopoverPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        .popover(isPresented: $isAddQueryTypePopoverPresented, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Add Query Type")
                                    .font(.headline)

                                TextField("Query Type Name", text: $newQueryTypeName)
                                    .solidFocusField()
                                    .focused($isRenameQueryTypeNameFocused)
                                    .onSubmit {
                                        Task {
                                            await addQueryType()
                                        }
                                    }

                                HStack {
                                    Spacer()

                                    Button("Cancel") {
                                        isAddQueryTypePopoverPresented = false
                                    }

                                    Button("Add") {
                                        Task {
                                            await addQueryType()
                                        }
                                    }
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(newQueryTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            .padding(16)
                            .frame(width: 280)
                            .onAppear {
                                DispatchQueue.main.async {
                                    isRenameQueryTypeNameFocused = true
                                }
                            }
                        }
                        if !displayedQueryTypes.isEmpty {
                            Button("Duplicate Query Type") {
                                duplicateQueryTypeName = ""
                                activeEditor = nil
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                isDuplicateQueryTypePopoverPresented = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(selectedQueryType == nil)
                            .popover(isPresented: $isDuplicateQueryTypePopoverPresented, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Duplicate Query Type")
                                        .font(.headline)

                                    TextField("Query Type Name", text: $duplicateQueryTypeName)
                                        .solidFocusField()
                                        .focused($isRenameQueryTypeNameFocused)
                                        .onSubmit {
                                            Task {
                                                await duplicateSelectedQueryType()
                                            }
                                        }

                                    HStack {
                                        Spacer()

                                        Button("Cancel") {
                                            isDuplicateQueryTypePopoverPresented = false
                                        }

                                        Button("Duplicate") {
                                            Task {
                                                await duplicateSelectedQueryType()
                                            }
                                        }
                                        .keyboardShortcut(.defaultAction)
                                        .disabled(duplicateQueryTypeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                                .padding(16)
                                .frame(width: 280)
                                .onAppear {
                                    DispatchQueue.main.async {
                                        isRenameQueryTypeNameFocused = true
                                    }
                                }
                            }
                        }
                        if !displayedQueryTypes.isEmpty {
                            Button("Delete Query Type") {
                                queryTypePendingDeletion = selectedQueryType
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(selectedQueryType == nil)
                        }
                    }
    }

    @ViewBuilder
    private var queryEditorAndPreview: some View {
        if showsQueryTypesSection {
                        HStack(spacing: 16) {
                            RadioSelectionButton(
                                title: "Question",
                                isSelected: selectedHTMLContentMode == .query
                            ) {
                                selectedHTMLContentMode = .query
                            }

                            // Built-in queries have no editable answer (answers are
                            // computed from relationship/office data), so only
                            // "Question" shows.
                            if !isAnyBuiltinSelected {
                                RadioSelectionButton(
                                    title: "Answer",
                                    isSelected: selectedHTMLContentMode == .answer
                                ) {
                                    selectedHTMLContentMode = .answer
                                }

                                Button {
                                    isInstanceIDInfoPopoverPresented = true
                                } label: {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .popover(isPresented: $isInstanceIDInfoPopoverPresented, arrowEdge: .bottom) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("The {{#InstanceID}} placeholder")
                                            .font(.headline)
                                        Text("In a query type's HTML, {{#InstanceID}} substitutes to the instance's numeric id when the query renders. For example, <a href=\"id:{{#InstanceID}}\">details</a> makes a link that opens the instance being shown. It works in the question and answer HTML alike, including question content spliced into an answer by {{#QuestionContent}}. The preview on this page renders no specific instance, so the placeholder substitutes to nothing here.")
                                            .font(.callout)
                                    }
                                    .frame(width: 360, alignment: .leading)
                                    .padding(12)
                                }
                                .help("What is {{#InstanceID}}?")
                            }

                            if type.isPerson, !isAnyBuiltinSelected {
                                Button {
                                    isPersonOfficesElementInfoPopoverPresented = true
                                } label: {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .popover(isPresented: $isPersonOfficesElementInfoPopoverPresented, arrowEdge: .bottom) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("The _offices element")
                                            .font(.headline)
                                        Text("In a Person query's HTML, the first element with the id _offices—for example <div id=\"_offices\"></div>—has its contents replaced when the query renders. Later elements with the id are left alone. The replacement is one three-panel succession row per office term this person held—an office held twice gets two rows—in the person's office order. The left and right panels list that term's predecessors and successors. The middle panel shows the office name, a colon, and the held period—not the person's name. The term's note, when present, appears on its own line beneath. Style the rows with the .office-succession CSS classes. The preview on this page renders no specific person, so the element is left as typed here.")
                                            .font(.callout)
                                    }
                                    .frame(width: 360, alignment: .leading)
                                    .padding(12)
                                }
                                .help("Person query HTML features")
                            }
                        }

                        queryTypeEditorsCard

                        if isPreviewMounted {
                            PreviewCanvasSection(
                                html: previewHTML,
                                errorMessage: previewErrorMessage
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            // Reserve the preview's footprint so layout doesn't jump
                            // when the WebView mounts a beat later.
                            Color.clear.frame(maxWidth: .infinity, minHeight: 500)
                        }
        }
    }

    @MainActor
    private func loadTypeDetails() async {
        do {
            let currentType = try appDatabase.fetchType(typeID: type.id) ?? type
            displayedTypeName = currentType.name
            description = currentType.description
            isSyncingEditorState = true
            selectedTypeCSS = currentType.css
            isSyncingEditorState = false
            fields = try appDatabase.fetchFieldsForDisplay(forTypeID: type.id)
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: type.id)
            if type.isPerson {
                personResetOnConnectionChange = (try? appDatabase.fetchPersonResetQueriesOnConnectionChange()) ?? false
                personBuiltinQueryHTML = (try? appDatabase.fetchPersonBuiltinQueryHTML()) ?? PERSON_BUILTIN_QUERY_HTML_DEFAULT
                personOfficeQueryHTML = (try? appDatabase.fetchPersonOfficeQueryHTML()) ?? PERSON_OFFICE_QUERY_HTML_DEFAULT
            }
            // Person always has the built-in entries to fall back on, even
            // when the user has deleted every ordinary query type.
            selectedQueryTypeID = displayedQueryTypes.first?.id
                ?? (type.isPerson ? Self.builtinQueriesSelectionID : nil)
            syncSelectedQueryTypeEditorState(selectedQueryTypeID: selectedQueryTypeID)
            refreshPreviewCanvas()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load type details."
        }
    }

    private func syncSelectedQueryTypeEditorState(selectedQueryTypeID: Int64?) {
        isSyncingEditorState = true
        defer { isSyncingEditorState = false }

        if type.isPerson && selectedQueryTypeID == Self.builtinQueriesSelectionID {
            // No editable answer for built-in queries; the HTML editor shows the
            // shared "details" block sourced from the globals table.
            selectedHTMLContentMode = .query
            selectedQueryHTML = personBuiltinQueryHTML
            activeEditor = .html
            return
        }

        if type.isPerson && selectedQueryTypeID == Self.builtinOfficeQueriesSelectionID {
            // The per-office question template ({{@Office}} etc.); the office
            // answer layout is fixed and never editable.
            selectedHTMLContentMode = .query
            selectedQueryHTML = personOfficeQueryHTML
            activeEditor = .html
            return
        }

        guard let selectedQueryTypeID,
              let queryType = queryTypes.first(where: { $0.id == selectedQueryTypeID }) else {
            selectedQueryHTML = ""
            activeEditor = .html
            return
        }

        selectedQueryHTML = selectedHTMLContentMode == .query ? queryType.questionHTML : queryType.answerHTML
    }

    private func scheduleHTMLAutoSave() {
        guard let queryTypeID = selectedQueryTypeID else { return }
        pendingHTMLSaveQueryTypeID = queryTypeID
        pendingHTMLSaveMode = selectedHTMLContentMode
        pendingHTMLSaveText = selectedQueryHTML
        hasPendingHTMLSave = true
        htmlSaveTask?.cancel()
        htmlSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            flushPendingHTMLSave()
        }
    }

    private func scheduleCSSAutoSave() {
        hasPendingCSSSave = true
        cssSaveTask?.cancel()
        cssSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            flushPendingCSSSave()
        }
    }

    @MainActor
    private func flushPendingHTMLSave() {
        htmlSaveTask?.cancel()
        htmlSaveTask = nil
        guard hasPendingHTMLSave, let queryTypeID = pendingHTMLSaveQueryTypeID else { return }
        let mode = pendingHTMLSaveMode
        let html = pendingHTMLSaveText
        hasPendingHTMLSave = false

        if queryTypeID == Self.builtinQueriesSelectionID {
            do {
                try appDatabase.setPersonBuiltinQueryHTML(html)
                personBuiltinQueryHTML = html
                errorMessage = nil
            } catch {
                errorMessage = "Failed to save built-in query HTML."
            }
            return
        }

        if queryTypeID == Self.builtinOfficeQueriesSelectionID {
            do {
                try appDatabase.setPersonOfficeQueryHTML(html)
                personOfficeQueryHTML = html
                errorMessage = nil
            } catch {
                errorMessage = "Failed to save office query HTML."
            }
            return
        }

        do {
            switch mode {
            case .query:
                try appDatabase.updateQuestionHTML(forQueryTypeID: queryTypeID, questionHTML: html)
            case .answer:
                try appDatabase.updateAnswerHTML(forQueryTypeID: queryTypeID, answerHTML: html)
            }
            updateCachedQueryType(queryTypeID: queryTypeID) { queryType in
                QueryType(
                    id: queryType.id,
                    typeID: queryType.typeID,
                    name: queryType.name,
                    questionHTML: mode == .query ? html : queryType.questionHTML,
                    answerHTML: mode == .answer ? html : queryType.answerHTML
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = mode == .query
                ? "Failed to save query HTML."
                : "Failed to save answer HTML."
        }
    }

    @MainActor
    private func flushPendingCSSSave() {
        cssSaveTask?.cancel()
        cssSaveTask = nil
        guard hasPendingCSSSave else { return }
        let css = selectedTypeCSS
        hasPendingCSSSave = false
        do {
            try appDatabase.updateTypeCSS(typeID: type.id, css: css)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save type CSS."
        }
    }

    @MainActor
    private func renameType() async {
        let trimmedTypeName = renamedTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTypeName.isEmpty else { return }

        do {
            try appDatabase.renameType(typeID: type.id, to: trimmedTypeName)
            displayedTypeName = trimmedTypeName
            isRenameTypePopoverPresented = false
            errorMessage = nil
        } catch {
            errorMessage = (error as? DatabaseError)?.message ?? "Failed to rename type."
        }
    }

    @MainActor
    private func renameSelectedQueryType() async {
        guard let selectedQueryTypeID, !isAnyBuiltinSelected else { return }

        let trimmedQueryTypeName = renamedQueryTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQueryTypeName.isEmpty else { return }

        do {
            try appDatabase.renameQueryType(queryTypeID: selectedQueryTypeID, to: trimmedQueryTypeName)
            updateCachedQueryType(queryTypeID: selectedQueryTypeID) { queryType in
                QueryType(
                    id: queryType.id,
                    typeID: queryType.typeID,
                    name: trimmedQueryTypeName,
                    questionHTML: queryType.questionHTML,
                    answerHTML: queryType.answerHTML
                )
            }
            isRenameQueryTypePopoverPresented = false
            errorMessage = nil
        } catch {
            errorMessage = "Failed to rename query type."
        }
    }

    @MainActor
    private func addQueryType() async {
        let trimmedQueryTypeName = newQueryTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQueryTypeName.isEmpty else { return }

        do {
            let newQueryType = try appDatabase.createQueryType(forTypeID: type.id, name: trimmedQueryTypeName)
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: type.id)
            selectedQueryTypeID = newQueryType.id
            isAddQueryTypePopoverPresented = false
            errorMessage = nil
        } catch {
            errorMessage = "Failed to add query type."
        }
    }

    @MainActor
    private func duplicateSelectedQueryType() async {
        guard let selectedQueryTypeID, !isAnyBuiltinSelected else { return }

        let trimmedQueryTypeName = duplicateQueryTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQueryTypeName.isEmpty else { return }

        do {
            let newQueryType = try appDatabase.duplicateQueryType(
                sourceQueryTypeID: selectedQueryTypeID,
                name: trimmedQueryTypeName
            )
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: type.id)
            self.selectedQueryTypeID = newQueryType.id
            isDuplicateQueryTypePopoverPresented = false
            errorMessage = nil
        } catch {
            errorMessage = "Failed to duplicate query type."
        }
    }

    @MainActor
    private func deleteQueryType(_ queryType: QueryType) async {
        do {
            try appDatabase.deleteQueryType(queryTypeID: queryType.id)
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: type.id)
            selectedQueryTypeID = displayedQueryTypes.first?.id
                ?? (type.isPerson ? Self.builtinQueriesSelectionID : nil)
            queryTypePendingDeletion = nil
            errorMessage = nil
        } catch {
            errorMessage = "Failed to delete query type."
        }
    }

    private func updateCachedQueryType(
        queryTypeID: Int64,
        transform: (QueryType) -> QueryType
    ) {
        guard let index = queryTypes.firstIndex(where: { $0.id == queryTypeID }) else { return }
        queryTypes[index] = transform(queryTypes[index])
    }

    private var queryTypeEditorsSection: some View {
        QueryTypeEditorsSplitView(
            htmlText: $selectedQueryHTML,
            cssText: $selectedTypeCSS,
            fieldNames: Set(fields.map(\.name)),
            booleanFieldNames: Set(fields.filter { $0.fieldType == .boolean }.map(\.name)),
            activeEditor: $activeEditor,
            splitRatio: $editorSplitRatio
        )
    }

    private var queryTypeEditorsCard: some View {
        queryTypeEditorsSection
            .frame(height: 500)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }
    }

    private func refreshPreviewCanvas() {
        guard selectedQueryTypeID != nil else {
            previewHTML = ""
            previewErrorMessage = "Select a query type to preview it."
            return
        }

        do {
            let generatedHTML = try {
                switch selectedHTMLContentMode {
                case .query:
                    return try generatePreviewHTMLForQuestion(
                        appDatabase: appDatabase,
                        questionHTML: selectedQueryHTML
                    )
                case .answer:
                    return try generatePreviewHTMLForAnswer(
                        appDatabase: appDatabase,
                        questionHTML: selectedQueryType?.questionHTML ?? "",
                        answerHTML: selectedQueryHTML
                    )
                }
            }()
            try PreviewHTMLValidator.validate(generatedHTML)
            previewHTML = try injectPreviewCSS(into: generatedHTML, typeCSS: selectedTypeCSS)
            previewErrorMessage = nil
        } catch {
            previewHTML = ""
            previewErrorMessage = error.localizedDescription
        }
    }

    private func injectPreviewCSS(into html: String, typeCSS: String) throws -> String {
        let previewResetCSS = """
        html, body, main {
            width: 100%;
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        """

        let globalQueryCSS = try appDatabase.fetchGlobalQueryCSS()
        let cssSegments = [previewResetCSS, globalQueryCSS, typeCSS].filter { !$0.isEmpty }
        let combinedCSS = cssSegments.joined(separator: "\n\n")

        let styleTag = "<style>\n\(combinedCSS)\n</style>"

        if let headRange = html.range(of: "</head>", options: [.caseInsensitive, .backwards]) {
            var updatedHTML = html
            updatedHTML.insert(contentsOf: "\(styleTag)\n", at: headRange.lowerBound)
            return updatedHTML
        }

        return "\(styleTag)\n\(html)"
    }

    @MainActor
    private func addField() async {
        let trimmedFieldName = newFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFieldName.isEmpty else { return }
        guard isValidNewFieldName(trimmedFieldName) else {
            errorMessage = "Field names must start with a letter and contain only letters and numbers."
            return
        }

        do {
            _ = try appDatabase.addField(toTypeID: type.id, name: trimmedFieldName, fieldType: newFieldType)
            fields = try appDatabase.fetchFieldsForDisplay(forTypeID: type.id)
            newFieldName = ""
            newFieldType = .text
            isAddFieldPopoverPresented = false
            errorMessage = nil
        } catch {
            errorMessage = "Failed to add field."
        }
    }

    private func isValidNewFieldName(_ fieldName: String) -> Bool {
        guard let firstCharacter = fieldName.first, firstCharacter.isLetter else {
            return false
        }

        return fieldName.allSatisfy { $0.isLetter || $0.isNumber }
    }

    @MainActor
    private func deleteField(_ field: TypeField) async {
        do {
            try appDatabase.deleteField(fieldID: field.id, fromTypeID: type.id)
            fields.removeAll { $0.id == field.id }
            fields = try appDatabase.fetchFieldsForDisplay(forTypeID: type.id)
            fieldPendingDeletion = nil
            errorMessage = nil
        } catch {
            errorMessage = "Failed to delete field."
        }
    }

    @MainActor
    private func renameField(_ field: TypeField) async {
        let trimmedFieldName = renamedFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFieldName.isEmpty else { return }

        do {
            try appDatabase.renameField(fieldID: field.id, fromTypeID: type.id, to: trimmedFieldName)
            if let index = fields.firstIndex(where: { $0.id == field.id }) {
                let existingField = fields[index]
                fields[index] = TypeField(
                    id: existingField.id,
                    typeID: existingField.typeID,
                    name: trimmedFieldName,
                    fieldIndex: existingField.fieldIndex,
                    fieldDisplayIndex: existingField.fieldDisplayIndex,
                    isPrimary: existingField.isPrimary
                )
            }
            fieldPendingRename = nil
            errorMessage = nil
        } catch {
            errorMessage = "Failed to rename field."
        }
    }

    // Persists a new text-field display order (field_display_index renumbered
    // 1...N) from the drag-reordered list of field IDs.
    @MainActor
    private func reorderFields(orderedIDs: [Int64]) async {
        guard orderedIDs != fields.map(\.id) else { return }
        let reordered = orderedIDs.compactMap { id in fields.first(where: { $0.id == id }) }
        guard reordered.count == fields.count else { return }
        fields = reordered

        do {
            try appDatabase.setFieldDisplayOrder(typeID: type.id, orderedFieldIDs: reordered.map(\.id))
            fields = try appDatabase.fetchFieldsForDisplay(forTypeID: type.id)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to reorder fields."
        }
    }
}

private struct TypeDetailAlertsModifier: ViewModifier {
    @Binding var fieldPendingDeletion: TypeField?
    @Binding var queryTypePendingDeletion: QueryType?
    let onDeleteField: (TypeField) -> Void
    let onDeleteQueryType: (QueryType) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Are you sure you want to delete this field?",
                isPresented: Binding(
                    get: { fieldPendingDeletion != nil },
                    set: { if !$0 { fieldPendingDeletion = nil } }
                ),
                presenting: fieldPendingDeletion
            ) { field in
                Button("Delete", role: .destructive) { onDeleteField(field) }
                Button("Cancel", role: .cancel) { fieldPendingDeletion = nil }
            } message: { _ in
                Text("This action is irreversible. All data stored in this field, across all instances, will be deleted.")
            }
            .alert(
                "Are you sure you want to delete \(queryTypePendingDeletion?.name ?? "")?",
                isPresented: Binding(
                    get: { queryTypePendingDeletion != nil },
                    set: { if !$0 { queryTypePendingDeletion = nil } }
                ),
                presenting: queryTypePendingDeletion
            ) { queryType in
                Button("Delete", role: .destructive) { onDeleteQueryType(queryType) }
                Button("Cancel", role: .cancel) { queryTypePendingDeletion = nil }
            } message: { _ in
                Text("This action is irreversible.")
            }
    }
}

private struct FieldRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct FieldsSectionView: View {
    let fields: [TypeField]
    let onEditField: (TypeField) -> Void
    let onDeleteField: (TypeField) -> Void
    var onReorder: (_ orderedIDs: [Int64]) -> Void = { _ in }

    private static let coordinateSpaceName = "fieldsList"

    // The field currently being dragged (rendered as an invisible "hole").
    @State private var draggingID: Int64?
    // The live visual order while dragging; nil when not dragging.
    @State private var liveOrder: [Int64]?
    // Continuously-captured row frames, and a snapshot frozen at drag start so
    // the target index stays stable while rows reflow around the hole.
    @State private var rowFrames: [Int64: CGRect] = [:]
    @State private var frozenFrames: [Int64: CGRect] = [:]

    private var displayedFields: [TypeField] {
        guard let liveOrder else { return fields }
        return liveOrder.compactMap { id in fields.first(where: { $0.id == id }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayedFields.enumerated()), id: \.element.id) { index, field in
                fieldRow(field)

                if index < displayedFields.count - 1 {
                    Divider()
                }
            }
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(FieldRowFramePreferenceKey.self) { frames in
            rowFrames = frames
        }
        .onChange(of: fields.map(\.id)) { _, _ in
            // The parent has committed a new field order; drop the temporary
            // drag order so the view tracks `fields` again.
            if draggingID == nil {
                liveOrder = nil
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private func fieldKindIconName(_ field: TypeField) -> String {
        switch field.fieldType {
        case .boolean: return "checkmark.square"
        case .sex: return "person.fill"
        case .text: return "textformat"
        }
    }

    private func fieldKindHelp(_ field: TypeField) -> String {
        switch field.fieldType {
        case .boolean: return "Boolean field"
        case .sex: return "Sex field (built-in)"
        case .text: return "Text field"
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: TypeField) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .font(.caption)

            Image(systemName: fieldKindIconName(field))
                .foregroundStyle(.secondary)
                .help(fieldKindHelp(field))

            Text(field.name)
                .frame(maxWidth: .infinity, alignment: .leading)

            if field.isProtected {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Built-in field — can't be renamed or deleted")
            } else {
                Button {
                    onEditField(field)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)

                Button {
                    onDeleteField(field)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // The dragged row becomes the hole: it keeps its size (so the gap is
        // row-shaped) but is invisible.
        .opacity(draggingID == field.id ? 0 : 1)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FieldRowFramePreferenceKey.self,
                    value: [field.id: proxy.frame(in: .named(Self.coordinateSpaceName))]
                )
            }
        )
        .pointerStyle(draggingID == nil ? .grabIdle : .grabActive)
        .gesture(reorderGesture(for: field))
    }

    private func reorderGesture(for field: TypeField) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                if draggingID != field.id {
                    draggingID = field.id
                    frozenFrames = rowFrames
                    liveOrder = fields.map(\.id)
                }
                updateLiveOrder(draggedID: field.id, locationY: value.location.y)
            }
            .onEnded { _ in
                let finalOrder = liveOrder ?? fields.map(\.id)
                let originalOrder = fields.map(\.id)
                draggingID = nil
                frozenFrames = [:]
                if finalOrder != originalOrder {
                    // Keep showing the reordered list until the parent commits the
                    // new `fields` order; clearing liveOrder now would briefly flash
                    // the pre-swap order. `.onChange(of: fields)` clears it.
                    liveOrder = finalOrder
                    onReorder(finalOrder)
                } else {
                    liveOrder = nil
                }
            }
    }

    // Places the dragged field into the slot under the pointer, using the frozen
    // (drag-start) row midpoints so the computation doesn't oscillate as the
    // visible rows reflow.
    private func updateLiveOrder(draggedID: Int64, locationY: CGFloat) {
        let others = fields.map(\.id).filter { $0 != draggedID }
        var newIndex = 0
        for id in others {
            if let midY = frozenFrames[id]?.midY, midY < locationY {
                newIndex += 1
            }
        }
        newIndex = min(max(newIndex, 0), others.count)

        var order = others
        order.insert(draggedID, at: newIndex)
        if order != liveOrder {
            withAnimation(.easeInOut(duration: 0.15)) {
                liveOrder = order
            }
        }
    }
}

private struct RenameFieldPopoverAnchor: View {
    // Item-based presentation (see the popover rule in CLAUDE.md): keying the
    // popover on the pending field itself makes an empty-content presentation
    // unrepresentable. Dismissal = nil-ing the binding.
    @Binding var fieldPendingRename: TypeField?
    @Binding var renamedFieldName: String
    let isFieldNameFocused: FocusState<Bool>.Binding
    let onSubmit: (TypeField) -> Void
    let onCancel: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .popover(item: $fieldPendingRename, arrowEdge: .bottom) { fieldPendingRename in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Edit Field")
                        .font(.headline)

                    TextField("Field Name", text: $renamedFieldName)
                        .solidFocusField()
                        .focused(isFieldNameFocused)
                        .onSubmit {
                            onSubmit(fieldPendingRename)
                        }

                    Text("You can change this later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()

                        Button("Cancel") {
                            onCancel()
                        }

                        Button("Save") {
                            onSubmit(fieldPendingRename)
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(renamedFieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(16)
                .frame(width: 280)
                .onAppear {
                    isFieldNameFocused.wrappedValue = true
                }
            }
    }
}

