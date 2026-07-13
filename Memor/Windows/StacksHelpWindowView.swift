//
//  StacksHelpWindowView.swift
//  Memor
//
//  Lightweight reference window describing what Stacks are, opened from the
//  help button next to the stack count on the Stacks page.
//

import SwiftUI

private struct StackColorLegendEntry: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
    let description: String
}

// Colors mirror the per-stack query counts on the stack cards.
private let stackColorLegend: [StackColorLegendEntry] = [
    StackColorLegendEntry(
        name: "Blue",
        color: .blue,
        description: "New — never studied."
    ),
    StackColorLegendEntry(
        name: "Red",
        color: .red,
        description: "Being learned — studied, but its interval is still under a day."
    ),
    StackColorLegendEntry(
        name: "Green",
        color: .green,
        description: "Answered correctly, but its interval is still under a day."
    ),
    StackColorLegendEntry(
        name: "Magenta",
        color: Color(nsColor: .magenta),
        description: "Mature — its interval is a day or more."
    )
]

struct StacksHelpWindowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What Are Stacks?")
                    .font(.headline)

                Text("A stack is a saved search over your queries: a named \"deck of flashcards\" containing every query that matches its search text. Click a stack to study it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Stacks don't own their queries—one query can be in multiple stacks simultaneously. Membership is recomputed from the search on every refresh, so new queries that match join automatically. Editing a stack's search changes what it contains. Deleting a stack never deletes any queries.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Each stack card counts its queries by study state:")
                    .font(.callout)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stackColorLegend) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(entry.name)
                                .foregroundStyle(entry.color)
                                .fontWeight(.medium)
                                .frame(width: 80, alignment: .leading)

                            Text(entry.description)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Text("Studying a stack shows overdue red queries first, then draws randomly from the blue and green pools. Your rating (Again, Hard, Good, or Easy) shrinks or grows each query's interval, which decides when you'll see it next.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("To create a stack, click Add Stack: it opens the Search window in Queries mode, where you can refine a search until it matches the queries you want, then save it as a stack.")
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
