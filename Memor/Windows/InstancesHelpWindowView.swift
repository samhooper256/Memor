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
                Text("Instances")
                    .font(.headline)

                Text("An instance is a data object: it stores information about something you want to remember. Every instance has a type, which describes what data fields the instance stores.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("The left sidebar of this page lists all of your types. When you click a type in the sidebar, the central table displays all the instances of that type. The first column shows each instance's display field. Every other column shows one of the query types attached to that type.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Each checkbox toggles the corresponding query for the row's instance. An enabled query is a flashcard—it starts New (blue), joins any stacks whose search matches it, and carries its own study history. Unchecking a box deletes the flashcard and its study history.")
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
