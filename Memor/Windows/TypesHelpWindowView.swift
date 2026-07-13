//
//  TypesHelpWindowView.swift
//  Memor
//
//  Lightweight reference window describing what Types are, opened from the
//  help button next to the title on the Types page.
//

import SwiftUI

struct TypesHelpWindowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Types")
                    .font(.headline)

                Text("A type is the schema shared by its instances: a named set of data fields, the query types that turn those instances into flashcards, and the CSS that styles the rendered cards.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("A query type is a question/answer pair of HTML templates. {{FieldName}} placeholders splice in each instance's field values, so one query type defines a flashcard for every instance of the type.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This page lists your types. Create new ones with Add Type, or open a type to edit its fields, query types, and CSS with a live preview. Edit Global HTML and Edit Global CSS edit the shared wrapper that every card in the app renders inside.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Person, PointMap, and BoundaryMap are built-in types—they can't be renamed or deleted, and parts of them (Person's protected fields and built-in queries, the map types' editors) are managed by the app.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Deleting a type is destructive: all of its instances, and their queries, are deleted with it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 440)
        .onExitCommand { dismiss() }
        .background(
            // Reliable Escape-to-close even when no control holds focus.
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }
}
