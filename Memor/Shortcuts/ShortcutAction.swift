//
//  ShortcutAction.swift
//  Memor
//
//  Registry of all user-customizable keyboard shortcuts in the app.
//

import SwiftUI

enum ShortcutCategory: String, CaseIterable, Identifiable {
    case global
    case study
    case editor
    case types
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: return "Global"
        case .study: return "Study Mode"
        case .editor: return "Instance Editor"
        case .types: return "Types Page"
        case .search: return "Search Windows"
        }
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    // Global / navigation
    case goToStacksTab
    case goToInstancesTab
    case goToCollectionsTab
    case goToTypesTab
    case goToGraphTab
    case openAddInstance
    case openSearchInstances
    case openSearchQueries
    case openSettings
    case findInList
    case toggleDeveloperMode

    // Study mode
    case studyRevealOrGood
    case studyRatingAgain
    case studyRatingHard
    case studyRatingGood
    case studyRatingEasy
    case studyUndo
    case studyEditInstance
    case studyEditType
    case studyDuplicateInstance
    case studyPlayAudio

    // Instance editor
    case editorSave
    case editorSubmit
    case editorWrapBold
    case editorWrapItalic
    case editorWrapEmphasis
    case editorInsertImage
    case editorCopyLink
    case editorPickType
    case editorOpenHyperlinkSearch
    case editorPointMapAddQuery
    case editorPreviewTopQueryType
    case editorFocusCollectionSearch
    case editorHighlightQueryTypes

    // Types page / code editors
    case typesSaveCurrent

    // Search windows
    case searchResetDueDates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .goToStacksTab: return "Go to Stacks Tab"
        case .goToInstancesTab: return "Go to Instances Tab"
        case .goToCollectionsTab: return "Go to Collections Tab"
        case .goToTypesTab: return "Go to Types Tab"
        case .goToGraphTab: return "Go to Graph Tab"
        case .openAddInstance: return "Add Instance"
        case .openSearchInstances: return "Open Search"
        case .openSearchQueries: return "Open Search (Queries)"
        case .openSettings: return "Open Settings"
        case .findInList: return "Find in List"
        case .toggleDeveloperMode: return "Toggle Developer Mode"
        case .studyRevealOrGood: return "Reveal / Rate Good"
        case .studyRatingAgain: return "Rate Again"
        case .studyRatingHard: return "Rate Hard"
        case .studyRatingGood: return "Rate Good"
        case .studyRatingEasy: return "Rate Easy"
        case .studyUndo: return "Undo Study Response"
        case .studyEditInstance: return "Edit Current Instance"
        case .studyEditType: return "Edit Type"
        case .studyDuplicateInstance: return "Duplicate Current Instance"
        case .studyPlayAudio: return "Play Audio"
        case .editorSave: return "Save"
        case .editorSubmit: return "Submit"
        case .editorWrapBold: return "Wrap Bold"
        case .editorWrapItalic: return "Wrap Italic"
        case .editorWrapEmphasis: return "Wrap Emphasis"
        // The case name is the persisted UserDefaults key for user overrides — only the title
        // changed when the picker learned to insert .mp3 audio as well.
        case .editorInsertImage: return "Insert Image or Audio"
        case .editorCopyLink: return "Copy Link"
        case .editorPickType: return "Pick Type"
        case .editorOpenHyperlinkSearch: return "Open Hyperlink Search"
        case .editorPointMapAddQuery: return "PointMap — Add Query"
        case .editorPreviewTopQueryType: return "Preview Topmost Query"
        case .editorFocusCollectionSearch: return "Focus Collections Search"
        case .editorHighlightQueryTypes: return "Highlight Query Types"
        case .typesSaveCurrent: return "Save Current Editor"
        case .searchResetDueDates: return "Reset Due Dates"
        }
    }

    var category: ShortcutCategory {
        switch self {
        case .goToStacksTab, .goToInstancesTab, .goToCollectionsTab, .goToTypesTab, .goToGraphTab,
             .openAddInstance, .openSearchInstances, .openSearchQueries, .openSettings, .findInList,
             .toggleDeveloperMode:
            return .global
        case .studyRevealOrGood, .studyRatingAgain, .studyRatingHard, .studyRatingGood,
             .studyRatingEasy, .studyUndo, .studyEditInstance, .studyEditType,
             .studyDuplicateInstance, .studyPlayAudio:
            return .study
        case .editorSave, .editorSubmit, .editorWrapBold, .editorWrapItalic, .editorWrapEmphasis,
             .editorInsertImage, .editorCopyLink, .editorPickType, .editorOpenHyperlinkSearch,
             .editorPointMapAddQuery, .editorPreviewTopQueryType, .editorFocusCollectionSearch,
             .editorHighlightQueryTypes:
            return .editor
        case .typesSaveCurrent:
            return .types
        case .searchResetDueDates:
            return .search
        }
    }

    var `default`: KeyBinding {
        switch self {
        case .goToStacksTab: return KeyBinding(key: "1", modifiers: .command)
        case .goToInstancesTab: return KeyBinding(key: "2", modifiers: .command)
        case .goToCollectionsTab: return KeyBinding(key: "3", modifiers: .command)
        case .goToTypesTab: return KeyBinding(key: "4", modifiers: .command)
        case .goToGraphTab: return KeyBinding(key: "5", modifiers: .command)
        case .openAddInstance: return KeyBinding(key: "A", modifiers: [.command, .shift])
        case .openSearchInstances: return KeyBinding(key: "S", modifiers: [.command, .shift])
        case .openSearchQueries: return KeyBinding(key: "S", modifiers: [.command, .option])
        case .openSettings: return KeyBinding(key: "Comma", modifiers: .command)
        case .findInList: return KeyBinding(key: "F", modifiers: .command)
        case .toggleDeveloperMode: return KeyBinding(key: "D", modifiers: [.command, .shift])
        case .studyRevealOrGood: return KeyBinding(key: "Space")
        case .studyRatingAgain: return KeyBinding(key: "1")
        case .studyRatingHard: return KeyBinding(key: "2")
        case .studyRatingGood: return KeyBinding(key: "3")
        case .studyRatingEasy: return KeyBinding(key: "4")
        case .studyUndo: return KeyBinding(key: "Z", modifiers: .command)
        case .studyEditInstance: return KeyBinding(key: "E")
        case .studyEditType: return KeyBinding(key: "T", modifiers: [.command, .shift])
        case .studyDuplicateInstance: return KeyBinding(key: "D", modifiers: .command)
        // Plays the first <audio> on the shown query page. Also matched by the Query Preview
        // window's monitor (like .studyEditInstance). Shares bare A with .editorPointMapAddQuery
        // on purpose: both monitors are window-scoped and never coexist in one window — the same
        // precedent as the ⌘S / ⌘⇧T / ⌘D cross-category duplicates. Settings' "Reassign" cannot
        // separate two actions whose DEFAULT is the contested key (it resets the other to its
        // default, which is A again) — a pre-existing quirk of the conflict resolver.
        case .studyPlayAudio: return KeyBinding(key: "A")
        case .editorSave: return KeyBinding(key: "S", modifiers: .command)
        case .editorSubmit: return KeyBinding(key: "Return", modifiers: .command)
        case .editorWrapBold: return KeyBinding(key: "B", modifiers: .command)
        case .editorWrapItalic: return KeyBinding(key: "I", modifiers: .command)
        // The <e> wrap is dispatched by the hard-coded ⌘J route in
        // WindowKeyCommandHandler; this default mirrors that reality (the old
        // ⌘E default was never dispatched, and ⌘E now highlights query types).
        case .editorWrapEmphasis: return KeyBinding(key: "J", modifiers: .command)
        case .editorInsertImage: return KeyBinding(key: "O", modifiers: .command)
        case .editorCopyLink: return KeyBinding(key: "K", modifiers: [.command, .shift])
        case .editorPickType: return KeyBinding(key: "T", modifiers: [.command, .shift])
        case .editorOpenHyperlinkSearch: return KeyBinding(key: "L", modifiers: .command)
        case .editorPointMapAddQuery: return KeyBinding(key: "A")
        case .editorPreviewTopQueryType: return KeyBinding(key: "P", modifiers: .command)
        case .editorFocusCollectionSearch: return KeyBinding(key: "D", modifiers: .command)
        case .editorHighlightQueryTypes: return KeyBinding(key: "E", modifiers: .command)
        case .typesSaveCurrent: return KeyBinding(key: "S", modifiers: .command)
        case .searchResetDueDates: return KeyBinding(key: "R", modifiers: .command)
        }
    }
}
