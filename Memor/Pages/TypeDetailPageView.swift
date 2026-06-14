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
    @State private var isAddFieldPopoverPresented = false
    @State private var newFieldName = ""
    @State private var fieldPendingDeletion: TypeField?
    @State private var fieldPendingRename: TypeField?
    @State private var isRenameFieldPopoverPresented = false
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
    @State private var queryTypePendingDeletion: QueryType?
    @State private var hasAutoPresentedRenamePopover = false

    // Node types only
    @State private var linkFields: [LinkField] = []
    @State private var isLinkFieldPopoverPresented = false
    @State private var linkFieldBeingEdited: LinkField?
    @State private var linkFieldName = ""
    @State private var linkFieldIsParent = false
    @State private var linkFieldMinText = "0"
    @State private var linkFieldMaxText = ""
    @State private var linkFieldPendingDeletion: LinkField?
    @FocusState private var isLinkFieldNameFocused: Bool

    private var selectedQueryType: QueryType? {
        guard let selectedQueryTypeID else { return nil }
        return queryTypes.first(where: { $0.id == selectedQueryTypeID })
    }

    private var displayedQueryTypes: [QueryType] {
        queryTypes.sorted { lhs, rhs in
            lhs.id < rhs.id
        }
    }

    var body: some View {
        if type.isBuiltin {
            builtinTypeBody
        } else {
            editableTypeBody
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

                Text(type.name)
                    .font(.largeTitle)
                    .fontWeight(.semibold)

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
                                .textFieldStyle(.roundedBorder)
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
                    Text(type.isNode ? "Text Fields" : "Fields")
                        .font(.title3)
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 6) {
                    FieldsSectionView(
                        fields: fields,
                        isNode: type.isNode,
                        onEditField: { field in
                            fieldPendingRename = field
                            renamedFieldName = field.name
                            isRenameFieldPopoverPresented = true
                        },
                        onDeleteField: { field in
                            fieldPendingDeletion = field
                        },
                        onSetPrimary: { field in
                            Task { await setPrimaryField(field) }
                        },
                        onReorder: { orderedIDs in
                            Task { await reorderFields(orderedIDs: orderedIDs) }
                        }
                    )

                    RenameFieldPopoverAnchor(
                        fieldPendingRename: fieldPendingRename,
                        isRenameFieldPopoverPresented: $isRenameFieldPopoverPresented,
                        renamedFieldName: $renamedFieldName,
                        isFieldNameFocused: $isAddFieldNameFocused,
                        onSubmit: { field in
                            Task {
                                await renameField(field)
                            }
                        },
                        onCancel: {
                            isRenameFieldPopoverPresented = false
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
                                .textFieldStyle(.roundedBorder)
                                .focused($isAddFieldNameFocused)
                                .onSubmit {
                                    Task {
                                        await addField()
                                    }
                                }

                            Text("You can change this later.")
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

                    if type.isNode {
                        linkFieldsSection
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
            // Link queries have no editable answer; always show the question editor.
            if let newValue,
               queryTypes.first(where: { $0.id == newValue })?.isLinkQuery == true,
               selectedHTMLContentMode == .answer {
                selectedHTMLContentMode = .query
            }
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
            linkFieldPendingDeletion: $linkFieldPendingDeletion,
            onDeleteField: { field in Task { await deleteField(field) } },
            onDeleteQueryType: { queryType in Task { await deleteQueryType(queryType) } },
            onDeleteLinkField: { linkField in Task { await deleteLinkField(linkField) } }
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
    }

    private var queryTypesToolbar: some View {
        HStack(spacing: 12) {
                        if !displayedQueryTypes.isEmpty {
                            Picker("Edit Query Type:", selection: $selectedQueryTypeID) {
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
                                        .textFieldStyle(.roundedBorder)
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
                                    .textFieldStyle(.roundedBorder)
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
                            Button("Delete Query Type") {
                                queryTypePendingDeletion = selectedQueryType
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(selectedQueryType == nil || selectedQueryType?.isLinkQuery == true)
                        }
                    }
    }

    @ViewBuilder
    private var queryEditorAndPreview: some View {
        if !displayedQueryTypes.isEmpty {
                        if selectedQueryType?.isLinkQuery == true {
                            Text("This is an auto-generated link query. You can edit its question; the answer lists the linked nodes automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: 16) {
                                RadioSelectionButton(
                                    title: "Question",
                                    isSelected: selectedHTMLContentMode == .query
                                ) {
                                    selectedHTMLContentMode = .query
                                }

                                RadioSelectionButton(
                                    title: "Answer",
                                    isSelected: selectedHTMLContentMode == .answer
                                ) {
                                    selectedHTMLContentMode = .answer
                                }
                            }
                        }

                        queryTypeEditorsCard
                        
                        PreviewCanvasSection(
                            html: previewHTML,
                            errorMessage: previewErrorMessage
                        )
                        .frame(maxWidth: .infinity)
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
            if type.isNode {
                linkFields = try appDatabase.fetchLinkFields(forTypeID: type.id)
            }
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: type.id)
            selectedQueryTypeID = displayedQueryTypes.first?.id
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
                    answerHTML: mode == .answer ? html : queryType.answerHTML,
                    linkFieldID: queryType.linkFieldID
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
            errorMessage = "Failed to rename type."
        }
    }

    @MainActor
    private func renameSelectedQueryType() async {
        guard let selectedQueryTypeID else { return }

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
                    answerHTML: queryType.answerHTML,
                    linkFieldID: queryType.linkFieldID
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
    private func deleteQueryType(_ queryType: QueryType) async {
        do {
            try appDatabase.deleteQueryType(queryTypeID: queryType.id)
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: type.id)
            selectedQueryTypeID = displayedQueryTypes.first?.id
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
            _ = try appDatabase.addField(toTypeID: type.id, name: trimmedFieldName)
            fields = try appDatabase.fetchFieldsForDisplay(forTypeID: type.id)
            newFieldName = ""
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
            isRenameFieldPopoverPresented = false
            fieldPendingRename = nil
            errorMessage = nil
        } catch {
            errorMessage = "Failed to rename field."
        }
    }

    // MARK: - Node types

    @MainActor
    private func setPrimaryField(_ field: TypeField) async {
        guard !field.isPrimary else { return }
        do {
            try appDatabase.setPrimaryField(fieldID: field.id, forTypeID: type.id)
            fields = try appDatabase.fetchFieldsForDisplay(forTypeID: type.id)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to set primary field."
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

    private var linkFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link Fields")
                .font(.title3)
                .fontWeight(.semibold)

            if linkFields.isEmpty {
                Text("No link fields yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(linkFields.enumerated()), id: \.element.id) { index, linkField in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(linkField.name)
                                Text(linkFieldDetailText(linkField))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                beginEditingLinkField(linkField)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)

                            Button {
                                linkFieldPendingDeletion = linkField
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        if index < linkFields.count - 1 {
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
            }

            Button("Add Link Field") {
                beginAddingLinkField()
            }
            .popover(isPresented: $isLinkFieldPopoverPresented, arrowEdge: .bottom) {
                linkFieldPopover
            }
        }
    }

    private var linkFieldPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(linkFieldBeingEdited == nil ? "Add Link Field" : "Edit Link Field")
                .font(.headline)

            TextField("Link Field Name", text: $linkFieldName)
                .textFieldStyle(.roundedBorder)
                .focused($isLinkFieldNameFocused)

            Toggle("Parent link", isOn: $linkFieldIsParent)

            HStack(spacing: 8) {
                Text("Min:")
                TextField("0", text: $linkFieldMinText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onChange(of: linkFieldMinText) { _, newValue in
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue { linkFieldMinText = digits }
                    }

                Text("Max:")
                TextField("∞", text: $linkFieldMaxText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onChange(of: linkFieldMaxText) { _, newValue in
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue { linkFieldMaxText = digits }
                    }
            }
            Text("Leave Max blank for unlimited.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    isLinkFieldPopoverPresented = false
                }
                Button("Save") {
                    Task { await saveLinkField() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(linkFieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            DispatchQueue.main.async { isLinkFieldNameFocused = true }
        }
    }

    private func linkFieldDetailText(_ linkField: LinkField) -> String {
        let maxText = linkField.maxCount.map(String.init) ?? "∞"
        var parts = ["min \(linkField.minCount)", "max \(maxText)"]
        if linkField.isParent { parts.append("parent") }
        return parts.joined(separator: " · ")
    }

    private func beginAddingLinkField() {
        linkFieldBeingEdited = nil
        linkFieldName = ""
        linkFieldIsParent = false
        linkFieldMinText = "0"
        linkFieldMaxText = ""
        isLinkFieldPopoverPresented = true
    }

    private func beginEditingLinkField(_ linkField: LinkField) {
        linkFieldBeingEdited = linkField
        linkFieldName = linkField.name
        linkFieldIsParent = linkField.isParent
        linkFieldMinText = String(linkField.minCount)
        linkFieldMaxText = linkField.maxCount.map(String.init) ?? ""
        isLinkFieldPopoverPresented = true
    }

    @MainActor
    private func saveLinkField() async {
        let trimmedName = linkFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let minCount = Int(linkFieldMinText) ?? 0
        let maxCount = Int(linkFieldMaxText)
        if let maxCount, maxCount < minCount {
            errorMessage = "Maximum must be greater than or equal to minimum."
            return
        }

        do {
            if let linkFieldBeingEdited {
                try appDatabase.updateLinkField(
                    linkFieldID: linkFieldBeingEdited.id,
                    name: trimmedName,
                    isParent: linkFieldIsParent,
                    minCount: minCount,
                    maxCount: maxCount
                )
            } else {
                _ = try appDatabase.createLinkField(
                    forTypeID: type.id,
                    name: trimmedName,
                    isParent: linkFieldIsParent,
                    minCount: minCount,
                    maxCount: maxCount
                )
            }
            linkFields = try appDatabase.fetchLinkFields(forTypeID: type.id)
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: type.id)
            if selectedQueryTypeID == nil {
                selectedQueryTypeID = displayedQueryTypes.first?.id
                syncSelectedQueryTypeEditorState(selectedQueryTypeID: selectedQueryTypeID)
            }
            isLinkFieldPopoverPresented = false
            errorMessage = nil
        } catch {
            errorMessage = (error as? DatabaseError)?.message ?? "Failed to save link field."
        }
    }

    @MainActor
    private func deleteLinkField(_ linkField: LinkField) async {
        do {
            try appDatabase.deleteLinkField(linkFieldID: linkField.id)
            linkFields = try appDatabase.fetchLinkFields(forTypeID: type.id)
            queryTypes = try appDatabase.fetchQueryTypes(forTypeID: type.id)
            if !queryTypes.contains(where: { $0.id == selectedQueryTypeID }) {
                selectedQueryTypeID = displayedQueryTypes.first?.id
                syncSelectedQueryTypeEditorState(selectedQueryTypeID: selectedQueryTypeID)
            }
            linkFieldPendingDeletion = nil
            errorMessage = nil
        } catch {
            errorMessage = "Failed to delete link field."
        }
    }
}

private struct TypeDetailAlertsModifier: ViewModifier {
    @Binding var fieldPendingDeletion: TypeField?
    @Binding var queryTypePendingDeletion: QueryType?
    @Binding var linkFieldPendingDeletion: LinkField?
    let onDeleteField: (TypeField) -> Void
    let onDeleteQueryType: (QueryType) -> Void
    let onDeleteLinkField: (LinkField) -> Void

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
            .alert(
                "Are you sure you want to delete \(linkFieldPendingDeletion?.name ?? "")?",
                isPresented: Binding(
                    get: { linkFieldPendingDeletion != nil },
                    set: { if !$0 { linkFieldPendingDeletion = nil } }
                ),
                presenting: linkFieldPendingDeletion
            ) { linkField in
                Button("Delete", role: .destructive) { onDeleteLinkField(linkField) }
                Button("Cancel", role: .cancel) { linkFieldPendingDeletion = nil }
            } message: { _ in
                Text("This action is irreversible. Its auto-generated query type and all links in this field will be deleted.")
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
    var isNode: Bool = false
    let onEditField: (TypeField) -> Void
    let onDeleteField: (TypeField) -> Void
    var onSetPrimary: (TypeField) -> Void = { _ in }
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

    @ViewBuilder
    private func fieldRow(_ field: TypeField) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .font(.caption)

            Text(field.name)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isNode {
                Button {
                    onSetPrimary(field)
                } label: {
                    Label("Primary", systemImage: field.isPrimary ? "largecircle.fill.circle" : "circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(field.isPrimary ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Mark as the primary field")
            }

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
    let fieldPendingRename: TypeField?
    @Binding var isRenameFieldPopoverPresented: Bool
    @Binding var renamedFieldName: String
    let isFieldNameFocused: FocusState<Bool>.Binding
    let onSubmit: (TypeField) -> Void
    let onCancel: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .popover(isPresented: $isRenameFieldPopoverPresented, arrowEdge: .bottom) {
                if let fieldPendingRename {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Edit Field")
                            .font(.headline)

                        TextField("Field Name", text: $renamedFieldName)
                            .textFieldStyle(.roundedBorder)
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
}

