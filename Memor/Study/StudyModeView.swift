//
//  StudyModeView.swift
//  Memor
//
//  Study-mode UI: query rendering, rating buttons, undo, overlay, and key handling.
//

import AppKit
import SwiftUI

enum StudyUndoAction {
    case revealAnswer
    case responseRating(
        previousQuery: StudyQuery,
        previousRenderedQuestionHTML: String,
        previousRenderedAnswerHTML: String,
        previousProjectedIntervals: [StudyResponseRating: Int64],
        previousBlueQueries: [StudyQuery],
        previousRedQueries: [StudyQuery],
        previousGreenQueries: [StudyQuery],
        previousOverlayCollectionNames: [String],
        previousAllCollectionNames: [String],
        originalInterval: Int64,
        originalLastAnsweredTimestamp: Int64?,
        originalQueryState: QueryState
    )
}

struct StudyModeView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var queryPreviewWindowState: QueryPreviewWindowState
    @EnvironmentObject private var editInstanceWindowState: EditInstanceWindowState
    @EnvironmentObject private var addInstanceWindowState: AddInstanceWindowState
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    @EnvironmentObject private var navigationState: AppNavigationState
    @EnvironmentObject private var studyModeState: StudyModeState

    let stack: Stack
    let appDatabase: AppDatabase
    let onExit: () -> Void

    @State private var currentQuery: StudyQuery?
    @State private var renderedQuestionHTML = ""
    @State private var renderedAnswerHTML = ""
    @State private var isAnswerRevealed = false
    @State private var isCompleted = false
    @State private var errorMessage: String?
    @State private var projectedIntervalsByRating: [StudyResponseRating: Int64] = [:]
    @State private var blueQueries: [StudyQuery] = []
    @State private var redQueries: [StudyQuery] = []
    @State private var greenQueries: [StudyQuery] = []
    @State private var showCollectionOverlay = false
    @State private var showBoundaryFinder = false
    @State private var overlayCollectionNames: [String] = []
    @State private var allCollectionNames: [String] = []
    @State private var pendingUndo: StudyUndoAction?

    // Object/Node queries get a slim bottom bar; map queries keep the taller one.
    private var isStandardQuery: Bool {
        currentQuery?.kind == .standard
    }

    private var projectedIntervals: [(title: String, label: String, color: Color, isClamped: Bool, rating: StudyResponseRating)] {
        guard let currentQuery else { return [] }

        let againKey = shortcutSettings.binding(for: .studyRatingAgain).displayString
        let hardKey = shortcutSettings.binding(for: .studyRatingHard).displayString
        let goodKey = shortcutSettings.binding(for: .studyRatingGood).displayString
        let easyKey = shortcutSettings.binding(for: .studyRatingEasy).displayString

        let maxInterval = currentQuery.maxInterval
        func isAtMax(_ interval: Int64) -> Bool {
            guard let maxInterval else { return false }
            return interval == maxInterval
        }

        let againInterval = projectedIntervalsByRating[.again] ?? Int64(QUERY_STARTER_DELAY_AGAIN)
        let hardInterval = projectedIntervalsByRating[.hard] ?? Int64(QUERY_STARTER_DELAY_HARD)
        let goodInterval = projectedIntervalsByRating[.good] ?? Int64(QUERY_STARTER_DELAY_GOOD)
        let easyInterval = projectedIntervalsByRating[.easy] ?? Int64(3 * 86_400)

        return [
            (
                title: "Again (\(againKey))",
                label: formatStudyInterval(againInterval),
                color: .red,
                isClamped: isAtMax(againInterval),
                rating: .again
            ),
            (
                title: "Hard (\(hardKey))",
                label: formatStudyInterval(hardInterval),
                color: .orange,
                isClamped: isAtMax(hardInterval),
                rating: .hard
            ),
            (
                title: "Good (\(goodKey))",
                label: formatStudyInterval(goodInterval),
                color: .green,
                isClamped: isAtMax(goodInterval),
                rating: .good
            ),
            (
                title: "Easy (\(easyKey))",
                label: formatStudyInterval(easyInterval),
                color: Color(red: 0.65, green: 0.86, blue: 0.65),
                isClamped: isAtMax(easyInterval),
                rating: .easy
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(24)
                } else if isCompleted {
                    VStack(spacing: 16) {
                        Text("Congratulations! You have reviewed all the queries in this stack.")
                            .font(.title2)
                            .multilineTextAlignment(.center)

                        Button("Return to Stacks") {
                            onExit()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(24)
                } else if let currentQuery {
                    VStack(spacing: 0) {
                        StudyQueryHeaderBar(query: currentQuery)
                        queryContent(for: currentQuery)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        if currentQuery.kind != .boundaryMap && showCollectionOverlay && !(isAnswerRevealed ? allCollectionNames : overlayCollectionNames).isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(isAnswerRevealed ? allCollectionNames : overlayCollectionNames, id: \.self) { name in
                                    Text(name)
                                        .font(.callout)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(.thinMaterial)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            .padding(.trailing, 16)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                StudyModeKeyCommandHandler(
                    shortcutSettings: shortcutSettings,
                    onEscape: onExit,
                    onSpace: {
                        if isCompleted {
                            onExit()
                        } else if isAnswerRevealed {
                            Task { await submit(.good) }
                        } else {
                            revealAnswerIfPossible()
                        }
                    },
                    onUndo: performUndo,
                    onResponse: { rating in
                        guard isAnswerRevealed else { return }
                        Task { await submit(rating) }
                    },
                    onShiftDown: {
                        if currentQuery?.kind == .boundaryMap {
                            showBoundaryFinder.toggle()
                        } else {
                            showCollectionOverlay.toggle()
                        }
                    },
                    onEditInstance: {
                        guard let currentQuery, isAnswerRevealed else { return }
                        let autoEditPointID: Int64? = currentQuery.kind == .pointMap
                            ? currentQuery.pointMapPayload?.pointID
                            : nil
                        editInstanceWindowState.requestOpen(
                            instanceID: currentQuery.instanceID,
                            autoEditPointID: autoEditPointID
                        )
                        openWindow(id: "edit-instance")
                    },
                    onEditType: performEditType,
                    onArrowLinkShortcut: { key in
                        // Only after the answer is revealed; mirrors the link-click callbacks below.
                        guard isAnswerRevealed, let currentQuery else { return false }
                        switch resolveLinkShortcut(key, fieldValues: currentQuery.fieldValuesByName) {
                        case .none:
                            return false
                        case .collision:
                            presentLinkShortcutCollisionAlert(key)
                            return true
                        case .navigate(.instance(let instanceID)):
                            queryPreviewWindowState.requestOpenFirstQuery(instanceID: instanceID)
                            openWindow(id: "query-preview")
                            return true
                        case .navigate(.query(let instanceID, let queryTypeID)):
                            queryPreviewWindowState.requestOpen(instanceID: instanceID, queryTypeID: queryTypeID)
                            openWindow(id: "query-preview")
                            return true
                        }
                    }
                )
            }

            Divider()

            HStack {
                Spacer()

                if let currentQuery, !isAnswerRevealed, !isCompleted {
                    revealControls(for: currentQuery)
                } else if currentQuery != nil && isAnswerRevealed {
                    HStack(spacing: 12) {
                        ForEach(projectedIntervals, id: \.title) { item in
                            StudyResponseButton(
                                title: item.title,
                                intervalLabel: item.label,
                                color: item.color,
                                isClampedToMax: item.isClamped
                            ) {
                                Task { await submit(item.rating) }
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, isStandardQuery ? 8 : 24)
            .frame(maxWidth: .infinity, minHeight: isStandardQuery ? nil : 100)
            .background(.bar)
        }
        .task {
            await loadStudySession()
        }
        .onExitCommand(perform: onExit)
        .onChange(of: currentQuery) { _, newQuery in
            overlayCollectionNames = []
            allCollectionNames = []
            if let newQuery, newQuery.kind == .standard {
                studyModeState.currentTypeID = try? appDatabase.fetchTypeID(instanceID: newQuery.instanceID)
            } else {
                studyModeState.currentTypeID = nil
            }
            guard let instanceID = newQuery?.instanceID else { return }
            overlayCollectionNames = (try? appDatabase.fetchVisibleBeforeAnswerCollectionNames(instanceID: instanceID)) ?? []
            allCollectionNames = (try? appDatabase.fetchAllCollectionNames(instanceID: instanceID)) ?? []
        }
        .onChange(of: editInstanceWindowState.latestSaveNonce) { _, _ in
            Task { await refreshStudySessionLive() }
        }
        .onChange(of: addInstanceWindowState.latestAddNonce) { _, _ in
            Task { await refreshStudySessionLive() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memorDidChangeDatabase)) { _ in
            Task { await refreshStudySessionLive() }
        }
        .onChange(of: studyModeState.editTypeRequestNonce) { _, _ in
            performEditType()
        }
        .onDisappear {
            studyModeState.currentTypeID = nil
        }
    }

    @ViewBuilder
    private func queryContent(for currentQuery: StudyQuery) -> some View {
        if currentQuery.kind == .pointMap, let payload = currentQuery.pointMapPayload {
            PointMapQueryView(
                payload: payload,
                revealName: isAnswerRevealed,
                onAnswerSelected: { revealAnswerIfPossible() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if currentQuery.kind == .boundaryMap, let payload = currentQuery.boundaryMapPayload {
            BoundaryMapQueryView(
                payload: payload,
                revealName: isAnswerRevealed,
                showFinder: showBoundaryFinder,
                onAnswerSelected: { revealAnswerIfPossible() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            QueryHTMLView(
                html: isAnswerRevealed ? renderedAnswerHTML : renderedQuestionHTML,
                onInstanceLinkActivated: { instanceID in
                    queryPreviewWindowState.requestOpenFirstQuery(instanceID: instanceID)
                    openWindow(id: "query-preview")
                },
                onQueryLinkActivated: { instanceID, queryTypeID in
                    queryPreviewWindowState.requestOpen(instanceID: instanceID, queryTypeID: queryTypeID)
                    openWindow(id: "query-preview")
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func revealControls(for currentQuery: StudyQuery) -> some View {
        let isReverseMap = currentQuery.isReverse
            && (currentQuery.kind == .pointMap || currentQuery.kind == .boundaryMap)
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                Text("\(greenQueries.count)")
                    .foregroundStyle(.green)
                    .underline(greenQueries.contains(where: { $0.id == currentQuery.id }))
                Text("\(redQueries.count)")
                    .foregroundStyle(.red)
                    .underline(redQueries.contains(where: { $0.id == currentQuery.id }))
                Text("\(blueQueries.count)")
                    .foregroundStyle(.blue)
                    .underline(blueQueries.contains(where: { $0.id == currentQuery.id }))
            }
            .font(.headline)

            if isReverseMap {
                Text("Click the location on the map")
                    .foregroundStyle(.secondary)
            } else {
                Button("Reveal Answer (\(shortcutSettings.binding(for: .studyRevealOrGood).displayString))") {
                    revealAnswerIfPossible()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func revealAnswerIfPossible() {
        guard currentQuery != nil, !isAnswerRevealed, !isCompleted else { return }
        isAnswerRevealed = true
        pendingUndo = .revealAnswer
    }

    /// Edit Type (⌘⇧T / Instances menu): exits Study mode and opens the Type
    /// detail page for the current instance's type. Does nothing on map queries
    /// (built-in types have no detail page).
    private func performEditType() {
        guard let typeID = studyModeState.currentTypeID else { return }
        // Exit first: a quick-study exit selects the Stacks tab, which would
        // otherwise clobber the Types-tab navigation below.
        onExit()
        navigationState.navigateToTypeDetail(typeID: typeID)
    }

    private func performUndo() {
        guard let undo = pendingUndo else { return }
        pendingUndo = nil

        switch undo {
        case .revealAnswer:
            guard currentQuery != nil, isAnswerRevealed, !isCompleted else { return }
            isAnswerRevealed = false

        case .responseRating(
            let previousQuery,
            let previousRenderedQuestionHTML,
            let previousRenderedAnswerHTML,
            let previousProjectedIntervals,
            let previousBlueQueries,
            let previousRedQueries,
            let previousGreenQueries,
            let previousOverlayCollectionNames,
            let previousAllCollectionNames,
            let originalInterval,
            let originalLastAnsweredTimestamp,
            let originalQueryState
        ):
            do {
                if previousQuery.kind == .pointMap, let pointID = previousQuery.pointMapPayload?.pointID {
                    try appDatabase.revertPointMapStudyResponse(
                        pointID: pointID,
                        originalInterval: originalInterval,
                        originalLastAnsweredTimestamp: originalLastAnsweredTimestamp,
                        originalQueryState: originalQueryState,
                        isReverse: previousQuery.isReverse
                    )
                } else if previousQuery.kind == .boundaryMap, let attachmentID = previousQuery.boundaryMapPayload?.attachmentID {
                    try appDatabase.revertBoundaryMapStudyResponse(
                        attachmentID: attachmentID,
                        originalInterval: originalInterval,
                        originalLastAnsweredTimestamp: originalLastAnsweredTimestamp,
                        originalQueryState: originalQueryState,
                        isReverse: previousQuery.isReverse
                    )
                } else {
                    try appDatabase.revertStudyResponse(
                        instanceID: previousQuery.instanceID,
                        queryTypeID: previousQuery.queryTypeID,
                        originalInterval: originalInterval,
                        originalLastAnsweredTimestamp: originalLastAnsweredTimestamp,
                        originalQueryState: originalQueryState
                    )
                }
            } catch {
                errorMessage = "Failed to undo."
                return
            }

            blueQueries = previousBlueQueries
            redQueries = previousRedQueries
            greenQueries = previousGreenQueries
            currentQuery = previousQuery
            renderedQuestionHTML = previousRenderedQuestionHTML
            renderedAnswerHTML = previousRenderedAnswerHTML
            projectedIntervalsByRating = previousProjectedIntervals
            isAnswerRevealed = true
            isCompleted = false
            overlayCollectionNames = previousOverlayCollectionNames
            allCollectionNames = previousAllCollectionNames
            errorMessage = nil
        }
    }

    @MainActor
    private func loadStudySession() async {
        do {
            let buckets = try appDatabase.fetchStudyQueryBuckets(forStackSearch: stack.search)
            blueQueries = buckets.blueQueries
            redQueries = buckets.redQueries
            greenQueries = buckets.greenQueries
            pendingUndo = nil
            await loadNextQuery()
        } catch {
            currentQuery = nil
            blueQueries = []
            redQueries = []
            greenQueries = []
            projectedIntervalsByRating = [:]
            renderedQuestionHTML = ""
            renderedAnswerHTML = ""
            isAnswerRevealed = false
            isCompleted = false
            pendingUndo = nil
            errorMessage = "Failed to load study mode."
        }
    }

    @MainActor
    private func refreshStudySessionLive() async {
        do {
            let buckets = try appDatabase.fetchStudyQueryBuckets(forStackSearch: stack.search)
            blueQueries = buckets.blueQueries
            redQueries = buckets.redQueries
            greenQueries = buckets.greenQueries
            pendingUndo = nil

            let allQueries = buckets.blueQueries + buckets.redQueries + buckets.greenQueries
            if let previousID = currentQuery?.id,
               let refreshed = allQueries.first(where: { $0.id == previousID }) {
                currentQuery = refreshed
                projectedIntervalsByRating = makeProjectedIntervals(for: refreshed)
                if refreshed.kind == .pointMap || refreshed.kind == .boundaryMap {
                    renderedQuestionHTML = ""
                    renderedAnswerHTML = ""
                } else {
                    renderedQuestionHTML = try buildRenderedQuestionHTML(appDatabase: appDatabase, query: refreshed)
                    renderedAnswerHTML = try buildRenderedAnswerHTML(appDatabase: appDatabase, query: refreshed)
                }
            } else if currentQuery != nil {
                isAnswerRevealed = false
                await loadNextQuery()
            }

            if currentQuery == nil && !allQueries.isEmpty {
                isCompleted = false
                isAnswerRevealed = false
                await loadNextQuery()
            }
        } catch {
            // Silent — keep showing the previous state rather than wiping the session.
        }
    }

    @MainActor
    private func loadNextQuery(nowTimestamp: Int64? = nil) async {
        let selectionTimestamp = nowTimestamp ?? Int64(Date().timeIntervalSince1970)

        let nextQuery: StudyQuery?
        if let overdueRedQuery = selectOverdueRedQuery(nowTimestamp: selectionTimestamp) {
            nextQuery = overdueRedQuery
        } else if let blueOrGreenQuery = selectRandomBlueOrGreenQuery() {
            nextQuery = blueOrGreenQuery
        } else {
            let previousID = currentQuery?.id
            let preferredRed = redQueries.filter { $0.id != previousID }
            nextQuery = preferredRed.randomElement() ?? redQueries.randomElement()
        }

        guard let nextQuery else {
            currentQuery = nil
            projectedIntervalsByRating = [:]
            renderedQuestionHTML = ""
            renderedAnswerHTML = ""
            isAnswerRevealed = false
            isCompleted = true
            errorMessage = nil
            return
        }

        do {
            currentQuery = nextQuery
            projectedIntervalsByRating = makeProjectedIntervals(for: nextQuery)
            if nextQuery.kind == .pointMap || nextQuery.kind == .boundaryMap {
                renderedQuestionHTML = ""
                renderedAnswerHTML = ""
            } else {
                renderedQuestionHTML = try buildRenderedQuestionHTML(appDatabase: appDatabase, query: nextQuery)
                renderedAnswerHTML = try buildRenderedAnswerHTML(appDatabase: appDatabase, query: nextQuery)
            }
            isAnswerRevealed = false
            isCompleted = false
            errorMessage = nil
        } catch {
            currentQuery = nil
            projectedIntervalsByRating = [:]
            renderedQuestionHTML = ""
            renderedAnswerHTML = ""
            isCompleted = false
            errorMessage = "Failed to load study mode."
        }
    }

    @MainActor
    private func reloadCurrentQuery() async {
        guard let currentQuery else { return }
        if currentQuery.kind == .pointMap {
            await reloadCurrentPointMapQuery()
            return
        }
        if currentQuery.kind == .boundaryMap {
            await reloadCurrentBoundaryMapQuery()
            return
        }
        do {
            let refreshed = try appDatabase.fetchQueryPreview(
                instanceID: currentQuery.instanceID,
                queryTypeID: currentQuery.queryTypeID
            )
            let updated = StudyQuery(
                instanceID: currentQuery.instanceID,
                queryTypeID: currentQuery.queryTypeID,
                interval: currentQuery.interval,
                maxInterval: currentQuery.maxInterval,
                lastAnsweredTimestamp: currentQuery.lastAnsweredTimestamp,
                queryState: currentQuery.queryState,
                typeName: refreshed.typeName,
                queryTypeName: refreshed.queryTypeName,
                questionHTML: refreshed.questionHTML,
                answerHTML: refreshed.answerHTML,
                typeCSS: refreshed.typeCSS,
                fieldValuesByName: refreshed.fieldValuesByName,
                booleanFieldNames: refreshed.booleanFieldNames
            )
            self.currentQuery = updated
            renderedQuestionHTML = try buildRenderedQuestionHTML(appDatabase: appDatabase, query: updated)
            renderedAnswerHTML = try buildRenderedAnswerHTML(appDatabase: appDatabase, query: updated)

            func replaceInPool(_ pool: inout [StudyQuery]) {
                if let idx = pool.firstIndex(where: { $0.id == updated.id }) {
                    pool[idx] = updated
                }
            }
            replaceInPool(&blueQueries)
            replaceInPool(&redQueries)
            replaceInPool(&greenQueries)
            refreshSiblingQueries(instanceID: updated.instanceID, excluding: updated.id)
        } catch {
            // Silently ignore — the old rendered content remains
        }
    }

    @MainActor
    private func reloadCurrentPointMapQuery() async {
        guard let currentQuery,
              currentQuery.kind == .pointMap,
              let previousPayload = currentQuery.pointMapPayload else { return }
        guard let refreshed = try? appDatabase.fetchPointMapInstance(instanceID: currentQuery.instanceID) else { return }

        let pointID = previousPayload.pointID
        let refreshedPoint = refreshed.points.first(where: { $0.id == pointID })
        let pointName = refreshedPoint?.name ?? previousPayload.pointName

        let refreshedBoundaries = (try? appDatabase.fetchBoundaryGeometries(forInstance: currentQuery.instanceID)) ?? previousPayload.boundaries
        let payload = PointMapStudyPayload(
            pointID: pointID,
            pointName: pointName,
            instanceTitle: refreshed.instance.title,
            points: refreshed.points,
            defaultCenterLat: refreshed.instance.defaultCenterLat,
            defaultCenterLng: refreshed.instance.defaultCenterLng,
            defaultZoom: refreshed.instance.defaultZoom,
            showAllPointsInQuestion: refreshed.instance.showAllPointsInQuestion,
            showHighlight: previousPayload.showHighlight,
            boundaries: refreshedBoundaries,
            isReverse: previousPayload.isReverse,
            pointSize: refreshed.instance.pointSize
        )
        let updated = StudyQuery(
            instanceID: currentQuery.instanceID,
            queryTypeID: currentQuery.queryTypeID,
            interval: currentQuery.interval,
            maxInterval: currentQuery.maxInterval,
            lastAnsweredTimestamp: currentQuery.lastAnsweredTimestamp,
            queryState: currentQuery.queryState,
            typeName: currentQuery.typeName,
            queryTypeName: refreshed.instance.title,
            questionHTML: "",
            answerHTML: "",
            typeCSS: "",
            fieldValuesByName: [:],
            kind: .pointMap,
            pointMapPayload: payload,
            isReverse: currentQuery.isReverse
        )
        self.currentQuery = updated

        func replaceInPool(_ pool: inout [StudyQuery]) {
            if let idx = pool.firstIndex(where: { $0.id == updated.id }) {
                pool[idx] = updated
            }
        }
        replaceInPool(&blueQueries)
        replaceInPool(&redQueries)
        replaceInPool(&greenQueries)
        refreshSiblingQueries(instanceID: updated.instanceID, excluding: updated.id)
    }

    @MainActor
    private func reloadCurrentBoundaryMapQuery() async {
        guard let currentQuery,
              currentQuery.kind == .boundaryMap,
              let previousPayload = currentQuery.boundaryMapPayload else { return }
        guard let refreshed = try? appDatabase.fetchBoundaryMapInstance(instanceID: currentQuery.instanceID) else { return }

        // The current attachment may have been deleted by the editor; if so,
        // keep the old payload so the user finishes the answer they were on.
        let attachment = refreshed.attachments.first(where: { $0.id == previousPayload.attachmentID })
        let boundaryName = attachment?.name ?? previousPayload.boundaryName
        let boundaryID = attachment?.boundaryID ?? previousPayload.boundaryID
        var geometries: [BoundaryGeometry] = []
        for attached in refreshed.attachments {
            guard let parsed = try? appDatabase.fetchBoundaryGeometry(boundaryID: attached.boundaryID) else { continue }
            geometries.append(BoundaryGeometry(id: attached.boundaryID, name: attached.name, geometry: parsed))
        }
        if geometries.isEmpty { geometries = previousPayload.geometries }

        let payload = BoundaryMapStudyPayload(
            attachmentID: previousPayload.attachmentID,
            boundaryID: boundaryID,
            boundaryName: boundaryName,
            instanceTitle: refreshed.instance.title,
            geometries: geometries,
            defaultCenterLat: refreshed.instance.defaultCenterLat,
            defaultCenterLng: refreshed.instance.defaultCenterLng,
            defaultZoom: refreshed.instance.defaultZoom,
            showAllBoundariesInQuestion: refreshed.instance.showAllBoundariesInQuestion,
            showHighlight: previousPayload.showHighlight,
            isReverse: previousPayload.isReverse
        )
        let updated = StudyQuery(
            instanceID: currentQuery.instanceID,
            queryTypeID: currentQuery.queryTypeID,
            interval: currentQuery.interval,
            maxInterval: currentQuery.maxInterval,
            lastAnsweredTimestamp: currentQuery.lastAnsweredTimestamp,
            queryState: currentQuery.queryState,
            typeName: currentQuery.typeName,
            queryTypeName: boundaryName,
            questionHTML: "",
            answerHTML: "",
            typeCSS: "",
            fieldValuesByName: [:],
            kind: .boundaryMap,
            boundaryMapPayload: payload,
            isReverse: currentQuery.isReverse
        )
        self.currentQuery = updated

        func replaceInPool(_ pool: inout [StudyQuery]) {
            if let idx = pool.firstIndex(where: { $0.id == updated.id }) {
                pool[idx] = updated
            }
        }
        replaceInPool(&blueQueries)
        replaceInPool(&redQueries)
        replaceInPool(&greenQueries)
        refreshSiblingQueries(instanceID: updated.instanceID, excluding: updated.id)
    }

    @MainActor
    private func refreshSiblingQueries(instanceID: Int64, excluding excludedID: String) {
        func refresh(_ pool: inout [StudyQuery]) {
            for i in pool.indices {
                let original = pool[i]
                guard original.instanceID == instanceID, original.id != excludedID else { continue }
                guard let refreshed = try? appDatabase.fetchQueryPreview(
                    instanceID: original.instanceID,
                    queryTypeID: original.queryTypeID
                ) else { continue }
                // The preview always renders the Forward version, so its payload's
                // direction defaults to false. Restore the original direction so a
                // refreshed reverse query keeps rendering as reverse.
                var pointMapPayload = refreshed.pointMapPayload
                pointMapPayload?.isReverse = original.isReverse
                var boundaryMapPayload = refreshed.boundaryMapPayload
                boundaryMapPayload?.isReverse = original.isReverse
                pool[i] = StudyQuery(
                    instanceID: original.instanceID,
                    queryTypeID: original.queryTypeID,
                    interval: original.interval,
                    maxInterval: original.maxInterval,
                    lastAnsweredTimestamp: original.lastAnsweredTimestamp,
                    queryState: original.queryState,
                    typeName: refreshed.typeName,
                    queryTypeName: refreshed.queryTypeName,
                    questionHTML: refreshed.questionHTML,
                    answerHTML: refreshed.answerHTML,
                    typeCSS: refreshed.typeCSS,
                    fieldValuesByName: refreshed.fieldValuesByName,
                    booleanFieldNames: refreshed.booleanFieldNames,
                    kind: refreshed.kind,
                    pointMapPayload: pointMapPayload,
                    boundaryMapPayload: boundaryMapPayload,
                    isReverse: original.isReverse
                )
            }
        }
        refresh(&blueQueries)
        refresh(&redQueries)
        refresh(&greenQueries)
    }

    @MainActor
    private func submit(_ rating: StudyResponseRating) async {
        guard let currentQuery else { return }
        let answeredAtTimestamp = Int64(Date().timeIntervalSince1970)

        let isPointMap = currentQuery.kind == .pointMap
        let isBoundaryMap = currentQuery.kind == .boundaryMap
        let pointID = currentQuery.pointMapPayload?.pointID ?? 0
        let attachmentID = currentQuery.boundaryMapPayload?.attachmentID ?? 0

        let savedUndo = StudyUndoAction.responseRating(
            previousQuery: currentQuery,
            previousRenderedQuestionHTML: renderedQuestionHTML,
            previousRenderedAnswerHTML: renderedAnswerHTML,
            previousProjectedIntervals: projectedIntervalsByRating,
            previousBlueQueries: blueQueries,
            previousRedQueries: redQueries,
            previousGreenQueries: greenQueries,
            previousOverlayCollectionNames: overlayCollectionNames,
            previousAllCollectionNames: allCollectionNames,
            originalInterval: currentQuery.interval,
            originalLastAnsweredTimestamp: currentQuery.lastAnsweredTimestamp,
            originalQueryState: currentQuery.queryState
        )

        do {
            let updatedInterval = projectedIntervalsByRating[rating] ?? currentQuery.interval
            let outcome: StudyResponseOutcome
            if isPointMap {
                outcome = try appDatabase.applyPointMapStudyResponse(
                    pointID: pointID,
                    rating: rating,
                    answeredAtTimestamp: answeredAtTimestamp,
                    overrideInterval: updatedInterval,
                    isReverse: currentQuery.isReverse
                )
            } else if isBoundaryMap {
                outcome = try appDatabase.applyBoundaryMapStudyResponse(
                    attachmentID: attachmentID,
                    rating: rating,
                    answeredAtTimestamp: answeredAtTimestamp,
                    overrideInterval: updatedInterval,
                    isReverse: currentQuery.isReverse
                )
            } else {
                outcome = try appDatabase.applyStudyResponse(
                    instanceID: currentQuery.instanceID,
                    queryTypeID: currentQuery.queryTypeID,
                    rating: rating,
                    answeredAtTimestamp: answeredAtTimestamp,
                    overrideInterval: updatedInterval
                )
            }
            updateStudyPools(
                for: currentQuery,
                outcome: outcome,
                answeredAtTimestamp: answeredAtTimestamp
            )
            await loadNextQuery(nowTimestamp: answeredAtTimestamp)
            pendingUndo = savedUndo
        } catch {
            errorMessage = "Failed to record study response."
        }
    }

    private func makeProjectedIntervals(for query: StudyQuery) -> [StudyResponseRating: Int64] {
        var intervals: [StudyResponseRating: Int64] = [:]
        for rating in StudyResponseRating.allCases {
            let raw = studyResponseOutcome(
                currentState: query.queryState,
                currentInterval: query.interval,
                rating: rating
            ).newInterval
            if let maxInterval = query.maxInterval {
                intervals[rating] = min(raw, maxInterval)
            } else {
                intervals[rating] = raw
            }
        }
        return intervals
    }

    private func selectOverdueRedQuery(nowTimestamp: Int64) -> StudyQuery? {
        let overdueQueries = redQueries.filter { query in
            guard let lastAnsweredTimestamp = query.lastAnsweredTimestamp else { return false }
            return lastAnsweredTimestamp + query.interval < nowTimestamp
        }
        guard let minimumDueTimestamp = overdueQueries.compactMap({ query in
            query.lastAnsweredTimestamp.map { $0 + query.interval }
        }).min() else {
            return nil
        }

        let tiedQueries = overdueQueries.filter { query in
            guard let lastAnsweredTimestamp = query.lastAnsweredTimestamp else { return false }
            return lastAnsweredTimestamp + query.interval == minimumDueTimestamp
        }
        return tiedQueries.randomElement()
    }

    private func selectRandomBlueOrGreenQuery() -> StudyQuery? {
        let totalEligibleCount = blueQueries.count + greenQueries.count
        guard totalEligibleCount > 0 else { return nil }

        if blueQueries.isEmpty {
            return greenQueries.randomElement()
        }
        if greenQueries.isEmpty {
            return blueQueries.randomElement()
        }

        let chooseGreen = Int.random(in: 0..<totalEligibleCount) < greenQueries.count
        return chooseGreen ? greenQueries.randomElement() : blueQueries.randomElement()
    }

    private func updateStudyPools(
        for query: StudyQuery,
        outcome: StudyResponseOutcome,
        answeredAtTimestamp: Int64
    ) {
        let queryID = query.id
        blueQueries.removeAll { $0.id == queryID }
        redQueries.removeAll { $0.id == queryID }
        greenQueries.removeAll { $0.id == queryID }

        guard outcome.newState == .zero || outcome.newState == .one else { return }

        redQueries.append(
            StudyQuery(
                instanceID: query.instanceID,
                queryTypeID: query.queryTypeID,
                interval: outcome.newInterval,
                maxInterval: query.maxInterval,
                lastAnsweredTimestamp: answeredAtTimestamp,
                queryState: outcome.newState,
                typeName: query.typeName,
                queryTypeName: query.queryTypeName,
                questionHTML: query.questionHTML,
                answerHTML: query.answerHTML,
                typeCSS: query.typeCSS,
                fieldValuesByName: query.fieldValuesByName,
                booleanFieldNames: query.booleanFieldNames,
                kind: query.kind,
                pointMapPayload: query.pointMapPayload,
                boundaryMapPayload: query.boundaryMapPayload,
                isReverse: query.isReverse
            )
        )
    }
}

private struct StudyQueryHeaderBar: View {
    let query: StudyQuery?

    var body: some View {
        HStack(spacing: 0) {
            if let query {
                Text(query.typeName)
                    .foregroundStyle(.blue)

                Text(":")
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 4)

                if query.kind == .pointMap, let payload = query.pointMapPayload {
                    Text(payload.instanceTitle)
                        .foregroundStyle(Color(nsColor: .systemYellow))
                } else if query.kind == .boundaryMap, let payload = query.boundaryMapPayload {
                    Text(payload.instanceTitle)
                        .foregroundStyle(Color(nsColor: .systemYellow))
                } else {
                    Text(query.queryTypeName)
                        .foregroundStyle(Color(nsColor: .magenta))
                }
            }

            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct StudyResponseButton: View {
    let title: String
    let intervalLabel: String
    let color: Color
    let isClampedToMax: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if isClampedToMax {
                    Text(intervalLabel)
                        .foregroundStyle(Color(nsColor: .systemYellow))
                } else {
                    Text(intervalLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            Button(action: action) {
                Text(title)
                    .fontWeight(.medium)
                    .foregroundStyle(.black)
                    .frame(minWidth: 76)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .frame(minWidth: 76)
    }
}

private struct StudyModeKeyCommandHandler: NSViewRepresentable {
    let shortcutSettings: ShortcutSettings
    let onEscape: () -> Void
    let onSpace: () -> Void
    let onUndo: () -> Void
    let onResponse: (StudyResponseRating) -> Void
    let onShiftDown: () -> Void
    let onEditInstance: () -> Void
    let onEditType: () -> Void
    let onArrowLinkShortcut: (LinkShortcutKey) -> Bool

    func makeNSView(context: Context) -> KeyCommandHandlingView {
        let view = KeyCommandHandlingView()
        view.shortcutSettings = shortcutSettings
        view.onEscape = onEscape
        view.onSpace = onSpace
        view.onUndo = onUndo
        view.onResponse = onResponse
        view.onShiftDown = onShiftDown
        view.onEditInstance = onEditInstance
        view.onEditType = onEditType
        view.onArrowLinkShortcut = onArrowLinkShortcut
        return view
    }

    func updateNSView(_ nsView: KeyCommandHandlingView, context: Context) {
        nsView.shortcutSettings = shortcutSettings
        nsView.onEscape = onEscape
        nsView.onSpace = onSpace
        nsView.onUndo = onUndo
        nsView.onResponse = onResponse
        nsView.onShiftDown = onShiftDown
        nsView.onEditInstance = onEditInstance
        nsView.onEditType = onEditType
        nsView.onArrowLinkShortcut = onArrowLinkShortcut
    }

    final class KeyCommandHandlingView: NSView {
        var shortcutSettings: ShortcutSettings?
        var onEscape: (() -> Void)?
        var onSpace: (() -> Void)?
        var onUndo: (() -> Void)?
        var onResponse: ((StudyResponseRating) -> Void)?
        var onShiftDown: (() -> Void)?
        var onEditInstance: (() -> Void)?
        var onEditType: (() -> Void)?
        var onArrowLinkShortcut: ((LinkShortcutKey) -> Bool)?

        private var keyDownMonitor: Any?
        private var flagsMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if window == nil {
                removeMonitors()
            } else {
                installMonitorsIfNeeded()
            }
        }

        deinit {
            removeMonitors()
        }

        private func installMonitorsIfNeeded() {
            if keyDownMonitor == nil {
                keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window else {
                        return event
                    }

                    // Escape stays hard-coded (non-customizable per design).
                    if event.keyCode == 53 {
                        self.onEscape?()
                        return nil
                    }

                    guard let settings = self.shortcutSettings else { return event }

                    if settings.binding(for: .studyRevealOrGood).matches(event) {
                        self.onSpace?()
                        return nil
                    }
                    if settings.binding(for: .studyRatingAgain).matches(event) {
                        self.onResponse?(.again)
                        return nil
                    }
                    if settings.binding(for: .studyRatingHard).matches(event) {
                        self.onResponse?(.hard)
                        return nil
                    }
                    if settings.binding(for: .studyRatingGood).matches(event) {
                        self.onResponse?(.good)
                        return nil
                    }
                    if settings.binding(for: .studyRatingEasy).matches(event) {
                        self.onResponse?(.easy)
                        return nil
                    }
                    if settings.binding(for: .studyUndo).matches(event) {
                        self.onUndo?()
                        return nil
                    }
                    if settings.binding(for: .studyEditInstance).matches(event) {
                        self.onEditInstance?()
                        return nil
                    }
                    if settings.binding(for: .studyEditType).matches(event) {
                        self.onEditType?()
                        return nil
                    }

                    // Plain left/right arrow -> instance link shortcuts (post-reveal).
                    let arrowFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.numericPad, .function])
                    if arrowFlags.isEmpty, let key = LinkShortcutKey.fromKeyCode(event.keyCode),
                       self.onArrowLinkShortcut?(key) == true {
                        return nil
                    }

                    return event
                }
            }

            if flagsMonitor == nil {
                flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                    guard let self, event.window === self.window else {
                        return event
                    }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if flags == .shift {
                        self.onShiftDown?()
                    }
                    return event
                }
            }
        }

        private func removeMonitors() {
            if let m = keyDownMonitor {
                NSEvent.removeMonitor(m)
                keyDownMonitor = nil
            }
            if let m = flagsMonitor {
                NSEvent.removeMonitor(m)
                flagsMonitor = nil
            }
        }
    }
}
