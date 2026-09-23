//
//  RenamePopover.swift
//  Memor
//
//  The app-standard "Rename X" popover: headline, name field (Return commits),
//  an in-place error line, Cancel/Rename buttons. Present it with
//  `.popover(item:)` scoped to ONE row (see ManageBoundariesWindowView's
//  scopedRenameItem) so a list-wide target doesn't open it from every row.
//

import SwiftUI

struct RenamePopover: View {
    let title: String
    let placeholder: String
    let initialName: String
    /// Returns an error message to show in place (the popover stays open so
    /// the name can be corrected), or nil once the owner accepted the name —
    /// the owner then dismisses the popover by clearing its item.
    let onCommit: (String) -> String?
    let onCancel: () -> Void

    @State private var text: String
    @State private var errorMessage: String?

    init(
        title: String,
        placeholder: String,
        initialName: String,
        onCommit: @escaping (String) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.initialName = initialName
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            TextField(placeholder, text: $text)
                .solidFocusField()
                .frame(width: 240)
                .onSubmit { commit() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func commit() {
        errorMessage = onCommit(text)
    }
}
