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

/// Tracks the rename popovers currently on screen so a window-level ⌘Return
/// handler (the instance editor's) can commit the open rename BEFORE it acts.
/// Needed for the same reason as PickerPopoverEscapeRegistry: the editor's
/// local key monitor sees the chord before the popover's field editor can
/// whenever the key event targets the editor window rather than the popover,
/// so without this ⌘Return saved and closed the instance around the popover
/// and the typed name was lost. Popovers register onAppear and unregister
/// onDisappear, keyed by a per-presentation token; realistically one is open
/// at a time, but the keyed order keeps an overlapping sequence correct.
final class RenamePopoverSubmitRegistry {
    static let shared = RenamePopoverSubmitRegistry()

    enum CommitOutcome {
        /// No rename popover is open — the caller proceeds as usual.
        case noneOpen
        /// The open popover's name was accepted (its owner dismissed it).
        case committed
        /// The open popover rejected the name and is showing the error in
        /// place — the caller stops and leaves it up.
        case rejected
    }

    private var commitsByToken: [UUID: () -> Bool] = [:]
    private var order: [UUID] = []

    func register(_ token: UUID, commit: @escaping () -> Bool) {
        if commitsByToken[token] == nil {
            order.append(token)
        }
        commitsByToken[token] = commit
    }

    func unregister(_ token: UUID) {
        commitsByToken[token] = nil
        order.removeAll { $0 == token }
    }

    /// Commits the most recently opened popover's rename.
    func commitTopmost() -> CommitOutcome {
        guard let token = order.last, let commit = commitsByToken[token] else { return .noneOpen }
        return commit() ? .committed : .rejected
    }
}

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
    @State private var submitToken = UUID()

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
        .onAppear {
            RenamePopoverSubmitRegistry.shared.register(submitToken) { commit() }
        }
        .onDisappear {
            RenamePopoverSubmitRegistry.shared.unregister(submitToken)
        }
    }

    /// Returns true once the owner accepted the name (it then dismisses the
    /// popover); false leaves the popover up showing the owner's error.
    @discardableResult
    private func commit() -> Bool {
        errorMessage = onCommit(text)
        return errorMessage == nil
    }
}
