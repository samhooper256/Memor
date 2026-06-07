//
//  SearchHelpWindowView.swift
//  Memor
//
//  Lightweight reference windows listing the search-query components, color-coded
//  to match the live highlighting in the search fields. Opened from the help
//  buttons next to the Search Instances / Search Queries boxes.
//
//  The two searches share almost all components; only instance search supports
//  the instance-only `:noqueries` flag, so each window gets its own component
//  list and the query-search window omits it.
//

import SwiftUI

// Colors mirror `applySearchQueryHighlighting` in SearchHighlightingTextView.swift.
private let searchOperatorColor = Color(nsColor: .systemBlue)
private let searchLogicalColor = Color(nsColor: .systemGreen)
private let searchPunctuationColor = Color(nsColor: .systemGray)

private struct SearchHelpComponent: Identifiable {
    let id = UUID()
    let segments: [(text: String, color: Color?)]
    let description: String

    var syntaxText: Text {
        segments.reduce(Text(verbatim: "")) { partial, segment in
            var piece = Text(verbatim: segment.text)
            if let color = segment.color {
                piece = piece.foregroundColor(color)
            }
            return partial + piece
        }
    }
}

// Components shared by both instance and query search.
private let sharedSearchHelpComponents: [SearchHelpComponent] = [
    SearchHelpComponent(
        segments: [("literal:", searchOperatorColor), ("text", nil)],
        description: "Match items with a field containing text. A bare word with no prefix works the same way."
    ),
    SearchHelpComponent(
        segments: [("type:", searchOperatorColor), ("name", nil)],
        description: "Restrict to items of the named type."
    ),
    SearchHelpComponent(
        segments: [("collection:", searchOperatorColor), ("name", nil)],
        description: "Restrict to items in the named collection."
    ),
    SearchHelpComponent(
        segments: [("col:", searchOperatorColor), ("name", nil)],
        description: "Shorthand for collection:."
    ),
    SearchHelpComponent(
        segments: [("id:", searchOperatorColor), ("number", nil)],
        description: "Restrict to the single instance with this ID."
    ),
    SearchHelpComponent(
        segments: [("OR", searchLogicalColor)],
        description: "Match if either neighboring component matches. Components are otherwise combined with AND."
    ),
    SearchHelpComponent(
        segments: [("NOT", searchLogicalColor)],
        description: "Exclude whatever the following component matches."
    ),
    SearchHelpComponent(
        segments: [("(", searchPunctuationColor), (" … ", nil), (")", searchPunctuationColor)],
        description: "Group components to control how OR and AND combine."
    ),
    SearchHelpComponent(
        segments: [("\"", searchPunctuationColor), ("literal:hi there", nil), ("\"", searchPunctuationColor)],
        description: "Wrap a component in double quotes to include spaces."
    )
]

// Instance-only component.
private let noQueriesSearchHelpComponent = SearchHelpComponent(
    segments: [(":noqueries", searchOperatorColor)],
    description: "Match only instances that have no query types enabled."
)

private let instanceSearchHelpComponents: [SearchHelpComponent] =
    sharedSearchHelpComponents + [noQueriesSearchHelpComponent]

private let querySearchHelpComponents: [SearchHelpComponent] = sharedSearchHelpComponents

private struct SearchHelpContentView: View {
    @Environment(\.dismiss) private var dismiss

    let heading: String
    let components: [SearchHelpComponent]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(heading)
                    .font(.headline)

                Text("Separate components with spaces to combine them with AND. An empty search matches everything.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(components) { component in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            component.syntaxText
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(width: 130, alignment: .leading)

                            Text(component.description)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 460)
        .onExitCommand { dismiss() }
        .background(
            // Reliable Escape-to-close even when no control holds focus.
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }
}

struct InstanceSearchHelpWindowView: View {
    var body: some View {
        SearchHelpContentView(
            heading: "Instance Search Components",
            components: instanceSearchHelpComponents
        )
    }
}

struct QuerySearchHelpWindowView: View {
    var body: some View {
        SearchHelpContentView(
            heading: "Query Search Components",
            components: querySearchHelpComponents
        )
    }
}

struct SearchHelpButton: View {
    @Environment(\.openWindow) private var openWindow

    let windowID: String

    var body: some View {
        Button {
            openWindow(id: windowID)
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 16))
        }
        .buttonStyle(.borderless)
        .help("Show search syntax help")
    }
}
