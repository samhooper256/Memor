//
//  InstancesHelpWindowView.swift
//  Memor
//
//  Lightweight reference window describing what Instances are, opened from the
//  help button next to the title on the Instances page.
//

import SwiftUI

struct InstancesHelpWindowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What Are Instances?")
                    .font(.headline)

                Text("An instance is one concrete \"thing\" of a type, described by that type's fields. If a ChemicalElement type defines Name and Symbol fields, the instance for oxygen stores \"Oxygen\" and \"O\".")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Select a type in the sidebar to see its instances in the table. The first column shows each instance's display field. Every other column is one of the type's query types—question/answer templates rendered with the instance's field values.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Each checkbox enables that query for that instance. An enabled query is a flashcard—it starts new (blue), joins any stacks whose search matches it, and carries its own study history. Unchecking it removes the flashcard and its study history.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Instances can be grouped into collections—one instance can be in multiple collections simultaneously, and one collection can hold instances of different types. Searches can then target a collection by name.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Use Add Instance to create instances, or double-click a row to edit one. Deleting an instance deletes its queries with it.")
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
