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
        previousStreak: Int,
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
    /// Consecutive non-Again answers this session (Hard/Good/Easy +1, Again
    /// resets to 0). Session-only by virtue of being view state — a fresh
    /// Study mode always starts at 0. Shown at the trailing edge of the
    /// response bar (hidden at 0); every multiple of 5 swaps the rating's
    /// sound for the streak jackpot (see RatingSounds).
    @State private var streak = 0
    @State private var pendingUndo: StudyUndoAction?
    /// Coalesces bursts of database-change triggers (e.g. a run of MCP
    /// writes) into one live refresh: refreshStudySessionLive rebuilds every
    /// bucket synchronously on the main actor, so N back-to-back triggers
    /// would stall the session N times.
    @State private var liveRefreshTask: Task<Void, Never>?
    /// The query the user glimpsed before undoing a rating (⌘Z after advancing
    /// too fast). The next advance re-shows it instead of drawing randomly —
    /// the user's mind has already started on it — as long as it is still in
    /// the session's pools. One-shot, and session-only by virtue of being view
    /// state (exiting Study or the app forgets it).
    @State private var peekedNextQueryID: String?

    // One-second colored flash over the divider above the rating just pressed
    // (pure overlay — the query HTML is untouched). Geometry is snapshotted at
    // submit time so the bar stays put while the next query's layout settles;
    // a new response replaces any live flash instantly (fresh id).
    private struct RatingFlash: Identifiable {
        let id = UUID()
        let color: Color
        let buttonFrame: CGRect
        let startDate = Date()
    }
    @State private var ratingFlash: RatingFlash?
    @State private var ratingButtonFrames: [StudyResponseRating: CGRect] = [:]
    @State private var bottomBarFrame: CGRect = .zero

    private static let ratingFlashCoordinateSpace = "study-rating-flash"

    // Same colors as the rating buttons (projectedIntervals).
    private static func ratingColor(_ rating: StudyResponseRating) -> Color {
        switch rating {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return Color(red: 0.65, green: 0.86, blue: 0.65)
        }
    }

    // One height for the response/reveal bar in every state and query kind —
    // sized to fit the tallest content (counts + Reveal button). A constant
    // height keeps the divider from shifting between queries, which the
    // rating flash bar's placement relies on.
    private static let responseBarHeight: CGFloat = 84

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
                    onDuplicateInstance: {
                        // Same reveal gate as Edit Current Instance (the filled-in Add
                        // window would give away the answer). Built-ins are excluded
                        // like the Search window's Duplicate: the Add editor doesn't
                        // support duplicating Person or map instances.
                        guard let currentQuery, isAnswerRevealed else { return }
                        guard currentQuery.kind == .standard,
                              currentQuery.typeName != PERSON_TYPE_NAME else { return }
                        addInstanceWindowState.requestOpenForDuplication(sourceInstanceID: currentQuery.instanceID)
                        openWindow(id: "add-instance")
                    },
                    onArrowLinkShortcut: { key in
                        // Only after the answer is revealed; mirrors the link-click callbacks below.
                        guard isAnswerRevealed, let currentQuery else { return false }
                        switch resolveLinkShortcut(key, fieldValues: currentQuery.fieldValuesByName) {
                        case .none:
                            // No authored data-shortcut for this key: fall back to
                            // office succession navigation (← predecessor, → successor).
                            guard let neighborID = resolveOfficeSuccessionShortcut(
                                key, query: currentQuery, appDatabase: appDatabase
                            ) else { return false }
                            queryPreviewWindowState.requestOpenFirstQuery(instanceID: neighborID)
                            openWindow(id: "query-preview")
                            return true
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
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.ratingFlashCoordinateSpace))
                            } action: { frame in
                                ratingButtonFrames[item.rating] = frame
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: Self.responseBarHeight)
            .background(.bar)
            // An overlay, not an HStack member: the reveal/rating controls
            // stay perfectly centered while the streak sits at the bar's
            // trailing edge.
            .overlay(alignment: .trailing) {
                streakLabel
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.ratingFlashCoordinateSpace))
            } action: { frame in
                bottomBarFrame = frame
            }
        }
        .coordinateSpace(name: Self.ratingFlashCoordinateSpace)
        .overlay(alignment: .topLeading) {
            ratingFlashOverlay
        }
        .task {
            await loadStudySession()
        }
        .onExitCommand(perform: onExit)
        .onChange(of: currentQuery) { _, newQuery in
            overlayCollectionNames = []
            allCollectionNames = []
            // studyModeState is an EnvironmentObject and onChange runs inside
            // the view-update transaction: writing its @Published here is the
            // "Publishing changes from within view updates is not allowed"
            // fault (one per query advance). Defer the publish; the @State
            // writes in this closure are fine where they are.
            let newTypeID: Int64?
            if let newQuery, newQuery.kind == .standard {
                newTypeID = try? appDatabase.fetchTypeID(instanceID: newQuery.instanceID)
            } else {
                newTypeID = nil
            }
            Task { @MainActor in
                studyModeState.currentTypeID = newTypeID
            }
            guard let instanceID = newQuery?.instanceID else { return }
            overlayCollectionNames = (try? appDatabase.fetchVisibleBeforeAnswerCollectionNames(instanceID: instanceID)) ?? []
            allCollectionNames = (try? appDatabase.fetchAllCollectionNames(instanceID: instanceID)) ?? []
        }
        .onChange(of: editInstanceWindowState.latestSaveNonce) { _, _ in
            scheduleLiveRefresh()
        }
        .onChange(of: addInstanceWindowState.latestAddNonce) { _, _ in
            scheduleLiveRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .memorDidChangeDatabase)) { _ in
            scheduleLiveRefresh()
        }
        .onChange(of: studyModeState.editTypeRequestNonce) { _, _ in
            performEditType()
        }
        .onDisappear {
            studyModeState.currentTypeID = nil
        }
    }

    // The flash bar itself: 4pt capsule straddling the divider, spanning the
    // pressed button's width. Opacity follows 1 − t² exactly (TimelineView
    // recomputes it per frame — no approximated animation curve), and the
    // flash state clears shortly after the second elapses.
    @ViewBuilder
    private var ratingFlashOverlay: some View {
        if let flash = ratingFlash {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(flash.startDate)
                let opacity = max(0.0, 1.0 - t * t)
                Capsule()
                    .fill(flash.color)
                    .frame(width: flash.buttonFrame.width, height: 4)
                    // The response bar's LIVE top edge (the divider line sits
                    // immediately above it): the flash's bottom edge lands
                    // exactly on the divider, covering the line and rising
                    // into the query area — never dipping into the response
                    // bar, even if the layout shifts under the fade.
                    .offset(x: flash.buttonFrame.minX, y: bottomBarFrame.minY - 4)
                    .opacity(opacity)
            }
            .allowsHitTesting(false)
            .task(id: flash.id) {
                try? await Task.sleep(for: .seconds(1.05))
                if ratingFlash?.id == flash.id {
                    ratingFlash = nil
                }
            }
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

    /// The session streak at the trailing edge of the response bar. Hidden
    /// entirely at 0 — the badge only appears once a run is going.
    @ViewBuilder
    private var streakLabel: some View {
        if streak > 0 {
            StreakBadgeView(streak: streak)
                .padding(.trailing, 12)
                .accessibilityLabel("Streak: \(streak)")
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
            let previousStreak,
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
                } else if let personKind = previousQuery.personQueryKind {
                    try appDatabase.revertPersonStudyResponse(
                        instanceID: previousQuery.instanceID,
                        kind: personKind,
                        partnershipID: previousQuery.personPartnershipID,
                        officeID: previousQuery.personOfficeID,
                        originalInterval: originalInterval,
                        originalLastAnsweredTimestamp: originalLastAnsweredTimestamp,
                        originalQueryState: originalQueryState
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

            // The query on screen was only glimpsed — remember it so the next
            // advance re-shows it (nil when the rating completed the session
            // and ⌘Z came from the congratulations screen). Recorded only
            // after a successful revert: a failed undo leaves the glimpsed
            // query current, where a stale peek would wrongly repeat it.
            peekedNextQueryID = currentQuery?.id

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
            streak = previousStreak
            errorMessage = nil
        }
    }

    @MainActor
    private func loadStudySession() async {
        RatingSounds.prewarm()
        do {
            let buckets = try appDatabase.fetchStudyQueryBuckets(forStackSearch: stack.search)
            blueQueries = buckets.blueQueries
            redQueries = buckets.redQueries
            greenQueries = buckets.greenQueries
            pendingUndo = nil
            peekedNextQueryID = nil
            // A fresh session starts at 0 (refreshStudySessionLive, a
            // mid-session data refresh, deliberately leaves it alone).
            streak = 0
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
            peekedNextQueryID = nil
            streak = 0
            errorMessage = "Failed to load study mode."
        }
    }

    private func scheduleLiveRefresh() {
        liveRefreshTask?.cancel()
        liveRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refreshStudySessionLive()
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

        // A peeked query (glimpsed, then ⌘Z'd away) preempts normal selection,
        // even over overdue reds. One-shot: consumed whether or not it is
        // still in the pools (live refreshes drop queries deleted or disabled
        // mid-session, in which case selection just proceeds normally).
        let peekedQuery = peekedNextQueryID.flatMap { peekedID in
            (redQueries + blueQueries + greenQueries).first { $0.id == peekedID }
        }
        peekedNextQueryID = nil

        let nextQuery: StudyQuery?
        if let peekedQuery {
            nextQuery = peekedQuery
        } else if let overdueRedQuery = selectOverdueRedQuery(nowTimestamp: selectionTimestamp) {
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
    private func submit(_ rating: StudyResponseRating) async {
        guard let currentQuery else { return }
        // The reveal gate at the call sites is checked at key-event time, but
        // the rating runs in a detached Task: a burst of presses can queue
        // several submits behind one passed gate check, and the later ones
        // would rate the NEXT, never-revealed query sight-unseen (submit ends
        // by advancing and clearing isAnswerRevealed). Re-check here — every
        // caller requires a revealed answer (the rating buttons only exist
        // post-reveal).
        guard isAnswerRevealed else { return }
        let previousStreak = streak
        // Flash the pressed rating's bar over the divider (replacing any
        // still-fading bar from the previous response outright), advance the
        // streak, and play the rating's sound — the streak jackpot replaces
        // it on every multiple of 5. All optimistic, like the flash always
        // was; ⌘Z restores the streak from the undo snapshot.
        if let buttonFrame = ratingButtonFrames[rating] {
            ratingFlash = RatingFlash(
                color: Self.ratingColor(rating),
                buttonFrame: buttonFrame
            )
        }
        streak = rating == .again ? 0 : previousStreak + 1
        RatingSounds.play(rating, streak: streak, previousStreak: previousStreak)
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
            previousStreak: previousStreak,
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
            } else if let personKind = currentQuery.personQueryKind {
                outcome = try appDatabase.applyPersonStudyResponse(
                    instanceID: currentQuery.instanceID,
                    kind: personKind,
                    partnershipID: currentQuery.personPartnershipID,
                    officeID: currentQuery.personOfficeID,
                    rating: rating,
                    answeredAtTimestamp: answeredAtTimestamp,
                    overrideInterval: updatedInterval
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
            // If the response failed because the card no longer exists (e.g. a
            // person_query row deleted mid-session by an edit), rebuilding from
            // the DB drops it from the pools instead of leaving the session
            // stuck re-erroring on the same card. A transient failure keeps the
            // card (and the banner) so the user can simply re-rate.
            await refreshStudySessionLive()
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
            query.withStudyOutcome(
                interval: outcome.newInterval,
                lastAnsweredTimestamp: answeredAtTimestamp,
                queryState: outcome.newState
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
    let onDuplicateInstance: () -> Void
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
        view.onDuplicateInstance = onDuplicateInstance
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
        nsView.onDuplicateInstance = onDuplicateInstance
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
        var onDuplicateInstance: (() -> Void)?
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

                    // A held key auto-repeats its keyDown, and acting on the
                    // repeats machine-guns the action — a held Space alternates
                    // reveal/Good, re-rating the same query many times a second.
                    // Swallow repeats of every key this monitor owns (same match
                    // checks as below, actions disabled) and pass the rest on.
                    if event.isARepeat {
                        if event.keyCode == 53 { return nil }
                        if let settings = self.shortcutSettings {
                            let ownedActions: [ShortcutAction] = [
                                .studyRevealOrGood, .studyRatingAgain, .studyRatingHard,
                                .studyRatingGood, .studyRatingEasy, .studyUndo,
                                .studyEditInstance, .studyEditType, .studyDuplicateInstance,
                            ]
                            if ownedActions.contains(where: { settings.binding(for: $0).matches(event) }) {
                                return nil
                            }
                        }
                        let repeatArrowFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                            .subtracting([.numericPad, .function])
                        if repeatArrowFlags.isEmpty, LinkShortcutKey.fromKeyCode(event.keyCode) != nil {
                            return nil
                        }
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
                    if settings.binding(for: .studyDuplicateInstance).matches(event) {
                        self.onDuplicateInstance?()
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
