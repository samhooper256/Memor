//
//  DescriptionField.swift
//  Memor
//
//  Shared, standardized description UI used by both Collections and Stacks so their
//  description editor and list display look identical. The debounced save lives in each
//  page (each owns which AppDatabase update method to call); these views are purely visual.
//

import SwiftUI

/// The free-text description editor: a multi-line plain-text box with a "Description"
/// placeholder shown while empty. Matches the styling shared by Collections and Stacks.
struct DescriptionEditor: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Description")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
            PlainTextEditor(text: $text)
                .frame(minHeight: 60)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }
}

/// The read-only description display shown in list rows/cards. Renders nothing when the
/// description is empty; otherwise a two-line truncated subheadline.
struct DescriptionDisplay: View {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var body: some View {
        if !description.isEmpty {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
